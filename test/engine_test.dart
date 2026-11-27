// Protocol-level tests for ServerEngine.quadrant, over raw sockets.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:quadrant_server/quadrant_server.dart';
import 'package:quadrant_server/src/engine/engine.dart';
import 'package:test/test.dart';

const _limit = Duration(seconds: 5);

void main() {
  late QuadrantServer app;
  late int port;

  setUp(() async {
    app = QuadrantServer(
      engine: ServerEngine.quadrant,
      middlewares: [bodyParser()],
      routes: [
        Route.get(path: '/', handler: (req) async => Response.text('hello')),
        Route.get(
          path: '/echo',
          handler: (req) async => Response.ok({
            'path': req.path,
            'query': req.query,
            'agent': req.headers['user-agent'],
          }),
        ),
        Route.post(
          path: '/body',
          handler: (req) async => Response.ok({'body': req.body}),
        ),
        Route.get(
          path: '/split',
          handler: (req) async => Response(
            statusCode: 200,
            headers: {'x-evil': 'a\r\nset-cookie: pwned=1'},
            body: 'no',
          ),
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
          path: '/cased',
          handler: (req) async => Response(
            statusCode: 200,
            headers: {
              'Content-Type': 'text/plain; charset=utf-8',
              'X-Thing': 'first',
              'x-thing': 'second',
              'x-name': 'Zoë 日本',
            },
            body: 'ok',
          ),
        ),
        Route.get(
          path: '/badlength',
          handler: (req) async => const Response(
            statusCode: 200,
            headers: {'content-length': '2\r\nx-evil: 1'},
            body: 'ok',
          ),
        ),
        Route.get(
          path: '/empty',
          handler: (req) async => Response.noContent(),
        ),
        Route.get(
          path: '/slow/:ms',
          handler: (req) async {
            await Future<void>.delayed(
                Duration(milliseconds: int.parse(req.params['ms']!)));
            return Response.text('slow ${req.params['ms']}');
          },
        ),
      ],
      webSocketRoutes: [
        WebSocketRoute(
          path: '/ws',
          onMessage: (ctx, data) async => ctx.send('echo: $data'),
        ),
      ],
    );
    port = (await app.listen(port: 0, address: '127.0.0.1')).port;
  });

  tearDown(() => app.close(force: true));

  group('framing', () {
    test('answers a plain GET with dart:io default headers', () async {
      final raw = await _exchange(
          port, 'GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n');
      expect(raw, startsWith('HTTP/1.1 200 OK\r\n'));
      expect(raw, contains('content-type: text/plain; charset=utf-8\r\n'));
      expect(raw, contains('x-content-type-options: nosniff\r\n'));
      expect(raw, contains('content-length: 5\r\n'));
      expect(raw, endsWith('\r\n\r\nhello'));
    });

    test('serves pipelined requests in order on one connection', () async {
      final raw = await _exchange(
        port,
        'GET /slow/50 HTTP/1.1\r\nHost: x\r\n\r\n'
        'GET /slow/1 HTTP/1.1\r\nHost: x\r\n\r\n'
        'GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n',
      );
      final first = raw.indexOf('slow 50');
      final second = raw.indexOf('slow 1');
      final third = raw.indexOf('hello');
      expect([first, second, third], everyElement(greaterThan(0)));
      expect(first < second && second < third, isTrue, reason: raw);
    });

    test('keeps the connection for HTTP/1.1, closes it for HTTP/1.0', () async {
      final keep = await _exchange(port, 'GET / HTTP/1.1\r\nHost: x\r\n\r\n',
          waitForClose: false);
      expect(keep, isNot(contains('connection: close')));

      final close = await _exchange(port, 'GET / HTTP/1.0\r\n\r\n');
      expect(close, contains('connection: close'));

      final keepAlive = await _exchange(
          port, 'GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n',
          waitForClose: false);
      expect(keepAlive, contains('connection: keep-alive'));
    });

    test('accepts bare LF line endings, as dart:io does', () async {
      final raw = await _exchange(
          port, 'GET / HTTP/1.1\nHost: x\nConnection: close\n\n');
      expect(raw, startsWith('HTTP/1.1 200 OK'));
    });

    test('reads a content-length body split across packets', () async {
      final socket = await Socket.connect('127.0.0.1', port);
      final received = _collect(socket);
      socket.write('POST /body HTTP/1.1\r\nHost: x\r\n'
          'Content-Type: application/json\r\nContent-Length: 11\r\n\r\n{"a"');
      await socket.flush();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      socket.write(':[1,2]}');
      await socket.flush();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      socket.write('GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n');
      final raw = await received.timeout(_limit);
      expect(raw, contains('{"body":{"a":[1,2]}}'));
      expect(raw, endsWith('hello'));
    });

    test('keeps the connection after a chunked body read with await for',
        () async {
      // Closing the body stream can run the handler to its response inside
      // close(). The connection must already know the body is done, or it
      // drops the connection as if the response came first.
      final client = HttpClient();
      addTearDown(client.close);
      final ports = <int>{};
      for (var i = 0; i < 5; i++) {
        final request = await client.post('127.0.0.1', port, '/count');
        request.headers.chunkedTransferEncoding = true;
        request.add(List.filled(200000, 1));
        final response = await request.close();
        expect(await response.transform(utf8.decoder).join(), '200000');
        ports.add(response.connectionInfo!.localPort);
      }
      expect(ports, hasLength(1), reason: 'one keep-alive connection');
    });

    test('decodes a chunked body with extensions and trailers', () async {
      final raw = await _exchange(
        port,
        'POST /body HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n'
        'Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n'
        '4;ext=1\r\n{"k"\r\n'
        '7\r\n:"v123"\r\n'
        '1\r\n}\r\n'
        '0\r\nX-Trailer: yes\r\n\r\n',
      );
      expect(raw, contains('{"body":{"k":"v123"}}'));
    });

    test('a JSON body that is not valid UTF-8 gets 400', () async {
      final socket = await Socket.connect('127.0.0.1', port);
      final received = _collect(socket);
      socket.add([
        ...latin1.encode('POST /body HTTP/1.1\r\nHost: x\r\n'
            'Content-Type: application/json\r\nContent-Length: 9\r\n'
            'Connection: close\r\n\r\n{"a":"'),
        0xFF,
        ...latin1.encode('"}'),
      ]);
      expect(await received.timeout(_limit), startsWith('HTTP/1.1 400 '));
    });

    test('sends 100 Continue once the body is read', () async {
      final socket = await Socket.connect('127.0.0.1', port);
      final chunks = <String>[];
      final gotContinue = Completer<void>();
      final done = Completer<void>();
      socket.listen((data) {
        chunks.add(latin1.decode(data));
        if (chunks.join().contains('100 Continue') &&
            !gotContinue.isCompleted) {
          gotContinue.complete();
        }
      }, onDone: done.complete);
      socket.write('POST /body HTTP/1.1\r\nHost: x\r\n'
          'Content-Type: application/json\r\nContent-Length: 2\r\n'
          'Expect: 100-continue\r\nConnection: close\r\n\r\n');
      await gotContinue.future.timeout(_limit);
      socket.write('{}');
      await done.future.timeout(_limit);
      final raw = chunks.join();
      expect(raw, startsWith('HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK'));
      expect(raw, endsWith('{"body":{}}'));
    });

    test('a 204 has neither a body nor a content-length', () async {
      final raw = await _exchange(
          port, 'GET /empty HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n');
      expect(raw, startsWith('HTTP/1.1 204 No Content'));
      expect(raw, isNot(contains('content-length')));
      expect(raw, endsWith('\r\n\r\n'));
    });

    test('a header value with CRLF becomes a 500, not a split response',
        () async {
      final raw =
          await _exchange(port, 'GET /split HTTP/1.1\r\nHost: x\r\n\r\n');
      expect(raw, startsWith('HTTP/1.1 500 '));
      expect(raw, isNot(contains('pwned')));
      expect(raw, contains('connection: close'));
    });

    test('names differing only in case: the later wins, as with set()',
        () async {
      final raw = await _exchange(
          port, 'GET /cased HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n');
      expect(raw, contains('x-thing: second\r\n'));
      expect(raw, isNot(contains('first')));
      expect(RegExp(r'^content-type:', multiLine: true).allMatches(raw),
          hasLength(1));
    });

    test('a header value beyond Latin-1 goes out wholly as UTF-8', () async {
      final socket = await Socket.connect('127.0.0.1', port);
      final bytes = BytesBuilder();
      final done = Completer<void>();
      socket.listen(bytes.add, onDone: done.complete);
      socket.write('GET /cased HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n');
      await done.future.timeout(_limit);
      final raw = bytes.takeBytes();
      // All of it, ë included, rather than a mix a client cannot decode.
      final expected = [...latin1.encode('x-name: '), ...utf8.encode('Zoë 日本')];
      expect(_indexOf(raw, expected), greaterThan(0));
    });

    test('a content-length that is not a number becomes a 500', () async {
      final raw = await _exchange(
          port, 'GET /badlength HTTP/1.1\r\nHost: x\r\n\r\n');
      expect(raw, startsWith('HTTP/1.1 500 '));
      expect(raw, isNot(contains('x-evil')));
    });

    test('HEAD gets the headers of GET and no body', () async {
      final raw = await _exchange(
          port, 'HEAD / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n');
      expect(raw, contains('content-length: 5\r\n'));
      expect(raw, endsWith('\r\n\r\n'));
    });
  });

  group('refuses', () {
    Future<void> refuses(String request, int status) async {
      final raw = await _exchange(port, request);
      expect(raw, startsWith('HTTP/1.1 $status '), reason: request);
      expect(raw, contains('connection: close'));
    }

    test(
        'both content-length and transfer-encoding',
        () => refuses(
            'POST /body HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n'
            'Transfer-Encoding: chunked\r\n\r\n0\r\n\r\n',
            400));

    test(
        'conflicting content-lengths',
        () => refuses(
            'POST /body HTTP/1.1\r\nContent-Length: 3\r\nContent-Length: 4\r\n\r\n',
            400));

    test(
        'a content-length that is not a number',
        () => refuses(
            'POST /body HTTP/1.1\r\nContent-Length: +3\r\n\r\nabc', 400));

    test(
        'transfer-encodings other than chunked',
        () => refuses(
            'POST /body HTTP/1.1\r\nTransfer-Encoding: gzip, chunked\r\n\r\n',
            501));

    test('folded header lines',
        () => refuses('GET / HTTP/1.1\r\nX-A: 1\r\n  continued\r\n\r\n', 400));

    test('whitespace before the colon',
        () => refuses('GET / HTTP/1.1\r\nHost : x\r\n\r\n', 400));

    test(
        'a bare CR', () => refuses('GET / HTTP/1.1\r\nX-A: 1\r2\r\n\r\n', 400));

    test('an unknown HTTP version',
        () => refuses('GET / HTTP/2.0\r\n\r\n', 505));

    test('a malformed request line', () => refuses('GET /\r\n\r\n', 400));

    test('a header block over 64 KB',
        () => refuses('GET / HTTP/1.1\r\nX-Big: ${'a' * 70000}\r\n\r\n', 431));

    test(
        'more than 100 header fields',
        () => refuses(
            'GET / HTTP/1.1\r\n${[
              for (var i = 0; i < 101; i++) 'X-$i: 1\r\n'
            ].join()}\r\n',
            431));

    test('a malformed chunk, after the handler has the request', () async {
      final raw = await _exchange(
        port,
        'POST /body HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n'
        'Transfer-Encoding: chunked\r\n\r\nzz\r\n',
      );
      // bodyParser sees a broken body; the connection is not reused.
      expect(raw, startsWith('HTTP/1.1 '));
      expect(raw, contains('connection: close'));
    });
  });

  group('request target', () {
    test('the fast path agrees with Uri.parse', () {
      final random = Random(42);
      const alphabet = "abcXYZ019-._~!\$&'()*+,;=:@/?%#[] ";
      for (var i = 0; i < 20000; i++) {
        final length = random.nextInt(12);
        final target = '/${[
          for (var j = 0; j < length; j++)
            alphabet[random.nextInt(alphabet.length)]
        ].join()}';
        Uri uri;
        try {
          uri = Uri.parse(target);
        } on FormatException {
          continue;
        }
        expect(debugPlainTargetParts(target) ?? (uri.path, uri.query),
            (uri.path, uri.query),
            reason: target);
      }
    });

    test('dot segments and escapes are normalised as dart:io does', () async {
      final raw = await _exchange(port,
          'GET /a/../ech%6F?x=1&y=%41 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n');
      expect(raw, contains('"path":"/echo"'));
      expect(raw, contains('"query":{"x":"1","y":"A"}'));
    });

    test('repeated headers are joined', () async {
      final raw = await _exchange(
          port,
          'GET /echo HTTP/1.1\r\nUser-Agent: a\r\nuser-agent: b\r\n'
          'Connection: close\r\n\r\n');
      expect(raw, contains('"agent":"a, b"'));
    });
  });

  test('a WebSocket upgrade works with "Connection: keep-alive, Upgrade"',
      () async {
    final socket = await WebSocket.connect('ws://127.0.0.1:$port/ws',
        headers: {'connection': 'keep-alive, Upgrade'});
    final reply = socket.first;
    socket.add('hi');
    expect(await reply.timeout(_limit), 'echo: hi');
    await socket.close();
  });

  test('HttpClient sees the same responses as with dart:io', () async {
    final client = HttpClient();
    addTearDown(client.close);
    for (var i = 0; i < 50; i++) {
      final request =
          await client.postUrl(Uri.parse('http://127.0.0.1:$port/body'));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'i': i, 'name': 'Zoë'}));
      final response = await request.close();
      expect(response.statusCode, 200);
      expect(await response.transform(utf8.decoder).join(),
          '{"body":{"i":$i,"name":"Zoë"}}');
    }
  });

  test('a cluster spreads connections across engine isolates', () async {
    final cluster = await QuadrantCluster.start(
      isolates: 2,
      port: 0,
      address: InternetAddress.loopbackIPv4,
      build: _clusterServer,
    );
    addTearDown(() => cluster.close(force: true));
    final seen = <int>{};
    for (var i = 0; i < 40 && seen.length < 2; i++) {
      final raw = await _exchange(cluster.port,
          'GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n');
      final body = raw.substring(raw.indexOf('\r\n\r\n') + 4);
      seen.add((jsonDecode(body) as Map)['isolate'] as int);
    }
    expect(seen, {0, 1});
  });

  test('serves HTTPS, including a WebSocket over TLS', () async {
    final dir = await Directory.systemTemp.createTemp('quadrant_tls_');
    addTearDown(() => dir.delete(recursive: true));
    final cert = File('${dir.path}/cert.pem');
    final key = File('${dir.path}/key.pem');
    final openssl = await Process.run('openssl', [
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-nodes',
      '-days',
      '1',
      '-subj',
      '/CN=localhost',
      '-keyout',
      key.path,
      '-out',
      cert.path,
    ]);
    expect(openssl.exitCode, 0, reason: '${openssl.stderr}');

    final server = QuadrantServer(
      engine: ServerEngine.quadrant,
      routes: [
        Route.get(
          path: '/',
          handler: (req) async => Response.text(req.raw.requestedUri.scheme),
        ),
      ],
      webSocketRoutes: [
        WebSocketRoute(
          path: '/ws',
          onMessage: (ctx, data) async => ctx.send('tls: $data'),
        ),
      ],
    );
    final bound = await server.listenSecure(
      port: 0,
      address: '127.0.0.1',
      certificateChain: cert,
      privateKey: key,
    );
    addTearDown(() => server.close(force: true));

    final client = HttpClient()..badCertificateCallback = (_, __, ___) => true;
    addTearDown(() => client.close(force: true));
    for (var i = 0; i < 3; i++) {
      final response = await (await client
              .getUrl(Uri.parse('https://127.0.0.1:${bound.port}/')))
          .close();
      expect(response.statusCode, 200);
      expect(await response.transform(utf8.decoder).join(), 'https');
    }

    final socket = await WebSocket.connect('wss://127.0.0.1:${bound.port}/ws',
        customClient: client);
    final reply = socket.first;
    socket.add('hi');
    expect(await reply.timeout(_limit), 'tls: hi');
    await socket.close();
  },
      skip: Process.runSync('which', ['openssl']).exitCode == 0
          ? false
          : 'openssl is not installed');

  test('connectionInfo and requestedUri are filled in', () async {
    late HttpRequest seen;
    final server = QuadrantServer(
      engine: ServerEngine.quadrant,
      routes: [
        Route.get(
          path: '/',
          handler: (req) async {
            seen = req.raw;
            return Response.text('ok');
          },
        ),
      ],
    );
    final bound = await server.listen(port: 0, address: '127.0.0.1');
    addTearDown(() => server.close(force: true));
    await _exchange(bound.port,
        'GET /?q=1 HTTP/1.1\r\nHost: example.com:8080\r\nConnection: close\r\n\r\n');
    expect(seen.connectionInfo!.remoteAddress.address, '127.0.0.1');
    expect(seen.requestedUri.toString(), 'http://example.com:8080/?q=1');
    expect(seen.headers.host, 'example.com');
    expect(seen.headers.port, 8080);
  });
}

int _indexOf(List<int> haystack, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

QuadrantServer _clusterServer() => QuadrantServer(
      engine: ServerEngine.quadrant,
      routes: [
        Route.get(
          path: '/',
          handler: (req) async =>
              Response.ok({'isolate': QuadrantCluster.isolateIndex}),
        ),
      ],
    );

/// Sends [request] and returns everything received, until the server closes
/// the connection or, with [waitForClose] false, until it goes quiet.
Future<String> _exchange(int port, String request,
    {bool waitForClose = true}) async {
  final socket = await Socket.connect('127.0.0.1', port);
  final received = _collect(socket, quiet: !waitForClose);
  socket.add(latin1.encode(request));
  return received.timeout(_limit);
}

Future<String> _collect(Socket socket, {bool quiet = false}) {
  final buffer = BytesBuilder();
  final done = Completer<String>();
  Timer? quietTimer;
  void finish() {
    if (done.isCompleted) return;
    done.complete(latin1.decode(buffer.takeBytes()));
    socket.destroy();
  }

  socket.listen(
    (data) {
      buffer.add(data);
      if (quiet) {
        quietTimer?.cancel();
        quietTimer = Timer(const Duration(milliseconds: 100), finish);
      }
    },
    onDone: finish,
    onError: (Object _) => finish(),
  );
  return done.future;
}
