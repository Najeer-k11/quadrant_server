import 'dart:io';

import 'package:quadrant_server/quadrant_server.dart';

import 'handlers/chat.dart';
import 'handlers/system.dart';
import 'handlers/users.dart';
import 'middlewares/auth.dart';

void main() async {
  // ─── Port from environment (useful for Docker) ──────────────
  final port = int.tryParse(Platform.environment['PORT'] ?? '') ?? 5050;

  // ─── API v1 router ───────────────────────────────────────────
  //
  // QuadrantRouter groups all routes under a shared prefix,
  // avoiding repetition and making versioning trivial.

  final apiV1 = QuadrantRouter(prefix: '/api/v1')
    // System
    ..get('/info', getInfo)
    ..post('/echo', echo)
    // Users — full CRUD
    ..get('/users', getUsers)
    ..post('/users', createUser, middlewares: [requireAuth()])
    ..get('/users/:id', getUser)
    ..put('/users/:id', updateUser, middlewares: [requireAuth()])
    ..patch('/users/:id', patchUser, middlewares: [requireAuth()])
    ..delete('/users/:id', deleteUserImpl,
        middlewares: [requireAuth(), requireAdmin()])
    // Catch-all — any unmatched sub-path under /api/v1
    ..get('/unknown/*', notFoundFallback);

  // ─── Server ──────────────────────────────────────────────────

  final app = QuadrantServer(
    // Global middlewares — run on every request before route handlers.
    middlewares: [
      cors(origin: '*'),      // CORS — set a real origin in production
      logger(),               // Logs: METHOD /path → STATUS (Xms)
      bodyParser(),           // Parses JSON bodies into req.body
    ],

    routes: [
      // Redirect legacy /api → /api/v1/info
      Route.get(path: '/api', handler: redirectToV1),

      // Health check — no auth, no versioning prefix
      Route.get(path: '/health', handler: getHealth),

      // Mount the versioned API router
      ...apiV1.routes,
    ],

    webSocketRoutes: [
      // ── Chat rooms ──────────────────────────────────────────
      //
      // Connect via: ws://localhost:<PORT>/ws/chat/<roomId>
      //
      // Supported messages:
      //   {"name": "Alice"}   → sets display name
      //   "hello world"       → broadcasts as plain chat message
      //   {"text": "..."}     → broadcasts as structured JSON message
      //
      // Events sent by server:
      //   welcome, user_joined, user_left, user_renamed, message
      WebSocketRoute(
        path: '/ws/chat/:roomId',
        onStart: chatOnStart,
        onMessage: chatOnMessage,
        onClose: chatOnClose,
        onError: chatOnError,
      ),

      // ── Ping / echo ─────────────────────────────────────────
      //
      // Connect via: ws://localhost:<PORT>/ws/ping
      // Send any message → receive {"event":"pong","echo":...,"ts":...}
      WebSocketRoute(
        path: '/ws/ping',
        onMessage: pingOnMessage,
      ),
    ],

    // Enable the built-in Swagger UI explorer.
    // Visit http://localhost:<PORT>/quadrant_docs
    docs: true,
    docsLocalOnly: false, // Set to true in production
    onError: (error, req) {
      // Centralised error handler.
      // Log the real error server-side, return a safe message to the client.
      // ignore: avoid_print
      print('[ERROR] ${req.method} ${req.path} — $error');
      return Response.internalServerError('Something went wrong');
    },
  );

  // ─── Start ───────────────────────────────────────────────────

  await app.listen(port: port);

  // ignore: avoid_print
  print('');
  // ignore: avoid_print
  print('REST:');
  // ignore: avoid_print
  print('  GET    http://localhost:$port/health');
  // ignore: avoid_print
  print('  GET    http://localhost:$port/api/v1/users');
  // ignore: avoid_print
  print('  POST   http://localhost:$port/api/v1/users');
  // ignore: avoid_print
  print('  GET    http://localhost:$port/api/v1/users/:id');
  // ignore: avoid_print
  print('  PUT    http://localhost:$port/api/v1/users/:id');
  // ignore: avoid_print
  print('  PATCH  http://localhost:$port/api/v1/users/:id');
  // ignore: avoid_print
  print('  DELETE http://localhost:$port/api/v1/users/:id');
  // ignore: avoid_print
  print('  POST   http://localhost:$port/api/v1/echo');
  // ignore: avoid_print
  print('');
  // ignore: avoid_print
  print('WebSocket:');
  // ignore: avoid_print
  print('  ws://localhost:$port/ws/chat/<roomId>');
  // ignore: avoid_print
  print('  ws://localhost:$port/ws/ping');
  // ignore: avoid_print
  print('');
  // ignore: avoid_print
  print('Auth tokens for protected routes:');
  // ignore: avoid_print
  print('  Bearer secret-admin-token  (admin)');
  // ignore: avoid_print
  print('  Bearer secret-user-token   (user)');
  // ignore: avoid_print
  print('');
}
