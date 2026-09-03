import 'dart:io';

import '../request.dart';
import '../response.dart';
import '../route.dart';

/// Returns a [Handler] that serves static files from [rootDir].
///
/// Designed to be used with a wildcard route:
/// ```dart
/// Route.get(path: '/static/*', handler: staticFiles('./public'))
/// ```
///
/// Features:
/// - **Path traversal protection** — rejects any path that escapes [rootDir].
/// - **MIME-type detection** — sets correct `Content-Type` for common types.
/// - **ETag + Last-Modified** headers for efficient browser caching.
/// - **304 Not Modified** support — avoids re-sending unchanged files.
/// - **index.html fallback** — serves `index.html` for bare directory requests
///   when [indexFallback] is `true` (default).
///
/// [rootDir] — path to the directory to serve. May be relative or absolute.
/// [indexFallback] — when true, serve `index.html` for directory requests.
Handler staticFiles(String rootDir, {bool indexFallback = true}) {
  final root = Directory(rootDir).absolute;

  return (Request req) async {
    // The wildcard captures everything after the route prefix.
    // e.g. for '/static/*' matching '/static/images/logo.png',
    // params['*'] == 'images/logo.png'
    final relativePath = req.params['*'] ?? '';

    // Normalize using URI to collapse '..' segments before the check.
    // Dart's File.absolute does NOT resolve '..' — only Uri does.
    final rootUri = Uri.directory(root.path);
    final resolvedUri = rootUri.resolve(relativePath).normalizePath();
    final resolvedPath = resolvedUri.toFilePath();

    // Reject if the resolved path escapes the root directory.
    if (!resolvedPath.startsWith(root.path)) {
      return Response.forbidden('Access denied');
    }

    File target = File(resolvedPath);

    // index.html fallback for directory requests.
    if (await Directory(resolvedPath).exists()) {
      if (!indexFallback) {
        return Response.notFound('Not found');
      }
      target = File('$resolvedPath/index.html');
    }

    if (!await target.exists()) {
      return Response.notFound('Not found');
    }

    final stat = await target.stat();
    final lastModified = stat.modified.toUtc();
    final etag = '"${stat.size}-${lastModified.millisecondsSinceEpoch}"';

    // Check conditional request headers.
    final ifNoneMatch = req.headers['if-none-match'];
    final ifModifiedSince = req.headers['if-modified-since'];

    if (ifNoneMatch != null && ifNoneMatch == etag) {
      return Response(statusCode: 304, headers: {'etag': etag});
    }

    if (ifModifiedSince != null) {
      try {
        final clientDate = HttpDate.parse(ifModifiedSince);
        if (!lastModified.isAfter(clientDate)) {
          return Response(
              statusCode: 304,
              headers: {'last-modified': HttpDate.format(lastModified)});
        }
      } catch (_) {
        // Malformed date — ignore and serve the file.
      }
    }

    final bytes = await target.readAsBytes();
    final mime = _mimeType(target.path);

    // Build headers.
    final headers = <String, String>{
      'content-type': mime,
      'content-length': '${bytes.length}',
      'etag': etag,
      'last-modified': HttpDate.format(lastModified),
      'cache-control': 'public, max-age=3600',
    };

    // Write raw bytes directly via the dart:io response.
    // We bypass Response.body (String) to avoid UTF-8 corruption of
    // binary assets (images, fonts, etc.).
    req.raw.response.statusCode = 200;
    headers.forEach(req.raw.response.headers.set);
    req.raw.response.add(bytes);
    await req.raw.response.close();

    // Return a sentinel — body already written above.
    return const Response(statusCode: 200);
  };
}

/// Maps common file extensions to MIME types.
String _mimeType(String path) {
  final ext = path.contains('.') ? path.split('.').last.toLowerCase() : '';
  return const {
    'html': 'text/html; charset=utf-8',
    'htm': 'text/html; charset=utf-8',
    'css': 'text/css; charset=utf-8',
    'js': 'application/javascript; charset=utf-8',
    'mjs': 'application/javascript; charset=utf-8',
    'json': 'application/json',
    'xml': 'application/xml',
    'txt': 'text/plain; charset=utf-8',
    'md': 'text/markdown; charset=utf-8',
    'svg': 'image/svg+xml',
    'png': 'image/png',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'gif': 'image/gif',
    'webp': 'image/webp',
    'ico': 'image/x-icon',
    'woff': 'font/woff',
    'woff2': 'font/woff2',
    'ttf': 'font/ttf',
    'otf': 'font/otf',
    'pdf': 'application/pdf',
    'zip': 'application/zip',
    'mp4': 'video/mp4',
    'webm': 'video/webm',
    'mp3': 'audio/mpeg',
    'wav': 'audio/wav',
  }[ext] ??
      'application/octet-stream';
}
