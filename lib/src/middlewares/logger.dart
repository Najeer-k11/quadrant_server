import '../middleware.dart';
import '../request.dart';

/// Logger middleware. Logs method, path, status code, and response time.
///
/// [output] — optional sink for log lines. Defaults to [print].
///
/// ```dart
/// // Default: print to stdout
/// logger()
///
/// // Custom sink — redirect to your logging framework
/// logger(output: (line) => myLogger.info(line))
/// ```
Middleware logger({void Function(String line)? output}) {
  final log = output ?? print;
  return (Request req, Next next) async {
    final stopwatch = Stopwatch()..start();
    final response = await next();
    stopwatch.stop();

    log(
      '${req.method} ${req.path} → ${response.statusCode} '
      '(${stopwatch.elapsedMilliseconds}ms)',
    );

    return response;
  };
}
