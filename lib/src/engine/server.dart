part of 'engine.dart';

/// An [HttpServer] built on [RawServerSocket] or [RawSecureServerSocket].
class EngineServer extends Stream<HttpRequest> implements HttpServer {
  final Stream<RawSocket> _listener;
  final Future<void> Function() _closeListener;

  @override
  final int port;

  @override
  final InternetAddress address;

  final StreamController<HttpRequest> _requests =
      StreamController<HttpRequest>(sync: true);
  final Set<_Connection> _connections = {};
  StreamSubscription<RawSocket>? _subscription;
  late final Timer _sweeper;
  final Stopwatch _clock = Stopwatch()..start();
  bool _closing = false;

  /// Largest request line plus header block accepted, in bytes. Larger gets
  /// `431`.
  final int maxHeaderBytes;

  /// Most header fields accepted in one request. More gets `431`.
  final int maxHeaderCount;

  /// How long a client may take to send a header block once it has started
  /// one. Slower gets `408` and is disconnected. dart:io has no such limit,
  /// which lets a slow client hold a connection open indefinitely.
  final Duration headerTimeout;

  @override
  Duration? idleTimeout = const Duration(seconds: 120);

  @override
  String? serverHeader;

  /// Ignored: compress responses with the `compress()` middleware instead.
  @override
  bool autoCompress = false;

  @override
  final EngineHeaders defaultResponseHeaders = EngineHeaders()
    ..set(HttpHeaders.contentTypeHeader, 'text/plain; charset=utf-8')
    ..set('x-frame-options', 'SAMEORIGIN')
    ..set('x-content-type-options', 'nosniff')
    ..set('x-xss-protection', '1; mode=block');

  List<String>? _defaultPairsCache;
  int _defaultPairsVersion = -1;

  EngineServer._(
    this._listener,
    this._closeListener,
    this.port,
    this.address, {
    required this.maxHeaderBytes,
    required this.maxHeaderCount,
    required this.headerTimeout,
  }) {
    _subscription = _listener.listen(
      (socket) {
        if (_closing) {
          socket.close();
          return;
        }
        _connections.add(_Connection(this, socket));
      },
      // A failed TLS handshake or an accept error affects one client only.
      onError: (Object _) {},
    );
    _sweeper = Timer.periodic(const Duration(seconds: 1), (_) {
      final now = _now;
      for (final connection in List.of(_connections)) {
        connection._sweep(now);
      }
    });
  }

  /// Binds a plain HTTP server, as [HttpServer.bind] does.
  static Future<EngineServer> bind(
    Object address,
    int port, {
    int backlog = 0,
    bool v6Only = false,
    bool shared = false,
    int maxHeaderBytes = 64 * 1024,
    int maxHeaderCount = 100,
    Duration headerTimeout = const Duration(seconds: 30),
  }) async {
    final socket = await RawServerSocket.bind(address, port,
        backlog: backlog, v6Only: v6Only, shared: shared);
    return EngineServer._(socket, socket.close, socket.port, socket.address,
        maxHeaderBytes: maxHeaderBytes,
        maxHeaderCount: maxHeaderCount,
        headerTimeout: headerTimeout);
  }

  /// Binds an HTTPS server, as [HttpServer.bindSecure] does.
  static Future<EngineServer> bindSecure(
    Object address,
    int port,
    SecurityContext context, {
    int backlog = 0,
    bool v6Only = false,
    bool shared = false,
    int maxHeaderBytes = 64 * 1024,
    int maxHeaderCount = 100,
    Duration headerTimeout = const Duration(seconds: 30),
  }) async {
    final socket = await RawSecureServerSocket.bind(address, port, context,
        backlog: backlog, v6Only: v6Only, shared: shared);
    return EngineServer._(socket, socket.close, socket.port, socket.address,
        maxHeaderBytes: maxHeaderBytes,
        maxHeaderCount: maxHeaderCount,
        headerTimeout: headerTimeout);
  }

  int get _now => _clock.elapsedMilliseconds;

  void _dispatch(EngineRequest request) => _requests.add(request);

  void _connectionClosed(_Connection connection) {
    _connections.remove(connection);
  }

  EngineHeaders _newHeaders() => EngineHeaders._copy(defaultResponseHeaders);

  /// [defaultResponseHeaders] as name, value, name, value, ….
  List<String> _defaultPairs() {
    final cached = _defaultPairsCache;
    if (cached != null &&
        _defaultPairsVersion == defaultResponseHeaders._version) {
      return cached;
    }
    final pairs = <String>[];
    defaultResponseHeaders.forEach((name, values) {
      for (final value in values) {
        pairs
          ..add(name)
          ..add(value);
      }
    });
    _defaultPairsVersion = defaultResponseHeaders._version;
    return _defaultPairsCache = pairs;
  }

  String? _defaultContentType() =>
      defaultResponseHeaders[HttpHeaders.contentTypeHeader]?.first;

  @override
  StreamSubscription<HttpRequest> listen(
    void Function(HttpRequest event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _requests.stream.listen(onData,
        onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  /// Stops accepting connections. Idle ones are closed now, and busy ones
  /// once their current response is done. With [force], all are closed now.
  @override
  Future<void> close({bool force = false}) async {
    if (!_closing) {
      _closing = true;
      _sweeper.cancel();
      await _subscription?.cancel();
      await _closeListener();
      unawaited(_requests.close());
    }
    for (final connection in List.of(_connections)) {
      if (force ||
          connection._state == _idle ||
          connection._state == _readingHead) {
        connection._destroy();
      }
    }
  }

  @override
  HttpConnectionsInfo connectionsInfo() {
    final info = HttpConnectionsInfo();
    for (final connection in _connections) {
      info.total++;
      switch (connection._state) {
        case _idle:
          info.idle++;
        case _closingState:
          info.closing++;
        default:
          info.active++;
      }
    }
    return info;
  }

  @override
  set sessionTimeout(int timeout) {}
}
