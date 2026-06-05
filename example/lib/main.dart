import 'package:quadrant_server/quadrant_server.dart';

// ─── Room Registry ───────────────────────────────────────────

/// Tracks all connected clients per room.
/// Key = roomId, Value = set of connected WebSocket contexts.
final Map<String, Set<WebSocketContext>> _rooms = {};

void _joinRoom(String roomId, WebSocketContext ctx) {
  _rooms.putIfAbsent(roomId, () => {}).add(ctx);
}

void _leaveRoom(String roomId, WebSocketContext ctx) {
  _rooms[roomId]?.remove(ctx);
  if (_rooms[roomId]?.isEmpty ?? false) {
    _rooms.remove(roomId);
  }
}

/// Sends [message] to all clients in [roomId] except [sender].
void _broadcast(String roomId, Object message, {WebSocketContext? sender}) {
  final members = _rooms[roomId] ?? {};
  for (final member in members) {
    if (member != sender) {
      member.send(message);
    }
  }
}

// ─── WebSocket Callbacks ─────────────────────────────────────

Future<void> chatOnStart(WebSocketContext ctx) async {
  final room = ctx.request.params['roomId'] ?? 'general';
  _joinRoom(room, ctx);
  ctx.send('Welcome to room: $room (${_rooms[room]?.length ?? 0} online)');
  _broadcast(room, '** A new user joined the room **', sender: ctx);
}

Future<void> chatOnMessage(WebSocketContext ctx, dynamic data) async {
  final room = ctx.request.params['roomId'] ?? 'general';
  // Broadcast message to everyone else in the room.
  _broadcast(room, data, sender: ctx);
}

Future<void> chatOnClose(
  WebSocketContext ctx,
  int? code,
  String? reason,
) async {
  final room = ctx.request.params['roomId'] ?? 'general';
  _leaveRoom(room, ctx);
  _broadcast(room, '** A user left the room **');
  print('User left room "$room" — code: $code, reason: $reason');
}

Future<void> chatOnError(WebSocketContext ctx, Object error) async {
  print('WebSocket error: $error');
}

// ─── HTTP Handlers ───────────────────────────────────────────

Future<Response> getHello(Request req) async {
  final name = req.params['name'] ?? 'World';
  return Response.ok({'message': 'Hello, $name!'});
}

Future<Response> getHealth(Request req) async {
  return Response.ok({'status': 'ok'});
}

// ─── Server ──────────────────────────────────────────────────

void main() async {
  final app = QuadrantServer(
    middlewares: [cors(), logger(), bodyParser()],
    routes: [
      Route.get(path: '/hello/:name', handler: getHello),
      Route.get(path: '/health', handler: getHealth),
    ],
    webSocketRoutes: [
      // Chat room — connect via ws://localhost:5050/ws/chat/general
      WebSocketRoute(
        path: '/ws/chat/:roomId',
        onStart: chatOnStart,
        onMessage: chatOnMessage,
        onClose: chatOnClose,
        onError: chatOnError,
      ),
    ],
    docs: true,
  );

  final server = await app.listen(port: 5050);
  print('QuadrantServer running on http://localhost:${server.port}');
  print('WebSocket: ws://localhost:${server.port}/ws/chat/<roomId>');
  print('Docs: http://localhost:${server.port}/quadrant_docs');
}
