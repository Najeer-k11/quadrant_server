// Started by quadrant_server_test.dart with a capped Dart heap
// (--old_gen_heap_size) to check that big bodies and files fit in it.
import 'dart:io';

import 'package:quadrant_server/quadrant_server.dart';

Future<void> main(List<String> args) async {
  final server = await QuadrantServer(
    routes: [
      Route.post(
        path: '/json',
        middlewares: [bodyParser(maxBodyBytes: 0)],
        handler: (req) async =>
            Response.text('${(req.bodyAsMap!['s'] as String).length}'),
      ),
      Route.post(
        path: '/form',
        middlewares: [formParser(maxBodyBytes: 0)],
        handler: (req) async =>
            Response.text('${(req.body as Map<String, String>)['s']!.length}'),
      ),
      Route.post(
        path: '/upload',
        middlewares: [multipartParser(maxFileSize: 1 << 30, maxTotalBytes: 0)],
        handler: (req) async => Response.text(
            '${(req.context['files'] as List<UploadedFile>).single.size}'),
      ),
      Route.get(path: '/static/*', handler: staticFiles(args.single)),
    ],
  ).listen(port: 0, address: InternetAddress.loopbackIPv4);

  // ignore: avoid_print
  print(server.port); // tells the test which port to use
}
