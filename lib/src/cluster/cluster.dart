import 'dart:async';
import 'dart:io';
import 'dart:isolate';

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
/// inside `build`. An isolate that dies is not restarted.
class QuadrantCluster {
  final ReceivePort _hub = ReceivePort();
  final Map<int, SendPort> _workers = {};
  final Set<int> _running = {};
  final Map<int, Completer<int>> _starting = {};
  final Map<String, SlidingWindowLimiter> _limiters = {};
  final Map<int, _RequestGather> _gathers = {};
  int _nextGatherId = 0;
  Completer<void>? _allExited;
  Future<void>? _closing;

  /// The port every isolate is listening on.
  late final int port;

  /// The number of isolates this cluster was started with.
  final int isolates;

  QuadrantCluster._(this.isolates) {
    _hub.listen(_onMessage);
  }

  /// This isolate's position in its cluster, from 0, or null outside a cluster.
  static int? get isolateIndex => currentClusterLink?.index;

  /// Starts [isolates] servers on [port] and waits until all are listening.
  ///
  /// Pass [certificateChain] and [privateKey] to serve HTTPS. Throws if any
  /// isolate fails to start, for example if `build` throws or the port is in
  /// use, after stopping the others.
  static Future<QuadrantCluster> start({
    required int isolates,
    required int port,
    required QuadrantServer Function() build,
    Object address = '0.0.0.0',
    File? certificateChain,
    File? privateKey,
    String? password,
  }) async {
    if (isolates < 1) {
      throw ArgumentError.value(isolates, 'isolates', 'Must be at least 1.');
    }
    if ((certificateChain == null) != (privateKey == null)) {
      throw ArgumentError('certificateChain and privateKey go together.');
    }

    final cluster = QuadrantCluster._(isolates);

    Future<int> spawn(int index, int bindPort) async {
      final started = cluster._starting[index] = Completer<int>();
      final isolate = await Isolate.spawn(
        _workerMain,
        _WorkerConfig(
          index: index,
          isolates: isolates,
          hub: cluster._hub.sendPort,
          build: build,
          port: bindPort,
          address: address,
          certificateChain: certificateChain?.path,
          privateKey: privateKey?.path,
          password: password,
        ),
        debugName: 'quadrant-$index',
        // Matches a single-isolate server: a stray error is reported, but the
        // other requests in that isolate keep being served.
        errorsAreFatal: false,
        onError: cluster._hub.sendPort,
        // Paused until the exit listener is attached, so no exit is missed.
        paused: true,
      );
      cluster._running.add(index);
      isolate.addOnExitListener(
        cluster._hub.sendPort,
        response: '$_exitPrefix$index',
      );
      isolate.resume(isolate.pauseCapability!);
      return started.future;
    }

    try {
      // The first isolate settles the port, in case `port` is 0.
      final boundPort = await spawn(0, port);
      cluster.port = boundPort;
      await Future.wait([
        for (var i = 1; i < isolates; i++) spawn(i, boundPort),
      ]);
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
    if (_running.isNotEmpty) {
      final exited = _allExited = Completer<void>();
      for (final worker in _workers.values) {
        worker.send(ShutdownWorker(force, timeout));
      }
      await exited.future;
    }
    _hub.close();
  }

  // ─── Coordinator ─────────────────────────────────────────────

  void _onMessage(Object? message) {
    switch (message) {
      case RateCheck():
        final limiter = _limiters.putIfAbsent(
          // Includes the settings, so a `build` that creates its limiters in a
          // different order cannot make two different limits share a count.
          '${message.limiter}:${message.maxRequests}:${message.windowMs}',
          () => SlidingWindowLimiter(message.maxRequests, message.windowMs),
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
        _starting[worker]?.complete(port);
      case WorkerFailed(:final worker, :final error):
        _starting[worker]
            ?.completeError(StateError('Isolate $worker failed: $error'));
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
    _gathers[gatherId] = _RequestGather(_workers.length, (total) {
      _gathers.remove(gatherId);
      _workers[worker]?.send(CallReply(callId, total));
    });
    for (final inbox in _workers.values) {
      inbox.send(RequestCountQuery(gatherId));
    }
  }

  void _onWorkerExit(int index) {
    _running.remove(index);
    _workers.remove(index);

    final starting = _starting[index];
    if (starting != null && !starting.isCompleted) {
      starting.completeError(StateError('Isolate $index exited during start.'));
    }

    final allExited = _allExited;
    if (allExited == null) {
      // ignore: avoid_print
      print('[QuadrantCluster] Isolate $index exited; it is not restarted.');
    } else if (_running.isEmpty && !allExited.isCompleted) {
      allExited.complete();
    }

    // A gather still waiting on this isolate would otherwise only end on its
    // timeout; the reply it was waiting for will never come.
    for (final gather in _gathers.values.toList()) {
      gather.workerGone();
    }
  }
}

const _exitPrefix = 'quadrant-exit:';

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
  final SendPort hub;
  final QuadrantServer Function() build;
  final int port;
  final Object address;
  final String? certificateChain;
  final String? privateKey;
  final String? password;

  const _WorkerConfig({
    required this.index,
    required this.isolates,
    required this.hub,
    required this.build,
    required this.port,
    required this.address,
    required this.certificateChain,
    required this.privateKey,
    required this.password,
  });
}

Future<void> _workerMain(_WorkerConfig config) async {
  final inbox = ReceivePort();
  final link = ClusterLink(config.index, config.isolates, config.hub);
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
    config.hub.send(WorkerStarted(config.index, inbox.sendPort, server.port));
  } catch (error, stack) {
    config.hub.send(WorkerFailed(config.index, '$error\n$stack'));
    Isolate.exit();
  }
}
