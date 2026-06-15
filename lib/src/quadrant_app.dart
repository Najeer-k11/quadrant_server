import 'dart:async';
import 'dart:io';

import 'docs.dart';
import 'middleware.dart';
import 'request.dart';
import 'response.dart';
import 'route.dart';
import 'router.dart';
import 'websocket_context.dart';
import 'websocket_route.dart';
import 'middlewares/body_parser.dart';

/// Error handler type — receives the error and the request, returns a Response.
typedef ErrorHandler = Response Function(Object error, Request req);

/// The main QuadrantServer class. Entry point for the framework.
///
/// Accepts everything via constructor. Immutable config.
///
/// ```dart
/// final app = QuadrantServer(
///   middlewares: [cors(), logger(), bodyParser()],
///   routes: [
///     Route.get(path: '/users', handler: getUsers),
///     Route.post(path: '/users', handler: createUser),
///   ],
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
  ///
  /// Set to `false` only when you intentionally want docs accessible from
  /// external IPs (e.g. a staging environment behind a firewall).
  final bool docsLocalOnly;

  /// Optional global error handler. Returns a [Response].
  final ErrorHandler? onError;

  final Router _router;
  HttpServer? _server;

  QuadrantServer({
    this.middlewares = const [],
    required this.routes,
    this.webSocketRoutes = const [],
    this.onError,
    this.docs = false,
    this.docsLocalOnly = true,
  }) : _router = Router(
          _buildRouteList(routes, docs,
              webSocketRoutes: webSocketRoutes, docsLocalOnly: true),
          webSocketRoutes: webSocketRoutes,
        );

  /// Builds the final route list, conditionally adding /quadrant_docs.
  static List<Route> _buildRouteList(
    List<Route> routes,
    bool docs, {
    List<WebSocketRoute> webSocketRoutes = const [],
    bool docsLocalOnly = true,
  }) {
    if (!docs) return routes;

    return [
      ...routes,
      Route.get(
        path: '/quadrant_docs',
        handler: docsHandler(
          routes,
          webSocketRoutes: webSocketRoutes,
          localOnly: docsLocalOnly,
        ),
      ),
    ];
  }

  /// Binds a dart:io [HttpServer] to the given [port] and starts handling
  /// incoming requests.
  ///
  /// Optionally specify [address] (defaults to any IPv4).
  ///
  /// When [docs] is enabled, a startup banner is printed listing the server
  /// URL and the docs endpoint.
  Future<HttpServer> listen({
    required int port,
    dynamic address = '0.0.0.0',
  }) async {
    _server = await HttpServer.bind(address, port);

    _server!.listen((httpRequest) async {
      await _handleRequest(httpRequest);
    });

    if (docs) {
      final host = 'http://localhost:$port';
      // ignore: avoid_print
      print('┌─────────────────────────────────────────┐');
      // ignore: avoid_print
      print('│         QuadrantServer v1.2.0            │');
      // ignore: avoid_print
      print('├─────────────────────────────────────────┤');
      // ignore: avoid_print
      print('│  Listening on  $host${' ' * (27 - host.length)}│');
      // ignore: avoid_print
      print('│  REST routes   ${routes.length} registered${' ' * (24 - routes.length.toString().length)}│');
      // ignore: avoid_print
      print(
          '│  WS routes     ${webSocketRoutes.length} registered${' ' * (24 - webSocketRoutes.length.toString().length)}│');
      // ignore: avoid_print
      print('│  Docs          $host/quadrant_docs${' ' * (7 - '/quadrant_docs'.length + 14)}│');
      // ignore: avoid_print
      print('└─────────────────────────────────────────┘');
    }

    return _server!;
  }

  /// Gracefully shuts down the server.
  ///
  /// If [force] is `false` (default), waits for in-flight requests to
  /// complete before closing. If `true`, closes immediately.
  Future<void> close({bool force = false}) async {
    await _server?.close(force: force);
    _server = null;
  }

  /// Handles a single incoming [HttpRequest].
  Future<void> _handleRequest(HttpRequest httpRequest) async {
    Request request = Request.fromHttpRequest(httpRequest);

    try {
      // Detect WebSocket upgrade requests.
      final isUpgrade = WebSocketTransformer.isUpgradeRequest(httpRequest);

      // Match route using the sealed result type.
      final result = _router.match(
        request.method,
        request.path,
        isUpgradeRequest: isUpgrade,
      );

      switch (result) {
        case NotFound():
          final response = Response.notFound('Route not found');
          _writeResponse(httpRequest.response, response);
          return;

        case MethodNotAllowed(:final allowedMethods):
          final response = Response(
            statusCode: 405,
            headers: {'allow': allowedMethods.join(', ')},
            body: '{"error":"Method not allowed"}',
          );
          _writeResponse(httpRequest.response, response);
          return;

        case Matched(:final route, :final params):
          // Attach path params to request.
          request = request.copyWith(params: params);

          // Build middleware chain: [global] + [route-level] + [handler].
          final allMiddlewares = [...middlewares, ...route.middlewares];

          // Execute the chain.
          final response = await _executeChain(
            allMiddlewares,
            0,
            request,
            route.handler,
            httpRequest,
          );

          _writeResponse(httpRequest.response, response);

        case MatchedWebSocket(:final route, :final params):
          final wsRequest = request.copyWith(params: params);

          // Run middleware chain — null means "chain passed, proceed".
          final middlewareChain = [...middlewares, ...route.middlewares];
          final rejected = await _runMiddlewareChainForUpgrade(
            wsRequest,
            middlewareChain,
            0,
            httpRequest,
          );

          if (rejected != null) {
            // Middleware rejected — write HTTP response, no upgrade.
            _writeResponse(httpRequest.response, rejected);
            return;
          }

          try {
            final ctx = await WebSocketContext.fromUpgrade(wsRequest);
            await _handleWebSocket(ctx, route);
          } catch (error) {
            // Upgrade failed — delegate to onError if provided.
            if (onError != null) {
              onError!(error, wsRequest);
            } else {
              // ignore: avoid_print
              print('[QuadrantServer] WebSocket upgrade error: $error');
            }
          }
      }
    } catch (error) {
      final response = onError != null
          ? onError!(error, request)
          : Response.internalServerError('Internal server error');
      _writeResponse(httpRequest.response, response);
    } finally {
      // Clean up any parsed body that was not consumed.
      RequestHolder.instance.consumeParsedBody(httpRequest);
    }
  }

  /// Recursively executes the middleware chain.
  ///
  /// Each middleware receives the current request and a [next] function.
  /// When [next] is called, the next middleware (or handler) runs.
  /// After bodyParser runs, the parsed body is attached to the request
  /// for all downstream consumers.
  Future<Response> _executeChain(
    List<Middleware> middlewareList,
    int index,
    Request request,
    Handler handler,
    HttpRequest rawRequest,
  ) async {
    // Check if bodyParser has stored a parsed body for this request.
    final parsedBody = RequestHolder.instance.consumeParsedBody(rawRequest);
    if (parsedBody != null) {
      request = request.copyWith(body: parsedBody);
    }

    if (index >= middlewareList.length) {
      return handler(request);
    }

    final middleware = middlewareList[index];

    return middleware(request, () async {
      // After this middleware runs, check for parsed body again.
      final body = RequestHolder.instance.consumeParsedBody(rawRequest);
      final updatedRequest =
          body != null ? request.copyWith(body: body) : request;
      return _executeChain(
        middlewareList,
        index + 1,
        updatedRequest,
        handler,
        rawRequest,
      );
    });
  }

  /// Runs the middleware chain for WebSocket upgrades.
  ///
  /// Returns null if all middlewares pass (proceed with upgrade).
  /// Returns a [Response] if a middleware rejects the request.
  Future<Response?> _runMiddlewareChainForUpgrade(
    Request request,
    List<Middleware> middlewareList,
    int index,
    HttpRequest rawRequest,
  ) async {
    // Check if bodyParser has stored a parsed body for this request.
    final parsedBody = RequestHolder.instance.consumeParsedBody(rawRequest);
    if (parsedBody != null) {
      request = request.copyWith(body: parsedBody);
    }

    if (index >= middlewareList.length) {
      return null; // All middlewares passed — proceed with upgrade.
    }

    final middleware = middlewareList[index];

    // We need to detect if the middleware short-circuits.
    // If next() is called, we continue the chain.
    // If a Response is returned without calling next(), it's a rejection.
    Response? chainResult;
    bool nextCalled = false;

    final response = await middleware(request, () async {
      nextCalled = true;
      final body = RequestHolder.instance.consumeParsedBody(rawRequest);
      final updatedRequest =
          body != null ? request.copyWith(body: body) : request;
      chainResult = await _runMiddlewareChainForUpgrade(
        updatedRequest,
        middlewareList,
        index + 1,
        rawRequest,
      );
      // Return a dummy response — the actual result is in chainResult.
      return Response(statusCode: 200);
    });

    if (!nextCalled) {
      // Middleware short-circuited — return rejection response.
      return response;
    }

    return chainResult;
  }

  /// Manages the WebSocket lifecycle after a successful upgrade.
  Future<void> _handleWebSocket(
    WebSocketContext ctx,
    WebSocketRoute route,
  ) async {
    // onStart — fire immediately after upgrade.
    if (route.onStart != null) {
      await route.onStart!(ctx);
    }

    // Wire the raw socket stream to the route's callbacks.
    final completer = Completer<void>();

    ctx.socket.listen(
      (data) async {
        await route.onMessage(ctx, data);
      },
      onError: (Object error) async {
        if (route.onError != null) {
          await route.onError!(ctx, error);
        } else {
          // ignore: avoid_print
          print('[QuadrantServer] WebSocket error on ${ctx.request.path}: $error');
        }
      },
      onDone: () async {
        if (route.onClose != null) {
          await route.onClose!(ctx, ctx.socket.closeCode, ctx.socket.closeReason);
        }
        completer.complete();
      },
      cancelOnError: false,
    );

    // Hold open until the socket closes.
    await completer.future;
  }

  /// Writes a [Response] to the dart:io [HttpResponse] and closes it.
  void _writeResponse(HttpResponse httpResponse, Response response) {
    httpResponse.statusCode = response.statusCode;

    response.headers.forEach((key, value) {
      httpResponse.headers.set(key, value);
    });

    if (response.body.isNotEmpty) {
      httpResponse.write(response.body);
    }

    httpResponse.close();
  }
}
