// ============================================================
// router.dart — QuadrantServer Route Matching Implementation
// ============================================================
//
// FEATURES:
//
// 1. Indexed lookup — routes grouped by HTTP method, then by first path
//    segment. Patterns are split once at startup and each request path once,
//    and the first registered match wins, so a route can be placed before a
//    more general one.
// 2. Method normalization — 'get' and 'GET' both work
// 3. HEAD → GET fallback — HTTP spec compliance
// 4. Trailing slash normalization — '/users/' == '/users'
// 5. 405 Method Not Allowed — distinguishes "wrong method" from "not found"
// 6. URI-decoded params — '%20' in path segments decoded automatically
// 7. Wildcard segments — '/files/*' matches '/files/a/b/c'
//    Captured as params['*'] = 'a/b/c'
//
// ============================================================

import 'route.dart';
import '../realtime/websocket_route.dart';

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

  /// The routes registered for this path, under other methods.
  final List<Route> routes;

  MethodNotAllowed({required this.allowedMethods, this.routes = const []});
}

/// Path does not exist at all.
/// Server should respond 404.
class NotFound extends RouteMatchResult {}

/// A path param is not valid percent-encoded UTF-8 (e.g. `/users/%FF`).
/// Server should respond 400.
class MalformedPath extends RouteMatchResult {}

/// WebSocket route matched — ready to upgrade.
class MatchedWebSocket extends RouteMatchResult {
  final WebSocketRoute route;
  final Map<String, String> params;

  MatchedWebSocket({required this.route, required this.params});
}

// ─── Router ──────────────────────────────────────────────────

/// A route pattern split into segments ahead of time.
class _CompiledPattern {
  final List<String> segments;
  final bool hasWildcard;

  /// Number of segments before the wildcard, if there is one.
  final int fixedLength;

  /// Names of `:param` segments by position; null for static segments.
  final List<String?> paramNames;

  factory _CompiledPattern(String pattern) {
    final segments = _segments(pattern);
    final hasWildcard = segments.isNotEmpty && segments.last == '*';
    final fixed = hasWildcard ? segments.length - 1 : segments.length;
    return _CompiledPattern._(
      segments,
      hasWildcard,
      fixed,
      [
        for (var i = 0; i < fixed; i++)
          segments[i].startsWith(':') ? segments[i].substring(1) : null,
      ],
    );
  }

  _CompiledPattern._(
    this.segments,
    this.hasWildcard,
    this.fixedLength,
    this.paramNames,
  );

  /// Whether [path] matches. Allocates nothing, so a route that does not match
  /// costs only a few comparisons.
  bool matches(List<String> path) {
    if (hasWildcard ? path.length < fixedLength : path.length != fixedLength) {
      return false;
    }
    for (var i = 0; i < fixedLength; i++) {
      if (paramNames[i] == null && segments[i] != path[i]) return false;
    }
    return true;
  }

  /// Extracts the params of a [path] that [matches], or returns null if one
  /// of them cannot be decoded.
  Map<String, String>? tryParams(List<String> path) {
    final params = <String, String>{};
    try {
      for (var i = 0; i < fixedLength; i++) {
        final name = paramNames[i];
        if (name != null) params[name] = Uri.decodeComponent(path[i]);
      }
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    }
    if (hasWildcard) params['*'] = path.skip(fixedLength).join('/');
    return params;
  }
}

class _CompiledRoute {
  final Route route;
  final _CompiledPattern pattern;

  /// Registration order, which decides between routes that both match.
  final int order;

  _CompiledRoute(this.route, this.order)
      : pattern = _CompiledPattern(route.path);
}

/// One method's routes, indexed by their first segment so that a request
/// only tries the routes that could match it.
class _MethodRoutes {
  /// Routes whose first segment is fixed, by that segment. A route for `/`
  /// is under the empty string.
  final Map<String, List<_CompiledRoute>> byFirstSegment = {};

  /// Routes starting with a `:param` or `*`, which any first segment fits.
  final List<_CompiledRoute> anyFirstSegment = [];

  void add(_CompiledRoute route) {
    final pattern = route.pattern;
    if (pattern.fixedLength == 0) {
      if (pattern.hasWildcard) {
        anyFirstSegment.add(route);
      } else {
        (byFirstSegment[''] ??= []).add(route);
      }
    } else if (pattern.paramNames[0] != null) {
      anyFirstSegment.add(route);
    } else {
      (byFirstSegment[pattern.segments[0]] ??= []).add(route);
    }
  }

  /// The first route, in registration order, that matches [segments].
  _CompiledRoute? match(List<String> segments) {
    final fixed =
        byFirstSegment[segments.isEmpty ? '' : segments[0]] ?? const [];
    final any = anyFirstSegment;
    // Both lists are in registration order: merge them, first match wins.
    var i = 0, j = 0;
    while (i < fixed.length || j < any.length) {
      final _CompiledRoute next;
      if (j >= any.length ||
          (i < fixed.length && fixed[i].order < any[j].order)) {
        next = fixed[i++];
      } else {
        next = any[j++];
      }
      if (next.pattern.matches(segments)) return next;
    }
    return null;
  }
}

class _CompiledWebSocketRoute {
  final WebSocketRoute route;
  final _CompiledPattern pattern;

  _CompiledWebSocketRoute(this.route) : pattern = _CompiledPattern(route.path);
}

/// Internal router. Groups routes by HTTP method for fast lookup.
/// Returns typed [RouteMatchResult] for proper 404 vs 405 handling.
class Router {
  /// Routes grouped by HTTP method, then by first segment.
  final Map<String, _MethodRoutes> _routesByMethod = {};

  /// Flat list for MethodNotAllowed lookup.
  final List<_CompiledRoute> _allRoutes = [];

  /// WebSocket routes for upgrade requests.
  final List<_CompiledWebSocketRoute> _webSocketRoutes;

  Router(List<Route> routes, {List<WebSocketRoute> webSocketRoutes = const []})
      : _webSocketRoutes = [
          for (final route in webSocketRoutes) _CompiledWebSocketRoute(route),
        ] {
    for (final route in routes) {
      final compiled = _CompiledRoute(route, _allRoutes.length);
      _routesByMethod
          .putIfAbsent(route.method.toUpperCase(), _MethodRoutes.new)
          .add(compiled);
      _allRoutes.add(compiled);
    }
  }

  /// Match an incoming [method] + [path] against registered routes.
  /// Returns [Matched], [MatchedWebSocket], [MalformedPath],
  /// [MethodNotAllowed], or [NotFound].
  ///
  /// When [isUpgradeRequest] is true, only WebSocket routes are checked.
  RouteMatchResult match(String method, String path,
      {bool isUpgradeRequest = false}) {
    // Empty segments are dropped, so '/users/' and '/users' are the same.
    final segments = _segments(path);

    // WebSocket upgrade requests only match WS routes.
    if (isUpgradeRequest) {
      for (final ws in _webSocketRoutes) {
        if (ws.pattern.matches(segments)) {
          final params = ws.pattern.tryParams(segments);
          return params == null
              ? MalformedPath()
              : MatchedWebSocket(route: ws.route, params: params);
        }
      }
      return NotFound();
    }

    final normalizedMethod = method.toUpperCase();

    // HEAD falls back to GET routes (HTTP spec requirement).
    final match = _routesByMethod[normalizedMethod]?.match(segments) ??
        (normalizedMethod == 'HEAD'
            ? _routesByMethod['GET']?.match(segments)
            : null);
    if (match != null) {
      final params = match.pattern.tryParams(segments);
      return params == null
          ? MalformedPath()
          : Matched(route: match.route, params: params);
    }

    // Check if path exists under any other method → 405.
    final pathRoutes = [
      for (final candidate in _allRoutes)
        if (candidate.pattern.matches(segments)) candidate.route,
    ];
    if (pathRoutes.isNotEmpty) {
      return MethodNotAllowed(
        allowedMethods: _allowedMethods(pathRoutes),
        routes: pathRoutes,
      );
    }

    return NotFound();
  }

  /// Returns which HTTP methods [routes] accept, for the `Allow` header.
  List<String> _allowedMethods(List<Route> routes) {
    final allowed = [for (final route in routes) route.method];
    // If GET is allowed, HEAD is implicitly allowed too.
    if (allowed.contains('GET') && !allowed.contains('HEAD')) {
      allowed.add('HEAD');
    }
    return allowed;
  }
}

/// Splits a path into non-empty segments.
List<String> _segments(String path) {
  final segments = <String>[];
  var start = 0;
  for (var i = 0; i <= path.length; i++) {
    if (i == path.length || path.codeUnitAt(i) == 0x2F) {
      if (i > start) segments.add(path.substring(start, i));
      start = i + 1;
    }
  }
  return segments;
}
