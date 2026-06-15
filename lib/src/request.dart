import 'dart:io';

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

  /// Escape hatch to the underlying dart:io [HttpRequest].
  final HttpRequest raw;

  const Request({
    required this.method,
    required this.path,
    required this.params,
    required this.query,
    required this.headers,
    this.body,
    required this.raw,
  });

  /// Creates a [Request] from a dart:io [HttpRequest].
  factory Request.fromHttpRequest(HttpRequest httpRequest) {
    final uri = httpRequest.uri;
    final headers = <String, String>{};
    httpRequest.headers.forEach((name, values) {
      headers[name] = values.join(', ');
    });

    return Request(
      method: httpRequest.method.toUpperCase(),
      path: uri.path,
      params: {},
      query: uri.queryParameters,
      headers: headers,
      body: null,
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
  }) {
    return Request(
      method: method ?? this.method,
      path: path ?? this.path,
      params: params ?? this.params,
      query: query ?? this.query,
      headers: headers ?? this.headers,
      body: clearBody ? null : (body ?? this.body),
      raw: raw,
    );
  }

  // ─── Typed body helpers ──────────────────────────────────────

  /// Returns the body as a [Map<String, dynamic>], or null if absent / wrong type.
  Map<String, dynamic>? get bodyAsMap =>
      body is Map<String, dynamic> ? body as Map<String, dynamic> : null;

  /// Returns the body as a [List<dynamic>], or null if absent / wrong type.
  List<dynamic>? get bodyAsList => body is List<dynamic> ? body as List<dynamic> : null;

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
