import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:quadrant_server/quadrant_server.dart';
import 'package:quadrant_server/src/cluster/cluster_link.dart';
import 'package:quadrant_server/src/utils/sliding_window.dart';
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

Future<Response> _die(Request req) async => Isolate.exit();

QuadrantServer _mortalServer() => QuadrantServer(routes: [
      Route.get(path: '/', handler: _whoAmI),
      Route.get(path: '/die', handler: _die),
    ]);

QuadrantServer _mortalLimitedServer() => QuadrantServer(routes: [
      Route.get(path: '/die', handler: _die),
      Route.get(
        path: '/',
        handler: _whoAmI,
        middlewares: [
          rateLimit(
            maxRequests: 10,
            window: const Duration(minutes: 1),
            keyExtractor: (_) => 'everyone',
          ),
        ],
      ),
    ]);

/// Builds fail for as long as the file at [marker] exists.
QuadrantServer Function() _failsWhileMarked(String marker) => () {
      if (File(marker).existsSync()) throw StateError('marked');
      return _mortalServer();
    };

/// Builds take a while for as long as the file at [marker] exists.
QuadrantServer Function() _slowWhileMarked(String marker) => () {
      if (File(marker).existsSync()) sleep(const Duration(milliseconds: 300));
      return _mortalServer();
    };

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

  group('restarting isolates', () {
    late Directory dir;
    late String marker;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('quadrant_cluster_test');
      marker = '${dir.path}/marker';
    });
    tearDown(() => dir.delete(recursive: true));

    Future<QuadrantCluster> startMortal(
      QuadrantServer Function() build,
      List<bool> exits, {
      int isolates = 3,
      int maxRestarts = 10,
      Duration restartDelay = const Duration(milliseconds: 10),
    }) async {
      final cluster = await QuadrantCluster.start(
        isolates: isolates,
        port: 0,
        address: InternetAddress.loopbackIPv4,
        build: build,
        maxRestarts: maxRestarts,
        restartDelay: restartDelay,
        onIsolateExit: (index, {required willRestart}) =>
            exits.add(willRestart),
      );
      addTearDown(() => cluster.close(force: true));
      return cluster;
    }

    Future<void> until(bool Function() condition) async {
      final stopwatch = Stopwatch()..start();
      while (!condition()) {
        if (stopwatch.elapsed > _limit) fail('Timed out waiting.');
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    /// Kills one isolate. This does not wait for a response, because there
    /// will be none: a dead isolate's connections stay open until a later
    /// garbage collection.
    Future<void> killOne(QuadrantCluster cluster) async {
      final socket =
          await Socket.connect(InternetAddress.loopbackIPv4, cluster.port);
      addTearDown(socket.destroy);
      socket.write('GET /die HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n');
      await socket.flush();
    }

    test('a dead isolate is replaced, and serves requests', () async {
      final exits = <bool>[];
      final cluster = await startMortal(_mortalServer, exits);
      expect(cluster.runningIsolates, 3);

      await killOne(cluster);
      await until(() => exits.isNotEmpty);
      expect(exits, [true]);
      await until(() => cluster.runningIsolates == 3);

      // All three positions are back, so the replacement takes requests.
      final seen = <Object?>{};
      final stopwatch = Stopwatch()..start();
      while (seen.length < 3 && stopwatch.elapsed < _limit) {
        final (status, body) = await get(cluster.port, '/');
        expect(status, 200);
        seen.add((jsonDecode(body) as Map)['isolate']);
      }
      expect(seen, {0, 1, 2});
    });

    test('an isolate can die and come back repeatedly', () async {
      final exits = <bool>[];
      final cluster = await startMortal(_mortalServer, exits, isolates: 2);
      for (var i = 1; i <= 3; i++) {
        await killOne(cluster);
        await until(() => exits.length == i);
        await until(() => cluster.runningIsolates == 2);
      }
      expect(exits, [true, true, true]);
    });

    test('rateLimit() counts survive a restart', () async {
      final exits = <bool>[];
      final cluster =
          await startMortal(_mortalLimitedServer, exits, isolates: 2);
      for (var i = 0; i < 10; i++) {
        expect((await get(cluster.port, '/')).$1, 200);
      }
      await killOne(cluster);
      await until(() => exits.isNotEmpty);
      await until(() => cluster.runningIsolates == 2);
      for (var i = 0; i < 10; i++) {
        expect((await get(cluster.port, '/')).$1, 429);
      }
    });

    test('restarting continues until a failing build recovers', () async {
      final exits = <bool>[];
      final cluster = await startMortal(_failsWhileMarked(marker), exits,
          isolates: 2, maxRestarts: 100);
      File(marker).createSync();
      await killOne(cluster);
      await until(() => exits.length >= 2); // the restart failed too
      expect(cluster.runningIsolates, 1);

      File(marker).deleteSync();
      await until(() => cluster.runningIsolates == 2);
      expect((await get(cluster.port, '/')).$1, 200);
    });

    test('an isolate that keeps failing is given up on', () async {
      final exits = <bool>[];
      final cluster = await startMortal(_failsWhileMarked(marker), exits,
          isolates: 2, maxRestarts: 2);
      File(marker).createSync();
      await killOne(cluster);
      await until(() => exits.contains(false));
      expect(exits, [true, true, false]);

      // The other one is unaffected, and nothing else is scheduled.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(exits, hasLength(3));
      expect(cluster.runningIsolates, 1);
      expect((await get(cluster.port, '/')).$1, 200);
    });

    test('maxRestarts of 0 turns restarting off', () async {
      final exits = <bool>[];
      final cluster =
          await startMortal(_mortalServer, exits, maxRestarts: 0);
      await killOne(cluster);
      await until(() => exits.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(exits, [false]);
      expect(cluster.runningIsolates, 2);
    });

    test('a throwing onIsolateExit does not stop the restart', () async {
      var called = false;
      final cluster = await QuadrantCluster.start(
        isolates: 2,
        port: 0,
        address: InternetAddress.loopbackIPv4,
        build: _mortalServer,
        restartDelay: const Duration(milliseconds: 10),
        onIsolateExit: (index, {required willRestart}) {
          called = true;
          throw StateError('callback failed');
        },
      );
      addTearDown(() => cluster.close(force: true));
      await killOne(cluster);
      await until(() => called);
      await until(() => cluster.runningIsolates == 2);
    });

    test('close() cancels a restart that is waiting', () async {
      final exits = <bool>[];
      final cluster = await startMortal(_mortalServer, exits,
          isolates: 2, restartDelay: const Duration(hours: 1));
      await killOne(cluster);
      await until(() => exits.isNotEmpty);
      await cluster.close().timeout(_limit);
    });

    test('close() waits for a restart that is under way', () async {
      final exits = <bool>[];
      final cluster =
          await startMortal(_slowWhileMarked(marker), exits, isolates: 2);
      File(marker).createSync();
      await killOne(cluster);
      await until(() => exits.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(cluster.runningIsolates, 1, reason: 'should still be starting');

      await cluster.close().timeout(_limit);
      expect(exits, hasLength(1), reason: 'a shutdown is not a crash');
      expect(cluster.runningIsolates, 0);
    });

    test('close() does not count as isolates dying', () async {
      final exits = <bool>[];
      final cluster = await startMortal(_mortalServer, exits);
      await cluster.close();
      expect(exits, isEmpty);
    });

    test('start() rejects bad restart settings', () {
      expect(
        () => QuadrantCluster.start(
            isolates: 1, port: 0, build: _plainServer, maxRestarts: -1),
        throwsArgumentError,
      );
      expect(
        () => QuadrantCluster.start(
            isolates: 1,
            port: 0,
            build: _plainServer,
            restartDelay: const Duration(seconds: -1)),
        throwsArgumentError,
      );
    });
  });

  group('when the main isolate does not answer', () {
    // A hub nobody reads stands in for a blocked main isolate. It cannot be
    // blocked for real here, as this test's client runs on it too.
    late ReceivePort hub;
    late List<Object?> received;

    setUp(() {
      hub = ReceivePort();
      received = [];
      hub.listen(received.add);
      currentClusterLink = ClusterLink(0, 1, hub.sendPort);
    });
    tearDown(() {
      currentClusterLink = null;
      hub.close();
    });

    test('rateLimit() falls back to counting on this isolate', () async {
      final server = await QuadrantServer(
        middlewares: [
          rateLimit(
            maxRequests: 1,
            window: const Duration(minutes: 1),
            keyExtractor: (_) => 'everyone',
          ),
        ],
        routes: [Route.get(path: '/', handler: _whoAmI)],
      ).listen(port: 0, address: InternetAddress.loopbackIPv4);
      addTearDown(() => server.close(force: true));

      expect((await get(server.port, '/')).$1, 200);
      expect((await get(server.port, '/')).$1, 429);
      expect(received.whereType<RateCheck>(), hasLength(2));
    });

    test('the health check still answers, with its own count', () async {
      final server = await QuadrantServer(healthCheck: true, routes: [
        Route.get(path: '/', handler: _whoAmI),
      ]).listen(port: 0, address: InternetAddress.loopbackIPv4);
      addTearDown(() => server.close(force: true));

      final (status, body) = await get(server.port, '/health');
      expect(status, 200);
      expect((jsonDecode(body) as Map)['requests'], 1);
    });

    test('a reply in time is used, and a late one is ignored', () async {
      final link = currentClusterLink!;
      const allowed = RateDecision(allowed: true, remaining: 7, resetAtMs: 0);

      final answered = link.rateCheck('l', 1, 1000, 10, 'k');
      await Future<void>.delayed(Duration.zero);
      link.handle(CallReply((received.last as RateCheck).callId, allowed));
      expect((await answered)?.remaining, 7);

      final unanswered = link.rateCheck('l', 1, 1000, 10, 'k');
      expect(await unanswered, isNull);
      await Future<void>.delayed(Duration.zero);
      link.handle(CallReply((received.last as RateCheck).callId, allowed));
    });
  });

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
