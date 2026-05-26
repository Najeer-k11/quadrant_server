import 'route.dart';

/// Result of a successful route match.
class RouteMatch {
  final Route route;
  final Map<String, String> params;

  const RouteMatch({required this.route, required this.params});
}

/// Internal router. Matches incoming requests to registered routes.
class Router {
  final List<Route> _routes;

  Router(this._routes);

  /// Attempts to match the given [method] and [path] to a registered route.
  ///
  /// Returns a [RouteMatch] with extracted path params on success, or null
  /// if no route matches.
  RouteMatch? match(String method, String path) {
    for (final route in _routes) {
      if (route.method != method) continue;

      final params = _matchPath(route.path, path);
      if (params != null) {
        return RouteMatch(route: route, params: params);
      }
    }
    return null;
  }

  /// Matches a route pattern against an actual path.
  ///
  /// Returns extracted params map on success, null on failure.
  /// Supports :param segments (e.g. /users/:id matches /users/123).
  Map<String, String>? _matchPath(String pattern, String path) {
    final patternSegments = _segments(pattern);
    final pathSegments = _segments(path);

    if (patternSegments.length != pathSegments.length) return null;

    final params = <String, String>{};

    for (var i = 0; i < patternSegments.length; i++) {
      final patternSeg = patternSegments[i];
      final pathSeg = pathSegments[i];

      if (patternSeg.startsWith(':')) {
        // Dynamic segment — extract param
        params[patternSeg.substring(1)] = pathSeg;
      } else if (patternSeg != pathSeg) {
        // Static segment mismatch
        return null;
      }
    }

    return params;
  }

  /// Splits a path into non-empty segments.
  List<String> _segments(String path) {
    return path.split('/').where((s) => s.isNotEmpty).toList();
  }
}
