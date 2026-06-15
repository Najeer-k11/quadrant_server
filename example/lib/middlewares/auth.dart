import 'package:quadrant_server/quadrant_server.dart';

// ─── Simple token store (replace with JWT in production) ──────

/// Accepted API tokens → user info.
const _validTokens = <String, Map<String, String>>{
  'secret-admin-token': {'userId': '1', 'role': 'admin'},
  'secret-user-token': {'userId': '2', 'role': 'user'},
};

// ─── Middleware ───────────────────────────────────────────────

/// Bearer-token auth middleware.
///
/// Reads the `Authorization: Bearer <token>` header.
/// On success — attaches nothing (use req.headers to read downstream).
/// On failure — short-circuits with 401 Unauthorized.
///
/// ```dart
/// Route.delete(
///   path: '/api/v1/users/:id',
///   handler: deleteUser,
///   middlewares: [requireAuth()],
/// )
/// ```
Middleware requireAuth() {
  return (Request req, Next next) async {
    final header = req.headers['authorization'] ?? '';

    if (!header.startsWith('Bearer ')) {
      return Response.unauthorized('Missing or malformed Authorization header');
    }

    final token = header.substring('Bearer '.length).trim();

    if (!_validTokens.containsKey(token)) {
      return Response.unauthorized('Invalid token');
    }

    return next();
  };
}

/// Admin-only guard. Must be used after [requireAuth].
///
/// Extracts the token again and checks the role.
Middleware requireAdmin() {
  return (Request req, Next next) async {
    final token =
        (req.headers['authorization'] ?? '').replaceFirst('Bearer ', '').trim();
    final user = _validTokens[token];

    if (user == null || user['role'] != 'admin') {
      return Response.forbidden('Admin access required');
    }

    return next();
  };
}
