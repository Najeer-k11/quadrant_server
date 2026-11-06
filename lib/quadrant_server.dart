/// QuadrantServer — A Dart-first, batteries-included HTTP server framework.
///
/// Built directly on dart:io with zero external dependencies.
library quadrant_server;

// ─── Core ─────────────────────────────────────────────────────
export 'src/cluster/cluster.dart';
export 'src/core/quadrant_app.dart';
export 'src/routing/quadrant_router.dart';
export 'src/core/middleware.dart';
export 'src/core/request.dart' hide consumeSetContext;
export 'src/core/response.dart';
export 'src/routing/route.dart';
export 'src/core/stream_response.dart';
export 'src/validation/validator.dart' hide schemaOf;

// ─── Real-time ────────────────────────────────────────────────
export 'src/realtime/sse_context.dart' hide registerSseTracker;
export 'src/realtime/websocket_context.dart';
export 'src/realtime/websocket_group.dart';
export 'src/realtime/websocket_route.dart';

// ─── Middlewares ──────────────────────────────────────────────
export 'src/middlewares/bearer_auth.dart' hide consumeContextOverride;
export 'src/middlewares/body_parser.dart';
export 'src/middlewares/compress.dart';
export 'src/middlewares/cookie_parser.dart' hide consumeCookieContext;
export 'src/middlewares/cors.dart' hide isCorsMiddleware;
export 'src/middlewares/etag.dart';
export 'src/middlewares/form_parser.dart';
export 'src/middlewares/helmet.dart';
export 'src/middlewares/ip_filter.dart';
export 'src/middlewares/logger.dart';
export 'src/middlewares/multipart_parser.dart' hide consumeMultipartContext;
export 'src/middlewares/rate_limit.dart';
export 'src/middlewares/request_id.dart' hide consumeRequestIdContext;
export 'src/middlewares/static_files.dart' show staticFiles;
export 'src/middlewares/timeout.dart';
