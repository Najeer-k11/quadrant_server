import 'dart:collection';

import '../middleware.dart';
import '../request.dart';
import '../response.dart';

/// Rate-limiting middleware using a sliding-window (request log) algorithm.
///
/// Limits the number of requests a single client IP can make within a given
/// [window]. Clients that exceed [maxRequests] receive a `429 Too Many
/// Requests` response with a `Retry-After` header.
///
/// Standard `X-RateLimit-*` headers are added to every response so clients
/// can track their quota without hitting the limit.
///
/// ```dart
/// // Allow 100 requests per minute per IP:
/// rateLimit(maxRequests: 100, window: Duration(minutes: 1))
///
/// // Stricter limit on a sensitive route:
/// Route.post(
///   path: '/auth/login',
///   handler: loginHandler,
///   middlewares: [rateLimit(maxRequests: 5, window: Duration(minutes: 15))],
/// )
/// ```
///
/// [keyExtractor] — optional function to customise the rate-limit key.
/// Defaults to the client's remote IP address. Override to key on, e.g.,
/// an API key header instead of IP.
Middleware rateLimit({
  required int maxRequests,
  required Duration window,
  String Function(Request req)? keyExtractor,
}) {
  final buckets = <String, _Bucket>{};
  final windowMs = window.inMilliseconds;
  var lastSweepMs = DateTime.now().millisecondsSinceEpoch;

  String defaultKey(Request req) {
    return req.raw.connectionInfo?.remoteAddress.address ?? 'unknown';
  }

  final getKey = keyExtractor ?? defaultKey;

  return (Request req, Next next) async {
    final key = getKey(req);
    final now = DateTime.now().millisecondsSinceEpoch;

    // Once per window, drop clients that have been idle for a full window so
    // the map does not grow forever with every distinct client.
    if (now - lastSweepMs > windowMs) {
      lastSweepMs = now;
      buckets.removeWhere(
        (_, b) => b.timestamps.isEmpty || now - b.timestamps.last > windowMs,
      );
    }

    // Lazy-create / fetch the bucket for this key.
    final bucket = buckets.putIfAbsent(key, () => _Bucket(maxRequests));

    // Remove timestamps outside the current window.
    bucket.timestamps.removeWhere((ts) => now - ts > windowMs);

    final remaining = maxRequests - bucket.timestamps.length;

    if (remaining <= 0) {
      // Compute when the oldest request will expire.
      final oldestTs = bucket.timestamps.first;
      final resetAt = oldestTs + windowMs;
      final retryAfterSeconds = ((resetAt - now) / 1000).ceil();

      return Response(
        statusCode: 429,
        headers: {
          'content-type': 'application/json',
          'x-ratelimit-limit': '$maxRequests',
          'x-ratelimit-remaining': '0',
          'x-ratelimit-reset': '${(resetAt / 1000).ceil()}',
          'retry-after': '$retryAfterSeconds',
        },
        body: '{"error":"Too Many Requests","retryAfter":$retryAfterSeconds}',
      );
    }

    // Record this request.
    bucket.timestamps.add(now);

    final response = await next();

    // Recalculate remaining after recording this request.
    final resetAt = bucket.timestamps.isNotEmpty
        ? bucket.timestamps.first + windowMs
        : now + windowMs;

    return response.copyWith(
      headers: {
        ...response.headers,
        'x-ratelimit-limit': '$maxRequests',
        'x-ratelimit-remaining': '${maxRequests - bucket.timestamps.length}',
        'x-ratelimit-reset': '${(resetAt / 1000).ceil()}',
      },
    );
  };
}

/// Internal bucket storing a sliding window of request timestamps per key.
class _Bucket {
  final int maxRequests;
  // Use a Queue for O(1) front-removal when sliding the window.
  final Queue<int> timestamps = Queue();

  _Bucket(this.maxRequests);
}
