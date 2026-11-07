import 'dart:async';
import 'dart:isolate';

import '../utils/sliding_window.dart';

// Messages between worker isolates and the coordinator in the main isolate.
// Not part of the public API.

// ─── Worker → coordinator ────────────────────────────────────

class WorkerStarted {
  final int worker;
  final SendPort inbox;
  final int port;
  const WorkerStarted(this.worker, this.inbox, this.port);
}

class WorkerFailed {
  final int worker;
  final String error;
  const WorkerFailed(this.worker, this.error);
}

class RateCheck {
  final int worker;
  final int callId;
  final String limiter;
  final int maxRequests;
  final int windowMs;
  final int maxKeys;
  final String key;
  const RateCheck(this.worker, this.callId, this.limiter, this.maxRequests,
      this.windowMs, this.maxKeys, this.key);
}

class CountRequests {
  final int worker;
  final int callId;
  const CountRequests(this.worker, this.callId);
}

class RequestCountReply {
  final int gatherId;
  final int count;
  const RequestCountReply(this.gatherId, this.count);
}

class GroupSend {
  final int worker;
  final String name;
  final Object data;
  const GroupSend(this.worker, this.name, this.data);
}

class GroupClose {
  final int worker;
  final String name;
  final int? code;
  final String? reason;
  const GroupClose(this.worker, this.name, this.code, this.reason);
}

// ─── Coordinator → worker ────────────────────────────────────

class CallReply {
  final int callId;
  final Object value;
  const CallReply(this.callId, this.value);
}

class RequestCountQuery {
  final int gatherId;
  const RequestCountQuery(this.gatherId);
}

class GroupDeliver {
  final String name;
  final Object data;
  const GroupDeliver(this.name, this.data);
}

class GroupCloseDeliver {
  final String name;
  final int? code;
  final String? reason;
  const GroupCloseDeliver(this.name, this.code, this.reason);
}

class ShutdownWorker {
  final bool force;
  final Duration? timeout;
  const ShutdownWorker(this.force, this.timeout);
}

// ─── Worker side ─────────────────────────────────────────────

/// This isolate's connection to the coordinator, or null outside a cluster.
ClusterLink? currentClusterLink;

/// How long a request waits for a rate-limit answer from the main isolate.
/// A round trip normally takes well under a millisecond.
const _rateCheckTimeoutMs = 250;

/// How long a health check waits for the total. Longer than the coordinator's
/// own wait for the other isolates, which it needs to give a useful answer.
const _totalRequestsTimeoutMs = 1000;

/// How often unanswered calls are checked for having timed out.
const _expiryInterval = Duration(milliseconds: 50);

class _PendingCall {
  final Completer<Object?> completer = Completer<Object?>();
  final int deadlineMs;
  _PendingCall(this.deadlineMs);
}

/// A worker isolate's connection to the coordinator.
class ClusterLink {
  final int index;
  final int isolateCount;
  final SendPort _hub;
  final Map<int, _PendingCall> _calls = {};
  final Stopwatch _clock = Stopwatch()..start();
  Timer? _expiryTimer;
  bool _warnedUnresponsive = false;
  int _nextCallId = 0;

  int Function() requestCount = () => 0;
  Future<void> Function(bool force, Duration? timeout) onShutdown =
      (_, __) async {};
  void Function(String name, Object data)? onGroupData;
  void Function(String name, int? code, String? reason)? onGroupClose;

  ClusterLink(this.index, this.isolateCount, this._hub);

  /// Asks the coordinator for a decision. Returns null if it does not answer
  /// in time, so that a blocked main isolate cannot hang requests.
  Future<RateDecision?> rateCheck(
    String limiter,
    int maxRequests,
    int windowMs,
    int maxKeys,
    String key,
  ) async {
    final reply = await _call(
      _rateCheckTimeoutMs,
      (callId) => RateCheck(
          index, callId, limiter, maxRequests, windowMs, maxKeys, key),
    );
    return reply as RateDecision?;
  }

  /// The number of requests handled by all isolates, or null if the
  /// coordinator does not answer in time.
  Future<int?> totalRequests() async {
    final reply = await _call(
      _totalRequestsTimeoutMs,
      (callId) => CountRequests(index, callId),
    );
    return reply as int?;
  }

  /// Sends the message from [build], and completes with its reply or with null
  /// after [timeoutMs].
  Future<Object?> _call(int timeoutMs, Object Function(int callId) build) {
    final callId = _nextCallId++;
    final call = _PendingCall(_clock.elapsedMilliseconds + timeoutMs);
    _calls[callId] = call;
    _hub.send(build(callId));
    // One shared timer: a timer per request would add a system call to each.
    _expiryTimer ??= Timer.periodic(_expiryInterval, _expireCalls);
    return call.completer.future;
  }

  void _expireCalls(Timer timer) {
    if (_calls.isEmpty) {
      timer.cancel();
      _expiryTimer = null;
      return;
    }
    final now = _clock.elapsedMilliseconds;
    _calls.removeWhere((_, call) {
      if (now < call.deadlineMs) return false;
      call.completer.complete(null);
      _warnUnresponsive();
      return true;
    });
  }

  void _warnUnresponsive() {
    if (_warnedUnresponsive) return;
    _warnedUnresponsive = true;
    // ignore: avoid_print
    print('[QuadrantCluster] Isolate $index: the main isolate is not '
        'answering, so rateLimit() is counting per isolate until it does. '
        'Keep long-running work off the main isolate.');
  }

  void sendToGroup(String name, Object data) =>
      _hub.send(GroupSend(index, name, data));

  void closeGroup(String name, int? code, String? reason) =>
      _hub.send(GroupClose(index, name, code, reason));

  void handle(Object? message) {
    switch (message) {
      case CallReply(:final callId, :final value):
        _warnedUnresponsive = false;
        // A call that already timed out is gone, so a late reply does nothing.
        _calls.remove(callId)?.completer.complete(value);
      case RequestCountQuery(:final gatherId):
        _hub.send(RequestCountReply(gatherId, requestCount()));
      case GroupDeliver(:final name, :final data):
        onGroupData?.call(name, data);
      case GroupCloseDeliver(:final name, :final code, :final reason):
        onGroupClose?.call(name, code, reason);
      case ShutdownWorker(:final force, :final timeout):
        unawaited(onShutdown(force, timeout));
    }
  }
}
