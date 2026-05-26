import 'package:quadrant_server/quadrant_server.dart';

Future<Response> getUsers(Request req) async {
  return Response.ok([
    {'id': '1', 'name': 'Ada'},
    {'id': '2', 'name': 'Grace'},
  ]);
}

Future<Response> getUser(Request req) async {
  final id = req.params['id'];
  return Response.ok({'id': id, 'name': 'Ada'});
}

Future<Response> createUser(Request req) async {
  final body = req.body;
  return Response.created(body);
}

void main() async {
  final app = QuadrantServer(
    middlewares: [cors(), logger(), bodyParser()],
    routes: [
      Route.get(path: '/users', handler: getUsers),
      Route.get(path: '/users/:id', handler: getUser),
      Route.post(path: '/users', handler: createUser),
    ],
    docs: true
  );

  await app.listen(port: 3000);
  print('QuadrantServer running on http://localhost:3000');
}
