import 'middleware.dart';
import 'websocket_context.dart';

/// Called once immediately after the WebSocket upgrade succeeds.
/// Use for welcome messages, logging, or initialising connection state.
typedef OnStartCallback = Future<void> Function(WebSocketContext ctx);

/// Called for every incoming message frame.
///
/// [data] is a [String] (text frame) or [List<int>] (binary frame).
typedef OnMessageCallback = Future<void> Function(
    WebSocketContext ctx, dynamic data);

/// Called when the connection closes, either by the client or server.
///
/// [code] and [reason] may be null.
typedef OnCloseCallback = Future<void> Function(
    WebSocketContext ctx, int? code, String? reason);

/// Called when a stream error occurs on the connection.
typedef OnErrorCallback = Future<void> Function(
    WebSocketContext ctx, Object error);

/// Declares a WebSocket endpoint.
///
/// Analogous to [Route] for HTTP handlers. Matches incoming `GET` requests
/// that carry an `Upgrade: websocket` header.
///
/// Only [onMessage] is required. The other three callbacks are optional —
/// omit any that are not needed for the use case.
///
/// Route-level [middlewares] run before the upgrade. If a middleware returns
/// a [Response] (e.g. auth rejection), the framework writes it as an HTTP
/// response and the upgrade never happens.
class WebSocketRoute {
  /// The URL path for this WebSocket endpoint.
  ///
  /// Supports path parameters: `/ws/orders/:orderId`, `/ws/rooms/:roomId`.
  final String path;

  /// Middlewares that run before the WebSocket upgrade.
  ///
  /// Same [Middleware] type used for HTTP routes. A rejection here (e.g.
  /// `Response.unauthorized(...)`) prevents the upgrade entirely.
  final List<Middleware> middlewares;

  /// Called once after upgrade succeeds. Optional.
  final OnStartCallback? onStart;

  /// Called for every incoming message frame. Required.
  final OnMessageCallback onMessage;

  /// Called when the connection closes. Optional.
  final OnCloseCallback? onClose;

  /// Called when a stream error occurs. Optional.
  final OnErrorCallback? onError;

  const WebSocketRoute({
    required this.path,
    required this.onMessage,
    this.middlewares = const [],
    this.onStart,
    this.onClose,
    this.onError,
  });
}
