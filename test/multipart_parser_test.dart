import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:quadrant_server/quadrant_server.dart';
import 'package:quadrant_server/src/middlewares/multipart_parser.dart'
    show MultipartFormatException, MultipartStreamParser;
import 'package:test/test.dart';

const _boundary = 'boundary';

class _ParsedPart {
  final String headers;
  final List<int> data = [];
  _ParsedPart(this.headers);
}

/// Feeds [chunks] to a parser, and returns the parts it found.
Future<List<_ParsedPart>> _parse(Iterable<List<int>> chunks) async {
  final parts = <_ParsedPart>[];
  var open = false;
  final parser = MultipartStreamParser(
    _boundary,
    onPartStart: (headers) {
      expect(open, isFalse, reason: 'the previous part did not end');
      open = true;
      parts.add(_ParsedPart(latin1.decode(headers)));
    },
    onData: (data) async => parts.last.data.addAll(data),
    onPartEnd: () async {
      expect(open, isTrue, reason: 'no part was started');
      open = false;
    },
  );
  for (final chunk in chunks) {
    await parser.add(Uint8List.fromList(chunk));
  }
  parser.close();
  return parts;
}

/// [bytes] with a split at each position in [splits].
List<List<int>> _splitAt(List<int> bytes, List<int> splits) {
  final chunks = <List<int>>[];
  var start = 0;
  for (final split in splits) {
    chunks.add(bytes.sublist(start, split));
    start = split;
  }
  chunks.add(bytes.sublist(start));
  return chunks;
}

List<int> _body(List<String> contents) => latin1.encode([
      for (final content in contents)
        '--$_boundary\r\nX-Part: yes\r\n\r\n$content\r\n',
      '--$_boundary--\r\n',
    ].join());

void main() {
  test('multipartParser refuses a negative diskThreshold', () {
    expect(() => multipartParser(diskThreshold: -1), throwsArgumentError);
  });

  group('MultipartStreamParser', () {
    // Contents that come close to a delimiter without being one.
    const tricky = [
      '',
      'plain',
      '\r',
      '\n',
      '\r\n',
      '\r\n\r\n',
      '-',
      '--',
      '\r\n-',
      '\r\n--',
      '\r\n--boun',
      '\r\n--boundar',
      '\r\n--boun\r\n--boundar\r',
      '--$_boundary', // Not at the start of a line, so it is just data.
      'x--$_boundary--',
      '\n--$_boundary',
    ];

    void expectContents(List<_ParsedPart> parts, List<String> contents) {
      expect(parts.map((p) => latin1.decode(p.data)), contents);
      for (final part in parts) {
        expect(part.headers, 'X-Part: yes');
      }
    }

    test('reads a body that arrives all at once', () async {
      expectContents(await _parse([_body(tricky)]), tricky);
    });

    test('reads a body that arrives one byte at a time', () async {
      final body = _body(tricky);
      final parts = await _parse(body.map((byte) => [byte]));
      expectContents(parts, tricky);
    });

    test('reads a body split in two at every position', () async {
      final body = _body(tricky);
      for (var split = 0; split <= body.length; split++) {
        expectContents(await _parse(_splitAt(body, [split])), tricky);
      }
    });

    test('reads random contents split at random positions', () async {
      final random = Random(42);
      const alphabet = '\r\n-boundary';
      for (var run = 0; run < 300; run++) {
        final contents = [
          for (var part = random.nextInt(4); part >= 0; part--)
            String.fromCharCodes([
              for (var i = random.nextInt(60); i > 0; i--)
                alphabet.codeUnitAt(random.nextInt(alphabet.length)),
            ]),
        ];
        // A line starting with the delimiter is not allowed in a part.
        if (contents.any((c) => '\r\n$c\r\n'.contains('\r\n--$_boundary'))) {
          continue;
        }
        final body = _body(contents);
        final splits = [
          for (var i = random.nextInt(8); i > 0; i--)
            random.nextInt(body.length),
        ]..sort();
        expectContents(await _parse(_splitAt(body, splits)), contents);
      }
    });

    test('handles binary contents', () async {
      final bytes = [for (var i = 0; i < 2048; i++) i % 256];
      final body = [
        ...latin1.encode('--$_boundary\r\nA: b\r\n\r\n'),
        ...bytes,
        ...latin1.encode('\r\n--$_boundary--'),
      ];
      expect((await _parse([body])).single.data, bytes);
    });

    test('ignores a preamble and an epilogue', () async {
      final parts = await _parse([
        latin1.encode('ignored\r\n--$_boundary\r\nA: b\r\n\r\nx\r\n'
            '--$_boundary--\r\nalso ignored\r\n--$_boundary\r\nC: d\r\n\r\n')
      ]);
      expect(parts.single.headers, 'A: b');
    });

    test('accepts spaces after a delimiter', () async {
      final parts = await _parse([
        latin1.encode('--$_boundary \t\r\nA: b\r\n\r\nx\r\n--$_boundary--')
      ]);
      expect(latin1.decode(parts.single.data), 'x');
    });

    test('accepts a part with no headers', () async {
      final parts = await _parse(
          [latin1.encode('--$_boundary\r\n\r\nx\r\n--$_boundary--')]);
      expect(parts.single.headers, '');
      expect(latin1.decode(parts.single.data), 'x');
    });

    test('accepts a body with no parts', () async {
      expect(await _parse([latin1.encode('--$_boundary--')]), isEmpty);
    });

    group('rejects', () {
      final isFormatError = throwsA(isA<MultipartFormatException>());

      final cases = {
        'an empty body': '',
        'a body with no delimiter': 'just some text',
        'a body ending inside headers': '--$_boundary\r\nA: b',
        'a body ending inside a part': '--$_boundary\r\nA: b\r\n\r\ncontents',
        'a body ending at a delimiter': '--$_boundary\r\nA: b\r\n\r\nx\r\n'
            '--$_boundary',
        'a body ending halfway through the end': '--$_boundary\r\n\r\nx\r\n'
            '--$_boundary-',
        'a line that only starts with the delimiter': '--$_boundary\r\n\r\nx'
            '\r\n--${_boundary}extra\r\n--$_boundary--',
      };

      cases.forEach((name, body) {
        test(name, () {
          expect(_parse([latin1.encode(body)]), isFormatError);
        });
      });

      test('headers that never end', () {
        final body = '--$_boundary\r\n${'x' * 20000}';
        expect(_parse([latin1.encode(body)]), isFormatError);
      });

      test('headers that end, but are too big', () {
        final body = '--$_boundary\r\nA: ${'x' * 20000}\r\n\r\n'
            'x\r\n--$_boundary--';
        expect(_parse([latin1.encode(body)]), isFormatError);
      });
    });

    test('holds on to little while a big part goes through', () async {
      // Everything except a possible delimiter must have been passed on.
      var delivered = 0;
      final parser = MultipartStreamParser(
        _boundary,
        onPartStart: (_) {},
        onData: (data) async => delivered += data.length,
        onPartEnd: () async {},
      );
      await parser.add(
          Uint8List.fromList(latin1.encode('--$_boundary\r\nA: b\r\n\r\n')));
      const chunk = 64 * 1024;
      for (var i = 1; i <= 10; i++) {
        await parser.add(Uint8List(chunk));
        expect(i * chunk - delivered, lessThan(_boundary.length + 4));
      }
    });
  });

  group('multipartParser', () {
    late Directory temp;
    late HttpServer server;
    late HttpClient client;

    /// Set by a test, and called by the handler with the parsed request.
    late Future<Response> Function(
        List<UploadedFile> files, Map<String, String> fields) handle;

    Object? handlerError;

    Future<void> serve(Middleware parser) async {
      server = await QuadrantServer(
        onError: (error, req) {
          handlerError = error;
          return Response.internalServerError('failed');
        },
        routes: [
          Route.post(
            path: '/',
            middlewares: [parser],
            handler: (req) => handle(
              req.context['files'] as List<UploadedFile>,
              req.context['fields'] as Map<String, String>,
            ),
          ),
        ],
      ).listen(port: 0, address: InternetAddress.loopbackIPv4);
    }

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('quadrant_multipart_test');
      client = HttpClient();
      handlerError = null;
      handle = (files, fields) async => Response.ok({
            'files': [
              for (final f in files)
                {'name': f.fieldName, 'file': f.filename, 'size': f.size},
            ],
            'fields': fields,
          });
    });

    tearDown(() async {
      client.close(force: true);
      await server.close(force: true);
      await temp.delete(recursive: true);
    });

    String filePart(String name, String contents) => '--b\r\n'
        'Content-Disposition: form-data; name="$name"; filename="$name.txt"\r\n'
        'Content-Type: text/plain\r\n\r\n'
        '$contents\r\n';

    String fieldPart(String name, String value) => '--b\r\n'
        'Content-Disposition: form-data; name="$name"\r\n\r\n'
        '$value\r\n';

    Future<(int, String)> post(String body) async {
      final req = await client.post('127.0.0.1', server.port, '/');
      req.headers.set('content-type', 'multipart/form-data; boundary=b');
      req.write(body);
      final res = await req.close();
      return (res.statusCode, await res.transform(utf8.decoder).join());
    }

    Future<int> statusOf(String body) async => (await post(body)).$1;

    /// Sends [firstPart] of a body declared as huge, and never sends the rest,
    /// so a response can only be one that did not wait for it. Returns what
    /// arrived by the time the server closed the connection.
    Future<String> rawResponse(String firstPart) async {
      final socket =
          await Socket.connect(InternetAddress.loopbackIPv4, server.port);
      addTearDown(socket.destroy);
      socket.write('POST / HTTP/1.1\r\nHost: x\r\n'
          'Content-Type: multipart/form-data; boundary=b\r\n'
          'Content-Length: 1073741824\r\n\r\n$firstPart');
      await socket.flush();
      return latin1
          .decodeStream(socket)
          .timeout(const Duration(seconds: 5), onTimeout: () => 'timed out');
    }

    List<FileSystemEntity> leftovers() => temp.listSync(recursive: true);

    group('in memory, by default', () {
      test('gives files and fields to the handler', () async {
        await serve(multipartParser());
        late UploadedFile file;
        handle = (files, fields) async {
          file = files.single;
          expect(file.isInMemory, isTrue);
          expect(file.path, isNull);
          expect(fields, {'title': 'hello'});
          return Response.text('ok');
        };
        final body =
            '${fieldPart('title', 'hello')}${filePart('a', 'contents')}--b--';
        expect(await statusOf(body), 200);

        expect(file.fieldName, 'a');
        expect(file.filename, 'a.txt');
        expect(file.mimeType, 'text/plain');
        expect(file.size, 8);
        expect(utf8.decode(file.bytes), 'contents');
        expect(utf8.decode(await file.readAsBytes()), 'contents');
        expect(await utf8.decodeStream(file.openRead()), 'contents');
      });

      test('moveTo() writes the file', () async {
        await serve(multipartParser());
        final target = '${temp.path}/saved';
        handle = (files, _) async {
          await files.single.moveTo(target);
          return Response.text('ok');
        };
        expect(await statusOf('${filePart('a', 'contents')}--b--'), 200);
        expect(File(target).readAsStringSync(), 'contents');
      });

      test('writes nothing to disk', () async {
        await serve(multipartParser(tempDirectory: temp));
        handle = (files, _) async {
          expect(leftovers(), isEmpty);
          return Response.text('ok');
        };
        expect(await statusOf('${filePart('a', 'x' * 100000)}--b--'), 200);
      });
    });

    group('with diskThreshold', () {
      Middleware parser({int threshold = 10, int maxFileSize = 1 << 20}) =>
          multipartParser(
            diskThreshold: threshold,
            tempDirectory: temp,
            maxFileSize: maxFileSize,
          );

      test('a small file stays in memory', () async {
        await serve(parser());
        handle = (files, _) async {
          expect(files.single.isInMemory, isTrue);
          expect(leftovers(), isEmpty);
          return Response.text('ok');
        };
        expect(await statusOf('${filePart('a', 'x' * 10)}--b--'), 200);
      });

      test('a bigger file goes to disk, intact, under our own name', () async {
        await serve(parser());
        final contents = List.filled(50000, 'abcdefg').join();
        handle = (files, _) async {
          final file = files.single;
          expect(file.isInMemory, isFalse);
          expect(file.size, contents.length);
          expect(file.path, startsWith(temp.path));
          expect(file.path, isNot(contains('a.txt')));
          expect(() => file.bytes, throwsStateError);
          expect(utf8.decode(await file.readAsBytes()), contents);
          expect(await utf8.decodeStream(file.openRead()), contents);
          return Response.text('ok');
        };
        expect(await statusOf('${filePart('a', contents)}--b--'), 200);
      });

      test('the temporary directory is private', () async {
        await serve(parser());
        handle = (files, _) async {
          final directory = File(files.single.path!).parent;
          expect(directory.statSync().mode & 511, 448); // 0700
          return Response.text('ok');
        };
        expect(await statusOf('${filePart('a', 'x' * 100)}--b--'), 200);
      }, testOn: '!windows');

      test('the temporary directory is private by default too', () async {
        await serve(multipartParser(diskThreshold: 10));
        handle = (files, _) async {
          final directory = File(files.single.path!).parent;
          expect(directory.statSync().mode & 511, 448); // 0700
          return Response.text('ok');
        };
        expect(await statusOf('${filePart('a', 'x' * 100)}--b--'), 200);
      }, testOn: '!windows');

      test('a client filename cannot choose the path', () async {
        await serve(parser());
        handle = (files, _) async {
          expect(files.single.filename, '../../evil');
          expect(files.single.path, isNot(contains('evil')));
          return Response.text('ok');
        };
        final body = '--b\r\nContent-Disposition: form-data; name="a"; '
            'filename="../../evil"\r\n\r\n${'x' * 100}\r\n--b--';
        expect(await statusOf(body), 200);
        expect(leftovers(), isEmpty);
      });

      test('temporary files are gone once the response is ready', () async {
        await serve(parser());
        handle = (files, _) async {
          expect(File(files.first.path!).existsSync(), isTrue);
          return Response.text('ok');
        };
        final body =
            '${filePart('a', 'x' * 100)}${filePart('b', 'y' * 100)}--b--';
        expect(await statusOf(body), 200);
        expect(leftovers(), isEmpty);
      });

      test('temporary files are gone if the handler throws', () async {
        await serve(parser());
        handle = (files, _) async => throw StateError('database is down');
        expect(await statusOf('${filePart('a', 'x' * 100)}--b--'), 500);
        expect(handlerError, isA<StateError>());
        expect(leftovers(), isEmpty);
      });

      test('temporary files are gone if the upload is rejected', () async {
        await serve(parser(maxFileSize: 1000));
        final body = '${filePart('a', 'x' * 500)}${filePart('b', 'y' * 2000)}';
        expect(await statusOf(body), 413);
        expect(leftovers(), isEmpty);
      });

      test('temporary files are gone if the body is cut off', () async {
        await serve(parser());
        expect(await statusOf(filePart('a', 'x' * 100)), 400);
        expect(leftovers(), isEmpty);
      });

      test('temporary files are gone if the client disconnects', () async {
        await serve(parser());
        final socket =
            await Socket.connect(InternetAddress.loopbackIPv4, server.port);
        addTearDown(socket.destroy);
        socket.write('POST / HTTP/1.1\r\nHost: x\r\n'
            'Content-Type: multipart/form-data; boundary=b\r\n'
            'Content-Length: 100000\r\n\r\n'
            '${filePart('a', 'x' * 1000)}');
        await socket.flush();

        final stopwatch = Stopwatch()..start();
        while (leftovers().isEmpty) {
          if (stopwatch.elapsed.inSeconds > 5) fail('Nothing was written.');
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }

        socket.destroy();
        while (leftovers().isNotEmpty) {
          if (stopwatch.elapsed.inSeconds > 10) fail('Files were left behind.');
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      });

      test('moveTo() keeps the file past the response', () async {
        await serve(parser());
        final target = '${temp.path}/saved';
        late UploadedFile file;
        handle = (files, _) async {
          file = files.single;
          await file.moveTo(target);
          expect(file.path, target);
          return Response.text('ok');
        };
        final contents = 'x' * 100;
        expect(await statusOf('${filePart('a', contents)}--b--'), 200);
        expect(File(target).readAsStringSync(), contents);
        expect(leftovers().map((e) => e.path), [target]);
        expect(await utf8.decodeStream(file.openRead()), contents);
      });

      test('an unusable directory is a server error, not a 400', () async {
        await serve(multipartParser(
          diskThreshold: 10,
          tempDirectory: Directory('${temp.path}/does/not/exist'),
        ));
        expect(await statusOf('${filePart('a', 'x' * 100)}--b--'), 500);
        expect(handlerError, isA<FileSystemException>());
      });

    });

    group('limits', () {
      test('maxFileSize rejects before the body has finished arriving',
          () async {
        await serve(multipartParser(maxFileSize: 1000, maxTotalBytes: 0));
        final response = await rawResponse(filePart('a', 'x' * 2000));
        expect(response, startsWith('HTTP/1.1 413'));
        expect(response, contains('"maxFileBytes":1000'));
      });

      test('maxTotalBytes rejects a declared size up front', () async {
        await serve(multipartParser(maxTotalBytes: 100));
        expect(await rawResponse(''), startsWith('HTTP/1.1 413'));
      });

      test('maxParts counts files and fields', () async {
        await serve(multipartParser(maxParts: 2));
        final two = '${fieldPart('a', '1')}${filePart('b', '2')}';
        expect(await statusOf('$two--b--'), 200);

        final (status, body) = await post('$two${fieldPart('c', '3')}--b--');
        expect(status, 413);
        expect(body, contains('"maxParts":2'));
      });

      test('maxFieldBytes covers all the fields of a request', () async {
        await serve(multipartParser(maxFieldBytes: 10));
        final five = fieldPart('a', 'x' * 5);
        expect(await statusOf('$five${fieldPart('b', 'y' * 5)}--b--'), 200);

        final (status, body) =
            await post('$five${fieldPart('b', 'y' * 6)}--b--');
        expect(status, 413);
        expect(body, contains('"maxFieldBytes":10'));
      });

      test('maxParts and maxFieldBytes of 0 turn them off', () async {
        await serve(multipartParser(maxParts: 0, maxFieldBytes: 0));
        final parts = [for (var i = 0; i < 2000; i++) fieldPart('f$i', 'x')];
        expect(await statusOf('${parts.join()}--b--'), 200);
      });
    });

    group('maxBufferedBytes', () {
      test('answers 503 when memory is used up, and gives it back', () async {
        await serve(multipartParser(maxBufferedBytes: 100));
        final tooMuch =
            '${filePart('a', 'x' * 60)}${filePart('b', 'y' * 60)}--b--';
        final req = await client.post('127.0.0.1', server.port, '/');
        req.headers.set('content-type', 'multipart/form-data; boundary=b');
        req.write(tooMuch);
        final res = await req.close();
        expect(res.statusCode, 503);
        expect(res.headers.value('retry-after'), isNotNull);
        await res.drain<void>();

        // Would not fit if the 60 bytes above were still counted.
        expect(await statusOf('${filePart('a', 'x' * 90)}--b--'), 200);
      });

      test('is shared by requests in progress', () async {
        await serve(multipartParser(maxBufferedBytes: 100));
        final firstInHandler = Completer<void>();
        final finishFirst = Completer<void>();
        handle = (files, _) async {
          if (!firstInHandler.isCompleted) {
            firstInHandler.complete();
            await finishFirst.future;
          }
          return Response.text('ok');
        };

        final first = statusOf('${filePart('a', 'x' * 60)}--b--');
        await firstInHandler.future;
        expect(await statusOf('${filePart('b', 'y' * 60)}--b--'), 503);

        finishFirst.complete();
        expect(await first, 200);
        expect(await statusOf('${filePart('c', 'z' * 60)}--b--'), 200);
      });

      test('sends files to disk instead, with diskThreshold', () async {
        await serve(multipartParser(
          maxBufferedBytes: 10,
          diskThreshold: 1000,
          tempDirectory: temp,
        ));
        handle = (files, _) async {
          expect(files.single.isInMemory, isFalse);
          return Response.text('ok');
        };
        expect(await statusOf('${filePart('a', 'x' * 100)}--b--'), 200);
      });

      test('still limits fields with diskThreshold', () async {
        await serve(multipartParser(
          maxBufferedBytes: 10,
          diskThreshold: 1000,
          tempDirectory: temp,
        ));
        expect(await statusOf('${fieldPart('a', 'x' * 100)}--b--'), 503);
      });

      test('0 turns it off', () async {
        await serve(multipartParser(maxBufferedBytes: 0));
        expect(await statusOf('${filePart('a', 'x' * 100000)}--b--'), 200);
      });
    });

    test('name is not confused with filename, in either order', () async {
      await serve(multipartParser());
      handle = (files, _) async => Response.text(files.single.fieldName);
      final body = '--b\r\nContent-Disposition: form-data; '
          'filename="a.txt"; name="real"\r\n\r\nx\r\n--b--';
      expect(await post(body), (200, 'real'));
    });

    test('an empty boundary is refused', () async {
      await serve(multipartParser());
      final req = await client.post('127.0.0.1', server.port, '/');
      req.headers.set('content-type', 'multipart/form-data; boundary=');
      req.write('x');
      final res = await req.close();
      expect(res.statusCode, 400);
      await res.drain<void>();
    });
  });
}

