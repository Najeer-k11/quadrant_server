import 'dart:convert';
import 'dart:typed_data';

import '../middleware.dart';
import '../request.dart';
import '../response.dart';
import '../middlewares/body_parser.dart';

/// Form body parser middleware.
///
/// Parses `application/x-www-form-urlencoded` request bodies (standard HTML
/// form submissions) into `req.body` as a `Map<String, String>`.
///
/// Combine with [bodyParser] to support both JSON and form bodies:
///
/// ```dart
/// middlewares: [bodyParser(), formParser()]
/// ```
///
/// Or on specific routes:
///
/// ```dart
/// Route.post(
///   path: '/auth/login',
///   handler: loginHandler,
///   middlewares: [formParser()],
/// )
///
/// // In handler:
/// final form = req.body as Map<String, String>?;
/// final username = form?['username'];
/// ```
///
/// [maxBodyBytes] — maximum number of bytes to read. Returns `413` if exceeded.
///   Defaults to 64 KB. Set to `0` to disable.
Middleware formParser({int maxBodyBytes = 65536}) {
  return (Request req, Next next) async {
    final contentType = req.headers['content-type'] ?? '';

    if (!contentType.contains('application/x-www-form-urlencoded')) {
      return next();
    }

    try {
      // Stream bytes with limit.
      // BytesBuilder stores 1 byte per byte; a List<int> would use 8.
      final bodyBytes = BytesBuilder(copy: false);
      await for (final chunk in req.raw) {
        bodyBytes.add(chunk);
        if (maxBodyBytes > 0 && bodyBytes.length > maxBodyBytes) {

          return Response(
            statusCode: 413,
            headers: {'content-type': 'application/json'},
            body: '{"error":"Payload Too Large","maxBytes":$maxBodyBytes}',
          );
        }
      }

      if (bodyBytes.isEmpty) return await next();

      final bodyString = utf8.decode(bodyBytes.takeBytes());
      final parsed = Uri.splitQueryString(bodyString);

      // Store via RequestHolder so _executeChain propagates it.
      RequestHolder.instance.setParsedBody(req.raw, parsed);
    } on FormatException {
      return Response.badRequest('Invalid form body');
    }

    return next();
  };
}
