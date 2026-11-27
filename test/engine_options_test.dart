// EngineOptions: connection and request limits, timeouts, the Date header.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:quadrant_server/quadrant_server.dart';
import 'package:test/test.dart';

const _limit = Duration(seconds: 6);

Future<(QuadrantServer, int)> _start(EngineOptions options,
    {ServerEngine engine = ServerEngine.quadrant}) async {
  final app = QuadrantServer(
    engine: engine,
    engineOptions: options,
    middlewares: [bodyParser()],
    routes: [
      Route.get(path: '/', handler: (req) async => Response.text('hi')),
      Route.post(
        path: '/body',
        handler: (req) async => Response.ok({'body': req.body}),
      ),
    ],
  );
  final server = await app.listen(port: 0, address: '127.0.0.1');
  addTearDown(() => app.close(force: true));
  return (app, server.port);
}

/// A raw connection that collects what it receives.
class _Conn {
  final Socket socket;
  final _received = StringBuffer();
  final _closed = Completer<void>();
  final _changed = StreamController<void>.broadcast();

  _Conn(this.socket) {
    socket.listen(
      (data) {
        _received.write(latin1.decode(data));
        _changed.add(null);
      },
      onDone: _closed.complete,
      onError: (Object _) {
        if (!_closed.isCompleted) _closed.complete();
      },
    );
  }

  static Future<_Conn> open(int port) async =>
      _Conn(await Socket.connect('127.0.0.1', port));

  String get received => _received.toString();
  Future<void> get closed => _closed.future.timeout(_limit);

  void send(String text) => socket.add(latin1.encode(text));

  /// Waits until [pattern] has been received [count] times.
  Future<void> waitFor(String pattern, {int count = 1}) async {
    bool done() => pattern.allMatches(received).length >= count;
    if (done()) return;
    await _changed.stream.firstWhere((_) => done()).timeout(_limit);
  }

  void destroy() => socket.destroy();
}

void main() {
  test('maxConnections answers 503 past the limit, then frees up', () async {
    final (_, port) = await _start(const EngineOptions(maxConnections: 2));
    final a = await _Conn.open(port);
    final b = await _Conn.open(port);
    addTearDown(a.destroy);
    addTearDown(b.destroy);
    // Both served, and both kept open.
    a.send('GET / HTTP/1.1\r\nHost: x\r\n\r\n');
    b.send('GET / HTTP/1.1\r\nHost: x\r\n\r\n');
    await a.waitFor('200 OK');
    await b.waitFor('200 OK');

    final c = await _Conn.open(port);
    c.send('GET / HTTP/1.1\r\nHost: x\r\n\r\n');
    await c.closed;
    expect(c.received, startsWith('HTTP/1.1 503 Service Unavailable'));

    a.destroy();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final d = await _Conn.open(port);
    addTearDown(d.destroy);
    d.send('GET / HTTP/1.1\r\nHost: x\r\n\r\n');
    await d.waitFor('200 OK');
  });

  test('maxRequestsPerConnection closes after the last allowed one', () async {
    final (_, port) =
        await _start(const EngineOptions(maxRequestsPerConnection: 3));
    final conn = await _Conn.open(port);
    addTearDown(conn.destroy);
    for (var i = 0; i < 4; i++) {
      conn.send('GET / HTTP/1.1\r\nHost: x\r\n\r\n');
    }
    await conn.closed;
    final responses = '200 OK'.allMatches(conn.received).length;
    expect(responses, 3, reason: conn.received);
    expect('connection: close'.allMatches(conn.received), hasLength(1));
  });

  test('bodyTimeout answers 408 when the body stalls', () async {
    final (_, port) =
        await _start(const EngineOptions(bodyTimeout: Duration(seconds: 1)));
    final conn = await _Conn.open(port);
    addTearDown(conn.destroy);
    conn.send('POST /body HTTP/1.1\r\nHost: x\r\n'
        'Content-Type: application/json\r\nContent-Length: 20\r\n\r\n{"a"');
    await conn.closed;
    expect(conn.received, startsWith('HTTP/1.1 408 '));
    expect(conn.received, contains('Request body timeout'));
  });

  test('bodyTimeout does not count time the handler spends not reading',
      () async {
    final app = QuadrantServer(
      engine: ServerEngine.quadrant,
      engineOptions: const EngineOptions(bodyTimeout: Duration(seconds: 1)),
      routes: [
        Route.post(
          path: '/',
          handler: (req) async {
            await Future<void>.delayed(const Duration(milliseconds: 2500));
            final body = await utf8.decodeStream(req.raw);
            return Response.text('got $body');
          },
        ),
      ],
    );
    final server = await app.listen(port: 0, address: '127.0.0.1');
    addTearDown(() => app.close(force: true));
    final conn = await _Conn.open(server.port);
    addTearDown(conn.destroy);
    conn.send('POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\n'
        'Connection: close\r\n\r\nbody');
    await conn.closed;
    expect(conn.received, startsWith('HTTP/1.1 200 OK'));
    expect(conn.received, endsWith('got body'));
  });

  test('headerTimeout answers 408 to a header block that stalls', () async {
    final (_, port) =
        await _start(const EngineOptions(headerTimeout: Duration(seconds: 1)));
    final conn = await _Conn.open(port);
    addTearDown(conn.destroy);
    conn.send('GET / HTTP/1.1\r\nHost: x\r\n');
    await conn.closed;
    expect(conn.received, startsWith('HTTP/1.1 408 '));
  });

  test('idleTimeout closes a connection left unused', () async {
    final (_, port) =
        await _start(const EngineOptions(idleTimeout: Duration(seconds: 1)));
    final conn = await _Conn.open(port);
    addTearDown(conn.destroy);
    conn.send('GET / HTTP/1.1\r\nHost: x\r\n\r\n');
    await conn.waitFor('200 OK');
    await conn.closed;
  });

  test('maxHeaderBytes and maxHeaderCount are configurable', () async {
    final (_, port) = await _start(
        const EngineOptions(maxHeaderBytes: 200, maxHeaderCount: 3));
    final big = await _Conn.open(port);
    addTearDown(big.destroy);
    big.send('GET / HTTP/1.1\r\nX-A: ${'a' * 300}\r\n\r\n');
    await big.closed;
    expect(big.received, startsWith('HTTP/1.1 431 '));

    final many = await _Conn.open(port);
    addTearDown(many.destroy);
    many.send('GET / HTTP/1.1\r\nA: 1\r\nB: 1\r\nC: 1\r\nD: 1\r\n\r\n');
    await many.closed;
    expect(many.received, startsWith('HTTP/1.1 431 '));
  });

  test('dateHeader adds a valid Date header', () async {
    final (_, port) = await _start(const EngineOptions(dateHeader: true));
    final client = HttpClient();
    addTearDown(client.close);
    final response = await (await client.get('127.0.0.1', port, '/')).close();
    await response.drain<void>();
    final date = response.headers.date;
    expect(date, isNotNull);
    expect(DateTime.now().difference(date!).inSeconds.abs(), lessThan(5));
  });

  test('no Date header by default, as with dart:io', () async {
    final (_, port) = await _start(const EngineOptions());
    final client = HttpClient();
    addTearDown(client.close);
    final response = await (await client.get('127.0.0.1', port, '/')).close();
    await response.drain<void>();
    expect(response.headers.value('date'), isNull);
  });

  test('idleTimeout also applies to ServerEngine.dartIo', () async {
    final app = QuadrantServer(
      engineOptions: const EngineOptions(idleTimeout: Duration(seconds: 7)),
      routes: [Route.get(path: '/', handler: (req) async => Response.text(''))],
    );
    final server = await app.listen(port: 0, address: '127.0.0.1');
    addTearDown(app.close);
    expect(server.idleTimeout, const Duration(seconds: 7));
  });
}
