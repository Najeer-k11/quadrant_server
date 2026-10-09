import 'dart:convert';

/// Immutable HTTP response object.
///
/// Handlers and middlewares always return a [Response] — never mutate one.
class Response {
  final int statusCode;
  final Map<String, String> headers;
  final String body;

  /// `Set-Cookie` values. Each entry becomes a separate `Set-Cookie` header.
  ///
  /// Use [withCookie] to add cookies in a non-mutating way:
  /// ```dart
  /// return Response.ok(data).withCookie('session', token, httpOnly: true);
  /// ```
  final List<String> cookies;

  const Response({
    required this.statusCode,
    this.headers = const {},
    this.body = '',
    this.cookies = const [],
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
    if (statusCode != 301 &&
        statusCode != 302 &&
        statusCode != 307 &&
        statusCode != 308) {
      throw ArgumentError.value(
          statusCode, 'statusCode', 'Must be 301, 302, 307, or 308.');
    }
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

  // ─── Cookie helper ───────────────────────────────────────────

  /// Returns a new [Response] with a `Set-Cookie` header appended.
  ///
  /// Multiple cookies can be set by chaining calls:
  /// ```dart
  /// return Response.ok(data)
  ///     .withCookie('session', token, httpOnly: true, sameSite: 'Strict')
  ///     .withCookie('lang', 'en');
  /// ```
  ///
  /// [name] / [value] — the cookie name and value (will be URL-encoded if needed).
  /// [maxAge] — cookie lifetime. Omit for a session cookie.
  /// [path] — cookie path. Defaults to `'/'`.
  /// [domain] — cookie domain. Omit to use the request host.
  /// [httpOnly] — prevents JavaScript access. Default: `true`.
  /// [secure] — send only over HTTPS. Default: `false`.
  /// [sameSite] — `'Strict'`, `'Lax'`, or `'None'`. Default: `'Lax'`.
  Response withCookie(
    String name,
    String value, {
    Duration? maxAge,
    String path = '/',
    String? domain,
    bool httpOnly = true,
    bool secure = false,
    String sameSite = 'Lax',
  }) {
    final buf = StringBuffer('$name=${Uri.encodeComponent(value)}');
    if (maxAge != null) buf.write('; Max-Age=${maxAge.inSeconds}');
    buf.write('; Path=$path');
    if (domain != null) buf.write('; Domain=$domain');
    if (httpOnly) buf.write('; HttpOnly');
    if (secure) buf.write('; Secure');
    buf.write('; SameSite=$sameSite');

    return copyWith(cookies: [...cookies, buf.toString()]);
  }

  /// Returns a new [Response] that clears a cookie by setting `Max-Age=0`.
  Response clearCookie(String name, {String path = '/'}) {
    return withCookie(name, '', maxAge: Duration.zero, path: path);
  }

  /// Returns a copy of this response with the given fields replaced.
  ///
  /// Middlewares should use this instead of `Response(...)` so that nothing
  /// is lost (cookies) and subclasses such as [StreamResponse] survive.
  Response copyWith({
    int? statusCode,
    Map<String, String>? headers,
    String? body,
    List<String>? cookies,
  }) {
    return Response(
      statusCode: statusCode ?? this.statusCode,
      headers: headers ?? this.headers,
      body: body ?? this.body,
      cookies: cookies ?? this.cookies,
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
