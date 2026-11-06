import 'dart:io';

import 'package:quadrant_server/quadrant_server.dart';
import 'package:test/test.dart';

// These use a real server on purpose. Calling a middleware directly cannot
// show whether the server ever runs it.

Future<Response> _ok(Request req) async => Response.ok({'ok': true});

void main() {
  final client = HttpClient();
  tearDownAll(() => client.close(force: true));

  Future<int> start(QuadrantServer app) async {
    addTearDown(() => app.close(force: true));
    final server = await app.listen(
      port: 0,
      address: InternetAddress.loopbackIPv4,
    );
    return server.port;
  }

  Future<HttpClientResponse> send(int port, String method, String path) async {
    final request = await client.open(method, '127.0.0.1', port, path);
    request.headers
      ..set('origin', 'https://example.com')
      ..set('access-control-request-method', 'POST');
    final response = await request.close();
    await response.drain<void>();
    return response;
  }

  void expectPreflight(HttpClientResponse res) {
    expect(res.statusCode, 204);
    expect(res.headers.value('access-control-allow-origin'), '*');
    expect(res.headers.value('access-control-allow-methods'), contains('POST'));
    expect(res.headers.value('access-control-max-age'), '86400');
  }

  group('CORS preflight', () {
    test('works with a global cors()', () async {
      final port = await start(QuadrantServer(
        middlewares: [cors()],
        routes: [Route.post(path: '/users', handler: _ok)],
      ));
      expectPreflight(await send(port, 'OPTIONS', '/users'));
    });

    test('works with cors() on the route', () async {
      final port = await start(QuadrantServer(routes: [
        Route.post(path: '/users', handler: _ok, middlewares: [cors()]),
      ]));
      expectPreflight(await send(port, 'OPTIONS', '/users'));
    });

    test('works with cors() on a QuadrantRouter', () async {
      final router = QuadrantRouter(prefix: '/api', middlewares: [cors()])
        ..post('/users/:id', _ok);
      final port = await start(QuadrantServer(routes: router.routes));
      expectPreflight(await send(port, 'OPTIONS', '/api/users/1'));
    });

    test('runs before route auth, because preflights carry no credentials',
        () async {
      final port = await start(QuadrantServer(routes: [
        Route.post(
          path: '/users',
          handler: _ok,
          middlewares: [
            bearerAuth<String>(validate: (token) async => null),
            cors(),
          ],
        ),
      ]));
      expectPreflight(await send(port, 'OPTIONS', '/users'));
      expect((await send(port, 'POST', '/users')).statusCode, 401);
    });

    test('an OPTIONS route of your own still takes priority', () async {
      final port = await start(QuadrantServer(routes: [
        Route(
          method: 'OPTIONS',
          path: '/users',
          handler: (req) async => Response.text('mine'),
        ),
        Route.post(path: '/users', handler: _ok, middlewares: [cors()]),
      ]));
      expect((await send(port, 'OPTIONS', '/users')).statusCode, 200);
    });

    test('without cors(), OPTIONS is still a 405 listing the methods', () async {
      final port = await start(QuadrantServer(routes: [
        Route.post(path: '/users', handler: _ok),
      ]));
      final res = await send(port, 'OPTIONS', '/users');
      expect(res.statusCode, 405);
      expect(res.headers.value('allow'), 'POST');
    });
  });

  group('Global middleware on requests that match no route', () {
    late List<String> logged;
    late int port;

    setUp(() async {
      logged = [];
      port = await start(QuadrantServer(
        middlewares: [
          helmet(),
          cors(origin: 'https://example.com'),
          logger(output: logged.add),
        ],
        routes: [Route.get(path: '/users/:id', handler: _ok)],
      ));
    });

    void expectHeaders(HttpClientResponse res) {
      expect(res.headers.value('referrer-policy'), isNotNull,
          reason: 'helmet() should have run');
      expect(res.headers.value('access-control-allow-origin'),
          'https://example.com',
          reason: 'cors() should have run');
    }

    test('a 404 gets the headers and is logged', () async {
      final res = await send(port, 'GET', '/nope');
      expect(res.statusCode, 404);
      expectHeaders(res);
      expect(logged.single, contains('/nope'));
      expect(logged.single, contains('404'));
    });

    test('a 405 gets the headers, keeps Allow, and is logged', () async {
      final res = await send(port, 'DELETE', '/users/1');
      expect(res.statusCode, 405);
      expect(res.headers.value('allow'), contains('GET'));
      expectHeaders(res);
      expect(logged.single, contains('405'));
    });

    test('a malformed path gets the headers and is logged', () async {
      final res = await send(port, 'GET', '/users/%FF');
      expect(res.statusCode, 400);
      expectHeaders(res);
      expect(logged.single, contains('400'));
    });

    test('a WebSocket upgrade to an unknown path gets a 404 and is logged',
        () async {
      await expectLater(
        WebSocket.connect('ws://127.0.0.1:$port/nope'),
        throwsA(isA<WebSocketException>()),
      );
      expect(logged.single, contains('404'));
    });
  });

  test('the health check still skips middleware', () async {
    final logged = <String>[];
    final port = await start(QuadrantServer(
      healthCheck: true,
      middlewares: [logger(output: logged.add)],
      routes: [Route.get(path: '/', handler: _ok)],
    ));
    expect((await send(port, 'GET', '/health')).statusCode, 200);
    expect(logged, isEmpty);
  });

  test('global auth answers 401 for unknown paths, hiding which exist',
      () async {
    final port = await start(QuadrantServer(
      middlewares: [bearerAuth<String>(validate: (token) async => null)],
      routes: [Route.get(path: '/users', handler: _ok)],
    ));
    expect((await send(port, 'GET', '/users')).statusCode, 401);
    expect((await send(port, 'GET', '/nope')).statusCode, 401);
  });

  test('a global rateLimit() counts requests to unknown paths', () async {
    final port = await start(QuadrantServer(
      middlewares: [
        rateLimit(maxRequests: 2, window: const Duration(minutes: 1)),
      ],
      routes: [Route.get(path: '/users', handler: _ok)],
    ));
    expect((await send(port, 'GET', '/a')).statusCode, 404);
    expect((await send(port, 'GET', '/b')).statusCode, 404);
    expect((await send(port, 'GET', '/users')).statusCode, 429);
  });

  test('a middleware that throws on an unknown path answers 500', () async {
    final port = await start(QuadrantServer(
      middlewares: [
        (Request req, Next next) async => throw StateError('boom'),
      ],
      routes: [Route.get(path: '/users', handler: _ok)],
    ));
    final res = await send(port, 'GET', '/nope');
    expect(res.statusCode, 500);
  });
}
