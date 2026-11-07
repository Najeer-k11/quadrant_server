import 'package:quadrant_server/quadrant_server.dart';

// ─── Schemas ──────────────────────────────────────────────────

const _roles = ['admin', 'user'];

/// `validate()` checks these before a handler runs, and passes on only the
/// declared fields, so a client cannot set anything else on a user.
final createUserSchema = BodySchema({
  'name': Field.string().minLength(1).maxLength(100).required(),
  'role': Field.string().oneOf(_roles),
});

final replaceUserSchema = BodySchema({
  'name': Field.string().minLength(1).maxLength(100).required(),
  'role': Field.string().oneOf(_roles).required(),
});

final patchUserSchema = BodySchema({
  'name': Field.string().minLength(1).maxLength(100),
  'role': Field.string().oneOf(_roles),
});

// ─── In-memory data store ─────────────────────────────────────

// Replace this with a database. Being a variable, it exists once per isolate
// and is lost on restart, which is why this app defaults to `ISOLATES=1`. With
// a database, open its connection in `buildServer` and raise `ISOLATES`.
final List<Map<String, dynamic>> _users = [
  {'id': '1', 'name': 'Ada Lovelace', 'role': 'admin'},
  {'id': '2', 'name': 'Grace Hopper', 'role': 'user'},
  {'id': '3', 'name': 'Alan Turing', 'role': 'user'},
];

int _nextId = 4;

const _maxPageSize = 100;

// ─── Handlers ─────────────────────────────────────────────────

/// GET /api/v1/users?role=admin&page=1&limit=10
Future<Response> getUsers(Request req) async {
  final role = req.queryString('role');
  final page = req.queryInt('page', defaultValue: 1)!.clamp(1, 1 << 31);
  final limit = req.queryInt('limit', defaultValue: 10)!.clamp(1, _maxPageSize);

  final matching = role.isEmpty
      ? _users
      : _users.where((user) => user['role'] == role).toList();

  final total = matching.length;
  final start = ((page - 1) * limit).clamp(0, total);
  final end = (start + limit).clamp(0, total);

  return Response.ok({
    'data': matching.sublist(start, end),
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
  final index = _indexOf(req);
  if (index == -1) return _notFound(req);
  return Response.ok(_users[index]);
}

/// POST /api/v1/users
Future<Response> createUser(Request req) async {
  final body = _validated(req);
  final problem = _checkName(body);
  if (problem != null) return problem;

  final user = <String, dynamic>{
    'id': '${_nextId++}',
    'name': body['name'],
    'role': body['role'] ?? 'user',
  };
  _users.add(user);
  return Response.created(user);
}

/// PUT /api/v1/users/:id, which replaces every field.
Future<Response> updateUser(Request req) async {
  final index = _indexOf(req);
  if (index == -1) return _notFound(req);
  final body = _validated(req);
  final problem = _checkName(body);
  if (problem != null) return problem;

  _users[index] = {
    'id': _users[index]['id'],
    'name': body['name'],
    'role': body['role'],
  };
  return Response.ok(_users[index]);
}

/// PATCH /api/v1/users/:id, which changes only the fields it is given.
Future<Response> patchUser(Request req) async {
  final index = _indexOf(req);
  if (index == -1) return _notFound(req);
  final body = _validated(req);
  final problem = _checkName(body);
  if (problem != null) return problem;

  _users[index] = {
    ..._users[index],
    if (body['name'] != null) 'name': body['name'],
    if (body['role'] != null) 'role': body['role'],
  };
  return Response.ok(_users[index]);
}

/// DELETE /api/v1/users/:id
Future<Response> deleteUser(Request req) async {
  final index = _indexOf(req);
  if (index == -1) return _notFound(req);
  _users.removeAt(index);
  return Response.noContent();
}

// ─── Helpers ──────────────────────────────────────────────────

/// `validate()` accepts a name that is only spaces, as it does not trim.
Response? _checkName(Map<String, dynamic> body) {
  final name = body['name'] as String?;
  if (name != null && name.trim().isEmpty) {
    return Response.unprocessableEntity('Field "name" must not be blank');
  }
  return null;
}

int _indexOf(Request req) =>
    _users.indexWhere((user) => user['id'] == req.params['id']);

Response _notFound(Request req) =>
    Response.notFound('User "${req.params['id']}" not found');

Map<String, dynamic> _validated(Request req) =>
    req.context['validated'] as Map<String, dynamic>;
