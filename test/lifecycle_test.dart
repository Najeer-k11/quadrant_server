import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:quadrant_server/quadrant_server.dart';
import 'package:quadrant_server/src/core/version.dart';
import 'package:test/test.dart';

const _limit = Duration(seconds: 5);

void main() {
  final client = HttpClient();
  tearDownAll(() => client.close(force: true));

  Future<(QuadrantServer, Uri)> start({
    List<Middleware> middlewares = const [],
    List<Route> routes = const [],
    List<WebSocketRoute> webSocketRoutes = const [],
  }) async {
    final app = QuadrantServer(
      middlewares: middlewares,
      routes: routes,
      webSocketRoutes: webSocketRoutes,
    );
    addTearDown(() => app.close(force: true));
    final server = await app.listen(
      port: 0,
      address: InternetAddress.loopbackIPv4,
    );
    return (app, Uri.parse('http://127.0.0.1:${server.port}'));
  }

  group('close()', () {
    test('ends open WebSockets with 1001 instead of waiting for them',
        () async {
      final (app, base) = await start(webSocketRoutes: [
        WebSocketRoute(path: '/ws', onMessage: (ctx, data) async {}),
      ]);
      // ignore: close_sinks — the server closes it, which is what is tested.
      final ws = await WebSocket.connect('ws://127.0.0.1:${base.port}/ws');
      final received = ws.drain<void>();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await app.close().timeout(_limit);

      await received.timeout(_limit);
      expect(ws.closeCode, WebSocketStatus.goingAway);
    });

    test('ends open SSE streams and lets the handler finish', () async {
      final handlerDone = Completer<void>();
      final (app, base) = await start(routes: [
        Route.get(
          path: '/events',
          handler: (req) async {
            final sse = await SseContext.from(req);
            sse.send(data: 'hello');
            await sse.done;
            handlerDone.complete();
            return sse.response;
          },
        ),
      ]);
      final res = await (await client.getUrl(base.resolve('/events'))).close();
      final body = res.transform(utf8.decoder).join();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await app.close().timeout(_limit);

      await handlerDone.future.timeout(_limit);
      expect(await body.timeout(_limit), contains('data: hello'));
    });

    test('waits for a StreamResponse that is still sending', () async {
      final source = StreamController<List<int>>();
      final (app, base) = await start(routes: [
        Route.get(
          path: '/stream',
          handler: (req) async => StreamResponse(stream: source.stream),
        ),
      ]);
      final res = await _sendWhenFirstChunkArrives(
        client,
        base.resolve('/stream'),
        source,
      );
      final body = res.transform(utf8.decoder).join();

      var closed = false;
      final closing = app.close().whenComplete(() => closed = true);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(closed, isFalse, reason: 'the stream has not finished yet');

      source.add(utf8.encode('end'));
      await source.close();

      await closing.timeout(_limit);
      expect(await body.timeout(_limit), 'startend');
    });

    test('timeout gives up on a request that never finishes', () async {
      final source = StreamController<List<int>>();
      final (app, base) = await start(routes: [
        Route.get(
          path: '/stream',
          handler: (req) async => StreamResponse(stream: source.stream),
        ),
      ]);
      final res = await _sendWhenFirstChunkArrives(
        client,
        base.resolve('/stream'),
        source,
      );
      unawaited(res.drain<void>().catchError((Object _) {}));

      await app
          .close(timeout: const Duration(milliseconds: 100))
          .timeout(_limit);
      await source.close();
    });

    test('can be called twice while draining', () async {
      final release = Completer<void>();
      final (app, base) = await start(routes: [
        Route.get(
          path: '/slow',
          handler: (req) async {
            await release.future;
            return Response.text('done');
          },
        ),
      ]);
      final request = client.getUrl(base.resolve('/slow')).then((r) => r.close());
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final first = app.close();
      final second = app.close();
      release.complete();

      await Future.wait([first, second]).timeout(_limit);
      await (await request).drain<void>();
    });
  });

  test('a stream that fails midway does not look like a complete response',
      () async {
    final source = StreamController<List<int>>();
    final (_, base) = await start(routes: [
      Route.get(
        path: '/stream',
        handler: (req) async => StreamResponse(stream: source.stream),
      ),
      Route.get(path: '/ok', handler: (req) async => Response.text('ok')),
    ]);
    final res = await _sendWhenFirstChunkArrives(
      client,
      base.resolve('/stream'),
      source,
    );
    final body = res.drain<void>();

    source.addError(StateError('disk failed'));
    unawaited(source.close());

    await expectLater(body.timeout(_limit), throwsA(isA<HttpException>()));
    final next = await (await client.getUrl(base.resolve('/ok'))).close();
    expect(next.statusCode, 200, reason: 'the server keeps serving');
    await next.drain<void>();
  });

  test('a stream that cannot be listened to does not hang the request',
      () async {
    final used = StreamController<List<int>>()..stream.listen((_) {});
    addTearDown(used.close);
    final (app, base) = await start(routes: [
      Route.get(
        path: '/used',
        handler: (req) async => StreamResponse(stream: used.stream),
      ),
    ]);

    final attempt = () async {
      final res = await (await client.getUrl(base.resolve('/used'))).close();
      await res.drain<void>();
    }();
    await attempt.catchError((Object _) {}).timeout(_limit);

    await app.close().timeout(_limit);
  });

  group('staticFiles()', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('quadrant_static_');
      await File('${dir.path}/a.txt').writeAsString('hello');
    });
    tearDown(() => dir.delete(recursive: true));

    test('keeps headers added by middleware', () async {
      final (_, base) = await start(
        middlewares: [helmet(), cors(), requestId()],
        routes: [Route.get(path: '/s/*', handler: staticFiles(dir.path))],
      );
      final res = await (await client.getUrl(base.resolve('/s/a.txt'))).close();

      expect(await res.transform(utf8.decoder).join(), 'hello');
      expect(res.headers.value('x-content-type-options'), 'nosniff');
      expect(res.headers.value('access-control-allow-origin'), '*');
      expect(res.headers.value('x-request-id'), isNotNull);
      expect(res.headers.contentLength, 5);
    });

    test('answers HEAD with headers and no body', () async {
      final (_, base) = await start(routes: [
        Route.get(path: '/s/*', handler: staticFiles(dir.path)),
      ]);
      final res = await (await client.headUrl(base.resolve('/s/a.txt'))).close();

      expect(res.statusCode, 200);
      expect(res.headers.contentLength, 5);
      expect(await res.fold<int>(0, (n, c) => n + c.length), 0);
    });
  });

  group('Response body encoding', () {
    Future<(List<int>, HttpClientResponse)> fetch(Response response) async {
      final (_, base) = await start(routes: [
        Route.get(path: '/', handler: (req) async => response),
      ]);
      final res = await (await client.getUrl(base)).close();
      final bytes = await res.fold<List<int>>([], (all, c) => all..addAll(c));
      return (bytes, res);
    }

    for (final text in ['Zoë', '日本語', 'age ≥ 18', '😀']) {
      test('JSON containing "$text" arrives as UTF-8', () async {
        final (bytes, _) = await fetch(Response.ok({'name': text}));
        expect(jsonDecode(utf8.decode(bytes)), {'name': text});
      });
    }

    test('a custom content-type without a charset is sent as UTF-8', () async {
      final (bytes, _) = await fetch(const Response(
        statusCode: 200,
        headers: {'content-type': 'application/xml'},
        body: '<a>日本語</a>',
      ));
      expect(utf8.decode(bytes), '<a>日本語</a>');
    });

    test('no content-type at all is sent as UTF-8', () async {
      final (bytes, _) = await fetch(
        const Response(statusCode: 200, body: 'Zoë'),
      );
      expect(utf8.decode(bytes), 'Zoë');
    });

    test('an explicit charset is respected', () async {
      final (bytes, _) = await fetch(const Response(
        statusCode: 200,
        headers: {'content-type': 'text/plain; charset=iso-8859-1'},
        body: 'Zoë',
      ));
      expect(bytes, latin1.encode('Zoë'));
    });
  });

  test('QuadrantRouter.ws() passes heartbeat to the route', () {
    final router = QuadrantRouter(prefix: '/api')
      ..ws(
        '/live',
        onMessage: (ctx, data) async {},
        heartbeat: const Duration(seconds: 30),
      );
    expect(router.webSocketRoutes.single.heartbeat,
        const Duration(seconds: 30));
  });

  test('the version in the banner matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final declared = RegExp(r'^version: (.+)$', multiLine: true)
        .firstMatch(pubspec)!
        .group(1);
    expect(quadrantVersion, declared);
  });
}

/// Sends a GET and returns once the response has started, by making [source]
/// emit `start` first. Headers only reach the client after the first chunk.
Future<HttpClientResponse> _sendWhenFirstChunkArrives(
  HttpClient client,
  Uri url,
  StreamController<List<int>> source,
) async {
  source.add(utf8.encode('start'));
  return (await client.getUrl(url)).close();
}
