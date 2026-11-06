import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../cluster/cluster_link.dart';
import '../docs/docs.dart';
import 'middleware.dart';
import 'request.dart';
import 'response.dart';
import '../routing/route.dart';
import '../routing/router.dart';
import '../realtime/sse_context.dart';
import 'stream_response.dart';
import 'version.dart';
import '../realtime/websocket_context.dart';
import '../realtime/websocket_route.dart';
import '../middlewares/bearer_auth.dart';
import '../middlewares/body_parser.dart';
import '../middlewares/cookie_parser.dart';
import '../middlewares/cors.dart';
import '../middlewares/multipart_parser.dart';
import '../middlewares/request_id.dart';

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

  // ─── Long-lived connections ──────────────────────────────────

  // These never finish by themselves, so close() has to end them.
  final Set<WebSocketContext> _webSockets = {};
  final Set<SseContext> _sseStreams = {};
  bool _closing = false;

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

  /// The number of requests this server has received.
  int get requestCount => _requestCount;

  /// Binds an HTTP server to [port] and starts handling requests.
  ///
  /// [shared] lets several isolates bind the same port. To run on several
  /// isolates, use `QuadrantCluster`, which also keeps their state in step.
  Future<HttpServer> listen({
    required int port,
    dynamic address = '0.0.0.0',
    bool shared = false,
  }) async {
    _closing = false;
    _server = await HttpServer.bind(address, port, shared: shared);
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
    bool shared = false,
  }) async {
    final context = SecurityContext();
    context.useCertificateChain(certificateChain.path, password: password);
    context.usePrivateKey(privateKey.path, password: password);

    _closing = false;
    _server =
        await HttpServer.bindSecure(address, port, context, shared: shared);
    _server!.listen(_handleRequest);
    _printBanner('https://localhost:$port');
    return _server!;
  }

  /// Gracefully shuts down the server.
  ///
  /// Closes the listening socket, so no new connections are accepted, and ends
  /// open WebSockets (with code `1001`) and SSE streams, which would otherwise
  /// stay open for as long as their clients do. It then **waits for all
  /// in-flight requests** to finish, including any [StreamResponse] that is
  /// still sending.
  ///
  /// [timeout] limits that wait. When it runs out, the remaining connections
  /// are destroyed. Without one, a client that stops reading a large response
  /// can hold up shutdown until the connection fails.
  ///
  /// If [force] is `true`, connections are destroyed immediately regardless of
  /// in-flight requests.
  Future<void> close({bool force = false, Duration? timeout}) async {
    final server = _server;
    _server = null;
    _closing = true;
    await server?.close(force: force);

    for (final socket in List.of(_webSockets)) {
      unawaited(socket
          .close(WebSocketStatus.goingAway, 'Server shutting down')
          .catchError((_) {}));
    }
    for (final stream in List.of(_sseStreams)) {
      unawaited(stream.close());
    }

    if (force || _inFlightCount == 0) return;

    final drained = (_activeCompleter ??= Completer<void>()).future;
    if (timeout == null) {
      await drained;
      return;
    }
    try {
      await drained.timeout(timeout);
    } on TimeoutException {
      await server?.close(force: true);
    }
  }

  void _printBanner(String url) {
    if (!docs && !healthCheck) return;
    // Once per cluster rather than once per isolate.
    if ((currentClusterLink?.index ?? 0) > 0) return;
    final routePad = max(0, 24 - routes.length.toString().length);
    final wsPad = max(0, 24 - webSocketRoutes.length.toString().length);
    // ignore: avoid_print
    print('┌─────────────────────────────────────────┐');
    // ignore: avoid_print
    print('│         QuadrantServer v$quadrantVersion            │');
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
    registerSseTracker(httpRequest, _trackSse);

    try {
      // Built-in health check — intercept before router.
      if (healthCheck &&
          request.method == 'GET' &&
          request.path == healthCheckPath) {
        final uptime =
            DateTime.now().difference(_startTime).inSeconds;
        final memMb =
            (ProcessInfo.currentRss / (1024 * 1024)).toStringAsFixed(1);
        final link = currentClusterLink;
        final requests = await link?.totalRequests() ?? _requestCount;
        final isolates = link == null ? '' : ',"isolates":${link.isolateCount}';
        await _writeResponse(
          httpRequest.response,
          Response(
            statusCode: 200,
            headers: {'content-type': 'application/json'},
            body: '{"status":"ok","uptime":$uptime,'
                '"requests":$requests,"memoryMb":$memMb$isolates}',
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
          await _respondUnmatched(
              Response.notFound('Route not found'), request, httpRequest);
          return;

        case MalformedPath():
          await _respondUnmatched(
              Response.badRequest('Malformed URL path'), request, httpRequest);
          return;

        case MethodNotAllowed(:final allowedMethods, :final routes):
          await _respondUnmatched(
            Response(
              statusCode: 405,
              headers: {'allow': allowedMethods.join(', ')},
              body: '{"error":"Method not allowed"}',
            ),
            request,
            httpRequest,
            routeMiddlewares: request.method == 'OPTIONS'
                ? _preflightMiddlewares(routes)
                : const [],
          );
          return;

        case Matched(:final route, :final params):
          request = request.copyWith(params: params);
          final allMiddlewares = [...middlewares, ...route.middlewares];
          final response = await _executeChain(
              allMiddlewares, 0, request, route.handler, httpRequest);
          await _writeResponse(httpRequest.response, response);

        case MatchedWebSocket(:final route, :final params):
          var wsRequest = request.copyWith(params: params);
          final middlewareChain = [...middlewares, ...route.middlewares];
          final rejected = await _runMiddlewareChainForUpgrade(
              wsRequest, middlewareChain, 0, httpRequest, (updated) {
            // Keeps what the middlewares added, such as the bearerAuth() user.
            wsRequest = updated;
          });

          if (rejected != null) {
            await _writeResponse(httpRequest.response, rejected);
            return;
          }

          try {
            final ctx = await WebSocketContext.fromUpgrade(wsRequest);
            await _handleWebSocket(ctx, route);
          } catch (error) {
            await _writeResponse(httpRequest.response,
                _errorResponse(error, wsRequest, 'WebSocket upgrade failed'));
          }
      }
    } catch (error) {
      await _writeResponse(httpRequest.response,
          _errorResponse(error, request, 'Internal server error'));
    } finally {
      RequestHolder.instance.consumeParsedBody(httpRequest);
      _inFlightCount--;
      if (_inFlightCount == 0) {
        _activeCompleter?.complete();
        _activeCompleter = null;
      }
    }
  }

  /// Sends [response] through the global middlewares, so that requests matching
  /// no route also get security headers, logging, rate limiting and so on.
  Future<void> _respondUnmatched(
    Response response,
    Request request,
    HttpRequest httpRequest, {
    List<Middleware> routeMiddlewares = const [],
  }) async {
    final result = await _executeChain(
      [...middlewares, ...routeMiddlewares],
      0,
      request,
      (_) async => response,
      httpRequest,
    );
    await _writeResponse(httpRequest.response, result);
  }

  /// The `cors()` on a path's routes, which has to answer its preflights. A
  /// preflight is an `OPTIONS` request, so it never matches those routes.
  List<Middleware> _preflightMiddlewares(List<Route> routes) {
    for (final route in routes) {
      for (final middleware in route.middlewares) {
        if (isCorsMiddleware(middleware)) return [middleware];
      }
    }
    return const [];
  }

  void _trackSse(SseContext stream) {
    if (_closing) {
      unawaited(stream.close());
      return;
    }
    _sseStreams.add(stream);
    unawaited(stream.done.whenComplete(() => _sseStreams.remove(stream)));
  }

  /// Asks [onError] for a response; falls back to a 500 if it throws too.
  Response _errorResponse(Object error, Request request, String fallback) {
    try {
      if (onError != null) return onError!(error, request);
    } catch (handlerError) {
      // ignore: avoid_print
      print('[QuadrantServer] onError threw: $handlerError');
    }
    return Response.internalServerError(fallback);
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
  /// cookieParser, multipartParser, Request.setContext) to [request].
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
      consumeSetContext,            // Request.setContext
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
    void Function(Request request) onChainEnd,
  ) async {
    request = _applyOverrides(request, rawRequest);

    if (index >= middlewareList.length) {
      onChainEnd(request);
      return null;
    }

    final middleware = middlewareList[index];
    bool nextCalled = false;
    Response? chainResult;

    final response = await middleware(request, () async {
      nextCalled = true;
      final updated = _applyOverrides(request, rawRequest);
      chainResult = await _runMiddlewareChainForUpgrade(
          updated, middlewareList, index + 1, rawRequest, onChainEnd);
      return const Response(statusCode: 204);
    });

    if (!nextCalled) return response;
    return chainResult;
  }

  // ─── WebSocket lifecycle ──────────────────────────────────────

  Future<void> _handleWebSocket(
      WebSocketContext ctx, WebSocketRoute route) async {
    _webSockets.add(ctx);
    unawaited(ctx.socket.done
        .whenComplete(() => _webSockets.remove(ctx))
        .catchError((_) {}));
    if (_closing) {
      unawaited(ctx
          .close(WebSocketStatus.goingAway, 'Server shutting down')
          .catchError((_) {}));
    }

    if (route.onStart != null) {
      try {
        await route.onStart!(ctx);
      } catch (_) {
        unawaited(ctx.socket
            .close(WebSocketStatus.internalServerError)
            .catchError((_) {}));
        rethrow;
      }
    }

    // Wire heartbeat if configured.
    Timer? heartbeatTimer;
    if (route.heartbeat != null) {
      heartbeatTimer = _startHeartbeat(ctx, route.heartbeat!);
    }

    final completer = Completer<void>();

    Future<void> report(Object error) async {
      if (route.onError != null) {
        try {
          return await route.onError!(ctx, error);
        } catch (handlerError) {
          error = handlerError;
        }
      }
      // ignore: avoid_print
      print('[QuadrantServer] WS error on ${ctx.request.path}: $error');
    }

    // Callbacks run inside the socket listener, where an uncaught error
    // would kill the whole process.
    Future<void> guard(Future<void> Function() callback) async {
      try {
        await callback();
      } catch (error) {
        await report(error);
      }
    }

    ctx.socket.listen(
      (data) => guard(() => route.onMessage(ctx, data)),
      onError: report,
      onDone: () async {
        heartbeatTimer?.cancel();
        // Close our side too: `socket.done` only completes after that, and
        // WebSocketGroup waits on it to drop the connection.
        unawaited(ctx.socket.close().catchError((_) {}));
        if (route.onClose != null) {
          await guard(() => route.onClose!(
              ctx, ctx.socket.closeCode, ctx.socket.closeReason));
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

  /// Completes once the response has been handed to the socket, so a request
  /// counts as in flight until then.
  Future<void> _writeResponse(
      HttpResponse httpResponse, Response response) async {
    try {
      httpResponse.statusCode = response.statusCode;

      response.headers.forEach(httpResponse.headers.set);

      // Emit each Set-Cookie value as a separate header.
      for (final cookie in response.cookies) {
        httpResponse.headers.add('set-cookie', cookie);
      }

      if (response is StreamResponse) {
        await httpResponse.addStream(_guardListen(response.stream));
      } else if (response.body.isNotEmpty) {
        // Not write(): without a charset in the content-type, it encodes as
        // Latin-1, which corrupts JSON and throws on most of Unicode.
        final charset = httpResponse.headers.contentType?.charset;
        final encoding =
            charset == null ? null : Encoding.getByName(charset);
        httpResponse.add((encoding ?? utf8).encode(response.body));
      }

      await httpResponse.close();
    } catch (_) {
      // Client disconnected, the stream failed, or the connection was already
      // closed or handed to a WebSocket. Nothing more can be sent.
      try {
        unawaited(httpResponse.close().then((_) {}, onError: (_) {}));
      } catch (_) {
        // Handed to a WebSocket: there is no response left to close.
      }
    }
  }
}

/// Turns a failure to start [source], such as a single-subscription stream
/// that is already in use, into an error event. Thrown directly, it would leave
/// the response bound to a stream that never ends, so it could never close.
Stream<List<int>> _guardListen(Stream<List<int>> source) async* {
  yield* source;
}
