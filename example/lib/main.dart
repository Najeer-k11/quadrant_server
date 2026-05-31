import 'package:quadrant_server/quadrant_server.dart';

void main(List<String> args) {
  final server = QuadrantServer(
    routes: [
      Route.get(
        path: '/hello/:name',
        handler: (req) async {
          final name = req.params['name'];
          return Response.ok('Hello, $name!');
        },
      ),
    ],
    docs: true,
    middlewares: [cors(), bodyParser(), logger()],
  );
  server.listen(port: 5050);
}
