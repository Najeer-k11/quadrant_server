import 'dart:convert';

/// Immutable HTTP response object.
///
/// Handlers and middlewares always return a [Response] — never mutate one.
class Response {
  final int statusCode;
  final Map<String, String> headers;
  final String body;

  const Response({
    required this.statusCode,
    this.headers = const {},
    this.body = '',
  });

  /// 200 OK. If [data] is a Map or List, it is JSON-encoded automatically.
  factory Response.ok(dynamic data) => _buildJson(200, data);

  /// 201 Created. If [data] is a Map or List, it is JSON-encoded automatically.
  factory Response.created(dynamic data) => _buildJson(201, data);

  /// 204 No Content.
  factory Response.noContent() => const Response(statusCode: 204);

  /// 400 Bad Request.
  factory Response.badRequest(String message) =>
      _buildJson(400, {'error': message});

  /// 401 Unauthorized.
  factory Response.unauthorized(String message) =>
      _buildJson(401, {'error': message});

  /// 403 Forbidden.
  factory Response.forbidden(String message) =>
      _buildJson(403, {'error': message});

  /// 404 Not Found.
  factory Response.notFound(String message) =>
      _buildJson(404, {'error': message});

  /// 500 Internal Server Error.
  factory Response.internalServerError(String message) =>
      _buildJson(500, {'error': message});

  /// Builds a JSON response if [data] is a Map or List, otherwise treats it
  /// as a plain string.
  static Response _buildJson(int statusCode, dynamic data) {
    if (data is Map || data is List) {
      return Response(
        statusCode: statusCode,
        headers: {'content-type': 'application/json'},
        body: jsonEncode(data),
      );
    }
    return Response(statusCode: statusCode, body: data.toString());
  }
}
