import 'middleware.dart';
import 'request.dart';
import 'response.dart';

/// Handler function type — takes a [Request], returns a [Response].
typedef Handler = Future<Response> Function(Request req);

/// Immutable route definition.
///
/// Use named constructors for each HTTP method:
/// ```dart
/// Route.get(path: '/users', handler: getUsers)
/// Route.post(path: '/users', handler: createUser)
/// ```
class Route {
  /// HTTP method (GET, POST, PUT, DELETE, PATCH).
  final String method;

  /// Route path pattern. Supports :param segments (e.g. /users/:id).
  final String path;

  /// The handler function for this route.
  final Handler handler;

  /// Route-level middlewares, applied after global middlewares.
  final List<Middleware> middlewares;

  const Route({
    required this.method,
    required this.path,
    required this.handler,
    this.middlewares = const [],
  });

  /// GET route.
  factory Route.get({
    required String path,
    required Handler handler,
    List<Middleware> middlewares = const [],
  }) => Route(
    method: 'GET',
    path: path,
    handler: handler,
    middlewares: middlewares,
  );

  /// POST route.
  factory Route.post({
    required String path,
    required Handler handler,
    List<Middleware> middlewares = const [],
  }) => Route(
    method: 'POST',
    path: path,
    handler: handler,
    middlewares: middlewares,
  );

  /// PUT route.
  factory Route.put({
    required String path,
    required Handler handler,
    List<Middleware> middlewares = const [],
  }) => Route(
    method: 'PUT',
    path: path,
    handler: handler,
    middlewares: middlewares,
  );

  /// DELETE route.
  factory Route.delete({
    required String path,
    required Handler handler,
    List<Middleware> middlewares = const [],
  }) => Route(
    method: 'DELETE',
    path: path,
    handler: handler,
    middlewares: middlewares,
  );

  /// PATCH route.
  factory Route.patch({
    required String path,
    required Handler handler,
    List<Middleware> middlewares = const [],
  }) => Route(
    method: 'PATCH',
    path: path,
    handler: handler,
    middlewares: middlewares,
  );
}
