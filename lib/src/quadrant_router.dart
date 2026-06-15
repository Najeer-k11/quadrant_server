import 'middleware.dart';
import 'route.dart';
import 'websocket_route.dart';

/// A route group that prefixes all its routes with a common path segment.
///
/// Use [QuadrantRouter] to organise large applications into logical sections
/// (e.g. API versions, feature modules) without repeating path prefixes.
///
/// ```dart
/// final usersRouter = QuadrantRouter(prefix: '/api/v1')
///   ..get('/users', getUsers)
///   ..post('/users', createUser)
///   ..get('/users/:id', getUser);
///
/// final app = QuadrantServer(
///   routes: [
///     ...usersRouter.routes,
///   ],
/// );
/// ```
///
/// Router-level [middlewares] are prepended to every route's middleware list.
class QuadrantRouter {
  /// The path prefix prepended to every route added to this router.
  final String prefix;

  /// Middlewares applied to every route in this router, before route-level ones.
  final List<Middleware> middlewares;

  final List<Route> _routes = [];
  final List<WebSocketRoute> _wsRoutes = [];

  QuadrantRouter({
    required this.prefix,
    this.middlewares = const [],
  });

  /// All HTTP [Route]s registered on this router (prefix already applied).
  List<Route> get routes => List.unmodifiable(_routes);

  /// All [WebSocketRoute]s registered on this router (prefix already applied).
  List<WebSocketRoute> get webSocketRoutes => List.unmodifiable(_wsRoutes);

  // ─── HTTP route registration ─────────────────────────────────

  /// Registers a GET route at [prefix] + [path].
  QuadrantRouter get(String path, Handler handler,
      {List<Middleware> middlewares = const []}) {
    _add('GET', path, handler, middlewares);
    return this;
  }

  /// Registers a POST route at [prefix] + [path].
  QuadrantRouter post(String path, Handler handler,
      {List<Middleware> middlewares = const []}) {
    _add('POST', path, handler, middlewares);
    return this;
  }

  /// Registers a PUT route at [prefix] + [path].
  QuadrantRouter put(String path, Handler handler,
      {List<Middleware> middlewares = const []}) {
    _add('PUT', path, handler, middlewares);
    return this;
  }

  /// Registers a DELETE route at [prefix] + [path].
  QuadrantRouter delete(String path, Handler handler,
      {List<Middleware> middlewares = const []}) {
    _add('DELETE', path, handler, middlewares);
    return this;
  }

  /// Registers a PATCH route at [prefix] + [path].
  QuadrantRouter patch(String path, Handler handler,
      {List<Middleware> middlewares = const []}) {
    _add('PATCH', path, handler, middlewares);
    return this;
  }

  // ─── WebSocket route registration ───────────────────────────

  /// Registers a WebSocket route at [prefix] + [path].
  QuadrantRouter ws(
    String path, {
    required OnMessageCallback onMessage,
    OnStartCallback? onStart,
    OnCloseCallback? onClose,
    OnErrorCallback? onError,
    List<Middleware> middlewares = const [],
  }) {
    _wsRoutes.add(WebSocketRoute(
      path: _buildPath(path),
      onMessage: onMessage,
      onStart: onStart,
      onClose: onClose,
      onError: onError,
      middlewares: [...this.middlewares, ...middlewares],
    ));
    return this;
  }

  // ─── Internal ────────────────────────────────────────────────

  void _add(
    String method,
    String path,
    Handler handler,
    List<Middleware> routeMiddlewares,
  ) {
    _routes.add(Route(
      method: method,
      path: _buildPath(path),
      handler: handler,
      middlewares: [...middlewares, ...routeMiddlewares],
    ));
  }

  /// Combines [prefix] and [path], normalising double slashes.
  String _buildPath(String path) {
    final cleanPrefix = prefix.endsWith('/') && prefix.length > 1
        ? prefix.substring(0, prefix.length - 1)
        : prefix;
    final cleanPath = path.startsWith('/') ? path : '/$path';
    return '$cleanPrefix$cleanPath';
  }
}
