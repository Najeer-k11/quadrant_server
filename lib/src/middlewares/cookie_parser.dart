import '../middleware.dart';
import '../request.dart';

/// Cookie parser middleware.
///
/// Parses the `Cookie` request header and injects the result into
/// `req.context['cookies']` as a `Map<String, String>`.
///
/// ```dart
/// middlewares: [cookieParser()]
///
/// // In a handler:
/// final cookies = req.context['cookies'] as Map<String, String>;
/// final sessionId = cookies['session'];
/// ```
///
/// **Setting cookies** — use [Response.withCookie] on the response:
///
/// ```dart
/// return Response.ok(data)
///     .withCookie('session', token, httpOnly: true, sameSite: 'Strict',
///                 maxAge: Duration(hours: 8))
///     .withCookie('lang', 'en');
/// ```
///
/// **Clearing cookies** — use [Response.clearCookie]:
///
/// ```dart
/// return Response.ok({}).clearCookie('session');
/// ```
///
/// [contextKey] — key under which the parsed map is stored in
///   [Request.context]. Defaults to `'cookies'`.
Middleware cookieParser({String contextKey = 'cookies'}) {
  return (Request req, Next next) async {
    final cookieHeader = req.headers['cookie'] ?? '';
    final cookies = _parseCookies(cookieHeader);

    _cookieOverrides[req.raw] = {...req.context, contextKey: cookies};
    final response = await next();
    _cookieOverrides[req.raw] = null;
    return response;
  };
}

/// Parses a `Cookie` header value into a map.
///
/// Format: `name1=value1; name2=value2`
/// Values are URI-decoded if possible.
Map<String, String> _parseCookies(String header) {
  if (header.isEmpty) return const {};

  final result = <String, String>{};
  for (final pair in header.split(';')) {
    final idx = pair.indexOf('=');
    if (idx == -1) continue;
    final name = pair.substring(0, idx).trim();
    final raw = pair.substring(idx + 1).trim();
    if (name.isEmpty) continue;
    try {
      result[name] = Uri.decodeComponent(raw);
    } catch (_) {
      result[name] = raw; // use raw value if decoding fails
    }
  }
  return result;
}

// ─── Context propagation ──────────────────────────────────────

final _cookieOverrides =
    Expando<Map<String, dynamic>>('quadrant_cookies');

/// Internal — consumed by [QuadrantServer._executeChain].
Map<String, dynamic>? consumeCookieContext(Object rawRequest) {
  final val = _cookieOverrides[rawRequest];
  if (val != null) _cookieOverrides[rawRequest] = null;
  return val;
}
