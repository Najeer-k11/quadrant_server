import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:quadrant_server/quadrant_server.dart';
import 'package:test/test.dart';

void main() {
  final client = HttpClient();
  tearDownAll(() => client.close(force: true));

  Middleware put(String key, Object value) => (Request req, Next next) {
        req.setContext(key, value);
        return next();
      };

  Future<Response> showContext(Request req) async =>
      Response.ok(req.context.map((k, v) => MapEntry(k, '$v')));

  Future<int> start(QuadrantServer app) async {
    addTearDown(() => app.close(force: true));
    final server = await app.listen(
      port: 0,
      address: InternetAddress.loopbackIPv4,
    );
    return server.port;
  }

  Future<Map<String, dynamic>> getContext(
    int port, {
    Map<String, String> headers = const {},
  }) async {
    final request = await client.get('127.0.0.1', port, '/');
    headers.forEach(request.headers.set);
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    expect(response.statusCode, 200, reason: body);
    return jsonDecode(body) as Map<String, dynamic>;
  }

  test('a custom middleware passes values to the handler', () async {
    final port = await start(QuadrantServer(
      middlewares: [put('tenant', 'acme')],
      routes: [Route.get(path: '/', handler: showContext)],
    ));
    expect(await getContext(port), {'tenant': 'acme'});
  });

  test('later middlewares see earlier values', () async {
    Object? seen;
    final port = await start(QuadrantServer(
      middlewares: [
        put('a', 1),
        (Request req, Next next) {
          seen = req.context['a'];
          return next();
        },
      ],
      routes: [Route.get(path: '/', handler: showContext)],
    ));
    await getContext(port);
    expect(seen, 1);
  });

  test('several values from one middleware are all kept', () async {
    final port = await start(QuadrantServer(
      middlewares: [
        (Request req, Next next) {
          req.setContext('a', 1);
          req.setContext('b', 2);
          return next();
        },
      ],
      routes: [Route.get(path: '/', handler: showContext)],
    ));
    expect(await getContext(port), {'a': '1', 'b': '2'});
  });

  test('works alongside the built-in middlewares, in any order', () async {
    final port = await start(QuadrantServer(
      middlewares: [
        put('first', 1),
        requestId(),
        put('second', 2),
        bearerAuth<String>(validate: (token) async => 'ada'),
        put('third', 3),
        cookieParser(),
      ],
      routes: [
        Route.get(
          path: '/',
          middlewares: [put('route', 4)],
          handler: showContext,
        ),
      ],
    ));
    final context = await getContext(port, headers: {
      'authorization': 'Bearer t',
      'cookie': 'c=1',
    });
    expect(context, containsPair('first', '1'));
    expect(context, containsPair('second', '2'));
    expect(context, containsPair('third', '3'));
    expect(context, containsPair('route', '4'));
    expect(context, containsPair('user', 'ada'));
    expect(context.keys, contains('requestId'));
    expect(context.keys, contains('cookies'));
  });

  test('values do not leak into other requests', () async {
    var calls = 0;
    final port = await start(QuadrantServer(
      middlewares: [
        (Request req, Next next) {
          if (calls++ == 0) req.setContext('once', true);
          return next();
        },
      ],
      routes: [Route.get(path: '/', handler: showContext)],
    ));
    expect(await getContext(port), {'once': 'true'});
    expect(await getContext(port), isEmpty);
  });

  test('WebSocket callbacks see values from middleware', () async {
    final started = Completer<Map<String, dynamic>>();
    final port = await start(QuadrantServer(
      routes: const [],
      middlewares: [put('tenant', 'acme')],
      webSocketRoutes: [
        WebSocketRoute(
          path: '/ws',
          middlewares: [
            bearerAuth<String>(validate: (token) async => 'ada'),
          ],
          onStart: (ctx) async => started.complete(ctx.request.context),
          onMessage: (ctx, data) async {},
        ),
      ],
    ));
    final ws = await WebSocket.connect(
      'ws://127.0.0.1:$port/ws',
      headers: {'authorization': 'Bearer t'},
    );
    addTearDown(ws.close);
    final context = await started.future.timeout(const Duration(seconds: 5));
    expect(context, {'tenant': 'acme', 'user': 'ada'});
  });
}
