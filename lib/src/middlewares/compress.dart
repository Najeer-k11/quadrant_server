import 'dart:convert';
import 'dart:io';

import '../middleware.dart';
import '../request.dart';
import '../stream_response.dart';

/// Gzip response compression middleware.
///
/// Compresses response bodies using `dart:io`'s built-in [GZipCodec].
/// Only compresses if:
/// 1. The client sends `Accept-Encoding: gzip` (or `*`)
/// 2. The response body is at least [minBytes] in size
/// 3. The response doesn't already have a `Content-Encoding` header
///
/// Sets `Content-Encoding: gzip` and `Vary: Accept-Encoding` on compressed
/// responses.
///
/// The compressed bytes travel inside a [StreamResponse], so other
/// middlewares (helmet, cors, ...) can still add headers to the response
/// without losing the body, whatever the middleware order is.
///
/// ```dart
/// middlewares: [compress()]
/// compress(minBytes: 1024)  // skip responses smaller than 1 KB
/// ```
///
/// [minBytes] — minimum body size to compress. Defaults to 512 bytes.
///   Smaller responses are returned unmodified (compression overhead
///   can make tiny responses larger, not smaller).
Middleware compress({int minBytes = 512}) {
  return (Request req, Next next) async {
    final response = await next();

    // Check if the client accepts gzip.
    final acceptEncoding = req.headers['accept-encoding'] ?? '';
    final acceptsGzip = acceptEncoding.contains('gzip') ||
        acceptEncoding.contains('*');

    if (!acceptsGzip) return response;

    // Skip if already encoded, empty, or too small.
    if (response.headers.containsKey('content-encoding')) return response;
    if (response.body.isEmpty) return response;

    final bodyBytes = utf8.encode(response.body);
    if (bodyBytes.length < minBytes) return response;

    // Compress.
    final compressed = GZipCodec().encode(bodyBytes);

    return StreamResponse(
      stream: Stream<List<int>>.value(compressed),
      statusCode: response.statusCode,
      headers: <String, String>{
        ...response.headers,
        'content-encoding': 'gzip',
        'content-length': '${compressed.length}',
        'vary': _mergeVary(response.headers['vary'], 'Accept-Encoding'),
      },
      cookies: response.cookies,
    );
  };
}

/// Merges an existing `Vary` header value with a new directive.
String _mergeVary(String? existing, String directive) {
  if (existing == null || existing.isEmpty) return directive;
  if (existing.contains(directive)) return existing;
  return '$existing, $directive';
}
