import 'package:quadrant_server/quadrant_server.dart';

/// Accepts a request whose bearer token is in [tokens], which maps each token
/// to a role, and puts that role in `req.context['user']`.
///
/// Fine for a few service tokens. For user accounts, look tokens up in your
/// database or verify a signed token here instead.
Middleware requireAuth(Map<String, String> tokens) => bearerAuth<String>(
      validate: (token) async => _roleOf(tokens, token),
    );

/// Must come after [requireAuth].
Middleware requireAdmin() => (Request req, Next next) async {
      if (req.context['user'] != 'admin') {
        return Response.forbidden('Admin access required');
      }
      return next();
    };

/// Compares against every token in full, so that the time taken does not reveal
/// how much of a guess was right.
String? _roleOf(Map<String, String> tokens, String candidate) {
  String? role;
  tokens.forEach((token, tokenRole) {
    if (_sameString(token, candidate)) role = tokenRole;
  });
  return role;
}

bool _sameString(String a, String b) {
  var difference = a.length ^ b.length;
  for (var i = 0; i < a.length; i++) {
    difference |= a.codeUnitAt(i) ^ b.codeUnitAt(i % (b.isEmpty ? 1 : b.length));
  }
  return difference == 0 && b.isNotEmpty;
}
