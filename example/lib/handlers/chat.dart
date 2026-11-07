import 'dart:convert';
import 'dart:math';

import 'package:quadrant_server/quadrant_server.dart';

const _maxMessageLength = 4096;
const _maxNameLength = 32;

final _validRoom = RegExp(r'^[A-Za-z0-9_-]{1,64}$');
final _random = Random();

// ─── Rooms ────────────────────────────────────────────────────

/// This isolate's members of each room, removed when the last one leaves.
///
/// A name makes groups with the same name on different isolates act as one, so
/// a broadcast reaches the whole room. `length` only counts this isolate, so
/// this app does not report how many people are online.
final Map<String, WebSocketGroup> _rooms = {};

WebSocketGroup _room(String id) =>
    _rooms.putIfAbsent(id, () => WebSocketGroup(name: 'room:$id'));

final Map<WebSocketContext, String> _names = {};

String _roomId(WebSocketContext ctx) => ctx.request.params['roomId']!;

/// Runs before the upgrade, so a bad name never becomes a connection.
Middleware validRoomId() => (Request req, Next next) async {
      if (!_validRoom.hasMatch(req.params['roomId'] ?? '')) {
        return Response.badRequest(
            'A room ID has 1 to 64 letters, digits, "-" or "_"');
      }
      return next();
    };

// ─── Chat callbacks ───────────────────────────────────────────

Future<void> chatOnStart(WebSocketContext ctx) async {
  final roomId = _roomId(ctx);
  final name =
      'Guest-${_random.nextInt(0x10000).toRadixString(16).padLeft(4, '0')}';
  _names[ctx] = name;
  _room(roomId).add(ctx);

  ctx.sendJson({
    'event': 'welcome',
    'room': roomId,
    'name': name,
    'hint': 'Send {"name":"YourName"} to set your display name.',
  });
  _room(roomId).broadcastJson(
    {'event': 'user_joined', 'room': roomId, 'name': name},
    exclude: ctx,
  );
}

/// Accepts `{"name": "Alice"}` to set a display name, and treats any other text
/// as a chat message.
Future<void> chatOnMessage(WebSocketContext ctx, dynamic data) async {
  if (data is! String) {
    ctx.sendJson({'event': 'error', 'message': 'Only text is accepted'});
    return;
  }
  if (data.length > _maxMessageLength) {
    ctx.sendJson({'event': 'error', 'message': 'That message is too long'});
    return;
  }

  final room = _room(_roomId(ctx));
  final json = _tryDecodeObject(data);
  final newName = json?['name'];

  if (newName is String && newName.trim().isNotEmpty) {
    final name = newName.trim();
    if (name.length > _maxNameLength) {
      ctx.sendJson({'event': 'error', 'message': 'That name is too long'});
      return;
    }
    final oldName = _names[ctx];
    _names[ctx] = name;
    ctx.sendJson({'event': 'name_set', 'name': name});
    room.broadcastJson(
      {'event': 'user_renamed', 'from': oldName, 'name': name},
      exclude: ctx,
    );
    return;
  }

  room.broadcastJson(
    {'event': 'message', 'from': _names[ctx], 'data': json ?? data},
    exclude: ctx,
  );
}

Future<void> chatOnClose(WebSocketContext ctx, int? code, String? reason) async {
  final roomId = _roomId(ctx);
  final name = _names.remove(ctx);
  final room = _room(roomId)..remove(ctx);
  room.broadcastJson({'event': 'user_left', 'name': name});
  if (room.isEmpty) _rooms.remove(roomId);
}

Future<void> chatOnError(WebSocketContext ctx, Object error) async {
  // ignore: avoid_print
  print('[WS] Error for ${_names[ctx]}: $error');
}

Map<String, dynamic>? _tryDecodeObject(String text) {
  try {
    final decoded = jsonDecode(text);
    return decoded is Map<String, dynamic> ? decoded : null;
  } on FormatException {
    return null;
  }
}

// ─── Ping ─────────────────────────────────────────────────────

/// Echoes each message with a timestamp, to test that a connection works.
Future<void> pingOnMessage(WebSocketContext ctx, dynamic data) async {
  ctx.sendJson({
    'event': 'pong',
    'echo': data is String ? data : '(binary)',
    'ts': DateTime.now().millisecondsSinceEpoch,
  });
}
