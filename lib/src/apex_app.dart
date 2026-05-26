import 'dart:io';

import 'middleware.dart';
import 'request.dart';
import 'response.dart';
import 'route.dart';
import 'router.dart';
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

  /// Optional global error handler. Returns a [Response].
  final ErrorHandler? onError;

  final Router _router;

  QuadrantServer({
    this.middlewares = const [],
    required this.routes,
    this.onError,
  }) : _router = Router(routes);

  /// Binds a dart:io [HttpServer] to the given [port] and starts handling
  /// incoming requests.
  ///
  /// Optionally specify [address] (defaults to any IPv4).
  Future<HttpServer> listen({
    required int port,
    dynamic address = '0.0.0.0',
  }) async {
    final server = await HttpServer.bind(address, port);

    server.listen((httpRequest) async {
      await _handleRequest(httpRequest);
    });

    return server;
  }

  /// Handles a single incoming [HttpRequest].
  Future<void> _handleRequest(HttpRequest httpRequest) async {
    Request request = Request.fromHttpRequest(httpRequest);
    final requestHash = httpRequest.hashCode;

    try {
      // Match route
      final match = _router.match(request.method, request.path);

      if (match == null) {
        final response = Response.notFound('Route not found');
        _writeResponse(httpRequest.response, response);
        return;
      }

      // Attach path params to request
      request = request.copyWith(params: match.params);

      // Build middleware chain: [global] + [route-level] + [handler]
      final allMiddlewares = [...middlewares, ...match.route.middlewares];

      // Execute the chain
      final response = await _executeChain(
        allMiddlewares,
        0,
        request,
        match.route.handler,
        requestHash,
      );

      _writeResponse(httpRequest.response, response);
    } catch (error) {
      final response = onError != null
          ? onError!(error, request)
          : Response.internalServerError(error.toString());
      _writeResponse(httpRequest.response, response);
    } finally {
      // Clean up any parsed body that wasn't consumed
      RequestHolder.instance.consumeParsedBody(requestHash);
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
    int requestHash,
  ) async {
    // Check if bodyParser has stored a parsed body for this request
    final parsedBody = RequestHolder.instance.consumeParsedBody(requestHash);
    if (parsedBody != null) {
      request = request.copyWith(body: parsedBody);
    }

    if (index >= middlewareList.length) {
      return handler(request);
    }

    final middleware = middlewareList[index];

    return middleware(request, () async {
      // After this middleware runs, check for parsed body again
      final body = RequestHolder.instance.consumeParsedBody(requestHash);
      final updatedRequest =
          body != null ? request.copyWith(body: body) : request;
      return _executeChain(
        middlewareList,
        index + 1,
        updatedRequest,
        handler,
        requestHash,
      );
    });
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
