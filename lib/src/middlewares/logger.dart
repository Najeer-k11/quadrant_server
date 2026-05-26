import '../middleware.dart';
import '../request.dart';

/// Logger middleware. Logs method, path, status code, and response time.
Middleware logger() {
  return (Request req, Next next) async {
    final stopwatch = Stopwatch()..start();
    final response = await next();
    stopwatch.stop();

    print(
      '${req.method} ${req.path} → ${response.statusCode} '
      '(${stopwatch.elapsedMilliseconds}ms)',
    );

    return response;
  };
}
