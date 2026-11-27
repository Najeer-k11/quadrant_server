// Measures a server's memory: idle, per open connection, and under traffic
// with large bodies. The server runs as a compiled child process, on its own,
// so its RSS is all its own.
//
//   dart run benchmark/memory.dart [--connections=5000] [--engine=quadrant,dartio]
//       [--vm-options="--new_gen_semi_max_size=2"] [--traffic=upload,download]
//
// Linux only: reads /proc.
//
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:quadrant_server/quadrant_server.dart';

const _exe = '.dart_tool/benchmark/memory';

/// Which large-body traffic to send: `upload`, `download`, or both.
var _traffic = 'upload,download';

Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args.first == 'server') {
    return _serve(
        args[1] == 'quadrant' ? ServerEngine.quadrant : ServerEngine.dartIo);
  }
  final connections = int.parse(_option(args, 'connections') ?? '5000');
  final engines = (_option(args, 'engine') ?? 'quadrant,dartio').split(',');
  final vmOptions = _option(args, 'vm-options') ?? '';
  _traffic = _option(args, 'traffic') ?? 'upload,download';

  Directory('.dart_tool/benchmark').createSync(recursive: true);
  final build = await Process.run(
      'dart', ['compile', 'exe', 'benchmark/memory.dart', '-o', _exe]);
  if (build.exitCode != 0) throw StateError('${build.stdout}${build.stderr}');

  for (final engine in engines) {
    await _measure(engine, connections, vmOptions);
  }
}

String? _option(List<String> args, String name) {
  for (final arg in args) {
    if (arg.startsWith('--$name=')) return arg.substring(name.length + 3);
  }
  return null;
}

// ─── Server ──────────────────────────────────────────────────

Future<void> _serve(ServerEngine engine) async {
  final app = QuadrantServer(
    engine: engine,
    middlewares: [bodyParser(maxBodyBytes: 4 << 20)],
    routes: [
      Route.get(path: '/', handler: (req) async => Response.text('hello')),
      Route.post(
        path: '/echo',
        handler: (req) async => Response.ok({'keys': req.bodyAsMap?.length}),
      ),
      Route.get(
        path: '/download',
        handler: (req) async => StreamResponse(
          stream: Stream.fromIterable(
              List.generate(64, (_) => Uint8List(65536))),
          headers: {'content-length': '${64 * 65536}'},
        ),
      ),
    ],
  );
  final server = await app.listen(port: 0, address: '127.0.0.1');
  print('PORT ${server.port}');
}

// ─── Measuring ───────────────────────────────────────────────

Future<void> _measure(String engine, int connections, String vmOptions) async {
  final server = await Process.start(_exe, ['server', engine],
      environment: {if (vmOptions.isNotEmpty) 'DART_VM_OPTIONS': vmOptions});
  final port = Completer<int>();
  server.stdout.transform(utf8.decoder).listen((text) {
    final match = RegExp(r'PORT (\d+)').firstMatch(text);
    if (match != null && !port.isCompleted) {
      port.complete(int.parse(match.group(1)!));
    }
  });
  server.stderr.transform(utf8.decoder).listen(stderr.write);
  final p = await port.future.timeout(const Duration(seconds: 30));
  await Future<void>.delayed(const Duration(seconds: 1));
  final idle = _rssKb(server.pid);

  // Open connections, each served once and then kept open.
  final sockets = <Socket>[];
  for (var i = 0; i < connections; i += 200) {
    await Future.wait([
      for (var j = i; j < min(i + 200, connections); j++)
        () async {
          final socket = await Socket.connect('127.0.0.1', p);
          final answered = Completer<void>();
          socket.listen((_) {
            if (!answered.isCompleted) answered.complete();
          }, onError: (_) {});
          socket.write('GET / HTTP/1.1\r\nHost: x\r\n\r\n');
          await answered.future;
          sockets.add(socket);
        }(),
    ]);
  }
  await Future<void>.delayed(const Duration(seconds: 2));
  final withConnections = _rssKb(server.pid);
  for (final socket in sockets) {
    socket.destroy();
  }
  await Future<void>.delayed(const Duration(seconds: 2));

  // Large bodies: 16 clients posting 1 MB of JSON, 8 downloading 4 MB, for
  // 15 seconds.
  final client = HttpClient()..maxConnectionsPerHost = 64;
  final pad = 'p' * (1 << 20);
  final body = utf8.encode(jsonEncode({'a': 1, 'pad': pad}));
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  var peak = 0;
  final sampler = Timer.periodic(const Duration(milliseconds: 250), (_) {
    peak = max(peak, _rssKb(server.pid));
  });
  var requests = 0;
  await Future.wait([
    for (var w = 0; w < (_traffic.contains('upload') ? 16 : 0); w++)
      () async {
        while (DateTime.now().isBefore(deadline)) {
          final request = await client.post('127.0.0.1', p, '/echo');
          request.headers.contentType = ContentType.json;
          request.add(body);
          await (await request.close()).drain<void>();
          requests++;
        }
      }(),
    for (var w = 0; w < (_traffic.contains('download') ? 8 : 0); w++)
      () async {
        while (DateTime.now().isBefore(deadline)) {
          await (await (await client.get('127.0.0.1', p, '/download')).close())
              .drain<void>();
          requests++;
        }
      }(),
  ]);
  sampler.cancel();
  client.close(force: true);
  await Future<void>.delayed(const Duration(seconds: 3));
  final after = _rssKb(server.pid);
  server.kill();
  await server.exitCode;

  final perConnection = (withConnections - idle) * 1024 / connections;
  print('$engine${vmOptions.isEmpty ? '' : ' ($vmOptions)'}:');
  print('  idle                 ${_mb(idle)}');
  print('  $connections connections  ${_mb(withConnections)} '
      '(${perConnection.round()} bytes each)');
  print('  large bodies         peak ${_mb(peak)}, '
      '${_mb(after)} 3 s after, ${(requests / 15).round()} req/s');
}

String _mb(int kb) => '${(kb / 1024).toStringAsFixed(1)} MB';

int _rssKb(int pid) {
  try {
    final status = File('/proc/$pid/status').readAsStringSync();
    return int.parse(
        RegExp(r'VmRSS:\s+(\d+) kB').firstMatch(status)!.group(1)!);
  } catch (_) {
    return 0;
  }
}
