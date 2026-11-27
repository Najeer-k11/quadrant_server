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

  /// The limits this server applies.
  final EngineOptions options;

  @override
  Duration? idleTimeout;

  /// `date: …\r\n`, reformatted once a second, when [EngineOptions.dateHeader]
  /// is on.
  Uint8List? _dateLine;

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

  List<_EncodedHeader>? _defaultsCache;
  int _defaultsVersion = -1;

  /// Shared by every response: an isolate writes one at a time.
  final _HeadWriter _writer = _HeadWriter();

  EngineServer._(
    this._listener,
    this._closeListener,
    this.port,
    this.address,
    this.options,
  ) : idleTimeout = options.idleTimeout {
    _updateDate();
    _subscription = _listener.listen(
      (socket) {
        if (_closing) {
          socket.close();
          return;
        }
        final max = options.maxConnections;
        if (max != null && _connections.length >= max) {
          _refuse(socket);
          return;
        }
        _connections.add(_Connection(this, socket));
      },
      // A failed TLS handshake or an accept error affects one client only.
      onError: (Object _) {},
    );
    _sweeper = Timer.periodic(const Duration(seconds: 1), (_) {
      _updateDate();
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
    EngineOptions options = const EngineOptions(),
  }) async {
    final socket = await RawServerSocket.bind(address, port,
        backlog: backlog, v6Only: v6Only, shared: shared);
    return EngineServer._(
        socket, socket.close, socket.port, socket.address, options);
  }

  /// Binds an HTTPS server, as [HttpServer.bindSecure] does.
  static Future<EngineServer> bindSecure(
    Object address,
    int port,
    SecurityContext context, {
    int backlog = 0,
    bool v6Only = false,
    bool shared = false,
    EngineOptions options = const EngineOptions(),
  }) async {
    final socket = await RawSecureServerSocket.bind(address, port, context,
        backlog: backlog, v6Only: v6Only, shared: shared);
    return EngineServer._(
        socket, socket.close, socket.port, socket.address, options);
  }

  void _updateDate() {
    if (!options.dateHeader) return;
    _dateLine =
        latin1.encode('date: ${HttpDate.format(DateTime.now())}\r\n');
  }

  /// Answers `503` on a connection over [EngineOptions.maxConnections] and
  /// closes it. The sending side closes first, so that the client reads the
  /// answer instead of a reset.
  static void _refuse(RawSocket socket) {
    var closed = false;
    void close() {
      if (closed) return;
      closed = true;
      socket.close();
    }

    final timer = Timer(const Duration(seconds: 2), close);
    try {
      socket.writeEventsEnabled = false;
      socket.write(_serviceUnavailable);
      socket.shutdown(SocketDirection.send);
    } on Object {
      timer.cancel();
      close();
      return;
    }
    socket.listen(
      (event) {
        if (event == RawSocketEvent.read) {
          socket.read(); // Discarded.
        } else if (event == RawSocketEvent.readClosed ||
            event == RawSocketEvent.closed) {
          timer.cancel();
          close();
        }
      },
      onError: (Object _) {
        timer.cancel();
        close();
      },
    );
  }

  int get _now => _clock.elapsedMilliseconds;

  void _dispatch(EngineRequest request) => _requests.add(request);

  void _connectionClosed(_Connection connection) {
    _connections.remove(connection);
  }

  EngineHeaders _newHeaders() => EngineHeaders._copy(defaultResponseHeaders);

  /// [defaultResponseHeaders], each encoded once until they change.
  List<_EncodedHeader> _encodedDefaults() {
    final cached = _defaultsCache;
    if (cached != null &&
        _defaultsVersion == defaultResponseHeaders._version) {
      return cached;
    }
    final encoded = <_EncodedHeader>[];
    defaultResponseHeaders.forEach((name, values) {
      for (final value in values) {
        encoded.add(_EncodedHeader(name, value));
      }
    });
    _defaultsVersion = defaultResponseHeaders._version;
    return _defaultsCache = encoded;
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

final Uint8List _serviceUnavailable =
    latin1.encode('HTTP/1.1 503 Service Unavailable\r\n'
        'content-length: 0\r\n'
        'connection: close\r\n\r\n');
