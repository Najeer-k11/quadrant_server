/// QuadrantServer — A Dart-first, batteries-included HTTP server framework.
///
/// Built directly on dart:io with zero external dependencies.
library quadrant_server;

// ─── Core ─────────────────────────────────────────────────────
export 'src/quadrant_app.dart';
export 'src/quadrant_router.dart';
export 'src/middleware.dart';
export 'src/request.dart';
export 'src/response.dart';
export 'src/route.dart';
export 'src/stream_response.dart';
export 'src/validator.dart';

// ─── Real-time ────────────────────────────────────────────────
export 'src/sse_context.dart';
export 'src/websocket_context.dart';
export 'src/websocket_group.dart';
export 'src/websocket_route.dart';

// ─── Middlewares ──────────────────────────────────────────────
export 'src/middlewares/bearer_auth.dart' hide consumeContextOverride;
export 'src/middlewares/body_parser.dart';
export 'src/middlewares/compress.dart' hide consumeCompressedBody;
export 'src/middlewares/cookie_parser.dart' hide consumeCookieContext;
export 'src/middlewares/cors.dart';
export 'src/middlewares/etag.dart';
export 'src/middlewares/form_parser.dart';
export 'src/middlewares/helmet.dart';
export 'src/middlewares/ip_filter.dart';
export 'src/middlewares/logger.dart';
export 'src/middlewares/multipart_parser.dart' hide consumeMultipartContext;
export 'src/middlewares/rate_limit.dart';
export 'src/middlewares/request_id.dart' hide consumeRequestIdContext;
export 'src/middlewares/static_files.dart';
export 'src/middlewares/timeout.dart';
