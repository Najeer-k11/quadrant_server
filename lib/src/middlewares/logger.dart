import 'dart:async';

import '../core/middleware.dart';
import '../core/request.dart';

/// Logger middleware. Logs method, path, status code, and response time.
///
/// [output] — optional sink for log lines, called once per request. Without
/// it, lines are printed in batches: every line logged while the server is
/// busy with one burst of work goes out in a single [print], straight after
/// it. One print per line costs a system call each, which under load is a
/// large share of a request.
///
/// ```dart
/// // Default: print to stdout
/// logger()
///
/// // Custom sink — redirect to your logging framework
/// logger(output: (line) => myLogger.info(line))
/// ```
Middleware logger({void Function(String line)? output}) {
  final log = output ?? _batchedPrint;
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

final _pending = StringBuffer();
var _flushScheduled = false;

/// Printed at once past this many characters, to bound the memory held.
const _flushAt = 16 * 1024;

void _batchedPrint(String line) {
  if (_pending.isNotEmpty) _pending.write('\n');
  _pending.write(line);
  if (_pending.length >= _flushAt) {
    _flush();
  } else if (!_flushScheduled) {
    _flushScheduled = true;
    // Runs once the events already waiting have been handled, so a line
    // appears within a millisecond or so, but a burst shares one print.
    Timer.run(_flush);
  }
}

void _flush() {
  _flushScheduled = false;
  if (_pending.isEmpty) return;
  final text = _pending.toString();
  _pending.clear();
  // ignore: avoid_print
  print(text);
}
