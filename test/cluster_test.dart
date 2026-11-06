import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:quadrant_server/quadrant_server.dart';
import 'package:test/test.dart';

const _limit = Duration(seconds: 10);

// `build` runs inside each isolate, so these are top-level on purpose.

Future<Response> _whoAmI(Request req) async =>
    Response.ok({'isolate': QuadrantCluster.isolateIndex});

QuadrantServer _plainServer() => QuadrantServer(
      healthCheck: true,
      routes: [Route.get(path: '/', handler: _whoAmI)],
    );

QuadrantServer _limitedServer() => QuadrantServer(
      middlewares: [
        rateLimit(
          maxRequests: 10,
          window: const Duration(minutes: 1),
          keyExtractor: (_) => 'everyone',
        ),
      ],
      routes: [Route.get(path: '/', handler: _whoAmI)],
    );

QuadrantServer _slowServer() => QuadrantServer(routes: [
      Route.get(
        path: '/slow',
        handler: (req) async {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          return Response.text('finished');
        },
      ),
    ]);

QuadrantServer _failingServer() => throw StateError('build failed');

final _room = WebSocketGroup(name: 'room');

QuadrantServer _chatServer() => QuadrantServer(
      routes: const [],
      webSocketRoutes: [
        WebSocketRoute(
          path: '/chat',
          onStart: (ctx) async {
            _room.add(ctx);
            ctx.sendJson({'isolate': QuadrantCluster.isolateIndex});
          },
          onMessage: (ctx, data) async {
            if (data == 'close-all') {
              await _room.closeAll(WebSocketStatus.normalClosure);
            } else {
              _room.broadcastJson({'said': data}, exclude: ctx);
            }
          },
        ),
      ],
    );

QuadrantServer _unnamedGroupServer() => QuadrantServer(
      routes: const [],
      webSocketRoutes: [
        WebSocketRoute(
          path: '/chat',
          onStart: (ctx) async => WebSocketGroup().add(ctx),
          onMessage: (ctx, data) async {},
        ),
      ],
    );

void main() {
  // A new connection per request, so requests reach different isolates.
  final client = HttpClient()..maxConnectionsPerHost = 1;
  tearDownAll(() => client.close(force: true));

  Future<QuadrantCluster> start(
    QuadrantServer Function() build, {
    int isolates = 3,
    int port = 0,
  }) async {
    final cluster = await QuadrantCluster.start(
      isolates: isolates,
      port: port,
      address: InternetAddress.loopbackIPv4,
      build: build,
    );
    addTearDown(() => cluster.close(force: true));
    return cluster;
  }

  Future<(int, String)> get(int port, String path) async {
    final request = await client.get('127.0.0.1', port, path);
    request.persistentConnection = false;
    final response = await request.close();
    return (response.statusCode, await response.transform(utf8.decoder).join());
  }

  test('requests are served by more than one isolate', () async {
    final cluster = await start(_plainServer);
    final seen = <Object?>{};
    for (var i = 0; i < 40; i++) {
      final (status, body) = await get(cluster.port, '/');
      expect(status, 200);
      seen.add((jsonDecode(body) as Map)['isolate']);
    }
    expect(seen.length, greaterThan(1));
    expect(seen.every((i) => i is int && i >= 0 && i < 3), isTrue);
  });

  test('rateLimit() keeps one count across isolates', () async {
    final cluster = await start(_limitedServer);
    final statuses = <int>[];
    final allowedOn = <Object?>{};
    for (var i = 0; i < 30; i++) {
      final (status, body) = await get(cluster.port, '/');
      statuses.add(status);
      if (status == 200) allowedOn.add((jsonDecode(body) as Map)['isolate']);
    }
    expect(statuses.where((s) => s == 200), hasLength(10));
    expect(statuses.where((s) => s == 429), hasLength(20));
    expect(allowedOn.length, greaterThan(1),
        reason: 'the test proves nothing if one isolate served everything');
  });

  test('the health check totals requests from every isolate', () async {
    final cluster = await start(_plainServer);
    for (var i = 0; i < 30; i++) {
      await get(cluster.port, '/');
    }
    final (status, body) = await get(cluster.port, '/health');
    final health = jsonDecode(body) as Map<String, dynamic>;
    expect(status, 200);
    expect(health['isolates'], 3);
    expect(health['requests'], 31);
  });

  group('WebSocketGroup', () {
    /// Connects until there are two clients on different isolates.
    Future<(_Client, _Client)> clientsOnTwoIsolates(int port) async {
      final clients = <_Client>[];
      addTearDown(() async {
        for (final c in clients) {
          await c.socket.close();
        }
      });
      for (var i = 0; i < 40; i++) {
        final client = await _Client.connect(port);
        clients.add(client);
        final other = clients.where((c) => c.isolate != client.isolate);
        if (other.isNotEmpty) return (other.first, client);
      }
      fail('Every connection landed on one isolate.');
    }

    test('a broadcast reaches members on other isolates', () async {
      final cluster = await start(_chatServer);
      final (a, b) = await clientsOnTwoIsolates(cluster.port);

      a.socket.add('hello');

      expect(await b.nextMessage().timeout(_limit), {'said': 'hello'});
    });

    test('closeAll() closes members on other isolates', () async {
      final cluster = await start(_chatServer);
      final (a, b) = await clientsOnTwoIsolates(cluster.port);

      a.socket.add('close-all');

      await b.closed.timeout(_limit);
      expect(b.socket.closeCode, WebSocketStatus.normalClosure);
    });

    test('a group without a name is refused in a cluster', () async {
      final cluster = await start(_unnamedGroupServer, isolates: 1);
      // ignore: close_sinks — the server closes it, which is what is tested.
      final ws = await WebSocket.connect('ws://127.0.0.1:${cluster.port}/chat');
      await ws.drain<void>().timeout(_limit);
      expect(ws.closeCode, WebSocketStatus.internalServerError);
    });
  });

  group('start() and close()', () {
    test('close() stops every isolate and frees the port', () async {
      final cluster = await start(_plainServer);
      final port = cluster.port;
      await get(port, '/');

      await cluster.close().timeout(_limit);

      expect(() => get(port, '/'), throwsA(isA<SocketException>()));
      final again = await start(_plainServer, port: port);
      expect(again.port, port);
    });

    test('close() waits for in-flight requests on every isolate', () async {
      final cluster = await start(_slowServer);
      final requests = [
        for (var i = 0; i < 12; i++) _getOnNewClient(cluster.port, '/slow'),
      ];
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await cluster.close().timeout(_limit);

      expect(await Future.wait(requests), everyElement('200 finished'));
    });

    test('close() can be called twice', () async {
      final cluster = await start(_plainServer);
      await Future.wait([cluster.close(), cluster.close()]).timeout(_limit);
    });

    test('start() fails when build throws', () async {
      await expectLater(
        QuadrantCluster.start(isolates: 2, port: 0, build: _failingServer)
            .timeout(_limit),
        throwsA(isA<StateError>()
            .having((e) => '$e', 'message', contains('build failed'))),
      );
    });

    test('start() fails when the port is taken', () async {
      final taken = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(taken.close);
      await expectLater(
        QuadrantCluster.start(
          isolates: 2,
          port: taken.port,
          address: InternetAddress.loopbackIPv4,
          build: _plainServer,
        ).timeout(_limit),
        throwsA(isA<StateError>()),
      );
    });

    test('start() rejects zero isolates', () {
      expect(
        () => QuadrantCluster.start(isolates: 0, port: 0, build: _plainServer),
        throwsArgumentError,
      );
    });
  });

  test('serves HTTPS', () async {
    final dir = await Directory.systemTemp.createTemp('quadrant_tls_');
    addTearDown(() => dir.delete(recursive: true));
    final cert = File('${dir.path}/cert.pem');
    final key = File('${dir.path}/key.pem');
    final openssl = await Process.run('openssl', [
      'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
      '-subj', '/CN=localhost', '-keyout', key.path, '-out', cert.path,
    ]);
    expect(openssl.exitCode, 0, reason: '${openssl.stderr}');

    final cluster = await QuadrantCluster.start(
      isolates: 2,
      port: 0,
      address: InternetAddress.loopbackIPv4,
      build: _plainServer,
      certificateChain: cert,
      privateKey: key,
    );
    addTearDown(() => cluster.close(force: true));

    final secure = HttpClient()..badCertificateCallback = (_, __, ___) => true;
    addTearDown(() => secure.close(force: true));
    final response = await (await secure.getUrl(
            Uri.parse('https://127.0.0.1:${cluster.port}/')))
        .close();
    await response.drain<void>();
    expect(response.statusCode, 200);
  }, skip: Process.runSync('which', ['openssl']).exitCode == 0
      ? false
      : 'openssl is not installed');

  test('outside a cluster, isolateIndex is null and unnamed groups work', () {
    expect(QuadrantCluster.isolateIndex, isNull);
    expect(WebSocketGroup().isEmpty, isTrue);
  });
}

/// Uses its own client, so that each request gets its own connection and they
/// spread across isolates.
Future<String> _getOnNewClient(int port, String path) async {
  final client = HttpClient();
  try {
    final response = await (await client.get('127.0.0.1', port, path)).close();
    final body = await response.transform(utf8.decoder).join();
    return '${response.statusCode} $body';
  } finally {
    client.close(force: true);
  }
}

class _Client {
  final WebSocket socket;
  final int isolate;
  final StreamIterator<dynamic> _messages;
  final Completer<void> _closed;

  _Client(this.socket, this.isolate, this._messages, this._closed);

  Future<void> get closed => _closed.future;

  static Future<_Client> connect(int port) async {
    // ignore: close_sinks — closed by the test's teardown.
    final socket = await WebSocket.connect('ws://127.0.0.1:$port/chat');
    final closed = Completer<void>();
    final messages = StreamIterator<dynamic>(
      socket.transform(StreamTransformer.fromHandlers(handleDone: (sink) {
        closed.complete();
        sink.close();
      })),
    );
    await messages.moveNext();
    final hello = jsonDecode(messages.current as String) as Map<String, dynamic>;
    final client = _Client(socket, hello['isolate'] as int, messages, closed);
    // Reads ahead so `closed` completes even if no one asks for a message.
    client._pump();
    return client;
  }

  final List<Object?> _received = [];
  Completer<Object?>? _waiter;

  void _pump() {
    unawaited(() async {
      while (await _messages.moveNext()) {
        final message = jsonDecode(_messages.current as String);
        final waiter = _waiter;
        if (waiter != null) {
          _waiter = null;
          waiter.complete(message);
        } else {
          _received.add(message);
        }
      }
    }());
  }

  Future<Object?> nextMessage() {
    if (_received.isNotEmpty) return Future.value(_received.removeAt(0));
    return (_waiter = Completer<Object?>()).future;
  }
}
