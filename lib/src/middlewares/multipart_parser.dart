import 'dart:convert';
import 'dart:typed_data';

import '../middleware.dart';
import '../request.dart';
import '../response.dart';

/// Represents a single uploaded file from a multipart form.
class UploadedFile {
  /// The `name` attribute of the `<input type="file">` field.
  final String fieldName;

  /// The original filename reported by the browser (may be empty).
  final String filename;

  /// The MIME type reported by the browser. May be `application/octet-stream`
  /// if the browser didn't provide one.
  final String mimeType;

  /// The raw file bytes.
  final Uint8List bytes;

  /// File size in bytes.
  int get size => bytes.length;

  const UploadedFile({
    required this.fieldName,
    required this.filename,
    required this.mimeType,
    required this.bytes,
  });

  @override
  String toString() =>
      'UploadedFile(fieldName: $fieldName, filename: $filename, '
      'mimeType: $mimeType, size: $size)';
}

/// Multipart form-data parser middleware.
///
/// Parses `multipart/form-data` request bodies (file uploads) and injects
/// the results into `req.context`:
///
/// - `req.context['files']` — `List<UploadedFile>` — uploaded files
/// - `req.context['fields']` — `Map<String, String>` — non-file form fields
///
/// Files are buffered entirely in memory. For very large files, consider
/// writing to disk yourself using `req.raw` and parsing the stream manually.
///
/// ```dart
/// middlewares: [multipartParser()]
///
/// // Or per-route:
/// Route.post(
///   path: '/upload',
///   handler: uploadHandler,
///   middlewares: [multipartParser(maxFileSize: 10 * 1024 * 1024)],
/// )
///
/// // In handler:
/// final files  = req.context['files']  as List<UploadedFile>;
/// final fields = req.context['fields'] as Map<String, String>;
///
/// final avatar = files.firstWhere((f) => f.fieldName == 'avatar');
/// // Never use the client-supplied filename as a path. Generate your own:
/// final savedName = '${DateTime.now().microsecondsSinceEpoch}.bin';
/// await File('uploads/$savedName').writeAsBytes(avatar.bytes);
/// ```
///
/// [maxFileSize] — maximum bytes per individual file. Defaults to 10 MB.
///   Returns `413` if any file exceeds this limit.
/// [maxTotalBytes] — maximum size of the whole request body (all files and
///   fields together). Defaults to 50 MB. Returns `413` if exceeded. Set to
///   `0` to disable. Keep it at least as large as [maxFileSize].
/// [filesContextKey] — key for files in context. Defaults to `'files'`.
/// [fieldsContextKey] — key for fields in context. Defaults to `'fields'`.
Middleware multipartParser({
  int maxFileSize = 10 * 1024 * 1024,
  int maxTotalBytes = 50 * 1024 * 1024,
  String filesContextKey = 'files',
  String fieldsContextKey = 'fields',
}) {
  return (Request req, Next next) async {
    final contentType = req.headers['content-type'] ?? '';
    if (!contentType.contains('multipart/form-data')) {
      return next();
    }

    // Extract boundary from Content-Type header.
    final boundary = _extractBoundary(contentType);
    if (boundary == null) {
      return Response.badRequest('Missing multipart boundary');
    }

    try {
      // Reject early when the client already declares a body that is too big.
      if (maxTotalBytes > 0 && req.raw.contentLength > maxTotalBytes) {
        return _tooLarge(maxTotalBytes);
      }

      // Read the body, enforcing the total size limit while streaming.
      final bodyBytes = <int>[];
      await for (final chunk in req.raw) {
        bodyBytes.addAll(chunk);
        if (maxTotalBytes > 0 && bodyBytes.length > maxTotalBytes) {
          return _tooLarge(maxTotalBytes);
        }
      }

      final result = _parseMultipart(
        Uint8List.fromList(bodyBytes),
        boundary,
        maxFileSize,
      );

      if (result == null) {
        return Response.badRequest('Malformed multipart body');
      }

      if (result.oversized) {
        return Response(
          statusCode: 413,
          headers: {'content-type': 'application/json'},
          body:
              '{"error":"Payload Too Large","maxFileBytes":$maxFileSize}',
        );
      }

      // Store via Expando for _executeChain to propagate.
      _multipartOverrides[req.raw] = {
        ...req.context,
        filesContextKey: result.files,
        fieldsContextKey: result.fields,
      };

      final response = await next();
      _multipartOverrides[req.raw] = null;
      return response;
    } catch (_) {
      return Response.badRequest('Invalid multipart body');
    }
  };
}

// ─── Parsing ─────────────────────────────────────────────────

class _MultipartResult {
  final List<UploadedFile> files;
  final Map<String, String> fields;
  final bool oversized;

  _MultipartResult(this.files, this.fields, {this.oversized = false});
}

Response _tooLarge(int maxTotalBytes) => Response(
      statusCode: 413,
      headers: {'content-type': 'application/json'},
      body: '{"error":"Payload Too Large","maxBytes":$maxTotalBytes}',
    );

String? _extractBoundary(String contentType) {
  for (final part in contentType.split(';')) {
    final trimmed = part.trim();
    if (trimmed.startsWith('boundary=')) {
      return trimmed.substring('boundary='.length).trim().replaceAll('"', '');
    }
  }
  return null;
}

_MultipartResult? _parseMultipart(
    Uint8List body, String boundary, int maxFileSize) {
  final files = <UploadedFile>[];
  final fields = <String, String>{};

  // Delimiter: \r\n--<boundary>
  final delimiter = '--$boundary';
  final delimiterBytes = ascii.encode(delimiter);

  int pos = 0;

  // Skip preamble up to first delimiter.
  pos = _indexOf(body, delimiterBytes, pos);
  if (pos == -1) return null;
  pos += delimiterBytes.length;

  while (pos < body.length) {
    // After delimiter: either \r\n (part follows) or -- (end).
    if (pos + 1 < body.length &&
        body[pos] == 45 && body[pos + 1] == 45) {
      break; // closing --boundary--
    }
    if (pos + 1 < body.length &&
        body[pos] == 13 && body[pos + 1] == 10) {
      pos += 2; // skip \r\n after delimiter
    } else {
      pos++;
    }

    // Parse headers until \r\n\r\n.
    final headerEnd = _indexOf(body, [13, 10, 13, 10], pos);
    if (headerEnd == -1) return null;

    final headerBytes = body.sublist(pos, headerEnd);
    final headerStr = utf8.decode(headerBytes, allowMalformed: true);
    pos = headerEnd + 4; // skip \r\n\r\n

    // Find next delimiter.
    final nextDelim = _indexOf(body, ascii.encode('\r\n$delimiter'), pos);
    final partEnd = nextDelim == -1 ? body.length : nextDelim;

    final partBytes = body.sublist(pos, partEnd);
    pos = nextDelim == -1
        ? body.length
        : nextDelim + 2 + delimiterBytes.length; // skip \r\n + delimiter

    // Parse part headers.
    final headers = _parsePartHeaders(headerStr);
    final disposition = headers['content-disposition'] ?? '';
    final partName = _extractParam(disposition, 'name') ?? '';
    final filename = _extractParam(disposition, 'filename');
    final mimeType = headers['content-type'] ?? 'application/octet-stream';

    if (filename != null) {
      // File part.
      if (partBytes.length > maxFileSize) {
        return _MultipartResult([], {}, oversized: true);
      }
      files.add(UploadedFile(
        fieldName: partName,
        filename: filename,
        mimeType: mimeType,
        bytes: Uint8List.fromList(partBytes),
      ));
    } else {
      // Text field.
      fields[partName] = utf8.decode(partBytes, allowMalformed: true);
    }
  }

  return _MultipartResult(files, fields);
}

Map<String, String> _parsePartHeaders(String raw) {
  final result = <String, String>{};
  for (final line in raw.split('\r\n')) {
    final idx = line.indexOf(':');
    if (idx == -1) continue;
    result[line.substring(0, idx).trim().toLowerCase()] =
        line.substring(idx + 1).trim();
  }
  return result;
}

String? _extractParam(String header, String param) {
  final pattern = RegExp('$param="([^"]*)"');
  final match = pattern.firstMatch(header);
  if (match != null) return match.group(1);
  // Unquoted value.
  final pattern2 = RegExp('$param=([^;\\s]+)');
  return pattern2.firstMatch(header)?.group(1);
}

int _indexOf(Uint8List haystack, List<int> needle, [int start = 0]) {
  outer:
  for (var i = start; i <= haystack.length - needle.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

// ─── Context propagation ──────────────────────────────────────

final _multipartOverrides =
    Expando<Map<String, dynamic>>('quadrant_multipart');

/// Internal — consumed by [QuadrantServer._executeChain].
Map<String, dynamic>? consumeMultipartContext(Object rawRequest) {
  final val = _multipartOverrides[rawRequest];
  if (val != null) _multipartOverrides[rawRequest] = null;
  return val;
}
