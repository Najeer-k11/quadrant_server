// Benchmark target. Usage: server <scenario> <port> <isolates>
//
// Prints READY once every isolate is listening.
//
// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:isolate';

import 'package:quadrant_server/quadrant_server.dart';

const _address = '127.0.0.1';
const _body = 'Hello, World!';

Future<void> main(List<String> args) async {
  final scenario = args[0];
  final port = int.parse(args[1]);
  final isolates = int.parse(args[2]);

  // QuadrantServer.listen() cannot share a port, so q_* stays on one isolate.
  if (scenario.startsWith('q_') && isolates != 1) {
    stderr.writeln('$scenario only supports 1 isolate');
    exit(2);
  }

  if (scenario.startsWith('qc_')) {
    await _startCluster(scenario.substring(3), port, isolates);
    print('READY');
    return;
  }

  final shared = isolates > 1;
  await _start(scenario, port, shared);

  final ready = ReceivePort();
  for (var i = 1; i < isolates; i++) {
    await Isolate.spawn(_worker, [scenario, port, ready.sendPort]);
  }
  var pending = isolates - 1;
  if (pending > 0) {
    await for (final _ in ready) {
      if (--pending == 0) break;
    }
  }
  ready.close();
  print('READY');
}

Future<void> _worker(List<Object> args) async {
  await _start(args[0] as String, args[1] as int, true);
  (args[2] as SendPort).send(true);
}

Future<void> _start(String scenario, int port, bool shared) async {
  switch (scenario) {
    case 'dart_socket':
      return _rawSocket(port, shared);
    case 'dartio_plain':
      return _dartIo(port, shared, () => _body);
    case 'dartio_cpu':
      return _dartIo(port, shared, () => '${_burn()}');
  }
  final app = _quadrant(scenario);
  await app.listen(port: port, address: _address);
}

/// Kept separate so the `build` closure captures only [scenario].
Future<void> _startCluster(String scenario, int port, int isolates) =>
    QuadrantCluster.start(
      isolates: isolates,
      port: port,
      address: _address,
      build: () => _quadrant('q_$scenario'),
    );

// ─── Controls without the framework ──────────────────────────

/// Sockets with no HTTP parsing: the most Dart can do on this machine.
Future<void> _rawSocket(int port, bool shared) async {
  final response = 'HTTP/1.1 200 OK\r\n'
          'content-type: text/plain; charset=utf-8\r\n'
          'x-frame-options: SAMEORIGIN\r\n'
          'x-xss-protection: 1; mode=block\r\n'
          'x-content-type-options: nosniff\r\n'
          'date: Fri, 06 Nov 2026 12:00:00 GMT\r\n'
          'content-length: ${_body.length}\r\n'
          '\r\n'
          '$_body'
      .codeUnits;
  final server = await RawServerSocket.bind(_address, port, shared: shared);
  server.listen((socket) {
    socket.setOption(SocketOption.tcpNoDelay, true);
    socket.writeEventsEnabled = false;
    socket.listen((event) {
      if (event == RawSocketEvent.read) {
        if (socket.read() != null) socket.write(response);
      } else if (event == RawSocketEvent.readClosed) {
        socket.close();
      }
    }, onError: (Object _) => socket.close()); // A client reset is not fatal.
  });
}

Future<void> _dartIo(int port, bool shared, String Function() body) async {
  final server = await HttpServer.bind(_address, port, shared: shared);
  server.listen((request) {
    request.response
      ..headers.set('content-type', 'text/plain; charset=utf-8')
      ..write(body())
      ..close();
  });
}

// ─── QuadrantServer scenarios ────────────────────────────────

Future<Response> _plain(Request req) async => Response.text(_body);

Future<Response> _json(Request req) async =>
    Response.ok({'id': 1, 'name': 'Ada', 'active': true});

Future<Response> _param(Request req) async =>
    Response.ok({'id': req.params['id']});

Future<Response> _noop(Request req, Next next) => next();

QuadrantServer _quadrant(String scenario) {
  Route plainRoute([List<Middleware> middlewares = const []]) =>
      Route.get(path: '/', handler: _plain, middlewares: middlewares);

  return switch (scenario) {
    'q_plain' => QuadrantServer(routes: [plainRoute()]),
    'q_json' => QuadrantServer(
        routes: [Route.get(path: '/', handler: _json)],
      ),
    'q_param1' => QuadrantServer(
        routes: [Route.get(path: '/r99/:id', handler: _param)],
      ),
    'q_param100' => QuadrantServer(routes: [
        for (var i = 0; i < 100; i++)
          Route.get(path: '/r$i/:id', handler: _param),
      ]),
    'q_noop5' => QuadrantServer(
        middlewares: [_noop, _noop, _noop, _noop, _noop],
        routes: [plainRoute()],
      ),
    'q_requestid' => QuadrantServer(
        middlewares: [requestId()],
        routes: [plainRoute()],
      ),
    'q_stack' => QuadrantServer(
        middlewares: [
          requestId(),
          helmet(),
          cors(),
          logger(output: (_) {}),
          bodyParser(),
        ],
        routes: [plainRoute()],
      ),
    // The limit is out of reach: this measures the cost of counting.
    'q_ratelimit' => QuadrantServer(
        middlewares: [
          rateLimit(
            maxRequests: 1 << 40,
            window: const Duration(seconds: 1),
            keyExtractor: (_) => 'everyone',
          ),
        ],
        routes: [plainRoute()],
      ),
    'q_post_json' => QuadrantServer(
        middlewares: [bodyParser()],
        routes: [
          Route.post(
            path: '/',
            handler: (req) async =>
                Response.ok({'keys': req.bodyAsMap?.length ?? 0}),
          ),
        ],
      ),
    // Stands in for a database call: waiting, not computing.
    'q_io10ms' => QuadrantServer(routes: [
        Route.get(
          path: '/',
          handler: (req) async {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            return Response.text(_body);
          },
        ),
      ]),
    'q_cpu1ms' => QuadrantServer(routes: [
        Route.get(
          path: '/',
          handler: (req) async => Response.text('${_burn()}'),
        ),
      ]),
    _ => throw ArgumentError('Unknown scenario: $scenario'),
  };
}

/// Fixed amount of CPU work, roughly 1 ms. The result is returned so the
/// compiler cannot remove the loop.
int _burn() {
  var x = 88172645463325252;
  for (var i = 0; i < 800000; i++) {
    x ^= x << 13;
    x ^= x >>> 7;
    x ^= x << 17;
  }
  return x;
}
