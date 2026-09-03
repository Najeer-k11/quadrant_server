import 'dart:async';

import '../middleware.dart';
import '../request.dart';
import '../response.dart';

/// Request timeout middleware.
///
/// Races the downstream handler chain against a deadline. If the deadline
/// expires first, the middleware returns a `408 Request Timeout` response
/// (or a custom response from [onTimeout]) without waiting for the handler.
///
/// ```dart
/// // Global 30-second timeout:
/// middlewares: [timeout(Duration(seconds: 30))]
///
/// // Strict 5-second limit on a specific route with a custom message:
/// Route.post(
///   path: '/slow-endpoint',
///   handler: slowHandler,
///   middlewares: [
///     timeout(
///       Duration(seconds: 5),
///       onTimeout: (req) => Response.badRequest('Processing took too long'),
///     ),
///   ],
/// )
/// ```
///
/// [duration] — maximum time allowed before the timeout fires.
/// [onTimeout] — optional factory for the timeout response. Receives the
///   original [Request]. Defaults to `408 Request Timeout`.
Middleware timeout(
  Duration duration, {
  Response Function(Request req)? onTimeout,
}) {
  return (Request req, Next next) async {
    try {
      return await next().timeout(
        duration,
        onTimeout: () =>
            onTimeout?.call(req) ??
            Response(
              statusCode: 408,
              headers: {'content-type': 'application/json'},
              body: '{"error":"Request Timeout",'
                  '"timeoutMs":${duration.inMilliseconds}}',
            ),
      );
    } on TimeoutException {
      // Fallback — should not normally be reached since onTimeout handles it.
      return onTimeout?.call(req) ??
          Response(
            statusCode: 408,
            headers: {'content-type': 'application/json'},
            body: '{"error":"Request Timeout",'
                '"timeoutMs":${duration.inMilliseconds}}',
          );
    }
  };
}
