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
  final String key;
  const RateCheck(this.worker, this.callId, this.limiter, this.maxRequests,
      this.windowMs, this.key);
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

/// A worker isolate's connection to the coordinator.
class ClusterLink {
  final int index;
  final int isolateCount;
  final SendPort _hub;
  final Map<int, Completer<Object>> _calls = {};
  int _nextCallId = 0;

  int Function() requestCount = () => 0;
  Future<void> Function(bool force, Duration? timeout) onShutdown =
      (_, __) async {};
  void Function(String name, Object data)? onGroupData;
  void Function(String name, int? code, String? reason)? onGroupClose;

  ClusterLink(this.index, this.isolateCount, this._hub);

  Future<RateDecision> rateCheck(
    String limiter,
    int maxRequests,
    int windowMs,
    String key,
  ) async {
    final completer = Completer<Object>();
    final callId = _nextCallId++;
    _calls[callId] = completer;
    _hub.send(RateCheck(index, callId, limiter, maxRequests, windowMs, key));
    return await completer.future as RateDecision;
  }

  /// The number of requests handled by all isolates.
  Future<int> totalRequests() async {
    final completer = Completer<Object>();
    final callId = _nextCallId++;
    _calls[callId] = completer;
    _hub.send(CountRequests(index, callId));
    return await completer.future as int;
  }

  void sendToGroup(String name, Object data) =>
      _hub.send(GroupSend(index, name, data));

  void closeGroup(String name, int? code, String? reason) =>
      _hub.send(GroupClose(index, name, code, reason));

  void handle(Object? message) {
    switch (message) {
      case CallReply(:final callId, :final value):
        _calls.remove(callId)?.complete(value);
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
