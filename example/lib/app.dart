import 'dart:io';

import 'package:quadrant_server/quadrant_server.dart';

import 'config.dart';
import 'handlers/chat.dart';
import 'handlers/files.dart';
import 'handlers/system.dart';
import 'handlers/users.dart';
import 'middlewares/auth.dart';

/// Creates the data directories, and removes temporary uploads left behind if
/// the last run was killed. Call this once, before the server starts.
Future<void> prepareDataDirectories(Config config) async {
  await Directory(config.uploadsDir).create(recursive: true);
  final temp = await Directory(config.tempDir).create(recursive: true);
  await for (final entry in temp.list()) {
    final name = entry.path.split(Platform.pathSeparator).last;
    if (name.startsWith('quadrant_upload_')) {
      await entry.delete(recursive: true);
    }
  }
}

/// Builds the server. In a cluster this runs inside each isolate, including
/// one that replaces an isolate that died.
///
/// `build` must create its rate limiters in the same order every time, so that
/// the isolates share their counts. Creating them here, unconditionally, does.
QuadrantServer buildServer(Config config) {
  final auth = requireAuth(config.tokens);
  final admin = requireAdmin();

  // Stricter than the global limit, because these are costly.
  Middleware strictLimit(int maxRequests) => rateLimit(
        maxRequests: maxRequests,
        window: const Duration(minutes: 1),
        trustedProxyHops: config.trustedProxyHops,
      );

  // QuadrantRouter groups routes under a shared prefix.
  final apiV1 = QuadrantRouter(prefix: '/api/v1')
    // System
    ..get('/info', getInfo)
    ..post('/echo', echo)
    // Users: full CRUD
    ..get('/users', getUsers)
    ..post('/users', createUser, middlewares: [auth, validate(createUserSchema)])
    ..get('/users/:id', getUser)
    ..put('/users/:id', updateUser,
        middlewares: [auth, validate(replaceUserSchema)])
    ..patch('/users/:id', patchUser,
        middlewares: [auth, validate(patchUserSchema)])
    ..delete('/users/:id', deleteUser, middlewares: [auth, admin])
    // Files: streaming uploads, kept on disk rather than in memory
    ..post('/files', uploadFiles(config.uploadsDir), middlewares: [
      strictLimit(30),
      auth,
      multipartParser(
        maxFileSize: maxUploadBytes,
        maxTotalBytes: maxUploadBytes,
        diskThreshold: 1024 * 1024,
        tempDirectory: Directory(config.tempDir),
        maxParts: 20,
      ),
    ])
    ..get('/files/*', staticFiles(config.uploadsDir, indexFallback: false),
        middlewares: [auth]);

  return QuadrantServer(
    middlewares: [
      // Sets HSTS only in production, where a proxy provides HTTPS.
      if (config.production)
        helmet()
      else
        helmet(hsts: null, crossOriginResourcePolicy: null),
      if (config.corsOrigin != null) cors(origin: config.corsOrigin!),
      logger(),
      rateLimit(
        maxRequests: 300,
        window: const Duration(minutes: 1),
        trustedProxyHops: config.trustedProxyHops,
      ),
      bodyParser(),
    ],
    routes: [
      Route.get(path: '/api', handler: redirectToV1),
      ...apiV1.routes,
    ],
    webSocketRoutes: [
      WebSocketRoute(
        path: '/ws/chat/:roomId',
        middlewares: [strictLimit(60), validRoomId()],
        // Notices clients that vanished without closing the connection.
        heartbeat: const Duration(seconds: 30),
        onStart: chatOnStart,
        onMessage: chatOnMessage,
        onClose: chatOnClose,
        onError: chatOnError,
      ),
      WebSocketRoute(path: '/ws/ping', onMessage: pingOnMessage),
    ],
    healthCheck: true,
    // Off in production, rather than limited to local clients: behind a proxy
    // on the same machine, every request looks local.
    docs: !config.production,
    onError: (error, req) {
      // The real error stays in the logs. The client gets a safe message.
      // ignore: avoid_print
      print('[ERROR] ${req.method} ${req.path}: $error');
      return Response.internalServerError('Something went wrong');
    },
  );
}
