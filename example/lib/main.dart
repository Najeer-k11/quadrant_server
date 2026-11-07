// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:io';

import 'package:quadrant_server/quadrant_server.dart';

import 'app.dart';
import 'config.dart';

/// `sysexits.h` EX_CONFIG. The systemd unit does not restart on this exit
/// code, because a wrong setting will not fix itself.
const _exitConfigError = 78;

/// Longer than this and in-flight requests are cut off. Keep it below
/// `TimeoutStopSec` in the systemd unit and `stop_grace_period` in Compose.
const _drainTimeout = Duration(seconds: 20);

Future<void> main(List<String> args) async {
  final env = Platform.environment;

  if (args.contains('--healthcheck')) {
    exit(await _healthCheck(Config.portFrom(env)));
  }

  final Config config;
  try {
    config = Config.fromEnvironment(env);
  } on ConfigException catch (error) {
    stderr.writeln('Configuration error: $error');
    exit(_exitConfigError);
  }

  await prepareDataDirectories(config);

  final cluster = await QuadrantCluster.start(
    isolates: config.isolates,
    port: config.port,
    address: config.address,
    build: _builderFor(config),
    onIsolateExit: _onIsolateExit,
  );

  _closeOnSignal(cluster);
  _printSummary(config, cluster);
}

// `build` is sent to every isolate, along with all the variables of the scope
// that created it. It has a function of its own so that it cannot carry
// something like the cluster, which would make every start fail.
QuadrantServer Function() _builderFor(Config config) =>
    () => buildServer(config);

void _onIsolateExit(int index, {required bool willRestart}) {
  if (willRestart) return;
  // It keeps failing, so let the process supervisor start everything afresh.
  stderr.writeln('Isolate $index keeps failing. Exiting.');
  exit(1);
}

/// Finishes in-flight requests on `systemctl stop`, `docker stop` or Ctrl+C.
/// A second signal stops at once.
void _closeOnSignal(QuadrantCluster cluster) {
  var closing = false;

  Future<void> onSignal(ProcessSignal signal) async {
    if (closing) exit(1);
    closing = true;
    print('$signal received, shutting down.');
    await cluster.close(timeout: _drainTimeout);
    exit(0);
  }

  ProcessSignal.sigint.watch().listen(onSignal);
  if (!Platform.isWindows) ProcessSignal.sigterm.watch().listen(onSignal);
}

/// Used as the Docker health check, as the image has no curl. Returns the exit
/// code: 0 if the server answers.
Future<int> _healthCheck(int port) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final request = await client.get('127.0.0.1', port, '/health');
    final response =
        await request.close().timeout(const Duration(seconds: 3));
    await response.drain<void>();
    return response.statusCode == 200 ? 0 : 1;
  } catch (error) {
    stderr.writeln('Health check failed: $error');
    return 1;
  } finally {
    client.close(force: true);
  }
}

void _printSummary(Config config, QuadrantCluster cluster) {
  print('Listening on ${config.address}:${cluster.port} '
      'with ${config.isolates} isolate(s), '
      '${config.production ? 'production' : 'development'} mode.');
  print('Data directory: ${config.dataDir}');
  if (config.production) return;
  print('');
  print('Docs:      http://localhost:${cluster.port}/quadrant_docs');
  print('Demo tokens, which production refuses:');
  Config.demoTokens.forEach((token, role) => print('  $token ($role)'));
}
