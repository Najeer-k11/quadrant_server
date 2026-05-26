import 'dart:convert';

import '../middleware.dart';
import '../request.dart';
import '../response.dart';

/// Body parser middleware. Reads the request body stream, JSON-decodes it,
/// and makes the parsed body available to downstream middlewares and handlers
/// via the [RequestHolder] in the Apex chain runner.
///
/// Only parses if Content-Type contains application/json.
Middleware bodyParser() {
  return (Request req, Next next) async {
    final contentType = req.headers['content-type'] ?? '';

    if (contentType.contains('application/json')) {
      try {
        final bodyString = await utf8.decoder.bind(req.raw).join();
        if (bodyString.isNotEmpty) {
          final decoded = jsonDecode(bodyString);
          if (decoded is Map<String, dynamic>) {
            // Store the parsed body on the RequestHolder so downstream
            // middlewares and the handler can access it.
            RequestHolder.instance.setParsedBody(req.raw.hashCode, decoded);
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
/// This is an internal mechanism — not part of the public API.
class RequestHolder {
  RequestHolder._();
  static final instance = RequestHolder._();

  final Map<int, Map<String, dynamic>> _bodies = {};

  void setParsedBody(int hash, Map<String, dynamic> body) {
    _bodies[hash] = body;
  }

  Map<String, dynamic>? consumeParsedBody(int hash) {
    return _bodies.remove(hash);
  }
}
