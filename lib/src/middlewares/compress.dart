import 'dart:convert';
import 'dart:io';

import '../middleware.dart';
import '../request.dart';
import '../response.dart';

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

    final newHeaders = <String, String>{
      ...response.headers,
      'content-encoding': 'gzip',
      'content-length': '${compressed.length}',
      'vary': _mergeVary(response.headers['vary'], 'Accept-Encoding'),
    };

    final compressedResponse = Response(
      statusCode: response.statusCode,
      headers: newHeaders,
      body: '', // body will be written as raw bytes by _writeResponse
      cookies: response.cookies,
    );

    _compressedBodies[_CompressKey(compressedResponse)] = compressed;

    return compressedResponse;
  };
}

/// Merges an existing `Vary` header value with a new directive.
String _mergeVary(String? existing, String directive) {
  if (existing == null || existing.isEmpty) return directive;
  if (existing.contains(directive)) return existing;
  return '$existing, $directive';
}

// ─── Compressed body store ────────────────────────────────────

/// Key used to store compressed bytes keyed by Response identity.
class _CompressKey {
  final Response response;
  _CompressKey(this.response);
  @override
  bool operator ==(Object other) =>
      other is _CompressKey && identical(response, other.response);
  @override
  int get hashCode => identityHashCode(response);
}

final _compressedBodies = <_CompressKey, List<int>>{};

/// Internal — retrieves and removes compressed bytes for a response.
/// Called by [QuadrantServer._writeResponse].
List<int>? consumeCompressedBody(Response response) {
  return _compressedBodies.remove(_CompressKey(response));
}
