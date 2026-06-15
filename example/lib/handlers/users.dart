import 'package:quadrant_server/quadrant_server.dart';

// ─── In-memory data store ─────────────────────────────────────

/// Simple in-memory user list. Replace with a real DB in production.
final List<Map<String, dynamic>> _users = [
  {'id': '1', 'name': 'Ada Lovelace', 'role': 'admin'},
  {'id': '2', 'name': 'Grace Hopper', 'role': 'user'},
  {'id': '3', 'name': 'Alan Turing', 'role': 'user'},
];

int _nextId = 4;

// ─── Users handlers ──────────────────────────────────────────

/// GET /api/v1/users
///
/// Optional query parameters:
///   ?role=admin    — filter by role
///   ?page=1        — page number (1-based)
///   ?limit=10      — items per page
Future<Response> getUsers(Request req) async {
  final role = req.queryString('role');
  final page = req.queryInt('page', defaultValue: 1)!;
  final limit = req.queryInt('limit', defaultValue: 10)!;

  var results = role.isEmpty
      ? List<Map<String, dynamic>>.from(_users)
      : _users.where((u) => u['role'] == role).toList();

  final total = results.length;
  final start = ((page - 1) * limit).clamp(0, total);
  final end = (start + limit).clamp(0, total);
  results = results.sublist(start, end);

  return Response.ok({
    'data': results,
    'meta': {
      'total': total,
      'page': page,
      'limit': limit,
      'pages': (total / limit).ceil(),
    },
  });
}

/// GET /api/v1/users/:id
Future<Response> getUser(Request req) async {
  final id = req.params['id'];
  try {
    final user = _users.firstWhere((u) => u['id'] == id);
    return Response.ok(user);
  } catch (_) {
    return Response.notFound('User "$id" not found');
  }
}

/// POST /api/v1/users
///
/// Body: { "name": "string", "role": "admin" | "user" }
Future<Response> createUser(Request req) async {
  final body = req.bodyAsMap;
  if (body == null) return Response.badRequest('JSON body required');

  final name = body['name'] as String?;
  if (name == null || name.trim().isEmpty) {
    return Response.unprocessableEntity('Field "name" is required');
  }

  final role = body['role'] as String? ?? 'user';
  if (!['admin', 'user'].contains(role)) {
    return Response.unprocessableEntity('Field "role" must be "admin" or "user"');
  }

  final user = <String, dynamic>{
    'id': '${_nextId++}',
    'name': name.trim(),
    'role': role,
  };
  _users.add(user);
  return Response.created(user);
}

/// PUT /api/v1/users/:id
///
/// Replaces the user's fields with the provided body.
Future<Response> updateUser(Request req) async {
  final id = req.params['id'];
  final idx = _users.indexWhere((u) => u['id'] == id);
  if (idx == -1) return Response.notFound('User "$id" not found');

  final body = req.bodyAsMap;
  if (body == null) return Response.badRequest('JSON body required');

  // Merge: keep 'id', overwrite everything else.
  _users[idx] = {..._users[idx], ...body, 'id': id};
  return Response.ok(_users[idx]);
}

/// PATCH /api/v1/users/:id
///
/// Partial update — only updates provided fields.
Future<Response> patchUser(Request req) async {
  final id = req.params['id'];
  final idx = _users.indexWhere((u) => u['id'] == id);
  if (idx == -1) return Response.notFound('User "$id" not found');

  final body = req.bodyAsMap;
  if (body == null) return Response.badRequest('JSON body required');

  _users[idx] = {..._users[idx], ...body, 'id': id};
  return Response.ok(_users[idx]);
}

/// DELETE /api/v1/users/:id
Future<Response> deleteUserImpl(Request req) async {
  final id = req.params['id'];
  final idx = _users.indexWhere((u) => u['id'] == id);
  if (idx == -1) return Response.notFound('User "$id" not found');
  _users.removeAt(idx);
  return Response.noContent();
}
