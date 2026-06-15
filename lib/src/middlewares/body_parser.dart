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
Middleware bodyParser() {
  return (Request req, Next next) async {
    final contentType = req.headers['content-type'] ?? '';

    if (contentType.contains('application/json')) {
      try {
        final bodyString = await utf8.decoder.bind(req.raw).join();
        if (bodyString.isNotEmpty) {
          final decoded = jsonDecode(bodyString);
          if (decoded is Map<String, dynamic> || decoded is List<dynamic>) {
            // Store the parsed body so downstream middlewares and the handler
            // can access it. Keyed on the HttpRequest object itself via
            // Expando — true identity, zero hash-collision risk.
            RequestHolder.instance.setParsedBody(req.raw, decoded as Object);
          }
        }
      } catch (_) {
        return Response.badRequest('Invalid JSON body');
      }
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
