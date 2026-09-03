import 'dart:async';
import 'dart:io';

import 'request.dart';
import 'response.dart';

/// Server-Sent Events (SSE) context for push-based HTTP streaming.
///
/// Use inside a regular route handler to upgrade the connection to a
/// persistent event stream. The client receives data in the standard
/// `text/event-stream` format, compatible with the browser's `EventSource` API.
///
/// ```dart
/// Route.get(
///   path: '/events',
///   handler: (req) async {
///     final sse = await SseContext.from(req);
///
///     // Push an event every second.
///     final timer = Timer.periodic(Duration(seconds: 1), (_) {
///       sse.send(data: 'ping', event: 'heartbeat');
///     });
///
///     // Wait until the client disconnects.
///     await sse.done;
///     timer.cancel();
///
///     return sse.response; // signals the framework the response was handled
///   },
/// )
/// ```
///
/// ### SSE Wire Format (RFC 8895)
/// ```
/// id: 42
/// event: update
/// data: {"key":"value"}
///
/// ```
/// Each field is separated by a newline; events are separated by a blank line.
class SseContext {
  final HttpResponse _httpResponse;
  final Completer<void> _done = Completer();

  SseContext._(this._httpResponse);

  /// Upgrades the current request to an SSE stream.
  ///
  /// Sets the required `Content-Type: text/event-stream` and
  /// `Cache-Control: no-cache` headers, disables Nagle's algorithm
  /// for low-latency delivery, and starts the keep-alive ping loop.
  ///
  /// [keepAliveInterval] — interval between empty comment pings sent to keep
  ///   proxies and load balancers from closing the idle connection.
  ///   Defaults to 15 seconds. Set to `Duration.zero` to disable.
  static Future<SseContext> from(
    Request req, {
    Duration keepAliveInterval = const Duration(seconds: 15),
  }) async {
    // ignore: close_sinks — lifecycle is managed by SseContext.close() / done
    final httpResponse = req.raw.response;

    httpResponse.statusCode = 200;
    httpResponse.headers
      ..set('content-type', 'text/event-stream; charset=utf-8')
      ..set('cache-control', 'no-cache')
      ..set('connection', 'keep-alive')
      ..set('x-accel-buffering', 'no'); // Disable nginx buffering
    httpResponse.bufferOutput = false;

    final ctx = SseContext._(httpResponse);

    // Mark done when the client disconnects.
    unawaited(req.raw.response.done.then((_) {
      if (!ctx._done.isCompleted) ctx._done.complete();
    }).catchError((_) {
      if (!ctx._done.isCompleted) ctx._done.complete();
    }));

    // Start keep-alive ping loop.
    if (keepAliveInterval > Duration.zero) {
      _startKeepAlive(ctx, keepAliveInterval);
    }

    return ctx;
  }

  /// A [Future] that completes when the client disconnects.
  ///
  /// Await this in your handler to keep the connection open until the
  /// client closes it. After awaiting, cancel any timers or subscriptions.
  Future<void> get done => _done.future;

  /// Whether the connection is still open.
  bool get isOpen => !_done.isCompleted;

  /// Sends an SSE event to the connected client.
  ///
  /// [data] — the event payload (required). Multi-line strings are split
  ///   automatically into multiple `data:` lines as per the spec.
  ///
  /// [event] — optional named event type. The client's `EventSource` can
  ///   filter by event name: `source.addEventListener('update', handler)`.
  ///
  /// [id] — optional event ID. The client sends this back in
  ///   `Last-Event-ID` on reconnect, enabling resumable streams.
  ///
  /// [retry] — optional reconnection interval in milliseconds.
  ///
  /// Does nothing if the connection is already closed.
  void send({
    required String data,
    String? event,
    String? id,
    int? retry,
  }) {
    if (_done.isCompleted) return;

    final buf = StringBuffer();

    if (id != null) buf.writeln('id: $id');
    if (event != null) buf.writeln('event: $event');
    if (retry != null) buf.writeln('retry: $retry');

    // Split multi-line data into multiple data: fields.
    for (final line in data.split('\n')) {
      buf.writeln('data: $line');
    }

    buf.writeln(); // Blank line terminates the event.

    try {
      _httpResponse.write(buf.toString());
    } catch (_) {
      // Client disconnected mid-write.
      if (!_done.isCompleted) _done.complete();
    }
  }

  /// Sends a raw comment line (`:  message`).
  ///
  /// Browsers ignore comment lines — useful as keep-alive pings.
  void sendComment(String comment) {
    if (_done.isCompleted) return;
    try {
      _httpResponse.write(': $comment\n\n');
    } catch (_) {
      if (!_done.isCompleted) _done.complete();
    }
  }

  /// Closes the SSE stream from the server side.
  Future<void> close() async {
    if (!_done.isCompleted) {
      await _httpResponse.close();
      _done.complete();
    }
  }

  /// A sentinel [Response] to return from the route handler after the SSE
  /// stream ends. The framework's [_writeResponse] is guarded with try/catch,
  /// so the no-op attempt to write this sentinel to an already-closed
  /// connection is silently swallowed.
  Response get response => const Response(statusCode: 200);
}

/// Sends a keep-alive comment ping on [interval] until the connection closes.
void _startKeepAlive(SseContext ctx, Duration interval) {
  Timer.periodic(interval, (timer) {
    if (!ctx.isOpen) {
      timer.cancel();
      return;
    }
    ctx.sendComment('keep-alive');
  });
}
