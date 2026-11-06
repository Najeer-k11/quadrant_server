import 'dart:collection';

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
  final Map<String, Queue<int>> _buckets = {};
  int _lastSweepMs = DateTime.now().millisecondsSinceEpoch;

  SlidingWindowLimiter(this.maxRequests, this.windowMs);

  /// Records a request for [key] if it is within the limit.
  RateDecision check(String key) {
    final now = DateTime.now().millisecondsSinceEpoch;

    // Once per window, drop clients that have been idle for a full window so
    // the map does not grow forever with every distinct client.
    if (now - _lastSweepMs > windowMs) {
      _lastSweepMs = now;
      _buckets.removeWhere(
        (_, timestamps) =>
            timestamps.isEmpty || now - timestamps.last > windowMs,
      );
    }

    final timestamps = _buckets.putIfAbsent(key, Queue<int>.new);

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
}
