import 'dart:convert';

import '../middleware.dart';
import '../request.dart';
import '../response.dart';

/// ETag middleware.
///
/// Automatically generates a weak ETag for every response body and handles
/// the `If-None-Match` conditional request header.
///
/// - If the response body hasn't changed, returns `304 Not Modified`
///   (no body, saving bandwidth).
/// - Skips ETag generation for responses that already have an `etag` header,
///   for non-2xx responses, or for empty bodies.
///
/// ```dart
/// middlewares: [etag()]
/// ```
///
/// The ETag is a simple FNV-1a hash of the response body bytes, formatted
/// as a weak ETag: `W/"<hash>"`. This is fast, deterministic, and avoids
/// any cryptographic overhead.
Middleware etag() {
  return (Request req, Next next) async {
    final response = await next();

    // Only generate ETags for successful responses with a body.
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return response;
    }
    if (response.body.isEmpty) return response;
    if (response.headers.containsKey('etag')) return response;

    final tag = _weakEtag(response.body);

    // Check If-None-Match.
    final ifNoneMatch = req.headers['if-none-match'];
    if (ifNoneMatch != null && ifNoneMatch == tag) {
      return Response(
        statusCode: 304,
        headers: {'etag': tag},
        cookies: response.cookies,
      );
    }

    return Response(
      statusCode: response.statusCode,
      headers: {...response.headers, 'etag': tag},
      body: response.body,
      cookies: response.cookies,
    );
  };
}

/// Computes a weak ETag using FNV-1a hash of the UTF-8 body bytes.
String _weakEtag(String body) {
  final bytes = utf8.encode(body);
  var hash = 0x811c9dc5; // FNV offset basis (32-bit)
  for (final byte in bytes) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xFFFFFFFF; // FNV prime, 32-bit wrap
  }
  return 'W/"${hash.toRadixString(16)}"';
}
