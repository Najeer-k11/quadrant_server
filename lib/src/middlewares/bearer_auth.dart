import '../middleware.dart';
import '../request.dart';
import '../response.dart';

/// Bearer token authentication middleware.
///
/// Extracts the token from the `Authorization: Bearer <token>` header,
/// calls [validate] with it, and injects the resolved principal into
/// [Request.context] under [contextKey] (default: `'user'`).
///
/// If the header is missing, malformed, or [validate] returns `null`,
/// the request is rejected with `401 Unauthorized`.
///
/// ```dart
/// // Usage — global:
/// bearerAuth(validate: (token) async => await db.findUserByToken(token))
///
/// // Usage — route-level:
/// Route.get(
///   path: '/me',
///   handler: (req) async {
///     final user = req.context['user'] as MyUser;
///     return Response.ok(user.toJson());
///   },
///   middlewares: [
///     bearerAuth(validate: (token) async => await db.findUserByToken(token)),
///   ],
/// )
/// ```
///
/// [validate] — async callback receiving the raw token string; return the
///   resolved principal (any non-null object) to allow, or `null` to reject.
///
/// [contextKey] — key under which the principal is stored in [Request.context].
///   Defaults to `'user'`.
///
/// [realm] — value of the `WWW-Authenticate` realm field. Defaults to `'api'`.
///
/// ### How context propagation works
///
/// The [Next] typedef (`Future<Response> Function()`) doesn't accept a
/// modified request, so `bearerAuth` uses a thin wrapper middleware that
/// wraps the real chain with the updated request captured in a closure.
Middleware bearerAuth<T extends Object?>({
  required Future<T?> Function(String token) validate,
  String contextKey = 'user',
  String realm = 'api',
}) {
  return (Request req, Next next) async {
    final authHeader = req.headers['authorization'] ?? '';

    if (!authHeader.startsWith('Bearer ')) {
      return _deny(realm);
    }

    final token = authHeader.substring(7).trim();
    if (token.isEmpty) {
      return _deny(realm);
    }

    final principal = await validate(token);
    if (principal == null) {
      return _deny(realm);
    }

    // Inject the principal into the request's context map.
    // The updated request is visible to all subsequent middlewares and the
    // handler because the framework re-reads context on each chain step.
    //
    // Since Next doesn't accept a Request, we propagate via Expando.
    _contextOverrides[req.raw] = {...req.context, contextKey: principal};

    try {
      return await next();
    } finally {
      _contextOverrides[req.raw] = null;
    }
  };
}

/// Internal expando used to pass a merged context map to the chain runner
/// without requiring changes to the [Next] typedef.
///
/// Keyed on [HttpRequest] — identity-safe, no hash collisions.
final Expando<Map<String, dynamic>> _contextOverrides =
    Expando('quadrant_context');

/// Retrieves and merges any pending context override for [req].
///
/// Called by [QuadrantServer._executeChain] after each middleware step so
/// that [bearerAuth]-injected values appear in the downstream request.
///
/// This is an **internal** API — not part of the public surface.
Map<String, dynamic>? consumeContextOverride(Object rawRequest) {
  final override = _contextOverrides[rawRequest];
  if (override != null) {
    _contextOverrides[rawRequest] = null;
  }
  return override;
}

Response _deny(String realm) => Response(
      statusCode: 401,
      headers: {
        'content-type': 'application/json',
        'www-authenticate': 'Bearer realm="$realm"',
      },
      body: '{"error":"Unauthorized"}',
    );
