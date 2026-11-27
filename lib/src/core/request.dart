import 'dart:convert';
import 'dart:io';

import '../engine/engine.dart';

/// Immutable wrapper around [HttpRequest] from dart:io.
///
/// Provides a clean, typed API for handlers and middlewares.
class Request {
  /// HTTP method (GET, POST, PUT, DELETE, PATCH, etc.)
  final String method;

  /// Request path (e.g. /users/123)
  final String path;

  /// Path parameters extracted by the router (e.g. {:id: '123'})
  final Map<String, String> params;

  /// Query string parameters
  final Map<String, String> query;

  /// Request headers
  final Map<String, String> headers;

  /// Parsed JSON body. `null` by default, populated by bodyParser().
  ///
  /// May be a [Map<String, dynamic>] for JSON objects or a [List] for JSON
  /// arrays. Cast accordingly, or use [bodyAsMap] / [bodyAsList] helpers.
  final dynamic body;

  /// Arbitrary per-request context map.
  ///
  /// Middlewares add typed values with [setContext] (e.g. an authenticated
  /// user) for downstream middlewares and handlers to consume.
  ///
  /// ```dart
  /// // In a middleware:
  /// req.setContext('user', user);
  /// return next();
  /// // In a handler:
  /// final user = req.context['user'] as MyUser;
  /// ```
  final Map<String, dynamic> context;

  /// Escape hatch to the underlying dart:io [HttpRequest].
  final HttpRequest raw;

  /// Shared by every copy of a request the framework created; null for one
  /// built with this constructor, which falls back to [scopeOf]'s Expando.
  final RequestScope? _scope;

  const Request({
    required this.method,
    required this.path,
    required this.params,
    required this.query,
    required this.headers,
    this.body,
    this.context = const {},
    required this.raw,
  }) : _scope = null;

  Request._scoped({
    required this.method,
    required this.path,
    required this.params,
    required this.query,
    required this.headers,
    required this.body,
    required this.context,
    required this.raw,
    required RequestScope? scope,
  }) : _scope = scope;

  /// Creates a [Request] from a dart:io [HttpRequest].
  factory Request.fromHttpRequest(HttpRequest httpRequest) {
    if (httpRequest is EngineRequest) return Request._fromEngine(httpRequest);
    final uri = httpRequest.uri;
    final headers = <String, String>{};
    httpRequest.headers.forEach((name, values) {
      headers[name] = values.join(', ');
    });

    return Request._scoped(
      scope: RequestScope(),
      method: httpRequest.method.toUpperCase(),
      path: uri.path,
      params: {},
      // Bad UTF-8 becomes U+FFFD instead of throwing before any handler runs.
      query: Uri.splitQueryString(uri.query,
          encoding: const Utf8Codec(allowMalformed: true)),
      headers: headers,
      body: null,
      context: const {},
      raw: httpRequest,
    );
  }

  /// Reads the engine's parsed form directly, skipping [HttpHeaders] and,
  /// for plain targets, [Uri].
  factory Request._fromEngine(EngineRequest httpRequest) {
    final pairs = httpRequest.headerPairs;
    final headers = <String, String>{};
    for (var i = 0; i < pairs.length; i += 2) {
      final name = pairs[i];
      final previous = headers[name];
      headers[name] =
          previous == null ? pairs[i + 1] : '$previous, ${pairs[i + 1]}';
    }
    final query = httpRequest.query;
    return Request._scoped(
      scope: RequestScope(),
      method: httpRequest.method.toUpperCase(),
      path: httpRequest.path,
      params: {},
      query: query.isEmpty
          ? {}
          : Uri.splitQueryString(query,
              encoding: const Utf8Codec(allowMalformed: true)),
      headers: headers,
      body: null,
      context: const {},
      raw: httpRequest,
    );
  }

  /// Returns a copy of this request with the given fields replaced.
  Request copyWith({
    String? method,
    String? path,
    Map<String, String>? params,
    Map<String, String>? query,
    Map<String, String>? headers,
    dynamic body,
    bool clearBody = false,
    Map<String, dynamic>? context,
  }) {
    return Request._scoped(
      method: method ?? this.method,
      path: path ?? this.path,
      params: params ?? this.params,
      query: query ?? this.query,
      headers: headers ?? this.headers,
      body: clearBody ? null : (body ?? this.body),
      context: context ?? this.context,
      raw: raw,
      scope: _scope,
    );
  }

  /// Adds a value to [context] for everything later in the chain: the
  /// following middlewares, the handler, and WebSocket callbacks.
  ///
  /// Call it in a middleware before `next()`. This [Request] object does not
  /// change, so the new value appears in the `req` that later steps receive.
  void setContext(String key, Object? value) {
    addPendingContext(this, {key: value});
  }

  // ─── Typed body helpers ──────────────────────────────────────

  /// Returns the body as a [Map<String, dynamic>], or null if absent / wrong type.
  Map<String, dynamic>? get bodyAsMap =>
      body is Map<String, dynamic> ? body as Map<String, dynamic> : null;

  /// Returns the body as a [List<dynamic>], or null if absent / wrong type.
  List<dynamic>? get bodyAsList =>
      body is List<dynamic> ? body as List<dynamic> : null;

  // ─── Typed query helpers ─────────────────────────────────────

  /// Returns a query parameter as a [String], or [defaultValue] if absent.
  String queryString(String key, {String defaultValue = ''}) =>
      query[key] ?? defaultValue;

  /// Returns a query parameter parsed as [int], or [defaultValue] if absent
  /// or not parseable.
  int? queryInt(String key, {int? defaultValue}) {
    final raw = query[key];
    if (raw == null) return defaultValue;
    return int.tryParse(raw) ?? defaultValue;
  }

  /// Returns a query parameter parsed as [double], or [defaultValue] if absent
  /// or not parseable.
  double? queryDouble(String key, {double? defaultValue}) {
    final raw = query[key];
    if (raw == null) return defaultValue;
    return double.tryParse(raw) ?? defaultValue;
  }

  /// Returns a query parameter parsed as [bool].
  ///
  /// `'true'`, `'1'`, `'yes'` → `true`.
  /// `'false'`, `'0'`, `'no'` → `false`.
  /// Anything else → [defaultValue].
  bool? queryBool(String key, {bool? defaultValue}) {
    final raw = query[key]?.toLowerCase();
    if (raw == null) return defaultValue;
    if (raw == 'true' || raw == '1' || raw == 'yes') return true;
    if (raw == 'false' || raw == '0' || raw == 'no') return false;
    return defaultValue;
  }
}

/// What middlewares hand on to the rest of the chain, which cannot be put in
/// the immutable [Request] they received. One per request, read by the
/// framework before each step.
///
/// This is an **internal** API — not part of the public surface.
class RequestScope {
  /// A body parsed by a middleware, for [Request.body] from the next step.
  Object? pendingBody;

  /// The whole context for the next step: [Request.context] plus additions.
  Map<String, dynamic>? pendingContext;

  /// Told about an SSE stream started on this request.
  void Function(Object stream)? sseTracker;
}

/// The scope [request] shares with its copies.
///
/// This is an **internal** API — not part of the public surface.
RequestScope scopeOf(Request request) =>
    request._scope ?? (_unscoped[request.raw] ??= RequestScope());

/// For requests built with the public constructor, such as in unit tests.
final _unscoped = Expando<RequestScope>('quadrant_request_scope');

/// Adds [entries] to the context the next step of the chain will see.
///
/// This is an **internal** API — not part of the public surface.
void addPendingContext(Request request, Map<String, dynamic> entries) {
  final scope = scopeOf(request);
  scope.pendingContext = {
    ...(scope.pendingContext ?? request.context),
    ...entries,
  };
}
