import 'dart:convert';
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
  /// to read connection-specific data. [request.body] is always null
  /// for WebSocket connections.
  final Request request;

  const WebSocketContext({
    required WebSocket socket,
    required this.request,
  }) : _socket = socket;

  /// Package-private access to the raw socket for internal dispatch.
  WebSocket get socket => _socket;

  // ─── Connection state ─────────────────────────────────────────

  /// Whether the WebSocket connection is currently open.
  ///
  /// Check this before calling [send] or [sendJson] to avoid
  /// throwing on a closed socket.
  bool get isOpen => _socket.readyState == WebSocket.open;

  /// Whether the WebSocket connection has been closed.
  bool get isClosed => !isOpen;

  // ─── Sending ──────────────────────────────────────────────────

  /// Sends [data] to the connected client.
  ///
  /// [data] must be a [String] (text frame) or [List<int>] (binary frame).
  /// Does nothing if the connection is already closed.
  void send(Object data) {
    if (isOpen) _socket.add(data);
  }

  /// JSON-encodes [data] and sends it as a text frame.
  ///
  /// Convenience wrapper around [send] for Map/List payloads.
  /// Does nothing if the connection is already closed.
  void sendJson(dynamic data) {
    if (isOpen) _socket.add(jsonEncode(data));
  }

  /// Closes the connection with an optional [code] and [reason].
  Future<void> close([int? code, String? reason]) =>
      _socket.close(code, reason);

  /// Upgrades an HTTP request to a WebSocket and returns a [WebSocketContext].
  ///
  /// Used internally by [QuadrantServer] — not part of the public handler API.
  /// The socket's lifecycle is managed by the caller; closing is intentional.
  static Future<WebSocketContext> fromUpgrade(Request request) async {
    // ignore: close_sinks
    final socket = await WebSocketTransformer.upgrade(request.raw);
    return WebSocketContext(socket: socket, request: request);
  }
}
