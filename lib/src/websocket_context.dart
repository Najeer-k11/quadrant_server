import 'dart:io';

import 'request.dart';

/// Per-connection WebSocket context passed to every callback.
///
/// Wraps the underlying [WebSocket] with a clean API.
/// The original HTTP upgrade [request] is preserved so callbacks have
/// access to path params, query params, and headers.
class WebSocketContext {
  final WebSocket _socket;

  /// The original HTTP upgrade request.
  ///
  /// Use [request.params], [request.query], and [request.headers]
  /// to read connection-specific data. [request.body] is always empty
  /// for WebSocket connections.
  final Request request;

  const WebSocketContext({
    required WebSocket socket,
    required this.request,
  }) : _socket = socket;

  /// Package-private access to the raw socket for internal dispatch.
  WebSocket get socket => _socket;

  /// Sends [data] to the connected client.
  ///
  /// [data] must be a [String] (text frame) or [List<int>] (binary frame).
  void send(Object data) => _socket.add(data);

  /// Closes the connection with an optional [code] and [reason].
  Future<void> close([int? code, String? reason]) =>
      _socket.close(code, reason);

  /// Upgrades an HTTP request to a WebSocket and returns a [WebSocketContext].
  ///
  /// Used internally by [QuadrantServer] — not part of the public handler API.
  static Future<WebSocketContext> fromUpgrade(Request request) async {
    final socket = await WebSocketTransformer.upgrade(request.raw);
    return WebSocketContext(socket: socket, request: request);
  }
}
