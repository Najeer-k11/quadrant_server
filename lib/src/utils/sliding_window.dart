import 'dart:collection';
import 'dart:math';

/// The outcome of one [SlidingWindowLimiter.check].
class RateDecision {
  final bool allowed;
  final int remaining;
  final int resetAtMs;
  final int retryAfterSeconds;

  const RateDecision({
    required this.allowed,
    required this.remaining,
    required this.resetAtMs,
    this.retryAfterSeconds = 0,
  });
}

/// Counts requests per key over a sliding window, by keeping their timestamps.
///
/// Runs inside `rateLimit()` on a single isolate, and on the main isolate when
/// running in a `QuadrantCluster`, so every isolate shares one count.
class SlidingWindowLimiter {
  final int maxRequests;
  final int windowMs;

  /// The most clients tracked at once.
  final int maxKeys;

  // In insertion order, which is what makes the oldest clients easy to find.
  final Map<String, Queue<int>> _buckets = {};
  int _lastSweepMs = DateTime.now().millisecondsSinceEpoch;

  SlidingWindowLimiter(this.maxRequests, this.windowMs, this.maxKeys);

  /// Records a request for [key] if it is within the limit.
  RateDecision check(String key) {
    final now = DateTime.now().millisecondsSinceEpoch;

    // Once per window, drop clients that have been idle for a full window so
    // the map does not grow forever with every distinct client.
    if (now - _lastSweepMs > windowMs) _sweep(now);

    var bucket = _buckets[key];
    if (bucket == null) {
      if (_buckets.length >= maxKeys) _makeRoom(now);
      bucket = _buckets[key] = Queue<int>();
    }
    final timestamps = bucket;

    // Timestamps are in order, so only the expired ones at the front are
    // touched. The cost does not grow with the size of the limit.
    while (timestamps.isNotEmpty && now - timestamps.first > windowMs) {
      timestamps.removeFirst();
    }

    if (timestamps.length >= maxRequests) {
      final resetAt = timestamps.first + windowMs;
      return RateDecision(
        allowed: false,
        remaining: 0,
        resetAtMs: resetAt,
        retryAfterSeconds: ((resetAt - now) / 1000).ceil(),
      );
    }

    timestamps.add(now);
    return RateDecision(
      allowed: true,
      remaining: maxRequests - timestamps.length,
      resetAtMs: timestamps.first + windowMs,
    );
  }

  void _sweep(int now) {
    _lastSweepMs = now;
    _buckets.removeWhere(
      (_, timestamps) => timestamps.isEmpty || now - timestamps.last > windowMs,
    );
  }

  /// Frees a tenth of [maxKeys], preferring idle clients to the oldest ones.
  ///
  /// Freeing many at once keeps a flood of new keys cheap: this walks the map,
  /// but then does not run again for the next tenth of [maxKeys] new clients.
  void _makeRoom(int now) {
    _sweep(now);
    final target = maxKeys - max<int>(1, maxKeys ~/ 10);
    final excess = _buckets.length - target;
    if (excess <= 0) return;
    _buckets.keys.take(excess).toList().forEach(_buckets.remove);
  }
}
