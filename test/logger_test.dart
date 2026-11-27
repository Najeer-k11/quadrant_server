import 'dart:async';
import 'dart:io';

import 'package:quadrant_server/quadrant_server.dart';
import 'package:test/test.dart';

void main() {
  test('the default output prints every line, several per print', () async {
    final prints = <String>[];
    await runZoned(
      () async {
        final app = QuadrantServer(
          middlewares: [logger()],
          routes: [
            Route.get(path: '/:n', handler: (req) async => Response.text('ok')),
          ],
        );
        final server = await app.listen(port: 0, address: '127.0.0.1');
        final client = HttpClient()..maxConnectionsPerHost = 50;
        await Future.wait([
          for (var i = 0; i < 50; i++)
            client
                .get('127.0.0.1', server.port, '/$i')
                .then((request) => request.close())
                .then((response) => response.drain<void>()),
        ]);
        client.close();
        await app.close();
        // The last batch goes out on the next turn of the event loop.
        await Future<void>.delayed(const Duration(milliseconds: 10));
      },
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => prints.add(line),
      ),
    );

    final lines = prints.expand((p) => p.split('\n')).toList();
    expect(lines, hasLength(50));
    for (var i = 0; i < 50; i++) {
      expect(lines, contains(matches(RegExp('^GET /$i → 200 \\(\\d+ms\\)\$'))));
    }
    expect(prints.length, lessThanOrEqualTo(50));
  });

  test('a custom output gets each line as it is logged', () async {
    final lines = <String>[];
    final app = QuadrantServer(
      middlewares: [logger(output: lines.add)],
      routes: [Route.get(path: '/', handler: (req) async => Response.text('ok'))],
    );
    final server = await app.listen(port: 0, address: '127.0.0.1');
    addTearDown(app.close);
    final client = HttpClient();
    addTearDown(client.close);
    final response = await (await client.get('127.0.0.1', server.port, '/')).close();
    await response.drain<void>();
    expect(lines, [matches(RegExp(r'^GET / → 200 \(\d+ms\)$'))]);
  });
}
