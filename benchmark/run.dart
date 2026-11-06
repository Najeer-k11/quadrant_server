// Builds the benchmark programs and runs every configuration.
//
//   dart run benchmark/run.dart [--quick] [--label=baseline] [--only=q_plain,q_json]
//
// Writes benchmark/results/<label>.json and .md. Linux only: uses taskset and /proc.
//
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';

const _serverCpus = '0-7'; // Four P-cores with their hyperthreads.
const _loaderCpus = '8-15'; // Two P-cores and four E-cores.
const _loaderProcesses = 8;
const _buildDir = '.dart_tool/benchmark';

class Config {
  final String scenario;
  final int isolates;
  final int connections;
  final String method;
  final String path;
  final int bodyBytes;

  const Config(
    this.scenario, {
    this.isolates = 1,
    this.connections = 64,
    this.method = 'GET',
    this.path = '/',
    this.bodyBytes = 0,
  });

  String get id => '$scenario/i$isolates/c$connections';
}

const _configs = [
  // Layers: bare C++, Dart sockets, dart:io HTTP, then the framework.
  Config('cpp_epoll'),
  Config('dart_socket'),
  Config('dartio_plain'),
  Config('q_plain'),
  // What each framework feature costs.
  Config('q_json'),
  Config('q_param1', path: '/r99/123'),
  Config('q_param100', path: '/r99/123'),
  Config('q_noop5'),
  Config('q_requestid'),
  Config('q_stack'),
  Config('q_post_json', method: 'POST', bodyBytes: 1024),
  // Open connections.
  Config('q_plain', connections: 16),
  Config('q_plain', connections: 256),
  Config('q_plain', connections: 1024),
  // Realistic handlers: waiting versus computing.
  Config('q_io10ms', connections: 256),
  Config('q_cpu1ms'),
  // Scaling across isolates or threads.
  Config('cpp_epoll', isolates: 2),
  Config('cpp_epoll', isolates: 4),
  Config('dart_socket', isolates: 2),
  Config('dart_socket', isolates: 4),
  Config('dartio_plain', isolates: 2),
  Config('dartio_plain', isolates: 4),
  Config('dartio_plain', isolates: 8),
  Config('dartio_cpu'),
  Config('dartio_cpu', isolates: 2),
  Config('dartio_cpu', isolates: 4),
  Config('dartio_cpu', isolates: 8),
  // QuadrantCluster, plus the cost of a limit shared between isolates.
  Config('q_ratelimit'),
  Config('qc_plain'),
  Config('qc_plain', isolates: 2),
  Config('qc_plain', isolates: 4),
  Config('qc_plain', isolates: 8),
  Config('qc_stack', isolates: 8),
  Config('qc_cpu1ms', isolates: 2),
  Config('qc_cpu1ms', isolates: 4),
  Config('qc_cpu1ms', isolates: 8),
  Config('qc_ratelimit'),
  Config('qc_ratelimit', isolates: 4),
  Config('qc_ratelimit', isolates: 8),
];

Future<void> main(List<String> args) async {
  final quick = args.contains('--quick');
  final label = _option(args, 'label') ?? (quick ? 'quick' : 'baseline');
  final only = _option(args, 'only')?.split(',').toSet();
  final reps = quick ? 1 : 3;
  final warmupMs = quick ? 500 : 2000;
  final durationMs = quick ? 1000 : 6000;

  await _build();

  final configs =
      _configs.where((c) => only == null || only.contains(c.scenario)).toList();
  final runs = <String, List<Map<String, Object>>>{};
  var port = 19000;

  // Whole passes rather than repeating each config in place, so that slow
  // drift such as the laptop warming up affects every config equally.
  for (var rep = 1; rep <= reps; rep++) {
    for (final config in configs) {
      final result = await _runOnce(config, port++, warmupMs, durationMs);
      runs.putIfAbsent(config.id, () => []).add(result);
      print('[$rep/$reps] ${config.id}: ${result['rps']} req/s, '
          'errors ${result['errors']}, non-2xx ${result['non2xx']}');
    }
  }

  final rows = [for (final c in configs) _summarize(c, runs[c.id]!)];
  final dir = Directory('benchmark/results')..createSync(recursive: true);
  File('${dir.path}/$label.json').writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert({
      'label': label,
      'date': DateTime.now().toIso8601String(),
      'dart': Platform.version,
      'reps': reps,
      'warmupMs': warmupMs,
      'durationMs': durationMs,
      'results': rows,
    }),
  );
  final table = _markdown(rows);
  File('${dir.path}/$label.md').writeAsStringSync(table);
  print('\n$table');
}

String? _option(List<String> args, String name) {
  for (final arg in args) {
    if (arg.startsWith('--$name=')) return arg.substring(name.length + 3);
  }
  return null;
}

Future<void> _build() async {
  Directory(_buildDir).createSync(recursive: true);
  for (final name in ['server', 'loader']) {
    await _check('dart', [
      'compile',
      'exe',
      'benchmark/$name.dart',
      '-o',
      '$_buildDir/$name',
    ]);
  }
  await _check('g++', [
    '-O2',
    '-std=c++17',
    '-pthread',
    'benchmark/epoll_server.cpp',
    '-o',
    '$_buildDir/epoll_server',
  ]);
}

Future<void> _check(String command, List<String> args) async {
  final result = await Process.run(command, args);
  if (result.exitCode != 0) {
    throw StateError('$command failed:\n${result.stdout}\n${result.stderr}');
  }
}

Future<Map<String, Object>> _runOnce(
    Config config, int port, int warmupMs, int durationMs) async {
  final serverArgs = config.scenario == 'cpp_epoll'
      ? ['$_buildDir/epoll_server', '$port', '${config.isolates}']
      : ['$_buildDir/server', config.scenario, '$port', '${config.isolates}'];
  final server =
      await Process.start('taskset', ['-c', _serverCpus, ...serverArgs]);

  final ready = Completer<void>();
  server.stdout.transform(utf8.decoder).listen((text) {
    if (text.contains('READY') && !ready.isCompleted) ready.complete();
  });
  final serverErrors = StringBuffer();
  server.stderr.transform(utf8.decoder).listen(serverErrors.write);
  await ready.future.timeout(const Duration(seconds: 15));

  final loaders = <Future<ProcessResult>>[
    for (var i = 0; i < _loaderProcesses; i++)
      Process.run('taskset', [
        '-c',
        _loaderCpus,
        '$_buildDir/loader',
        '$port',
        '${_share(config.connections, i)}',
        '$warmupMs',
        '$durationMs',
        config.method,
        config.path,
        '${config.bodyBytes}',
      ]),
  ];

  await Future<void>.delayed(Duration(milliseconds: warmupMs));
  final cpuStart = _processCpuSeconds(server.pid);
  await Future<void>.delayed(Duration(milliseconds: durationMs));
  final serverCpu = _processCpuSeconds(server.pid) - cpuStart;
  final rssMb = _peakRssMb(server.pid);

  final outputs = await Future.wait(loaders);
  final crashed = !server.kill(ProcessSignal.sigkill);
  await server.exitCode;
  if (crashed) print('SERVER CRASHED on ${config.id}:\n$serverErrors');

  var completed = 0, errors = 0, non2xx = 0;
  var loaderCpu = 0.0;
  final histogram = <int, int>{};
  for (final output in outputs) {
    if (output.exitCode != 0) {
      throw StateError('Loader failed on ${config.id}: ${output.stderr}');
    }
    if ((output.stderr as String).isNotEmpty) {
      print('Loader sample on ${config.id}:\n${output.stderr}');
    }
    final data = jsonDecode(output.stdout as String) as Map<String, dynamic>;
    completed += data['completed'] as int;
    errors += data['errors'] as int;
    non2xx += data['non2xx'] as int;
    loaderCpu += (data['cpuSeconds'] as num).toDouble();
    (data['latency'] as Map<String, dynamic>).forEach((us, count) {
      histogram.update(int.parse(us), (v) => v + (count as int),
          ifAbsent: () => count as int);
    });
  }

  final seconds = durationMs / 1000;
  return {
    'rps': (completed / seconds).round(),
    'p50Us': _percentile(histogram, completed, 0.50),
    'p99Us': _percentile(histogram, completed, 0.99),
    'errors': errors,
    'non2xx': non2xx,
    'crashed': crashed,
    // Independent of whether the loader could saturate the server.
    'rpsPerCore': serverCpu > 0 ? (completed / serverCpu).round() : 0,
    'serverCpuPct': (serverCpu / seconds * 100).round(),
    // Percent of the loader's whole CPU budget (8 logical CPUs).
    'loaderCpuPct': (loaderCpu / seconds / 8 * 100).round(),
    'rssMb': rssMb,
  };
}

/// Splits [total] connections across loader processes as evenly as possible.
int _share(int total, int index) =>
    total ~/ _loaderProcesses + (index < total % _loaderProcesses ? 1 : 0);

double _processCpuSeconds(int pid) {
  final stat = File('/proc/$pid/stat').readAsStringSync();
  final fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
  return (int.parse(fields[11]) + int.parse(fields[12])) / 100;
}

int _peakRssMb(int pid) {
  final status = File('/proc/$pid/status').readAsStringSync();
  final match = RegExp(r'VmHWM:\s+(\d+) kB').firstMatch(status)!;
  return (int.parse(match.group(1)!) / 1024).round();
}

int _percentile(Map<int, int> histogram, int total, double fraction) {
  final target = (total * fraction).ceil();
  var seen = 0;
  for (final us in histogram.keys.toList()..sort()) {
    seen += histogram[us]!;
    if (seen >= target) return us;
  }
  return 0;
}

/// Reports the run with the median throughput, plus the spread across runs.
Map<String, Object> _summarize(Config config, List<Map<String, Object>> runs) {
  final sorted = [...runs]
    ..sort((a, b) => (a['rps'] as int).compareTo(b['rps'] as int));
  final median = sorted[sorted.length ~/ 2];
  final low = sorted.first['rps'] as int;
  final high = sorted.last['rps'] as int;
  return {
    'id': config.id,
    'scenario': config.scenario,
    'isolates': config.isolates,
    'connections': config.connections,
    ...median,
    'minRps': low,
    'maxRps': high,
    'spreadPct': median['rps'] == 0
        ? 0
        : ((high - low) / (median['rps'] as int) * 100).round(),
    'errorsTotal':
        runs.fold<int>(0, (sum, r) => sum + (r['errors'] as int)),
    'non2xxTotal':
        runs.fold<int>(0, (sum, r) => sum + (r['non2xx'] as int)),
    'crashes': runs.where((r) => r['crashed'] == true).length,
  };
}

String _markdown(List<Map<String, Object>> rows) {
  final out = StringBuffer()
    ..writeln('| Scenario | Isolates | Conns | req/s | Spread | req/s per core | '
        'p50 ms | p99 ms | Errors | Crashes | Server CPU | Loader CPU | '
        'Peak RSS |')
    ..writeln('|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|');
  for (final r in rows) {
    final errors = (r['errorsTotal'] as int) + (r['non2xxTotal'] as int);
    out.writeln('| ${r['scenario']} | ${r['isolates']} | ${r['connections']} '
        '| ${r['rps']} | ${r['spreadPct']}% | ${r['rpsPerCore']} '
        '| ${_ms(r['p50Us'] as int)} | ${_ms(r['p99Us'] as int)} '
        '| $errors | ${r['crashes']} | ${r['serverCpuPct']}% | ${r['loaderCpuPct']}% '
        '| ${r['rssMb']} MB |');
  }
  return out.toString();
}

String _ms(int us) => (us / 1000).toStringAsFixed(2);
