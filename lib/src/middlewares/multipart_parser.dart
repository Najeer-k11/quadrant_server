import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../core/middleware.dart';
import '../core/request.dart';
import '../core/response.dart';
import '../utils/request_body.dart';

/// Represents a single uploaded file from a multipart form.
///
/// A file is held in memory unless `multipartParser(diskThreshold:)` moved it
/// to a temporary file. [readAsBytes], [openRead] and [moveTo] work either way.
///
/// A temporary file is deleted once the response is ready, so call [moveTo] to
/// keep it, and finish reading before the handler returns. That includes a
/// `StreamResponse`: do not return one that reads from [openRead].
class UploadedFile {
  /// The `name` attribute of the `<input type="file">` field.
  final String fieldName;

  /// The original filename reported by the browser (may be empty).
  ///
  /// This comes from the client. Never use it as a path.
  final String filename;

  /// The MIME type reported by the browser. May be `application/octet-stream`
  /// if the browser didn't provide one.
  final String mimeType;

  /// File size in bytes.
  final int size;

  final Uint8List? _bytes;
  File? _file;

  UploadedFile({
    required this.fieldName,
    required this.filename,
    required this.mimeType,
    required Uint8List bytes,
  })  : size = bytes.length,
        _bytes = bytes,
        _file = null;

  UploadedFile._onDisk({
    required this.fieldName,
    required this.filename,
    required this.mimeType,
    required this.size,
    required File file,
  })  : _bytes = null,
        _file = file;

  /// Whether the contents are in memory, so that [bytes] can be used.
  bool get isInMemory => _bytes != null;

  /// Where the file is on disk, or null if it is in memory.
  String? get path => _file?.path;

  /// The raw file bytes.
  ///
  /// Throws a [StateError] if the file is on disk. Use [readAsBytes], [openRead]
  /// or [moveTo] in code that may receive such a file.
  Uint8List get bytes {
    final bytes = _bytes;
    if (bytes != null) return bytes;
    throw StateError(
      'UploadedFile "$filename" is on disk, because of diskThreshold. Use '
      'readAsBytes(), openRead() or moveTo().',
    );
  }

  /// The whole file in memory, wherever it is now. Avoid this for big files.
  Future<Uint8List> readAsBytes() async => _bytes ?? await _file!.readAsBytes();

  /// The file as a stream, wherever it is now.
  Stream<List<int>> openRead() {
    final bytes = _bytes;
    return bytes != null ? Stream.value(bytes) : _file!.openRead();
  }

  /// Saves the file at [path], without copying it if it can be avoided.
  ///
  /// Never build [path] from [filename], which comes from the client.
  Future<void> moveTo(String path) async {
    final file = _file;
    if (file == null) {
      await File(path).writeAsBytes(_bytes!);
      return;
    }
    try {
      _file = await file.rename(path);
    } on FileSystemException {
      // A rename cannot cross file systems.
      await file.copy(path);
      await file.delete();
      _file = File(path);
    }
  }

  @override
  String toString() =>
      'UploadedFile(fieldName: $fieldName, filename: $filename, '
      'mimeType: $mimeType, size: $size)';
}

/// Multipart form-data parser middleware.
///
/// Parses `multipart/form-data` request bodies (file uploads) as they arrive,
/// and injects the results into `req.context`:
///
/// - `req.context['files']` — `List<UploadedFile>` — uploaded files
/// - `req.context['fields']` — `Map<String, String>` — non-file form fields
///
/// Files are held in memory until the handler finishes, unless [diskThreshold]
/// is set. Set it if you accept big files or many uploads at once.
///
/// ```dart
/// middlewares: [multipartParser()]
///
/// // Or per-route, keeping anything over 1 MB on disk:
/// Route.post(
///   path: '/upload',
///   handler: uploadHandler,
///   middlewares: [
///     multipartParser(
///       maxFileSize: 500 * 1024 * 1024,
///       maxTotalBytes: 500 * 1024 * 1024,
///       diskThreshold: 1024 * 1024,
///     ),
///   ],
/// )
///
/// // In handler:
/// final files  = req.context['files']  as List<UploadedFile>;
/// final fields = req.context['fields'] as Map<String, String>;
///
/// final avatar = files.firstWhere((f) => f.fieldName == 'avatar');
/// // Never use the client-supplied filename as a path. Generate your own:
/// final savedName = '${DateTime.now().microsecondsSinceEpoch}.bin';
/// await avatar.moveTo('uploads/$savedName');
/// ```
///
/// [maxFileSize] — maximum bytes per individual file. Defaults to 10 MB.
///   Returns `413` as soon as a file passes this limit.
/// [maxTotalBytes] — maximum size of the whole request body (all files and
///   fields together). Defaults to 50 MB. Returns `413` if exceeded. Set to
///   `0` to disable. Keep it at least as large as [maxFileSize].
/// [diskThreshold] — files bigger than this many bytes go to a temporary file,
///   which is deleted once the response is ready. Defaults to `null`, which
///   keeps every file in memory. If the process is killed, temporary files are
///   left behind, in directories named `quadrant_upload_*`.
/// [tempDirectory] — where temporary files go. Defaults to the system's
///   temporary directory. Each request gets a directory inside it that only
///   this user can read, using the `chmod` command except on Windows. Without
///   `chmod` such uploads fail with an error, so set this to a directory only
///   your server can read. Uploads can fill the disk it is on: [maxTotalBytes]
///   limits one request, not all of them together.
/// [maxBufferedBytes] — the most upload data all `multipartParser()`s on this
///   isolate may hold in memory at once. Defaults to 256 MB. Past it, files go
///   to disk if [diskThreshold] is set, and otherwise the request gets a `503`.
///   Set to `0` to disable. Each isolate of a `QuadrantCluster` has its own
///   count, but they share one heap, so divide the memory you can spare.
/// [maxParts] — maximum number of files and fields in one request. Defaults to
///   1,000. Returns `413` if exceeded. Set to `0` to disable.
/// [maxFieldBytes] — maximum total size of the text fields in one request,
///   which are always in memory. Defaults to 10 MB. Returns `413` if exceeded.
///   Set to `0` to disable.
/// [filesContextKey] — key for files in context. Defaults to `'files'`.
/// [fieldsContextKey] — key for fields in context. Defaults to `'fields'`.
Middleware multipartParser({
  int maxFileSize = 10 * 1024 * 1024,
  int maxTotalBytes = 50 * 1024 * 1024,
  int? diskThreshold,
  Directory? tempDirectory,
  int maxBufferedBytes = 256 * 1024 * 1024,
  int maxParts = 1000,
  int maxFieldBytes = 10 * 1024 * 1024,
  String filesContextKey = 'files',
  String fieldsContextKey = 'fields',
}) {
  if (diskThreshold != null && diskThreshold < 0) {
    throw ArgumentError.value(
        diskThreshold, 'diskThreshold', 'Must not be negative.');
  }

  return (Request req, Next next) async {
    final contentType = req.headers['content-type'] ?? '';
    if (!contentType.contains('multipart/form-data')) {
      return next();
    }

    // Extract boundary from Content-Type header.
    final boundary = _extractBoundary(contentType);
    if (boundary == null || boundary.isEmpty) {
      return Response.badRequest('Missing multipart boundary');
    }

    final store = _UploadStore(
      maxFileSize: maxFileSize,
      maxBufferedBytes: maxBufferedBytes,
      maxParts: maxParts,
      maxFieldBytes: maxFieldBytes,
      diskThreshold: diskThreshold,
      tempDirectory: tempDirectory,
    );

    try {
      final rejection = await _readBody(req, boundary, store, maxTotalBytes);
      if (rejection != null) return rejection;

      // Store via Expando for _executeChain to propagate.
      _multipartOverrides[req.raw] = {
        ...req.context,
        filesContextKey: store.files,
        fieldsContextKey: store.fields,
      };

      // Awaited so that the files stay until the handler has finished. An error
      // from a handler is not a malformed upload, so it passes through.
      return await next();
    } finally {
      await store.dispose();
    }
  };
}

/// Parses the body into [store]. Returns a response if it was rejected.
Future<Response?> _readBody(
  Request req,
  String boundary,
  _UploadStore store,
  int maxTotalBytes,
) async {
  try {
    // Reject early when the client already declares a body that is too big.
    if (maxTotalBytes > 0 && req.raw.contentLength > maxTotalBytes) {
      abandonBody(req.raw);
      return _tooLarge('maxBytes', maxTotalBytes);
    }

    final parser = MultipartStreamParser(
      boundary,
      onPartStart: store.startPart,
      onData: store.addData,
      onPartEnd: store.endPart,
    );

    // Awaiting each chunk pauses the socket while a slow disk catches up.
    var received = 0;
    await for (final chunk in readBody(req.raw)) {
      received += chunk.length;
      if (maxTotalBytes > 0 && received > maxTotalBytes) {
        return _tooLarge('maxBytes', maxTotalBytes);
      }
      await parser.add(chunk);
    }
    parser.close();
    return null;
  } on _Rejected catch (rejected) {
    return rejected.response;
  } on MultipartFormatException {
    return Response.badRequest('Malformed multipart body');
  } on FileSystemException {
    // A full disk is the server's problem, not a bad request from the client.
    rethrow;
  } catch (_) {
    // For example, the client disconnected.
    return Response.badRequest('Invalid multipart body');
  }
}

Response _tooLarge(String limitName, int limit) => Response(
      statusCode: 413,
      headers: {'content-type': 'application/json'},
      body: '{"error":"Payload Too Large","$limitName":$limit}',
    );

// ─── Storing uploads ─────────────────────────────────────────

/// Upload bytes held in memory by this isolate's requests.
var _bufferedBytes = 0;

class _Rejected implements Exception {
  final Response response;
  const _Rejected(this.response);
}

/// Receives one request's parts, keeping them in memory or on disk.
class _UploadStore {
  final int maxFileSize;
  final int maxBufferedBytes;
  final int maxParts;
  final int maxFieldBytes;
  final int? diskThreshold;
  final Directory? tempDirectory;

  final List<UploadedFile> files = [];
  final Map<String, String> fields = {};

  int _heldBytes = 0;
  int _fieldBytes = 0;
  int _parts = 0;
  int _nextFile = 0;
  Directory? _directory;

  // The part being received.
  String _name = '';
  String? _filename;
  String _mimeType = '';
  int _size = 0;
  BytesBuilder _memory = BytesBuilder(copy: false);
  File? _file;
  RandomAccessFile? _output;

  _UploadStore({
    required this.maxFileSize,
    required this.maxBufferedBytes,
    required this.maxParts,
    required this.maxFieldBytes,
    required this.diskThreshold,
    required this.tempDirectory,
  });

  void startPart(Uint8List rawHeaders) {
    if (maxParts > 0 && ++_parts > maxParts) {
      throw _Rejected(_tooLarge('maxParts', maxParts));
    }
    final headers =
        _parsePartHeaders(utf8.decode(rawHeaders, allowMalformed: true));
    final disposition = headers['content-disposition'] ?? '';
    _name = _extractParam(disposition, 'name') ?? '';
    _filename = _extractParam(disposition, 'filename');
    _mimeType = headers['content-type'] ?? 'application/octet-stream';
    _size = 0;
    _memory = BytesBuilder(copy: false);
    _file = null;
  }

  Future<void> addData(Uint8List data) async {
    _size += data.length;
    if (_filename == null) {
      _addFieldData(data);
    } else {
      await _addFileData(data);
    }
  }

  void _addFieldData(Uint8List data) {
    _fieldBytes += data.length;
    if (maxFieldBytes > 0 && _fieldBytes > maxFieldBytes) {
      throw _Rejected(_tooLarge('maxFieldBytes', maxFieldBytes));
    }
    _holdInMemory(data);
  }

  Future<void> _addFileData(Uint8List data) async {
    if (_size > maxFileSize) {
      throw _Rejected(_tooLarge('maxFileBytes', maxFileSize));
    }

    final threshold = diskThreshold;
    if (_output == null &&
        threshold != null &&
        (_size > threshold || !_fitsInMemory(data.length))) {
      await _moveToDisk();
    }

    final output = _output;
    if (output != null) {
      await output.writeFrom(data);
    } else {
      _holdInMemory(data);
    }
  }

  bool _fitsInMemory(int length) =>
      maxBufferedBytes <= 0 || _bufferedBytes + length <= maxBufferedBytes;

  void _holdInMemory(Uint8List data) {
    if (!_fitsInMemory(data.length)) {
      throw const _Rejected(Response(
        statusCode: 503,
        headers: {'content-type': 'application/json', 'retry-after': '5'},
        body: '{"error":"Service Unavailable"}',
      ));
    }
    _bufferedBytes += data.length;
    _heldBytes += data.length;
    _memory.add(data);
  }

  Future<void> _moveToDisk() async {
    final directory = _directory ??= await _createPrivateDirectory();
    // Our own name, because the client's filename must not become a path.
    final file = _file = File('${directory.path}/${_nextFile++}');
    final output = _output = await file.open(mode: FileMode.writeOnly);

    final held = _memory.takeBytes();
    await output.writeFrom(held);
    _release(held.length);
  }

  Future<Directory> _createPrivateDirectory() async {
    final directory = await (tempDirectory ?? Directory.systemTemp)
        .createTemp('quadrant_upload_');
    _directory = directory; // So that dispose() removes it, if this fails.
    if (Platform.isWindows) return directory; // Already private to the user.

    // createTemp makes it readable by every user, and dart:io has no chmod.
    // Nothing is written until this is done.
    var private = false;
    try {
      final result = await Process.run('chmod', ['700', directory.path]);
      private = result.exitCode == 0;
    } on ProcessException {
      // No chmod on this system.
    }
    // In a shared directory, an upload must not be readable by others. A
    // tempDirectory of your own is yours to protect.
    if (!private && tempDirectory == null) {
      throw FileSystemException(
        'Could not make the upload directory private. Set tempDirectory to a '
        'directory only this server can read.',
        directory.path,
      );
    }
    return directory;
  }

  void _release(int length) {
    _bufferedBytes -= length;
    _heldBytes -= length;
  }

  Future<void> endPart() async {
    final filename = _filename;
    if (filename == null) {
      fields[_name] = utf8.decode(_memory.takeBytes(), allowMalformed: true);
      return;
    }

    final output = _output;
    if (output != null) {
      _output = null;
      await output.close();
      files.add(UploadedFile._onDisk(
        fieldName: _name,
        filename: filename,
        mimeType: _mimeType,
        size: _size,
        file: _file!,
      ));
    } else {
      files.add(UploadedFile(
        fieldName: _name,
        filename: filename,
        mimeType: _mimeType,
        bytes: _memory.takeBytes(),
      ));
    }
  }

  /// Gives back the memory and deletes what is left on disk. Never throws, so
  /// that it cannot replace the response.
  Future<void> dispose() async {
    _bufferedBytes -= _heldBytes;
    _heldBytes = 0;

    try {
      await _output?.close();
    } catch (_) {
      // Only the delete below matters now.
    }
    _output = null;

    final directory = _directory;
    if (directory == null) return;
    _directory = null;
    try {
      await directory.delete(recursive: true);
    } catch (error) {
      // ignore: avoid_print
      print('[multipartParser] Could not delete ${directory.path}: $error');
    }
  }
}

// ─── Parsing ─────────────────────────────────────────────────

/// Thrown by [MultipartStreamParser] for a body that is not valid multipart.
class MultipartFormatException implements Exception {
  final String message;
  const MultipartFormatException(this.message);

  @override
  String toString() => 'MultipartFormatException: $message';
}

enum _ParserState { preamble, afterDelimiter, headers, body, epilogue }

/// Splits a multipart body into parts as its chunks arrive, holding on to no
/// more than it needs to recognise a delimiter split across two chunks.
///
/// The bytes given to `onData` are only views of the chunk they came from.
///
/// Internal, and not exported from the package.
class MultipartStreamParser {
  /// A single part's headers cannot grow past this.
  static const maxHeaderBytes = 16 * 1024;

  static final _headersEnd = Uint8List.fromList(const [13, 10, 13, 10]);
  static final _nothing = Uint8List(0);

  final void Function(Uint8List rawHeaders) onPartStart;
  final Future<void> Function(Uint8List data) onData;
  final Future<void> Function() onPartEnd;

  /// `\r\n--boundary`. A delimiter always starts on a new line.
  final Uint8List _delimiter;

  // Starts with a line break, so the very first delimiter looks like any other.
  Uint8List _pending = Uint8List.fromList(const [13, 10]);
  _ParserState _state = _ParserState.preamble;

  MultipartStreamParser(
    String boundary, {
    required this.onPartStart,
    required this.onData,
    required this.onPartEnd,
  }) : _delimiter = Uint8List.fromList(ascii.encode('\r\n--$boundary'));

  /// Parses [chunk]. Wait for the result before adding the next one.
  Future<void> add(Uint8List chunk) async {
    final data = _pending.isEmpty ? chunk : _join(_pending, chunk);
    var pos = 0;

    parsing:
    while (true) {
      switch (_state) {
        case _ParserState.preamble:
          final found = _indexOf(data, _delimiter, pos);
          if (found == -1) {
            pos = _keepForDelimiter(data, pos);
            break parsing;
          }
          pos = found + _delimiter.length;
          _state = _ParserState.afterDelimiter;

        case _ParserState.afterDelimiter:
          // A delimiter line may end in spaces and tabs.
          while (pos < data.length && (data[pos] == 32 || data[pos] == 9)) {
            pos++;
          }
          if (data.length - pos < 2) break parsing;
          if (data[pos] == 45 && data[pos + 1] == 45) {
            _state = _ParserState.epilogue; // closing --boundary--
          } else if (data[pos] == 13 && data[pos + 1] == 10) {
            // The line break stays, so that a part with no headers at all is
            // found by the same search as any other.
            _state = _ParserState.headers;
          } else {
            throw const MultipartFormatException(
                'A delimiter is followed by something else.');
          }

        case _ParserState.headers:
          final found = _indexOf(data, _headersEnd, pos);
          if (found == -1 && data.length - pos > maxHeaderBytes ||
              found - pos > maxHeaderBytes) {
            throw const MultipartFormatException('Part headers are too big.');
          }
          if (found == -1) break parsing;
          onPartStart(found == pos
              ? _nothing
              : Uint8List.sublistView(data, pos + 2, found));
          pos = found + _headersEnd.length;
          _state = _ParserState.body;

        case _ParserState.body:
          final found = _indexOf(data, _delimiter, pos);
          if (found == -1) {
            final safeEnd = _keepForDelimiter(data, pos);
            if (safeEnd > pos) {
              await onData(Uint8List.sublistView(data, pos, safeEnd));
            }
            pos = safeEnd;
            break parsing;
          }
          if (found > pos) {
            await onData(Uint8List.sublistView(data, pos, found));
          }
          await onPartEnd();
          pos = found + _delimiter.length;
          _state = _ParserState.afterDelimiter;

        case _ParserState.epilogue:
          pos = data.length; // Anything after the end is ignored.
          break parsing;
      }
    }

    _pending = pos >= data.length
        ? _nothing
        : Uint8List.fromList(Uint8List.sublistView(data, pos));
  }

  /// Call after the last chunk. Only a closing delimiter proves that the whole
  /// body arrived, so anything else is an error.
  void close() {
    if (_state != _ParserState.epilogue) {
      throw const MultipartFormatException('The body ended early.');
    }
  }

  /// Where the bytes that could still be the start of a delimiter begin.
  int _keepForDelimiter(Uint8List data, int pos) {
    final safeEnd = data.length - (_delimiter.length - 1);
    return safeEnd > pos ? safeEnd : pos;
  }
}

Uint8List _join(Uint8List first, Uint8List second) =>
    Uint8List(first.length + second.length)
      ..setRange(0, first.length, first)
      ..setRange(first.length, first.length + second.length, second);

String? _extractBoundary(String contentType) {
  for (final part in contentType.split(';')) {
    final trimmed = part.trim();
    if (trimmed.startsWith('boundary=')) {
      return trimmed.substring('boundary='.length).trim().replaceAll('"', '');
    }
  }
  return null;
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
  // Starts at a separator, so that `name` does not match inside `filename`.
  final pattern = RegExp('(?:^|[;\\s])$param="([^"]*)"');
  final match = pattern.firstMatch(header);
  if (match != null) return match.group(1);
  // Unquoted value.
  final pattern2 = RegExp('(?:^|[;\\s])$param=([^;\\s]+)');
  return pattern2.firstMatch(header)?.group(1);
}

int _indexOf(Uint8List haystack, Uint8List needle, int start) {
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
