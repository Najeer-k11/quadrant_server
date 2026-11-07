import 'dart:async';
import 'dart:convert';
import 'dart:io';

// Relative, so that `dart analyze` in the repository root can resolve it too.
// ignore_for_file: avoid_relative_lib_imports
import '../lib/app.dart';
import '../lib/config.dart';
import 'package:test/test.dart';

const _admin = 'secret-admin-token';
const _user = 'secret-user-token';

void main() {
  group('Config', () {
    final goodTokens = {
      'APP_ENV': 'production',
      'ADMIN_TOKEN': 'a' * 32,
      'USER_TOKEN': 'b' * 32,
    };

    Matcher refused(String text) => throwsA(isA<ConfigException>()
        .having((e) => e.message, 'message', contains(text)));

    test('development has safe, usable defaults', () {
      final config = Config.fromEnvironment(const {});
      expect(config.production, isFalse);
      expect(config.port, 5050);
      expect(config.address, '127.0.0.1');
      expect(config.isolates, 1);
      expect(config.tokens, Config.demoTokens);
    });

    test('production accepts generated tokens, and no demo ones', () {
      final config = Config.fromEnvironment(goodTokens);
      expect(config.production, isTrue);
      expect(config.corsOrigin, isNull);
      expect(config.tokens, {'a' * 32: 'admin', 'b' * 32: 'user'});
      for (final demo in Config.demoTokens.keys) {
        expect(config.tokens.containsKey(demo), isFalse);
      }
    });

    test('production refuses missing, short, or matching tokens', () {
      expect(() => Config.fromEnvironment(const {'APP_ENV': 'production'}),
          refused('ADMIN_TOKEN'));
      expect(() => Config.fromEnvironment({...goodTokens, 'USER_TOKEN': 'x'}),
          refused('USER_TOKEN'));
      expect(
          () => Config.fromEnvironment(
              {...goodTokens, 'USER_TOKEN': goodTokens['ADMIN_TOKEN']!}),
          refused('must differ'));
    });

    test('refuses numbers that make no sense', () {
      expect(() => Config.fromEnvironment(const {'PORT': 'abc'}),
          refused('PORT'));
      expect(() => Config.fromEnvironment(const {'ISOLATES': '0'}),
          refused('ISOLATES'));
    });
  });

  group('server', () {
    late Directory data;
    late Config config;
    late HttpServer server;
    late HttpClient client;

    Future<HttpServer> start(Config config) async {
      await prepareDataDirectories(config);
      return buildServer(config).listen(
        port: 0,
        address: InternetAddress.loopbackIPv4,
      );
    }

    Config configWith({bool production = false, int hops = 0}) => Config(
          production: production,
          port: 0,
          address: '127.0.0.1',
          isolates: 1,
          dataDir: data.path,
          trustedProxyHops: hops,
          corsOrigin: null,
          tokens: Config.demoTokens,
        );

    setUp(() async {
      data = await Directory.systemTemp.createTemp('quadrant_example_test');
      config = configWith();
      server = await start(config);
      client = HttpClient();
    });

    tearDown(() async {
      client.close(force: true);
      await server.close(force: true);
      await data.delete(recursive: true);
    });

    Future<(int, String)> send(
      String method,
      String path, {
      String? token,
      Object? json,
    }) async {
      final req = await client.open(method, '127.0.0.1', server.port, path);
      if (token != null) req.headers.set('authorization', 'Bearer $token');
      if (json != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(json));
      }
      final res = await req.close();
      return (res.statusCode, await res.transform(utf8.decoder).join());
    }

    Future<int> statusOf(String method, String path,
            {String? token, Object? json}) async =>
        (await send(method, path, token: token, json: json)).$1;

    test('the built-in health check answers', () async {
      final (status, body) = await send('GET', '/health');
      expect(status, 200);
      expect(jsonDecode(body), containsPair('status', 'ok'));
    });

    group('users', () {
      test('paging survives limits that make no sense', () async {
        for (final query in ['limit=0', 'limit=-5', 'page=-1', 'limit=99999']) {
          final (status, body) = await send('GET', '/api/v1/users?$query');
          expect(status, 200, reason: query);
          expect(jsonDecode(body)['data'], isA<List<dynamic>>());
        }
      });

      test('writing needs a token, and deleting needs an admin', () async {
        const body = {'name': 'Linus'};
        expect(await statusOf('POST', '/api/v1/users', json: body), 401);
        expect(await statusOf('POST', '/api/v1/users', token: 'wrong', json: body),
            401);
        expect(await statusOf('DELETE', '/api/v1/users/2', token: _user), 403);
        expect(await statusOf('DELETE', '/api/v1/users/2', token: _admin), 204);
        expect(await statusOf('GET', '/api/v1/users/2'), 404);
      });

      test('a token is not accepted for being a prefix of a real one', () async {
        expect(
            await statusOf('DELETE', '/api/v1/users/1',
                token: _admin.substring(0, 10)),
            401);
      });

      test('bad bodies get a 422, not a 500', () async {
        for (final body in [
          <String, Object>{},
          {'name': ''},
          {'name': 42},
          {'name': {'nested': true}},
          {'name': '   '},
          {'name': 'ok', 'role': 7},
          {'name': 'ok', 'role': 'root'},
        ]) {
          expect(
              await statusOf('POST', '/api/v1/users', token: _user, json: body),
              422,
              reason: '$body');
        }
      });

      test('clients cannot set fields that were not declared', () async {
        final (status, created) = await send('POST', '/api/v1/users',
            token: _user, json: {'name': 'Eve', 'id': '999', 'isOwner': true});
        expect(status, 201);
        final user = jsonDecode(created) as Map<String, dynamic>;
        expect(user['id'], isNot('999'));
        expect(user.containsKey('isOwner'), isFalse);

        final path = '/api/v1/users/${user['id']}';
        final (_, patched) = await send('PATCH', path,
            token: _user, json: {'name': 'Eve 2', 'id': '999', 'admin': true});
        expect(jsonDecode(patched), {
          'id': user['id'],
          'name': 'Eve 2',
          'role': 'user',
        });
      });

      test('PUT needs every field, and PATCH keeps the others', () async {
        final (_, created) = await send('POST', '/api/v1/users',
            token: _admin, json: {'name': 'Grace', 'role': 'admin'});
        final path = '/api/v1/users/${jsonDecode(created)['id']}';

        expect(await statusOf('PUT', path, token: _user, json: {'name': 'G'}),
            422);
        final (_, patched) =
            await send('PATCH', path, token: _user, json: {'name': 'G'});
        expect(jsonDecode(patched)['role'], 'admin');
      });
    });

    group('files', () {
      Future<(int, String)> upload(int size, {String? token}) async {
        final req =
            await client.post('127.0.0.1', server.port, '/api/v1/files');
        if (token != null) req.headers.set('authorization', 'Bearer $token');
        req.headers.set('content-type', 'multipart/form-data; boundary=b');
        req.write('--b\r\nContent-Disposition: form-data; name="f"; '
            'filename="../../evil.html"\r\n\r\n');
        req.write('x' * size);
        req.write('\r\n--b--\r\n');
        final res = await req.close();
        return (res.statusCode, await res.transform(utf8.decoder).join());
      }

      test('need a token', () async {
        expect((await upload(10)).$1, 401);
        expect(await statusOf('GET', '/api/v1/files/any.bin'), 401);
      });

      test('a big upload is kept under our own name, and downloads', () async {
        const size = 3 * 1024 * 1024; // Over the threshold, so via disk.
        final (status, body) = await upload(size, token: _user);
        expect(status, 201);

        final saved = (jsonDecode(body)['files'] as List).single as Map;
        expect(saved['size'], size);
        expect(saved['originalName'], '../../evil.html');
        expect(saved['url'], matches(r'^/api/v1/files/[0-9a-f]{32}\.bin$'));

        // Nothing escaped, and the temporary file is gone.
        expect(File('${data.parent.path}/evil.html').existsSync(), isFalse);
        expect(Directory(config.tempDir).listSync(), isEmpty);
        expect(Directory(config.uploadsDir).listSync(), hasLength(1));

        final req = await client.get(
            '127.0.0.1', server.port, saved['url'] as String);
        req.headers.set('authorization', 'Bearer $_user');
        final res = await req.close();
        expect(res.statusCode, 200);
        expect(res.headers.contentType?.mimeType, 'application/octet-stream');
        expect(res.headers.value('x-content-type-options'), 'nosniff');
        expect(await res.fold<int>(0, (n, chunk) => n + chunk.length), size);
      });

      test('a download cannot leave the uploads directory', () async {
        File('${data.path}/secret.txt').writeAsStringSync('secret');
        final (status, body) = await send(
            'GET', '/api/v1/files/..%2Fsecret.txt', token: _user);
        expect(status, isNot(200));
        expect(body, isNot(contains('secret')));
      });

      test('an upload with no files is refused', () async {
        final req =
            await client.post('127.0.0.1', server.port, '/api/v1/files');
        req.headers.set('authorization', 'Bearer $_user');
        req.headers.set('content-type', 'multipart/form-data; boundary=b');
        req.write('--b--\r\n');
        final res = await req.close();
        await res.drain<void>();
        expect(res.statusCode, 400);
      });
    });

    test('prepareDataDirectories clears only old temporary uploads', () async {
      final stale = Directory('${config.tempDir}/quadrant_upload_old')
        ..createSync(recursive: true);
      File('${stale.path}/0').writeAsStringSync('left behind');
      final kept = File('${config.uploadsDir}/keep.bin')
        ..writeAsStringSync('saved');

      await prepareDataDirectories(config);
      expect(stale.existsSync(), isFalse);
      expect(kept.existsSync(), isTrue);
    });

    test('a data directory named like a temporary upload is safe', () async {
      final odd = Directory('${data.path}/quadrant_upload_data');
      final oddConfig = Config(
        production: false,
        port: 0,
        address: '127.0.0.1',
        isolates: 1,
        dataDir: odd.path,
        trustedProxyHops: 0,
        corsOrigin: null,
        tokens: Config.demoTokens,
      );
      await prepareDataDirectories(oddConfig);
      final kept = File('${oddConfig.tempDir}/not-an-upload')
        ..writeAsStringSync('keep');
      await prepareDataDirectories(oddConfig);
      expect(kept.existsSync(), isTrue);
    });

    group('docs and HSTS', () {
      test('development has docs and no HSTS', () async {
        final req =
            await client.get('127.0.0.1', server.port, '/quadrant_docs');
        final res = await req.close();
        await res.drain<void>();
        expect(res.statusCode, 200);
        expect(res.headers.value('strict-transport-security'), isNull);
      });

      test('production has HSTS and no docs, even for local clients', () async {
        await server.close(force: true);
        server = await start(configWith(production: true));
        final req =
            await client.get('127.0.0.1', server.port, '/quadrant_docs');
        final res = await req.close();
        await res.drain<void>();
        expect(res.statusCode, 404);
        expect(res.headers.value('strict-transport-security'), isNotNull);
      });
    });

    test('behind a proxy, clients get separate rate limits', () async {
      await server.close(force: true);
      server = await start(configWith(hops: 1));

      Future<String?> remaining(String forwardedFor) async {
        final req = await client.get('127.0.0.1', server.port, '/api/v1/info');
        req.headers.set('x-forwarded-for', forwardedFor);
        final res = await req.close();
        await res.drain<void>();
        return res.headers.value('x-ratelimit-remaining');
      }

      expect(await remaining('203.0.113.1'), '299');
      expect(await remaining('203.0.113.1'), '298');
      expect(await remaining('203.0.113.2'), '299');
      // A forged entry on the left does not get a client a fresh count.
      expect(await remaining('1.2.3.4, 203.0.113.1'), '297');
    });

    group('chat', () {
      Future<(WebSocket, StreamIterator<Map<String, dynamic>>)> join(
          String room) async {
        final socket =
            await WebSocket.connect('ws://127.0.0.1:${server.port}/ws/chat/$room');
        addTearDown(socket.close);
        final events = StreamIterator(socket.map(
            (data) => jsonDecode(data as String) as Map<String, dynamic>));
        return (socket, events);
      }

      Future<Map<String, dynamic>> next(
          StreamIterator<Map<String, dynamic>> events) async {
        expect(await events.moveNext().timeout(const Duration(seconds: 5)),
            isTrue);
        return events.current;
      }

      test('messages reach the room, and only the room', () async {
        final (alice, aliceEvents) = await join('general');
        expect((await next(aliceEvents))['event'], 'welcome');

        final (_, bobEvents) = await join('general');
        expect((await next(bobEvents))['event'], 'welcome');
        expect((await next(aliceEvents))['event'], 'user_joined');

        final (other, otherEvents) = await join('other');
        expect((await next(otherEvents))['event'], 'welcome');

        alice.add(jsonEncode({'name': 'Alice'}));
        expect((await next(aliceEvents))['event'], 'name_set');
        expect((await next(bobEvents))['event'], 'user_renamed');

        alice.add('hello');
        final message = await next(bobEvents);
        expect(message['from'], 'Alice');
        expect(message['data'], 'hello');

        // The other room heard none of that: its next event is its own error.
        other.add([1, 2, 3]);
        expect((await next(otherEvents))['event'], 'error');
      });

      test('oversized and binary messages are refused', () async {
        final (socket, events) = await join('limits');
        await next(events);

        socket.add('x' * 5000);
        expect((await next(events))['event'], 'error');
        socket.add([1, 2, 3]);
        expect((await next(events))['event'], 'error');
        socket.add(jsonEncode({'name': 'n' * 33}));
        expect((await next(events))['event'], 'error');
      });

      test('a bad room ID never becomes a connection', () async {
        await expectLater(
          WebSocket.connect(
              'ws://127.0.0.1:${server.port}/ws/chat/${'x' * 65}'),
          throwsA(isA<WebSocketException>()),
        );
      });
    });
  });
}
