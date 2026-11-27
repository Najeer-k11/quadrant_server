import 'dart:convert';
import 'dart:io';

import '../core/middleware.dart';
import '../core/request.dart';
import '../core/response.dart';
import '../utils/request_body.dart';

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
        // Reject early when the client already declares a body that is too big.
        if (maxBodyBytes > 0 && req.raw.contentLength > maxBodyBytes) {
          abandonBody(req.raw);
          return _tooLarge(maxBodyBytes);
        }

        // Stream the body, counting bytes to enforce the size limit.
        final bodyBytes = await readBodyBytes(req.raw, maxBodyBytes);
        if (bodyBytes == null) return _tooLarge(maxBodyBytes);

        if (bodyBytes.isNotEmpty) {
          // Parsed straight from the bytes: the VM has a fast path for this
          // pair that skips building the whole body as a String first.
          final decoded = _utf8Json.convert(bodyBytes);
          if (decoded is Map<String, dynamic> || decoded is List<dynamic>) {
            // For the rest of the chain, which receives it as req.body.
            scopeOf(req).pendingBody = decoded;
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

Response _tooLarge(int maxBodyBytes) => Response(
      statusCode: 413,
      headers: {'content-type': 'application/json'},
      body: '{"error":"Payload Too Large","maxBytes":$maxBodyBytes}',
    );

final _utf8Json = utf8.decoder.fuse(json.decoder);

/// Hands a body parsed by a middleware of your own to the rest of the chain:
/// from the next step on, it is [Request.body].
///
/// ```dart
/// RequestHolder.instance.setParsedBody(req.raw, parsed);
/// return next();
/// ```
class RequestHolder {
  RequestHolder._();
  static final instance = RequestHolder._();

  final Expando<Object> _bodies = Expando('quadrant_body');

  /// Whether [setParsedBody] has ever been called, so that the framework
  /// only looks here if it has. The built-in parsers do not use it.
  static bool _used = false;

  void setParsedBody(HttpRequest req, Object body) {
    _used = true;
    _bodies[req] = body;
  }

  Object? consumeParsedBody(HttpRequest req) {
    if (!_used) return null;
    final body = _bodies[req];
    if (body != null) _bodies[req] = null;
    return body;
  }
}
