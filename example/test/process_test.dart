@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// Runs the real program, as systemd or Docker would, to cover what the other
/// tests cannot: exit codes, signals and the cluster starting up.
void main() {
  late Directory data;
  final binary = '${Directory.systemTemp.path}/quadrant_example_${pid}_server';

  setUpAll(() async {
    final result = await Process.run(
        Platform.resolvedExecutable, ['compile', 'exe', 'lib/main.dart', '-o', binary]);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  });
  tearDownAll(() => File(binary).delete());

  setUp(() async {
    data = await Directory.systemTemp.createTemp('quadrant_example_process');
  });
  tearDown(() => data.delete(recursive: true));

  Future<int> freePort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  Map<String, String> env(int port, [Map<String, String> extra = const {}]) => {
        'PORT': '$port',
        'DATA_DIR': data.path,
        ...extra,
      };

  /// Starts the server, and waits until it says it is listening.
  Future<Process> start(Map<String, String> environment) async {
    final process = await Process.start(binary, const [],
        environment: environment, includeParentEnvironment: false);
    addTearDown(() => process.kill(ProcessSignal.sigkill));
    process.stderr.listen(stderr.add);
    final ready = Completer<void>();
    process.stdout.transform(utf8.decoder).listen((text) {
      if (text.contains('Listening on') && !ready.isCompleted) ready.complete();
    });
    await ready.future.timeout(const Duration(seconds: 20));
    return process;
  }

  test('production refuses to start without tokens, with exit code 78', () async {
    final result = await Process.run(binary, const [],
        environment: env(await freePort(), {'APP_ENV': 'production'}),
        includeParentEnvironment: false);
    expect(result.exitCode, 78);
    expect(result.stderr, contains('ADMIN_TOKEN'));
  });

  test('--healthcheck reports whether the server is up', () async {
    final port = await freePort();
    final environment = env(port);

    Future<int> check() async => (await Process.run(binary, ['--healthcheck'],
            environment: environment, includeParentEnvironment: false))
        .exitCode;

    expect(await check(), 1);
    await start(environment);
    expect(await check(), 0);
  });

  test('SIGTERM finishes cleanly with several isolates', () async {
    final port = await freePort();
    final process = await start(env(port, {'ISOLATES': '3'}));

    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.get('127.0.0.1', port, '/health');
    final response = await request.close();
    final health = jsonDecode(await response.transform(utf8.decoder).join());
    expect(health['isolates'], 3);

    process.kill(ProcessSignal.sigterm);
    expect(await process.exitCode.timeout(const Duration(seconds: 25)), 0);
  }, testOn: '!windows');

  test('chat reaches clients on other isolates', () async {
    final port = await freePort();
    await start(env(port, {'ISOLATES': '4'}));
    final url = 'ws://127.0.0.1:$port/ws/chat/general';

    // New connections spread across isolates, so with enough of them some
    // are on different ones, and all must hear the sender.
    final listeners = <Future<Object?>>[];
    final sockets = <WebSocket>[];
    for (var i = 0; i < 12; i++) {
      final socket = await WebSocket.connect(url);
      sockets.add(socket);
      addTearDown(socket.close);
      listeners.add(socket
          .map((data) => jsonDecode(data as String) as Map)
          .firstWhere((event) => event['data'] == 'hello everyone')
          .timeout(const Duration(seconds: 10)));
    }

    final sender = await WebSocket.connect(url);
    addTearDown(sender.close);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    sender.add('hello everyone');
    await Future.wait(listeners);
  });
}
