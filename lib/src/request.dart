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

  /// Parsed JSON body. Empty map by default, populated by bodyParser().
  final Map<String, dynamic> body;

  /// Escape hatch to the underlying dart:io [HttpRequest].
  final HttpRequest raw;

  const Request({
    required this.method,
    required this.path,
    required this.params,
    required this.query,
    required this.headers,
    required this.body,
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
      body: {},
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
    Map<String, dynamic>? body,
  }) {
    return Request(
      method: method ?? this.method,
      path: path ?? this.path,
      params: params ?? this.params,
      query: query ?? this.query,
      headers: headers ?? this.headers,
      body: body ?? this.body,
      raw: raw,
    );
  }
}
