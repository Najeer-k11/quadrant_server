import 'dart:convert';

import 'package:quadrant_server/quadrant_server.dart';

// ─── Chat room registry ───────────────────────────────────────

/// One [WebSocketGroup] per room ID.
/// Rooms are created on first join and removed when the last user leaves.
final Map<String, WebSocketGroup> _rooms = {};

WebSocketGroup _room(String id) =>
    _rooms.putIfAbsent(id, () => WebSocketGroup());

// ─── Presence tracker ─────────────────────────────────────────

/// Maps WebSocketContext → display name (set on first message).
final Map<WebSocketContext, String> _names = {};

String _nameOf(WebSocketContext ctx) =>
    _names[ctx] ?? 'User#${ctx.hashCode.toRadixString(16).substring(0, 4)}';

// ─── Chat route callbacks ─────────────────────────────────────

/// Called once immediately after the WebSocket upgrade.
///
/// Sends a welcome payload and broadcasts a "joined" event to the room.
Future<void> chatOnStart(WebSocketContext ctx) async {
  final roomId = ctx.request.params['roomId'] ?? 'general';
  _room(roomId).add(ctx);

  // Welcome the new connection with room metadata.
  ctx.sendJson({
    'event': 'welcome',
    'room': roomId,
    'online': _room(roomId).length,
    'hint': 'Send {"name":"YourName"} to set your display name.',
  });

  // Announce to everyone else already in the room.
  _room(roomId).broadcastJson(
    {
      'event': 'user_joined',
      'room': roomId,
      'online': _room(roomId).length,
    },
    exclude: ctx,
  );
}

/// Called for every incoming message frame.
///
/// Supports two message formats:
///   1. JSON `{"name": "Alice"}` — sets the sender's display name.
///   2. Anything else — broadcast as a chat message to the whole room.
Future<void> chatOnMessage(WebSocketContext ctx, dynamic data) async {
  final roomId = ctx.request.params['roomId'] ?? 'general';

  // Try to parse JSON control messages.
  if (data is String) {
    try {
      final json = jsonDecode(data) as Map<String, dynamic>;

      // Name-setting control message.
      if (json.containsKey('name')) {
        final name = (json['name'] as String).trim();
        if (name.isNotEmpty) {
          _names[ctx] = name;
          ctx.sendJson({'event': 'name_set', 'name': name});
          _room(roomId).broadcastJson(
            {'event': 'user_renamed', 'name': name},
            exclude: ctx,
          );
          return;
        }
      }

      // Regular JSON chat message — broadcast with sender info.
      _room(roomId).broadcastJson({
        'event': 'message',
        'from': _nameOf(ctx),
        'data': json,
      }, exclude: ctx);
      return;
    } catch (_) {
      // Not JSON — treat as plain text chat message.
    }
  }

  // Plain text or binary broadcast.
  _room(roomId).broadcastJson({
    'event': 'message',
    'from': _nameOf(ctx),
    'data': data,
  }, exclude: ctx);
}

/// Called when the connection closes.
///
/// Removes the client from the room, broadcasts a "left" event,
/// and cleans up empty rooms.
Future<void> chatOnClose(
  WebSocketContext ctx,
  int? code,
  String? reason,
) async {
  final roomId = ctx.request.params['roomId'] ?? 'general';
  final name = _nameOf(ctx);

  _room(roomId).remove(ctx);
  _names.remove(ctx);

  _room(roomId).broadcastJson({
    'event': 'user_left',
    'name': name,
    'online': _room(roomId).length,
  });

  // Clean up empty rooms to prevent memory leaks.
  if (_room(roomId).isEmpty) _rooms.remove(roomId);

  // ignore: avoid_print
  print('[WS] "$name" left room "$roomId" — code: $code, reason: $reason');
}

/// Called when a stream error occurs on the connection.
Future<void> chatOnError(WebSocketContext ctx, Object error) async {
  // ignore: avoid_print
  print('[WS] Error for ${_nameOf(ctx)}: $error');
}

// ─── Ping / echo route callbacks ─────────────────────────────

/// Simple ping–pong echo WebSocket — useful for connection health checks.
///
/// Any message received is echoed back with a timestamp.
Future<void> pingOnMessage(WebSocketContext ctx, dynamic data) async {
  ctx.sendJson({
    'event': 'pong',
    'echo': data,
    'ts': DateTime.now().millisecondsSinceEpoch,
  });
}
