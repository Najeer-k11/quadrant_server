/// Limits and behaviour of `ServerEngine.quadrant`.
///
/// ```dart
/// QuadrantServer(
///   engine: ServerEngine.quadrant,
///   engineOptions: EngineOptions(
///     maxConnections: 10000,
///     maxRequestsPerConnection: 1000,
///   ),
///   routes: [...],
/// );
/// ```
///
/// Only [idleTimeout] also applies to `ServerEngine.dartIo`; the rest are
/// ignored there.
class EngineOptions {
  /// Most connections one server (one isolate, in a cluster) keeps open.
  /// Past it, a new connection gets `503` and is closed, instead of the
  /// process running out of file descriptors. Null for no limit, as with
  /// dart:io.
  final int? maxConnections;

  /// After this many requests on one connection, the response says
  /// `connection: close`, and the client opens a new one. In a cluster, that
  /// spreads long-lived clients across isolates again. Null for no limit.
  final int? maxRequestsPerConnection;

  /// How long a connection may sit unused between requests before it is
  /// closed. Null keeps it open until the client closes it.
  final Duration? idleTimeout;

  /// How long a client may take to send a header block once it has started
  /// one. Slower gets `408`.
  final Duration headerTimeout;

  /// How long a request body may go without a single byte arriving, while
  /// the handler is reading it. Longer gets `408`, and the body stream an
  /// [HttpException]. Time the handler spends not reading does not count.
  final Duration bodyTimeout;

  /// Largest request line plus header block, in bytes. Larger gets `431`.
  final int maxHeaderBytes;

  /// Most header fields in one request. More gets `431`.
  final int maxHeaderCount;

  /// Whether responses carry a `Date` header, as RFC 9110 asks of a server
  /// with a clock. dart:io does not send one, so it is off by default. It is
  /// formatted once a second, not per response.
  final bool dateHeader;

  const EngineOptions({
    this.maxConnections,
    this.maxRequestsPerConnection,
    this.idleTimeout = const Duration(seconds: 120),
    this.headerTimeout = const Duration(seconds: 30),
    this.bodyTimeout = const Duration(seconds: 30),
    this.maxHeaderBytes = 64 * 1024,
    this.maxHeaderCount = 100,
    this.dateHeader = false,
  })  : assert(maxConnections == null || maxConnections > 0),
        assert(maxRequestsPerConnection == null || maxRequestsPerConnection > 0),
        assert(maxHeaderBytes > 0),
        assert(maxHeaderCount > 0);
}
