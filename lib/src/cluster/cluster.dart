import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'cluster_link.dart';
import '../core/quadrant_app.dart';
import '../utils/sliding_window.dart';

/// Runs one server per isolate on the same port, so requests use more than
/// one CPU core.
///
/// Each isolate calls [start]'s `build` to create its own [QuadrantServer].
/// The main isolate only coordinates, and stays free for your own code.
///
/// ```dart
/// final cluster = await QuadrantCluster.start(
///   isolates: Platform.numberOfProcessors,
///   port: 3000,
///   build: () => QuadrantServer(
///     middlewares: [logger(), rateLimit(maxRequests: 100, window: Duration(minutes: 1))],
///     routes: [Route.get(path: '/users', handler: getUsers)],
///   ),
/// );
///
/// await cluster.close();
/// ```
///
/// ### What is shared between isolates
///
/// Isolates do not share memory, so a variable in your code exists once per
/// isolate. These built-in features are coordinated for you:
///
/// - `rateLimit()` keeps one count across all isolates. Each rate-limited
///   request makes one round trip to the main isolate. `build` must create the
///   same limiters in the same order every time.
/// - `WebSocketGroup(name: ...)` broadcasts reach members on every isolate.
///   Using a group without a name throws, unless it is `WebSocketGroup.local()`.
/// - The health check reports the total requests of all isolates.
///
/// Anything else you keep in memory, such as a cache or session map, is
/// separate per isolate. Keep it in a database or external store instead.
///
/// ### Requirements
///
/// `build` is sent to every isolate, so it must not capture anything that
/// cannot be sent, such as an open socket or database connection. Open those
/// inside `build`.
///
/// ### When an isolate dies
///
/// It is replaced with a new one from `build`, after a delay that doubles with
/// each consecutive failure, up to 30 seconds. After `maxRestarts` failures in
/// a row it is given up on, and the others keep serving. See [start].
///
/// New connections go to the isolates that are alive. Sockets the dead isolate
/// had stay open until the Dart VM next collects garbage, which can take a
/// while on a quiet server, so its clients may wait until their own timeout.
/// Its share of the health check's request total starts again from 0.
/// `rateLimit()` counts are kept.
///
/// Restarting does not cover everything. A crash of the Dart VM ends the whole
/// process, so still run it under systemd, Docker or similar. An isolate stuck
/// in an endless loop has not died, so it is not replaced.
class QuadrantCluster {
  final ReceivePort _hub = ReceivePort();
  final Map<int, SendPort> _workers = {};
  final Set<int> _running = {};
  final Map<int, Completer<int>> _starting = {};
  final Map<String, SlidingWindowLimiter> _limiters = {};
  final Map<int, _RequestGather> _gathers = {};
  final Map<int, _RestartHistory> _history = {};
  final Map<int, Timer> _restartTimers = {};
  int _nextGatherId = 0;
  bool _started = false;
  ShutdownWorker? _shutdown;
  Completer<void>? _allExited;
  Future<void>? _closing;

  final int _maxRestarts;
  final Duration _restartDelay;
  final void Function(int index, {required bool willRestart})? _onIsolateExit;
  final _WorkerConfig Function(int index, int bindPort) _configFor;

  /// The port every isolate is listening on.
  late final int port;

  /// The number of isolates this cluster was started with.
  final int isolates;

  QuadrantCluster._(
    this.isolates,
    this._maxRestarts,
    this._restartDelay,
    this._onIsolateExit,
    this._configFor,
  ) {
    _hub.listen(_onMessage);
  }

  /// The number of isolates listening right now. Lower than [isolates] while
  /// one is being restarted, or after one has been given up on.
  int get runningIsolates => _workers.length;

  /// This isolate's position in its cluster, from 0, or null outside a cluster.
  static int? get isolateIndex => currentClusterLink?.index;

  /// Starts [isolates] servers on [port] and waits until all are listening.
  ///
  /// Pass [certificateChain] and [privateKey] to serve HTTPS. Throws if any
  /// isolate fails to start, for example if `build` throws or the port is in
  /// use, after stopping the others.
  ///
  /// An isolate that dies later is restarted. [maxRestarts] is how many times
  /// in a row that may fail before it is given up on, and `0` turns restarting
  /// off. The count starts again once an isolate has run for a minute.
  /// [restartDelay] is the wait before the first restart; it doubles each time,
  /// up to 30 seconds. With the defaults, a failing isolate is retried for
  /// about 3 minutes.
  ///
  /// [onIsolateExit] is called on this isolate each time one dies, except
  /// during [close]. With `willRestart` false the isolate has been given up on,
  /// which is a good moment to call `exit(1)` if something supervises your
  /// process. Declare it outside the expression that creates `build`: closures
  /// from one scope share their variables, and `build` must not carry anything
  /// that cannot be sent to an isolate.
  static Future<QuadrantCluster> start({
    required int isolates,
    required int port,
    required QuadrantServer Function() build,
    Object address = '0.0.0.0',
    File? certificateChain,
    File? privateKey,
    String? password,
    int maxRestarts = 10,
    Duration restartDelay = const Duration(seconds: 1),
    void Function(int index, {required bool willRestart})? onIsolateExit,
  }) async {
    if (isolates < 1) {
      throw ArgumentError.value(isolates, 'isolates', 'Must be at least 1.');
    }
    if (maxRestarts < 0) {
      throw ArgumentError.value(
          maxRestarts, 'maxRestarts', 'Must not be negative.');
    }
    if (restartDelay.isNegative) {
      throw ArgumentError.value(
          restartDelay, 'restartDelay', 'Must not be negative.');
    }
    if ((certificateChain == null) != (privateKey == null)) {
      throw ArgumentError('certificateChain and privateKey go together.');
    }

    final cluster = QuadrantCluster._(
      isolates,
      maxRestarts,
      restartDelay,
      onIsolateExit,
      (index, bindPort) => _WorkerConfig(
        index: index,
        isolates: isolates,
        build: build,
        port: bindPort,
        address: address,
        certificateChain: certificateChain?.path,
        privateKey: privateKey?.path,
        password: password,
      ),
    );

    try {
      // The first isolate settles the port, in case `port` is 0.
      final boundPort = await cluster._startWorker(0, port);
      cluster.port = boundPort;
      await Future.wait([
        for (var i = 1; i < isolates; i++) cluster._startWorker(i, boundPort),
      ]);
      if (cluster._running.length < isolates) {
        throw StateError('An isolate exited during start.');
      }
      cluster._started = true;
    } catch (_) {
      await cluster.close(force: true);
      rethrow;
    }
    return cluster;
  }

  /// Shuts down every isolate, as [QuadrantServer.close] does for one server.
  ///
  /// Safe to call more than once.
  Future<void> close({bool force = false, Duration? timeout}) {
    return _closing ??= _close(force, timeout);
  }

  Future<void> _close(bool force, Duration? timeout) async {
    final shutdown = _shutdown = ShutdownWorker(force, timeout);
    for (final timer in _restartTimers.values) {
      timer.cancel();
    }
    _restartTimers.clear();

    if (_running.isNotEmpty) {
      final exited = _allExited = Completer<void>();
      // One that has not reported in yet is told as soon as it does.
      for (final worker in _workers.values) {
        worker.send(shutdown);
      }
      await exited.future;
    }
    _hub.close();
  }

  // ─── Starting and restarting ─────────────────────────────────

  /// Starts an isolate during [start], completing once it is listening.
  Future<int> _startWorker(int index, int bindPort) async {
    final started = _starting[index] = Completer<int>();
    await _spawn(index, bindPort);
    return started.future;
  }

  Future<void> _spawn(int index, int bindPort) async {
    // Counted from now on, so that [close] waits for it.
    _running.add(index);
    try {
      final isolate = await Isolate.spawn(
        _workerMain,
        _WorkerStart(_configFor(index, bindPort), _hub.sendPort),
        debugName: 'quadrant-$index',
        // Matches a single-isolate server: a stray error is reported, but the
        // other requests in that isolate keep being served.
        errorsAreFatal: false,
        onError: _hub.sendPort,
        // Paused until the exit listener is attached, so no exit is missed.
        paused: true,
      );
      isolate.addOnExitListener(
        _hub.sendPort,
        response: '$_exitPrefix$index',
      );
      isolate.resume(isolate.pauseCapability!);
    } catch (_) {
      _running.remove(index);
      _finishCloseIfDone();
      rethrow;
    }
  }

  /// Decides what happens to a dead isolate, once the cluster has started.
  void _onWorkerDied(int index) {
    final history = _history[index] ??= _RestartHistory();
    final upFor = history.uptime?.elapsed;
    history.uptime = null;
    if (upFor != null && upFor >= _stableAfter) history.failures = 0;

    final willRestart = history.failures < _maxRestarts;
    // ignore: avoid_print
    print('[QuadrantCluster] Isolate $index exited; '
        '${willRestart ? 'restarting it' : 'it is not restarted'}.');
    try {
      _onIsolateExit?.call(index, willRestart: willRestart);
    } catch (error, stack) {
      // ignore: avoid_print
      print('[QuadrantCluster] onIsolateExit threw: $error\n$stack');
    }
    // The callback may well have closed the cluster.
    if (!willRestart || _shutdown != null) return;

    final delay = _restartDelayAfter(history.failures);
    history.failures++;
    _restartTimers[index] = Timer(delay, () {
      _restartTimers.remove(index);
      unawaited(_restart(index));
    });
  }

  Duration _restartDelayAfter(int failures) {
    final doubled = _restartDelay.inMicroseconds * (1 << min(failures, 20));
    final longest = max(_restartDelay.inMicroseconds, _longestRestartDelayUs);
    return Duration(microseconds: min(doubled, longest));
  }

  Future<void> _restart(int index) async {
    try {
      await _spawn(index, port);
    } catch (error) {
      // ignore: avoid_print
      print('[QuadrantCluster] Could not restart isolate $index: $error');
      if (_shutdown == null) _onWorkerDied(index);
    }
  }

  void _finishCloseIfDone() {
    final allExited = _allExited;
    if (allExited != null && _running.isEmpty && !allExited.isCompleted) {
      allExited.complete();
    }
  }

  // ─── Coordinator ─────────────────────────────────────────────

  void _onMessage(Object? message) {
    switch (message) {
      case RateCheck():
        final limiter = _limiters.putIfAbsent(
          // Includes the settings, so a `build` that creates its limiters in a
          // different order cannot make two different limits share a count.
          '${message.limiter}:${message.maxRequests}:${message.windowMs}'
          ':${message.maxKeys}',
          () => SlidingWindowLimiter(
            message.maxRequests,
            message.windowMs,
            message.maxKeys,
          ),
        );
        _workers[message.worker]
            ?.send(CallReply(message.callId, limiter.check(message.key)));
      case GroupSend(:final worker, :final name, :final data):
        _toOthers(worker, GroupDeliver(name, data));
      case GroupClose(:final worker, :final name, :final code, :final reason):
        _toOthers(worker, GroupCloseDeliver(name, code, reason));
      case CountRequests(:final worker, :final callId):
        _gatherRequests(worker, callId);
      case RequestCountReply(:final gatherId, :final count):
        _gathers[gatherId]?.add(count);
      case WorkerStarted(:final worker, :final inbox, :final port):
        _workers[worker] = inbox;
        (_history[worker] ??= _RestartHistory()).uptime = Stopwatch()..start();
        _starting.remove(worker)?.complete(port);
        final shutdown = _shutdown;
        if (shutdown != null) inbox.send(shutdown);
      case WorkerFailed(:final worker, :final error):
        final starting = _starting.remove(worker);
        if (starting != null) {
          starting.completeError(StateError('Isolate $worker failed: $error'));
        } else {
          // A restart. Its exit comes next, and decides about trying again.
          // ignore: avoid_print
          print('[QuadrantCluster] Isolate $worker failed to restart: $error');
        }
      case String() when message.startsWith(_exitPrefix):
        _onWorkerExit(int.parse(message.substring(_exitPrefix.length)));
      case [final Object? error, final Object? stack]:
        // ignore: avoid_print
        print('[QuadrantCluster] Uncaught error: $error\n$stack');
    }
  }

  void _toOthers(int source, Object message) {
    _workers.forEach((index, worker) {
      if (index != source) worker.send(message);
    });
  }

  void _gatherRequests(int worker, int callId) {
    final gatherId = _nextGatherId++;
    // Held on to, because by the time the total is ready a restarted isolate
    // may have this index, and this reply must not reach it.
    final requester = _workers[worker];
    _gathers[gatherId] = _RequestGather(_workers.length, (total) {
      _gathers.remove(gatherId);
      requester?.send(CallReply(callId, total));
    });
    for (final inbox in _workers.values) {
      inbox.send(RequestCountQuery(gatherId));
    }
  }

  void _onWorkerExit(int index) {
    _running.remove(index);
    _workers.remove(index);

    _starting
        .remove(index)
        ?.completeError(StateError('Isolate $index exited during start.'));

    // A gather still waiting on this isolate would otherwise only end on its
    // timeout; the reply it was waiting for will never come.
    for (final gather in _gathers.values.toList()) {
      gather.workerGone();
    }

    _finishCloseIfDone();
    // Before that point, a failure is for start() to report.
    if (_started && _shutdown == null) _onWorkerDied(index);
  }
}

const _exitPrefix = 'quadrant-exit:';

/// How long an isolate must run before its earlier failures are forgotten.
const _stableAfter = Duration(minutes: 1);

const _longestRestartDelayUs = 30 * Duration.microsecondsPerSecond;

class _RestartHistory {
  /// How many restarts in a row have not lasted.
  int failures = 0;

  /// Running since the isolate started listening; null while it is not.
  Stopwatch? uptime;
}

/// Adds up one request count per isolate. Gives up after a short wait, so an
/// isolate stuck in a long computation cannot hang the health check.
class _RequestGather {
  final void Function(int total) _onDone;
  late final Timer _timer;
  int _waitingFor;
  int _total = 0;
  bool _done = false;

  _RequestGather(this._waitingFor, this._onDone) {
    _timer = Timer(const Duration(milliseconds: 500), _finish);
  }

  void add(int count) {
    _total += count;
    if (--_waitingFor <= 0) _finish();
  }

  void workerGone() {
    if (--_waitingFor <= 0) _finish();
  }

  void _finish() {
    if (_done) return;
    _done = true;
    _timer.cancel();
    _onDone(_total);
  }
}

// ─── Worker ──────────────────────────────────────────────────

class _WorkerConfig {
  final int index;
  final int isolates;
  final QuadrantServer Function() build;
  final int port;
  final Object address;
  final String? certificateChain;
  final String? privateKey;
  final String? password;

  const _WorkerConfig({
    required this.index,
    required this.isolates,
    required this.build,
    required this.port,
    required this.address,
    required this.certificateChain,
    required this.privateKey,
    required this.password,
  });
}

class _WorkerStart {
  final _WorkerConfig config;
  final SendPort hub;
  const _WorkerStart(this.config, this.hub);
}

Future<void> _workerMain(_WorkerStart start) async {
  final _WorkerStart(:config, :hub) = start;
  final inbox = ReceivePort();
  final link = ClusterLink(config.index, config.isolates, hub);
  currentClusterLink = link; // Before build(), which may depend on it.

  try {
    final app = config.build();
    link
      ..requestCount = (() => app.requestCount)
      ..onShutdown = (force, timeout) async {
        await app.close(force: force, timeout: timeout);
        Isolate.exit();
      };
    inbox.listen(link.handle);

    final certificateChain = config.certificateChain;
    final server = certificateChain == null
        ? await app.listen(
            port: config.port,
            address: config.address,
            shared: true,
          )
        : await app.listenSecure(
            port: config.port,
            address: config.address,
            certificateChain: File(certificateChain),
            privateKey: File(config.privateKey!),
            password: config.password,
            shared: true,
          );
    hub.send(WorkerStarted(config.index, inbox.sendPort, server.port));
  } catch (error, stack) {
    hub.send(WorkerFailed(config.index, '$error\n$stack'));
    Isolate.exit();
  }
}
