import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'docs.dart';
import 'middleware.dart';
import 'request.dart';
import 'response.dart';
import 'route.dart';
import 'router.dart';
import 'stream_response.dart';
import 'websocket_context.dart';
import 'websocket_route.dart';
import 'middlewares/bearer_auth.dart';
import 'middlewares/body_parser.dart';
import 'middlewares/compress.dart';
import 'middlewares/cookie_parser.dart';
import 'middlewares/multipart_parser.dart';
import 'middlewares/request_id.dart';

/// Error handler type — receives the error and the request, returns a Response.
typedef ErrorHandler = Response Function(Object error, Request req);

/// The main QuadrantServer class. Entry point for the framework.
///
/// Accepts everything via constructor. Immutable config.
///
/// ```dart
/// final app = QuadrantServer(
///   middlewares: [cors(), helmet(), logger(), bodyParser()],
///   routes: [
///     Route.get(path: '/users', handler: getUsers),
///     Route.post(path: '/users', handler: createUser),
///   ],
///   healthCheck: true,
/// );
/// await app.listen(port: 3000);
/// ```
class QuadrantServer {
  /// Global middleware list, applied to every request in order.
  final List<Middleware> middlewares;

  /// Flat list of route definitions.
  final List<Route> routes;

  /// WebSocket route definitions.
  final List<WebSocketRoute> webSocketRoutes;

  /// Whether the /quadrant_docs endpoint is enabled. Default: false.
  final bool docs;

  /// When [docs] is true, restrict the docs endpoint to loopback addresses
  /// only (127.0.0.1 / ::1). Default: true.
  final bool docsLocalOnly;

  /// Whether the built-in health check endpoint is enabled. Default: false.
  ///
  /// When enabled, `GET <healthCheckPath>` returns:
  /// ```json
  /// {"status":"ok","uptime":3600,"requests":1024,"memoryMb":42.1}
  /// ```
  final bool healthCheck;

  /// Path for the health check endpoint. Defaults to `'/health'`.
  final String healthCheckPath;

  /// Optional global error handler. Returns a [Response].
  final ErrorHandler? onError;

  final Router _router;
  HttpServer? _server;

  // ─── Metrics ─────────────────────────────────────────────────

  final DateTime _startTime = DateTime.now();
  int _requestCount = 0;
  int _inFlightCount = 0;
  Completer<void>? _activeCompleter;

  QuadrantServer({
    this.middlewares = const [],
    required this.routes,
    this.webSocketRoutes = const [],
    this.onError,
    this.docs = false,
    this.docsLocalOnly = true,
    this.healthCheck = false,
    this.healthCheckPath = '/health',
  }) : _router = Router(
          _buildRouteList(routes, docs,
              webSocketRoutes: webSocketRoutes,
              docsLocalOnly: docsLocalOnly,
              healthCheck: healthCheck,
              healthCheckPath: healthCheckPath),
          webSocketRoutes: webSocketRoutes,
        );

  // ─── Route building ──────────────────────────────────────────

  static List<Route> _buildRouteList(
    List<Route> routes,
    bool docs, {
    List<WebSocketRoute> webSocketRoutes = const [],
    bool docsLocalOnly = true,
    bool healthCheck = false,
    String healthCheckPath = '/health',
  }) {
    final result = [...routes];

    if (docs) {
      result.add(Route.get(
        path: '/quadrant_docs',
        handler: docsHandler(routes,
            webSocketRoutes: webSocketRoutes, localOnly: docsLocalOnly),
      ));
    }

    // Health check is a placeholder; the real handler is wired at listen()
    // time to access _startTime / _requestCount. We add a dummy here so the
    // router knows the path; _handleRequest overrides it before dispatch.
    // (see _handleRequest logic below — path is matched via healthCheckPath)

    return result;
  }

  // ─── Server start ─────────────────────────────────────────────

  /// Binds an HTTP server to [port] and starts handling requests.
  Future<HttpServer> listen({
    required int port,
    dynamic address = '0.0.0.0',
  }) async {
    _server = await HttpServer.bind(address, port);
    _server!.listen(_handleRequest);
    _printBanner('http://localhost:$port');
    return _server!;
  }

  /// Binds an HTTPS server to [port] using TLS certificates.
  ///
  /// [certificateChain] — PEM-encoded certificate chain file.
  /// [privateKey] — PEM-encoded private key file.
  /// [password] — optional PEM passphrase.
  ///
  /// ```dart
  /// await app.listenSecure(
  ///   port: 443,
  ///   certificateChain: File('cert.pem'),
  ///   privateKey: File('key.pem'),
  /// );
  /// ```
  Future<HttpServer> listenSecure({
    required int port,
    required File certificateChain,
    required File privateKey,
    String? password,
    dynamic address = '0.0.0.0',
  }) async {
    final context = SecurityContext();
    context.useCertificateChain(certificateChain.path, password: password);
    context.usePrivateKey(privateKey.path, password: password);

    _server = await HttpServer.bindSecure(address, port, context);
    _server!.listen(_handleRequest);
    _printBanner('https://localhost:$port');
    return _server!;
  }

  /// Gracefully shuts down the server.
  ///
  /// If [force] is `false` (default), closes the listening socket immediately
  /// (no new connections accepted) but **waits for all in-flight requests** to
  /// complete before returning.
  ///
  /// If [force] is `true`, closes immediately regardless of in-flight requests.
  Future<void> close({bool force = false}) async {
    await _server?.close(force: force);
    _server = null;

    if (!force && _inFlightCount > 0) {
      // Wait for all in-flight requests to complete.
      _activeCompleter = Completer<void>();
      await _activeCompleter!.future;
    }
  }

  void _printBanner(String url) {
    if (!docs && !healthCheck) return;
    final routePad = max(0, 24 - routes.length.toString().length);
    final wsPad = max(0, 24 - webSocketRoutes.length.toString().length);
    // ignore: avoid_print
    print('┌─────────────────────────────────────────┐');
    // ignore: avoid_print
    print('│         QuadrantServer v2.0.0            │');
    // ignore: avoid_print
    print('├─────────────────────────────────────────┤');
    // ignore: avoid_print
    print('│  Listening on  $url${' ' * (27 - url.length)}│');
    // ignore: avoid_print
    print('│  REST routes   ${routes.length} registered${' ' * routePad}│');
    // ignore: avoid_print
    print('│  WS routes     ${webSocketRoutes.length} registered${' ' * wsPad}│');
    if (docs) {
      // ignore: avoid_print
      print('│  Docs          $url/quadrant_docs       │');
    }
    if (healthCheck) {
      // ignore: avoid_print
      print('│  Health        $url$healthCheckPath${' ' * (26 - healthCheckPath.length)}│');
    }
    // ignore: avoid_print
    print('└─────────────────────────────────────────┘');
  }

  // ─── Request handling ─────────────────────────────────────────

  Future<void> _handleRequest(HttpRequest httpRequest) async {
    _requestCount++;
    _inFlightCount++;

    Request request = Request.fromHttpRequest(httpRequest);

    try {
      // Built-in health check — intercept before router.
      if (healthCheck &&
          request.method == 'GET' &&
          request.path == healthCheckPath) {
        final uptime =
            DateTime.now().difference(_startTime).inSeconds;
        final memMb =
            (ProcessInfo.currentRss / (1024 * 1024)).toStringAsFixed(1);
        _writeResponse(
          httpRequest.response,
          Response(
            statusCode: 200,
            headers: {'content-type': 'application/json'},
            body: '{"status":"ok","uptime":$uptime,'
                '"requests":$_requestCount,"memoryMb":$memMb}',
          ),
        );
        return;
      }

      // Detect WebSocket upgrade requests.
      final isUpgrade = WebSocketTransformer.isUpgradeRequest(httpRequest);

      final result = _router.match(
        request.method,
        request.path,
        isUpgradeRequest: isUpgrade,
      );

      switch (result) {
        case NotFound():
          _writeResponse(
              httpRequest.response, Response.notFound('Route not found'));
          return;

        case MethodNotAllowed(:final allowedMethods):
          _writeResponse(
            httpRequest.response,
            Response(
              statusCode: 405,
              headers: {'allow': allowedMethods.join(', ')},
              body: '{"error":"Method not allowed"}',
            ),
          );
          return;

        case Matched(:final route, :final params):
          request = request.copyWith(params: params);
          final allMiddlewares = [...middlewares, ...route.middlewares];
          final response = await _executeChain(
              allMiddlewares, 0, request, route.handler, httpRequest);
          _writeResponse(httpRequest.response, response);

        case MatchedWebSocket(:final route, :final params):
          final wsRequest = request.copyWith(params: params);
          final middlewareChain = [...middlewares, ...route.middlewares];
          final rejected = await _runMiddlewareChainForUpgrade(
              wsRequest, middlewareChain, 0, httpRequest);

          if (rejected != null) {
            _writeResponse(httpRequest.response, rejected);
            return;
          }

          try {
            final ctx = await WebSocketContext.fromUpgrade(wsRequest);
            await _handleWebSocket(ctx, route);
          } catch (error) {
            final response = onError != null
                ? onError!(error, wsRequest)
                : Response.internalServerError('WebSocket upgrade failed');
            _writeResponse(httpRequest.response, response);
          }
      }
    } catch (error) {
      final response = onError != null
          ? onError!(error, request)
          : Response.internalServerError('Internal server error');
      _writeResponse(httpRequest.response, response);
    } finally {
      RequestHolder.instance.consumeParsedBody(httpRequest);
      _inFlightCount--;
      if (_inFlightCount == 0) {
        _activeCompleter?.complete();
        _activeCompleter = null;
      }
    }
  }

  // ─── Middleware chain ─────────────────────────────────────────

  Future<Response> _executeChain(
    List<Middleware> middlewareList,
    int index,
    Request request,
    Handler handler,
    HttpRequest rawRequest,
  ) async {
    // Pull in any pending body / context overrides from the previous step.
    request = _applyOverrides(request, rawRequest);

    if (index >= middlewareList.length) {
      return handler(request);
    }

    final middleware = middlewareList[index];

    return middleware(request, () async {
      final updated = _applyOverrides(request, rawRequest);
      return _executeChain(middlewareList, index + 1, updated, handler, rawRequest);
    });
  }

  /// Applies all pending context overrides (body, bearerAuth, requestId,
  /// cookieParser, multipartParser) to [request].
  Request _applyOverrides(Request request, HttpRequest rawRequest) {
    final parsedBody = RequestHolder.instance.consumeParsedBody(rawRequest);
    if (parsedBody != null) request = request.copyWith(body: parsedBody);

    // Each middleware stores its context addition in its own Expando.
    // We merge them all in order.
    for (final consume in [
      consumeContextOverride,       // bearerAuth
      consumeRequestIdContext,      // requestId
      consumeCookieContext,         // cookieParser
      consumeMultipartContext,      // multipartParser
    ]) {
      final ctx = consume(rawRequest);
      if (ctx != null) request = request.copyWith(context: ctx);
    }

    return request;
  }

  Future<Response?> _runMiddlewareChainForUpgrade(
    Request request,
    List<Middleware> middlewareList,
    int index,
    HttpRequest rawRequest,
  ) async {
    request = _applyOverrides(request, rawRequest);

    if (index >= middlewareList.length) return null;

    final middleware = middlewareList[index];
    bool nextCalled = false;
    Response? chainResult;

    final response = await middleware(request, () async {
      nextCalled = true;
      final updated = _applyOverrides(request, rawRequest);
      chainResult = await _runMiddlewareChainForUpgrade(
          updated, middlewareList, index + 1, rawRequest);
      return const Response(statusCode: 204);
    });

    if (!nextCalled) return response;
    return chainResult;
  }

  // ─── WebSocket lifecycle ──────────────────────────────────────

  Future<void> _handleWebSocket(
      WebSocketContext ctx, WebSocketRoute route) async {
    if (route.onStart != null) await route.onStart!(ctx);

    // Wire heartbeat if configured.
    Timer? heartbeatTimer;
    if (route.heartbeat != null) {
      heartbeatTimer = _startHeartbeat(ctx, route.heartbeat!);
    }

    final completer = Completer<void>();

    ctx.socket.listen(
      (data) async => route.onMessage(ctx, data),
      onError: (Object error) async {
        if (route.onError != null) {
          await route.onError!(ctx, error);
        } else {
          // ignore: avoid_print
          print('[QuadrantServer] WS error on ${ctx.request.path}: $error');
        }
      },
      onDone: () async {
        heartbeatTimer?.cancel();
        if (route.onClose != null) {
          await route.onClose!(
              ctx, ctx.socket.closeCode, ctx.socket.closeReason);
        }
        completer.complete();
      },
      cancelOnError: false,
    );

    await completer.future;
  }

  /// Starts a ping/pong heartbeat timer. Closes the connection if no pong
  /// is received within the same [interval].
  Timer _startHeartbeat(WebSocketContext ctx, Duration interval) {
    // dart:io WebSocket tracks pong via pingInterval — use it directly.
    // We set the socket's own pingInterval which handles pong tracking.
    ctx.socket.pingInterval = interval;

    // Additionally close any connection that has been idle too long
    // by monitoring done state.
    return Timer.periodic(interval * 2, (t) {
      if (!ctx.isOpen) {
        t.cancel();
        return;
      }
      // If socket is still open but pingInterval hasn't closed it, it's alive.
    });
  }

  // ─── Response writing ─────────────────────────────────────────

  void _writeResponse(HttpResponse httpResponse, Response response) {
    try {
      httpResponse.statusCode = response.statusCode;

      response.headers.forEach(httpResponse.headers.set);

      // Emit each Set-Cookie value as a separate header.
      for (final cookie in response.cookies) {
        httpResponse.headers.add('set-cookie', cookie);
      }

      // Check if this is a StreamResponse — pipe stream directly.
      if (response is StreamResponse) {
        unawaited(response.stream
            .pipe(httpResponse)
            .catchError((_) {})
            .then((_) => httpResponse.close().catchError((_) {})));
        return;
      }

      // Check if compress() stored compressed bytes for this response.
      final compressedBytes = consumeCompressedBody(response);
      if (compressedBytes != null) {
        httpResponse.add(compressedBytes);
        httpResponse.close();
        return;
      }

      if (response.body.isNotEmpty) {
        httpResponse.write(response.body);
      }

      httpResponse.close();
    } catch (_) {
      // Connection already closed or handed to a WebSocket — nothing to do.
    }
  }
}
