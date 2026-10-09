import 'dart:convert';
import 'dart:io';

import '../middleware.dart';
import '../request.dart';
import '../response.dart';

/// Body parser middleware. Reads the request body stream, JSON-decodes it,
/// and makes the parsed body available to downstream middlewares and handlers
/// via the [RequestHolder] in the middleware chain runner.
///
/// Parses if Content-Type contains application/json.
/// Supports both top-level JSON objects (`Map`) and arrays (`List`).
///
/// [maxBodyBytes] — maximum number of bytes to read from the request body.
/// Requests exceeding this limit receive a `413 Payload Too Large` response.
/// Defaults to 1 MB (1,048,576 bytes). Set to `0` to disable the limit.
Middleware bodyParser({int maxBodyBytes = 1048576}) {
  return (Request req, Next next) async {
    final contentType = req.headers['content-type'] ?? '';

    if (contentType.contains('application/json')) {
      try {
        // Stream the body, counting bytes to enforce the size limit.
        final bodyBytes = <int>[];
        await for (final chunk in req.raw) {
          bodyBytes.addAll(chunk);
          if (maxBodyBytes > 0 && bodyBytes.length > maxBodyBytes) {

            return Response(
              statusCode: 413,
              headers: {'content-type': 'application/json'},
              body:
                  '{"error":"Payload Too Large","maxBytes":$maxBodyBytes}',
            );
          }
        }

        if (bodyBytes.isNotEmpty) {
          final bodyString = utf8.decode(bodyBytes);
          final decoded = jsonDecode(bodyString);
          if (decoded is Map<String, dynamic> || decoded is List<dynamic>) {
            // Store the parsed body so downstream middlewares and the handler
            // can access it. Keyed on the HttpRequest object itself via
            // Expando — true identity, zero hash-collision risk.
            RequestHolder.instance.setParsedBody(req.raw, decoded as Object);
          }
        }
      } on FormatException {
        // JSON parse / UTF-8 decode failure — client's fault.
        return Response.badRequest('Invalid JSON body');
      }
      // Any other exception (e.g. socket error) propagates up to the
      // framework's outer catch, which triggers the global error handler.
    }

    return next();
  };
}

/// Holds parsed request bodies so they can be propagated through the
/// middleware chain without mutating the immutable [Request].
///
/// Uses [Expando] keyed on the [HttpRequest] object for guaranteed identity
/// (no hash-collision risk under concurrent load).
///
/// This is an internal mechanism — not part of the public API.
class RequestHolder {
  RequestHolder._();
  static final instance = RequestHolder._();

  /// Expando keyed on HttpRequest — identity-safe, no hash collisions.
  final Expando<Object> _bodies = Expando('quadrant_body');

  void setParsedBody(HttpRequest req, Object body) {
    _bodies[req] = body;
  }

  Object? consumeParsedBody(HttpRequest req) {
    final body = _bodies[req];
    _bodies[req] = null;
    return body;
  }
}
