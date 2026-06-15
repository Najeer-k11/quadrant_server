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

  // ─── Success ─────────────────────────────────────────────────

  /// 200 OK. If [data] is a Map or List, it is JSON-encoded automatically.
  factory Response.ok(dynamic data) => _buildJson(200, data);

  /// 201 Created. If [data] is a Map or List, it is JSON-encoded automatically.
  factory Response.created(dynamic data) => _buildJson(201, data);

  /// 204 No Content.
  factory Response.noContent() => const Response(statusCode: 204);

  // ─── Redirection ─────────────────────────────────────────────

  /// 301 Moved Permanently / 302 Found redirect.
  ///
  /// [location] is the target URL. [statusCode] defaults to 302.
  factory Response.redirect(String location, {int statusCode = 302}) {
    assert(statusCode == 301 || statusCode == 302 || statusCode == 307 || statusCode == 308,
        'Redirect status code must be 301, 302, 307, or 308.');
    return Response(
      statusCode: statusCode,
      headers: {'location': location},
    );
  }

  // ─── Client errors ───────────────────────────────────────────

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

  /// 409 Conflict.
  factory Response.conflict(String message) =>
      _buildJson(409, {'error': message});

  /// 422 Unprocessable Entity.
  factory Response.unprocessableEntity(String message) =>
      _buildJson(422, {'error': message});

  // ─── Server errors ───────────────────────────────────────────

  /// 500 Internal Server Error.
  ///
  /// Prefer providing a safe [message] in production — avoid leaking
  /// raw exception strings to clients.
  factory Response.internalServerError(String message) =>
      _buildJson(500, {'error': message});

  // ─── Content-type helpers ────────────────────────────────────

  /// Plain-text response with `content-type: text/plain`.
  factory Response.text(String text, {int statusCode = 200}) {
    return Response(
      statusCode: statusCode,
      headers: {'content-type': 'text/plain; charset=utf-8'},
      body: text,
    );
  }

  /// HTML response with `content-type: text/html`.
  factory Response.html(String html, {int statusCode = 200}) {
    return Response(
      statusCode: statusCode,
      headers: {'content-type': 'text/html; charset=utf-8'},
      body: html,
    );
  }

  // ─── Internal ────────────────────────────────────────────────

  /// Builds a JSON response if [data] is a Map or List, otherwise treats it
  /// as a plain text string with `content-type: text/plain`.
  static Response _buildJson(int statusCode, dynamic data) {
    if (data is Map || data is List) {
      return Response(
        statusCode: statusCode,
        headers: {'content-type': 'application/json'},
        body: jsonEncode(data),
      );
    }
    return Response(
      statusCode: statusCode,
      headers: {'content-type': 'text/plain; charset=utf-8'},
      body: data.toString(),
    );
  }
}
