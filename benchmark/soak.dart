// Soak test for ServerEngine.quadrant: minutes of mixed, partly hostile
// traffic, checking that every answer is right and memory stays flat.
//
//   dart run benchmark/soak.dart [--seconds=120] [--engine=quadrant|dartio]
//       [--only=get,post-json,…]
//
// The server runs in a child process so its memory can be read on its own.
// Exits 1 if any response was wrong, the server died, or its memory kept
// growing.
//
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:quadrant_server/quadrant_server.dart';

Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args.first == 'server') {
    return _serve(args[1] == 'quadrant'
        ? ServerEngine.quadrant
        : ServerEngine.dartIo);
  }
  final seconds = int.parse(_option(args, 'seconds') ?? '120');
  final engine = _option(args, 'engine') ?? 'quadrant';
  final only = _option(args, 'only')?.split(',').toSet();
  exit(await _run(seconds, engine, only) ? 0 : 1);
}

String? _option(List<String> args, String name) {
  for (final arg in args) {
    if (arg.startsWith('--$name=')) return arg.substring(name.length + 3);
  }
  return null;
}

// ─── Server ──────────────────────────────────────────────────

final _megabyte = Uint8List(1 << 20);

Future<void> _serve(ServerEngine engine) async {
  late final HttpServer server;
  final app = QuadrantServer(
    engine: engine,
    engineOptions: const EngineOptions(
      maxConnections: 2000,
      maxRequestsPerConnection: 500,
      headerTimeout: Duration(seconds: 5),
      bodyTimeout: Duration(seconds: 5),
      idleTimeout: Duration(seconds: 10),
      dateHeader: true,
    ),
    middlewares: [requestId(), helmet(), cors(), bodyParser(maxBodyBytes: 1 << 20)],
    routes: [
      Route.get(path: '/', handler: (req) async => Response.text('hello')),
      Route.get(path: '/stats', handler: (req) async {
        final info = server.connectionsInfo();
        return Response.ok({'connections': info.total, 'active': info.active});
      }),
      Route.get(
        path: '/json/:id',
        handler: (req) async =>
            Response.ok({'id': req.params['id'], 'q': req.query['q']}),
      ),
      Route.post(
        path: '/echo',
        handler: (req) async => Response.ok({
          'keys': req.bodyAsMap?.length,
          'pad': (req.bodyAsMap?['pad'] as String?)?.length,
        }),
      ),
      Route.post(
        path: '/count',
        handler: (req) async {
          var bytes = 0;
          await for (final chunk in req.raw) {
            bytes += chunk.length;
          }
          return Response.text('$bytes');
        },
      ),
      Route.get(
        path: '/download',
        handler: (req) async => StreamResponse(
          stream: Stream.fromIterable(
              List.generate(16, (_) => Uint8List.sublistView(_megabyte, 0, 65536))),
          headers: {'content-length': '${16 * 65536}'},
        ),
      ),
      Route.get(
        path: '/sse',
        handler: (req) async {
          final sse = await SseContext.from(req);
          final timer = Timer.periodic(const Duration(milliseconds: 20), (_) {
            sse.send(data: 'tick');
          });
          await sse.done;
          timer.cancel();
          return sse.response;
        },
      ),
    ],
    webSocketRoutes: [
      WebSocketRoute(
        path: '/ws',
        onMessage: (ctx, data) async => ctx.send('echo:$data'),
      ),
    ],
  );
  server = await app.listen(port: 0, address: '127.0.0.1');
  print('PORT ${server.port}');
}

// ─── Load ────────────────────────────────────────────────────

class _Stats {
  final ok = <String, int>{};
  final failures = <String, int>{};
  final examples = <String>[];

  /// Connects that failed because this machine ran out of local ports, with
  /// thousands of closed connections waiting out TIME_WAIT: a limit of the
  /// load generator, not of the server.
  var outOfPorts = 0;

  void pass(String kind) => ok.update(kind, (n) => n + 1, ifAbsent: () => 1);

  void fail(String kind, Object detail) {
    final key = '$kind: ${'$detail'.split(',').first}';
    failures.update(key, (n) => n + 1, ifAbsent: () => 1);
    if (examples.length < 10) examples.add('$kind: $detail');
  }
}

bool _isOutOfPorts(Object error) =>
    error is SocketException &&
    (error.osError?.errorCode == 99 || error.osError?.errorCode == 49);

Future<bool> _run(int seconds, String engine, Set<String>? only) async {
  final server = await Process.start(Platform.resolvedExecutable,
      [Platform.script.toFilePath(), 'server', engine]);
  final portLine = Completer<int>();
  server.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
    (line) {
      if (line.startsWith('PORT ') && !portLine.isCompleted) {
        portLine.complete(int.parse(line.substring(5)));
      }
    },
  );
  final serverErrors = StringBuffer();
  server.stderr.transform(utf8.decoder).listen(serverErrors.write);
  final port = await portLine.future.timeout(const Duration(seconds: 60));
  print('Soaking $engine on port $port for ${seconds}s…');

  final stats = _Stats();
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  bool running() => DateTime.now().isBefore(deadline);

  final rss = <int>[];
  final sampler = Timer.periodic(const Duration(seconds: 2), (_) {
    rss.add(_rssKb(server.pid));
  });

  Future<void> loop(String kind, int workers, Future<void> Function(Random) body) {
    if (only != null && !only.contains(kind)) return Future.value();
    return Future.wait([
      for (var w = 0; w < workers; w++)
        () async {
          final random = Random(kind.hashCode + w);
          while (running()) {
            try {
              await body(random).timeout(const Duration(seconds: 20));
              stats.pass(kind);
            } catch (error) {
              if (_isOutOfPorts(error)) {
                stats.outOfPorts++;
                await Future<void>.delayed(const Duration(milliseconds: 200));
              } else {
                stats.fail(kind, error);
              }
            }
          }
        }(),
    ]);
  }

  final client = HttpClient()..maxConnectionsPerHost = 64;
  final base = Uri.parse('http://127.0.0.1:$port');

  await Future.wait([
    loop('get', 16, (random) async {
      final id = random.nextInt(1 << 20);
      final response =
          await (await client.getUrl(base.resolve('/json/$id?q=x%20y'))).close();
      final body = await response.transform(utf8.decoder).join();
      _expect(response.statusCode == 200, 'status ${response.statusCode}');
      _expect(body == '{"id":"$id","q":"x y"}', body);
      _expect(response.headers.value('x-request-id') != null, 'no request id');
    }),
    loop('post-json', 8, (random) async {
      final pad = 'p' * random.nextInt(200000);
      final request = await client.postUrl(base.resolve('/echo'));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'a': 1, 'b': 'Zoë', 'pad': pad}));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      _expect(body == '{"keys":3,"pad":${pad.length}}', body);
    }),
    loop('chunked-upload', 4, (random) async {
      final size = random.nextInt(3 << 20);
      final request = await client.postUrl(base.resolve('/count'));
      request.headers.chunkedTransferEncoding = true;
      for (var sent = 0; sent < size; sent += 65536) {
        request.add(Uint8List.sublistView(_megabyte, 0, min(65536, size - sent)));
      }
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      _expect(body == '$size', 'counted $body of $size');
    }),
    loop('pipelined', 4, (random) async {
      final socket = await _connect(port);
      final n = 1 + random.nextInt(20);
      final received = BytesBuilder();
      final done = Completer<void>();
      socket.listen(received.add, onDone: done.complete, onError: (_) {});
      socket.write([
        for (var i = 0; i < n; i++)
          'GET / HTTP/1.1\r\nHost: x\r\n${i == n - 1 ? 'Connection: close\r\n' : ''}\r\n',
      ].join());
      await done.future;
      final text = latin1.decode(received.takeBytes());
      _expect('200 OK'.allMatches(text).length == n, 'pipelined $n, got $text');
    }),
    loop('download', 4, (random) async {
      if (random.nextBool()) {
        final response =
            await (await client.getUrl(base.resolve('/download'))).close();
        var bytes = 0;
        await for (final chunk in response) {
          bytes += chunk.length;
        }
        _expect(bytes == 16 * 65536, 'downloaded $bytes');
      } else {
        // Abandoned partway, as by a client that went away: the server must
        // not keep anything for it.
        final own = HttpClient();
        final response =
            await (await own.getUrl(base.resolve('/download'))).close();
        final subscription = response.listen(null);
        await Future<void>.delayed(Duration(milliseconds: random.nextInt(5)));
        await subscription.cancel();
        own.close(force: true);
      }
    }),
    loop('sse', 4, (random) async {
      final response = await (await client.getUrl(base.resolve('/sse'))).close();
      final want = 1 + random.nextInt(10);
      var events = 0;
      await for (final line
          in response.transform(utf8.decoder).transform(const LineSplitter())) {
        if (line == 'data: tick' && ++events == want) break;
      }
      _expect(events == want, 'sse $events of $want');
    }),
    loop('websocket', 4, (random) async {
      final socket = await WebSocket.connect('ws://127.0.0.1:$port/ws');
      final replies = StreamIterator(socket);
      for (var i = 0; i < 1 + random.nextInt(20); i++) {
        socket.add('m$i');
        _expect(await replies.moveNext() && replies.current == 'echo:m$i',
            'websocket reply');
      }
      if (random.nextBool()) {
        await socket.close();
      } else {
        await socket.close(WebSocketStatus.goingAway);
      }
    }),
    loop('abrupt', 4, (random) async {
      // Gone partway through the headers or the body.
      final socket = await _connect(port);
      final request = latin1.encode('POST /echo HTTP/1.1\r\nHost: x\r\n'
          'Content-Type: application/json\r\nContent-Length: 1000\r\n\r\n{"a":');
      socket.add(Uint8List.sublistView(request, 0, random.nextInt(request.length)));
      await socket.flush();
      await Future<void>.delayed(Duration(milliseconds: random.nextInt(20)));
      socket.destroy();
    }),
    loop('slow-headers', 2, (random) async {
      // Byte by byte, but inside headerTimeout.
      final socket = await _connect(port);
      final received = BytesBuilder();
      final done = Completer<void>();
      socket.listen(received.add, onDone: done.complete, onError: (_) {});
      for (final byte in latin1.encode('GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n')) {
        socket.add([byte]);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await done.future;
      _expect(latin1.decode(received.takeBytes()).startsWith('HTTP/1.1 200'),
          'slow client');
    }),
    loop('garbage', 2, (random) async {
      final socket = await _connect(port);
      final done = Completer<void>();
      final received = BytesBuilder();
      socket.listen(received.add, onDone: done.complete, onError: (_) {});
      socket.add(List.generate(1 + random.nextInt(2000), (_) => random.nextInt(256)));
      socket.add(latin1.encode('\r\n\r\n'));
      await done.future;
      final text = latin1.decode(received.takeBytes());
      // Refused, or closed without a word; never a 2xx or a 5xx.
      _expect(text.isEmpty || RegExp(r'^HTTP/1\.1 4\d\d ').hasMatch(text) ||
          text.startsWith('HTTP/1.1 505'), 'garbage got: ${text.split('\r\n').first}');
    }),
  ]);
  sampler.cancel();
  client.close(force: true);

  // Still running, and still answering, after all that? Retried for a while
  // in case this machine is still short of local ports.
  final processAlive = File('/proc/${server.pid}/status').existsSync();
  var alive = false;
  for (var attempt = 0; processAlive && !alive && attempt < 60; attempt++) {
    try {
      final last = HttpClient();
      final response = await (await last.getUrl(base)).close();
      await response.drain<void>();
      last.close();
      alive = response.statusCode == 200;
    } catch (error) {
      if (!_isOutOfPorts(error)) break;
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  }
  // Once idleTimeout (10 s) has passed, nothing should be left open but the
  // connection asking. More would be connections the server lost track of.
  var leftOpen = -1;
  if (alive) {
    await Future<void>.delayed(const Duration(seconds: 13));
    final last = HttpClient();
    final response = await (await last.getUrl(base.resolve('/stats'))).close();
    final stats = jsonDecode(await response.transform(utf8.decoder).join());
    last.close(force: true);
    leftOpen = (stats as Map)['connections'] as int;
  }
  server.kill();

  // Memory: the last third of the run against the middle third, since the
  // first includes warming up.
  final third = rss.length ~/ 3;
  final middle = _median(rss.sublist(third, 2 * third));
  final end = _median(rss.sublist(2 * third));
  final growth = middle == 0 ? 0.0 : (end - middle) / middle * 100;

  print('');
  stats.ok.forEach((kind, n) => print('  ${kind.padRight(16)} $n ok'));
  final failures = stats.failures.values.fold(0, (a, b) => a + b);
  print('  failures         $failures');
  stats.failures.forEach((key, n) => print('    $n × $key'));
  for (final example in stats.examples) {
    print('    e.g. $example');
  }
  print('  client out of ports ${stats.outOfPorts} (skipped, not the server)');
  print('  RSS              ${middle ~/ 1024} MB mid-run, ${end ~/ 1024} MB at the end '
      '(${growth.toStringAsFixed(1)}%), peak ${rss.reduce(max) ~/ 1024} MB');
  print('  server alive     $alive (process running: $processAlive)');
  print('  connections left open after idle: $leftOpen (1 is this check)');
  if (serverErrors.isNotEmpty) print('  server stderr:\n$serverErrors');

  final passed = failures == 0 && alive && leftOpen == 1 && growth < 15;
  print(passed ? 'PASS' : 'FAIL');
  return passed;
}

/// A raw client socket. A server that refuses a request may close while the
/// client is still writing, which is expected here, not an error.
Future<Socket> _connect(int port) async {
  final socket = await Socket.connect('127.0.0.1', port);
  unawaited(socket.done.catchError((Object _) {}));
  return socket;
}

void _expect(bool condition, Object detail) {
  if (!condition) throw StateError('$detail');
}

int _rssKb(int pid) {
  try {
    final status = File('/proc/$pid/status').readAsStringSync();
    return int.parse(RegExp(r'VmRSS:\s+(\d+) kB').firstMatch(status)!.group(1)!);
  } catch (_) {
    return 0;
  }
}

int _median(List<int> values) {
  if (values.isEmpty) return 0;
  final sorted = [...values]..sort();
  return sorted[sorted.length ~/ 2];
}
