// ============================================================
// router.dart — QuadrantServer Route Matching Implementation
// ============================================================
//
// IMPROVEMENTS OVER NAIVE LINEAR SCAN:
//
// 1. O(n/m) lookup — routes grouped by HTTP method
// 2. Method normalization — 'get' and 'GET' both work
// 3. HEAD → GET fallback — HTTP spec compliance
// 4. Trailing slash normalization — '/users/' == '/users'
// 5. 405 Method Not Allowed — distinguishes "wrong method" from "not found"
// 6. URI-decoded params — '%20' in path segments decoded automatically
//
// ============================================================

import 'route.dart';
import 'websocket_route.dart';

// ─── Normalize path helper ───────────────────────────────────

/// Strips trailing slash unless path is root '/'.
/// '/users/'  → '/users'
/// '/users'   → '/users'
/// '/'        → '/'
String _normalizePath(String path) {
  if (path.length > 1 && path.endsWith('/')) {
    return path.substring(0, path.length - 1);
  }
  return path;
}

// ─── RouteMatch result — sealed pattern ──────────────────────

/// Result of attempting to match an incoming request to a route.
sealed class RouteMatchResult {}

/// Path found, method matched — ready to handle.
class Matched extends RouteMatchResult {
  final Route route;
  final Map<String, String> params;

  Matched({required this.route, required this.params});
}

/// Path exists in router but not for this HTTP method.
/// Server should respond 405 and set Allow header.
class MethodNotAllowed extends RouteMatchResult {
  final List<String> allowedMethods;

  MethodNotAllowed({required this.allowedMethods});
}

/// Path does not exist at all.
/// Server should respond 404.
class NotFound extends RouteMatchResult {}

/// WebSocket route matched — ready to upgrade.
class MatchedWebSocket extends RouteMatchResult {
  final WebSocketRoute route;
  final Map<String, String> params;

  MatchedWebSocket({required this.route, required this.params});
}

// ─── Router ──────────────────────────────────────────────────

/// Internal router. Groups routes by HTTP method for fast lookup.
/// Returns typed [RouteMatchResult] for proper 404 vs 405 handling.
class Router {
  /// Routes grouped by HTTP method for O(n/m) lookup.
  final Map<String, List<Route>> _routesByMethod = {};

  /// Flat list for MethodNotAllowed lookup.
  final List<Route> _allRoutes = [];

  /// WebSocket routes for upgrade requests.
  final List<WebSocketRoute> _webSocketRoutes;

  Router(List<Route> routes, {List<WebSocketRoute> webSocketRoutes = const []})
      : _webSocketRoutes = webSocketRoutes {
    for (final route in routes) {
      final method = route.method.toUpperCase();
      _routesByMethod.putIfAbsent(method, () => []).add(route);
      _allRoutes.add(route);
    }
  }

  /// Match an incoming [method] + [path] against registered routes.
  /// Returns [Matched], [MatchedWebSocket], [MethodNotAllowed], or [NotFound].
  ///
  /// When [isUpgradeRequest] is true, only WebSocket routes are checked.
  RouteMatchResult match(String method, String path,
      {bool isUpgradeRequest = false}) {
    final normalizedPath = _normalizePath(path);

    // WebSocket upgrade requests only match WS routes.
    if (isUpgradeRequest) {
      for (final wsRoute in _webSocketRoutes) {
        final params = _matchPath(wsRoute.path, normalizedPath);
        if (params != null) {
          return MatchedWebSocket(route: wsRoute, params: params);
        }
      }
      return NotFound();
    }

    final normalizedMethod = method.toUpperCase();

    // HEAD falls back to GET routes (HTTP spec requirement).
    final lookupMethods =
        normalizedMethod == 'HEAD' ? ['HEAD', 'GET'] : [normalizedMethod];

    for (final m in lookupMethods) {
      final candidates = _routesByMethod[m] ?? [];
      for (final route in candidates) {
        final params = _matchPath(route.path, normalizedPath);
        if (params != null) {
          return Matched(route: route, params: params);
        }
      }
    }

    // Check if path exists under any other method → 405.
    final allowedMethods = _findAllowedMethods(normalizedPath);
    if (allowedMethods.isNotEmpty) {
      return MethodNotAllowed(allowedMethods: allowedMethods);
    }

    return NotFound();
  }

  /// Returns which HTTP methods are registered for this [path].
  /// Used to build the `Allow` header on 405 responses.
  List<String> _findAllowedMethods(String path) {
    final allowed = <String>[];
    for (final route in _allRoutes) {
      if (_matchPath(route.path, path) != null) {
        allowed.add(route.method);
      }
    }
    // If GET is allowed, HEAD is implicitly allowed too.
    if (allowed.contains('GET') && !allowed.contains('HEAD')) {
      allowed.add('HEAD');
    }
    return allowed;
  }

  /// Match a route [pattern] against an incoming [path].
  ///
  /// Returns a params map on success: {'id': '42'}
  /// Returns null if the path does not match the pattern.
  Map<String, String>? _matchPath(String pattern, String path) {
    final patternSegments = _segments(pattern);
    final pathSegments = _segments(path);

    if (patternSegments.length != pathSegments.length) return null;

    final params = <String, String>{};

    for (var i = 0; i < patternSegments.length; i++) {
      final p = patternSegments[i];
      final s = pathSegments[i];

      if (p.startsWith(':')) {
        // Dynamic segment — capture value (URI-decoded).
        params[p.substring(1)] = Uri.decodeComponent(s);
      } else if (p != s) {
        // Static segment mismatch.
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
