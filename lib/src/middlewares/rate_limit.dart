import '../utils/client_ip.dart';
import '../cluster/cluster_link.dart';
import '../core/middleware.dart';
import '../core/request.dart';
import '../core/response.dart';
import '../utils/sliding_window.dart';

// Limiters are matched up across isolates by creation order.
var _nextLimiterId = 0;

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
///
/// [trustedProxyHops] — the number of proxies in front of this server. Behind
/// a proxy, every request appears to come from the proxy's IP, so all clients
/// would share one limit. With this set, the client IP is read from
/// `X-Forwarded-For`, counting that many entries from the right: entries your
/// own proxies appended, which a client cannot forge. Leave it at `0` (the
/// default) when not behind a proxy, or clients can pick their own key.
///
/// By default, IPv6 clients are grouped by /64, because one client usually
/// controls that whole range and could otherwise use a new address per request.
///
/// [maxKeys] — the most clients tracked at once, so that a flood of new keys
/// cannot use up the server's memory. Past it, idle clients are forgotten first
/// and then the oldest ones, whose counts start again. Defaults to 100,000.
///
/// Counts are kept in memory. In a `QuadrantCluster`, all isolates share one
/// count; separate processes or machines do not. If the main isolate is too
/// busy to answer, an isolate counts on its own until it recovers, and a
/// warning is printed.
Middleware rateLimit({
  required int maxRequests,
  required Duration window,
  String Function(Request req)? keyExtractor,
  int trustedProxyHops = 0,
  int maxKeys = 100000,
}) {
  if (trustedProxyHops < 0) {
    throw ArgumentError.value(
        trustedProxyHops, 'trustedProxyHops', 'Must not be negative.');
  }
  if (maxKeys < 1) {
    throw ArgumentError.value(maxKeys, 'maxKeys', 'Must be at least 1.');
  }

  final limiterId = '${_nextLimiterId++}';
  final windowMs = window.inMilliseconds;
  final local = SlidingWindowLimiter(maxRequests, windowMs, maxKeys);

  String defaultKey(Request req) {
    final forwarded = req.headers['x-forwarded-for'];
    if (trustedProxyHops > 0 && forwarded != null) {
      final client = forwardedClientIp(forwarded, trustedProxyHops);
      if (client != null) return clientRateLimitKey(client);
    }
    final remote = req.raw.connectionInfo?.remoteAddress.address;
    return remote == null ? 'unknown' : clientRateLimitKey(remote);
  }

  final getKey = keyExtractor ?? defaultKey;

  return (Request req, Next next) async {
    final key = getKey(req);
    final link = currentClusterLink;
    final decision = link == null
        ? local.check(key)
        : await link.rateCheck(limiterId, maxRequests, windowMs, maxKeys, key) ??
            local.check(key);

    final resetSeconds = (decision.resetAtMs / 1000).ceil();

    if (!decision.allowed) {
      final retryAfter = decision.retryAfterSeconds;
      return Response(
        statusCode: 429,
        headers: {
          'content-type': 'application/json',
          'x-ratelimit-limit': '$maxRequests',
          'x-ratelimit-remaining': '0',
          'x-ratelimit-reset': '$resetSeconds',
          'retry-after': '$retryAfter',
        },
        body: '{"error":"Too Many Requests","retryAfter":$retryAfter}',
      );
    }

    final response = await next();

    return response.copyWith(
      headers: {
        ...response.headers,
        'x-ratelimit-limit': '$maxRequests',
        'x-ratelimit-remaining': '${decision.remaining}',
        'x-ratelimit-reset': '$resetSeconds',
      },
    );
  };
}
