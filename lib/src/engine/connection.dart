part of 'engine.dart';

// What a connection is doing.
const int _idle = 0; // Between requests.
const int _readingHead = 1; // Part of a header block has arrived.
const int _readingBody = 2; // A request is out; its body is still arriving.
const int _waiting = 3; // A request is fully read; its response is pending.
const int _detachedState = 4; // Handed over, e.g. to a WebSocket.
const int _closingState = 5; // Finishing writes, then closing.
const int _closed = 6;

/// One HTTP/1.1 connection: reads requests one at a time, and keeps whatever
/// follows a request (a pipelined one) until its response is done, so that
/// responses always go out in order.
class _Connection {
  final EngineServer _server;
  final RawSocket _socket;
  final bool _secure;
  HttpConnectionInfo? _info;
  InternetAddress _localAddress = InternetAddress.loopbackIPv4;
  int _localPort = 0;

  int _state = _idle;

  /// When [_state] was entered, on the server's clock.
  int _since;

  /// Bytes received but not processed yet, starting at index 0.
  Uint8List? _pending;

  /// Where to resume looking for the end of a partial header block.
  int _scanFrom = 0;

  bool _processing = false;
  bool _readClosed = false;

  /// A detached socket's sending side is closed.
  bool _writeClosed = false;

  /// Set when the connection must close after the current response.
  bool _noKeepAlive = false;

  EngineRequest? _request;
  bool _responseDone = false;
  int _bodyRemaining = 0;
  _ChunkedDecoder? _chunks;
  bool _discardBody = false;
  bool _continueSent = false;

  /// Requests started on this connection.
  int _requests = 0;

  /// When body bytes last arrived, or the handler last started reading,
  /// for [EngineOptions.bodyTimeout].
  int _bodyProgressAt = 0;

  final ListQueue<List<int>> _queue = ListQueue();
  int _queueOffset = 0;
  int _queuedBytes = 0;
  Completer<void>? _drainCompleter;
  List<void Function()>? _goneCallbacks;

  StreamController<Uint8List>? _incoming;
  _DetachedSocket? _detachedSocket;

  _Connection(this._server, this._socket)
      : _secure = _socket is RawSecureSocket,
        _since = _server._now {
    try {
      _socket.setOption(SocketOption.tcpNoDelay, true);
      _info = _ConnectionInfo(
          _socket.remoteAddress, _socket.remotePort, _socket.port);
      _localAddress = _socket.address;
      _localPort = _socket.port;
    } on SocketException {
      // Already gone; the listener below will hear about it.
    }
    _socket.writeEventsEnabled = false;
    _socket.listen(_onEvent,
        onError: (Object _) => _destroy(), onDone: _destroy);
  }

  X509Certificate? get _certificate {
    final socket = _socket;
    return socket is RawSecureSocket ? socket.peerCertificate : null;
  }

  // ─── Reading ─────────────────────────────────────────────────

  void _onEvent(RawSocketEvent event) {
    switch (event) {
      case RawSocketEvent.read:
        final Uint8List? data;
        try {
          // What is there, up to the cap. A count above what is there would
          // allocate that much anyway.
          final available = _socket.available();
          data = available <= 0
              ? _socket.read()
              : _socket.read(available < _readSize ? available : _readSize);
        } on SocketException {
          _destroy();
          return;
        }
        if (data != null && data.isNotEmpty) _onData(data);
      case RawSocketEvent.write:
        _flushQueue();
      case RawSocketEvent.readClosed:
        _onReadClosed();
      case RawSocketEvent.closed:
        _destroy();
    }
  }

  void _onData(Uint8List data) {
    switch (_state) {
      case _closingState || _closed:
        return; // Discarded.
      case _detachedState:
        _incoming!.add(data);
        return;
    }
    final pending = _pending;
    if (pending != null) {
      _pending = null;
      data = (BytesBuilder(copy: false)
            ..add(pending)
            ..add(data))
          .takeBytes();
    }
    _process(data, 0);
  }

  void _process(Uint8List b, int offset) {
    _processing = true;
    try {
      loop:
      while (offset < b.length) {
        switch (_state) {
          case _idle:
            // A blank line before a request is allowed (RFC 9112 2.2).
            while (
                offset < b.length && (b[offset] == _cr || b[offset] == _lf)) {
              offset++;
            }
            if (offset == b.length) break loop;
            _enter(_readingHead);
            _scanFrom = offset;

          case _readingHead:
            final end = _findHeadEnd(b, offset, _scanFrom, b.length);
            if (end < 0) {
              if (b.length - offset > _server.options.maxHeaderBytes) {
                throw const _HttpError(431, 'Request header too large');
              }
              final rest = Uint8List.sublistView(b, offset);
              _pending = rest;
              _scanFrom = rest.length > 3 ? rest.length - 3 : 0;
              break loop;
            }
            if (end - offset > _server.options.maxHeaderBytes) {
              throw const _HttpError(431, 'Request header too large');
            }
            final head = _parseHead(b, offset, end, _server.options.maxHeaderCount);
            offset = end;
            _startRequest(head);

          case _readingBody:
            if (!_bodyFlowing) {
              _pending = Uint8List.sublistView(b, offset);
              _socket.readEventsEnabled = false;
              break loop;
            }
            offset = _feedBody(b, offset);

          case _waiting:
            // The next request, sent before this response: kept for later.
            final rest = Uint8List.sublistView(b, offset);
            _pending = rest;
            if (rest.length > _server.options.maxHeaderBytes) {
              _socket.readEventsEnabled = false;
            }
            break loop;

          case _detachedState:
            _incoming!.add(Uint8List.sublistView(b, offset));
            break loop;

          default:
            break loop;
        }
      }
    } on _HttpError catch (error) {
      _reject(error);
    } finally {
      _processing = false;
    }
  }

  void _startRequest(_Head head) {
    final request = EngineRequest._(this, head);
    _request = request;
    _responseDone = false;
    _discardBody = false;
    _continueSent = false;
    final max = _server.options.maxRequestsPerConnection;
    if (max != null && ++_requests >= max) {
      // This response says `connection: close`.
      request.response._persistent = false;
    }
    if (head.chunked) {
      _chunks = _ChunkedDecoder();
      _enter(_readingBody);
      _bodyProgressAt = _since;
    } else if (head.contentLength > 0) {
      _chunks = null;
      _bodyRemaining = head.contentLength;
      _enter(_readingBody);
      _bodyProgressAt = _since;
    } else {
      _enter(_waiting);
      request._body.close();
    }
    _server._dispatch(request);
  }

  bool get _bodyFlowing {
    if (_discardBody) return true;
    final body = _request!._body;
    return body.hasListener && !body.isPaused;
  }

  int _feedBody(Uint8List b, int offset) {
    _bodyProgressAt = _server._now;
    final chunks = _chunks;
    if (chunks != null) {
      offset = chunks.feed(b, offset, b.length, _emitBody);
      if (chunks.isDone) _endBody();
    } else {
      final available = b.length - offset;
      final n = available < _bodyRemaining ? available : _bodyRemaining;
      _emitBody(Uint8List.sublistView(b, offset, offset + n));
      offset += n;
      _bodyRemaining -= n;
      if (_bodyRemaining == 0) _endBody();
    }
    return offset;
  }

  void _emitBody(Uint8List data) {
    if (!_discardBody) _request!._body.add(data);
  }

  void _endBody() {
    _chunks = null;
    final responseDone = _responseDone;
    // The state moves on first: closing the body can run the handler on to
    // its response right here, inside close(), through the `await for` that
    // was reading it.
    if (!responseDone) _enter(_waiting);
    final body = _request!._body;
    if (!body.isClosed) body.close();
    if (responseDone) _nextRequest();
  }

  void _onBodyListen() {
    final request = _request;
    if (request != null &&
        _state == _readingBody &&
        request._head.expectContinue &&
        !_continueSent &&
        !request.response._headersSent) {
      _continueSent = true;
      _write(_continue);
    }
    _resumeReading();
  }

  void _onBodyCancel() {
    // The rest of the body is read and dropped, which keeps the connection
    // usable for the response.
    if (_state == _readingBody) {
      _discardBody = true;
      _resumeReading();
    }
  }

  /// Carries on reading: processes what was held back, then asks the socket
  /// for more.
  void _resumeReading() {
    if (_processing || _state >= _closingState) return;
    // Time spent paused was the handler's, not the client's.
    if (_state == _readingBody) _bodyProgressAt = _server._now;
    try {
      _socket.readEventsEnabled = true;
    } on Object {
      return;
    }
    final pending = _pending;
    if (pending != null) {
      _pending = null;
      _process(pending, 0);
    }
  }

  void _onReadClosed() {
    _readClosed = true;
    _noKeepAlive = true;
    switch (_state) {
      case _idle || _readingHead:
        _closeGracefully();
      case _readingBody:
        final body = _request!._body;
        if (!body.isClosed) {
          body
            ..addError(
                const HttpException('Connection closed while receiving data'))
            ..close();
        }
        _chunks = null;
        if (_responseDone) {
          _closeGracefully();
        } else {
          _enter(_waiting);
        }
      case _closingState:
        _destroy();
      case _detachedState:
        _incoming?.close();
        if (_writeClosed) _destroy();
    }
  }

  // ─── Responses ───────────────────────────────────────────────

  void _onResponseDone(EngineResponse response) {
    if (!identical(response._request, _request)) return;
    _responseDone = true;
    if (!response._persistent) _noKeepAlive = true;
    switch (_state) {
      case _readingBody:
        // Answered before the body was read. dart:io closes here too:
        // reading on could mean waiting for a large upload nobody wants.
        _noKeepAlive = true;
        _closeGracefully();
      case _waiting:
        _nextRequest();
    }
  }

  void _nextRequest() {
    _request = null;
    if (_noKeepAlive || _server._closing) {
      _closeGracefully();
      return;
    }
    _enter(_idle);
    _resumeReading();
  }

  /// Answers a request that never reached the framework, then closes.
  void _reject(_HttpError error) {
    final request = _request;
    if (request != null) {
      // Mid-body: the handler already has the request, so it hears of it
      // through the body stream and still writes the response.
      final body = request._body;
      if (!body.isClosed) {
        body
          ..addError(error.status == 408
              ? BodyTimeoutException(error.message)
              : HttpException(error.message))
          ..close();
      }
      _noKeepAlive = true;
      _pending = null;
      if (_responseDone) {
        _closeGracefully();
      } else {
        _enter(_waiting);
        _socket.readEventsEnabled = false;
      }
      return;
    }
    final reason = _reasonFor(error.status);
    _write(latin1.encode('HTTP/1.1 ${error.status} $reason\r\n'
        'content-length: 0\r\n'
        'connection: close\r\n\r\n'));
    _closeGracefully();
  }

  // ─── Writing ─────────────────────────────────────────────────

  void _write(List<int> data) {
    if (_state == _closed || data.isEmpty) return;
    if (_queue.isNotEmpty) {
      _queue.add(data);
      _queuedBytes += data.length;
      return;
    }
    final int written;
    try {
      written = _socket.write(data);
    } on Object {
      _destroy();
      return;
    }
    if (written == data.length) return;
    _queue.add(data);
    _queueOffset = written;
    _queuedBytes = data.length - written;
    _socket.writeEventsEnabled = true;
  }

  void _flushQueue() {
    while (_queue.isNotEmpty) {
      final data = _queue.first;
      final int written;
      try {
        written = _socket.write(data, _queueOffset);
      } on Object {
        _destroy();
        return;
      }
      _queueOffset += written;
      _queuedBytes -= written;
      if (_queueOffset < data.length) {
        _socket.writeEventsEnabled = true;
        return;
      }
      _queue.removeFirst();
      _queueOffset = 0;
    }
    final drain = _drainCompleter;
    _drainCompleter = null;
    drain?.complete();
    if (_state == _closingState || _writeClosed) _shutdownWrite();
  }

  /// Completes once everything written so far has gone to the socket.
  Future<void> _drained() {
    if (_queue.isEmpty || _state == _closed) return Future.value();
    return (_drainCompleter ??= Completer<void>()).future;
  }

  void _onGone(void Function() callback) {
    if (_state == _closed) {
      callback();
    } else {
      (_goneCallbacks ??= []).add(callback);
    }
  }

  // ─── Handing over and closing ────────────────────────────────

  _DetachedSocket _detach() {
    _enter(_detachedState);
    _request = null;
    final incoming = _incoming = StreamController<Uint8List>(
      sync: true,
      onPause: () => _setReading(false),
      onResume: () => _setReading(true),
    );
    final pending = _pending;
    _pending = null;
    if (pending != null && pending.isNotEmpty) incoming.add(pending);
    if (_readClosed) {
      incoming.close();
    } else {
      _setReading(true);
    }
    return _detachedSocket = _DetachedSocket(this, incoming.stream);
  }

  /// The detached socket's `close()`. Like dart:io's, it only closes the
  /// sending side: a WebSocket still reads the peer's closing frame.
  void _closeAfterDetach() {
    if (_state != _detachedState || _writeClosed) return;
    _writeClosed = true;
    _since = _server._now;
    if (_queue.isEmpty) _shutdownWrite();
  }

  void _setReading(bool enabled) {
    if (_state == _closed) return;
    try {
      _socket.readEventsEnabled = enabled;
    } on Object {
      // Closed under us.
    }
  }

  /// Sends what is queued, then closes the sending side and waits a moment
  /// for the client to close too. Closing outright could reset the
  /// connection before the client has read the last response.
  void _closeGracefully() {
    if (_state >= _closingState) return;
    _enter(_closingState);
    _pending = null;
    final request = _request;
    if (request != null && !request._body.isClosed) {
      request._body.close();
    }
    if (_queue.isEmpty) _shutdownWrite();
  }

  void _shutdownWrite() {
    if (_readClosed) {
      _destroy();
      return;
    }
    try {
      _socket.shutdown(SocketDirection.send);
      _socket.readEventsEnabled = true;
    } on Object {
      _destroy();
    }
  }

  void _destroy() {
    if (_state == _closed) return;
    _state = _closed;
    try {
      _socket.close();
    } on Object {
      // Already closed.
    }
    _queue.clear();
    _queuedBytes = 0;
    final drain = _drainCompleter;
    _drainCompleter = null;
    drain?.complete();

    final request = _request;
    _request = null;
    if (request != null) {
      final body = request._body;
      if (!body.isClosed) {
        body
          ..addError(
              const HttpException('Connection closed while receiving data'))
          ..close();
      }
      request.response._gone();
    }
    _incoming?.close();
    _detachedSocket?._onClosed();

    final callbacks = _goneCallbacks;
    _goneCallbacks = null;
    if (callbacks != null) {
      for (final callback in callbacks) {
        callback();
      }
    }
    _server._connectionClosed(this);
  }

  void _enter(int state) {
    _state = state;
    _since = _server._now;
  }

  /// Called by the server about once a second.
  void _sweep(int now) {
    final elapsed = now - _since;
    switch (_state) {
      case _idle:
        final timeout = _server.idleTimeout;
        if (timeout != null && elapsed >= timeout.inMilliseconds) _destroy();
      case _readingHead:
        if (elapsed >= _server.options.headerTimeout.inMilliseconds) {
          _reject(const _HttpError(408, 'Request header timeout'));
        }
      case _readingBody:
        if (_bodyFlowing &&
            now - _bodyProgressAt >=
                _server.options.bodyTimeout.inMilliseconds) {
          _reject(const _HttpError(408, 'Request body timeout'));
        }
      case _closingState:
        if (elapsed >= 2000) _destroy();
      case _detachedState:
        if (_writeClosed && elapsed >= 5000) _destroy();
    }
  }
}

/// Most bytes taken from the socket at once. Without a cap, a read takes all
/// the kernel has buffered, up to 4 MB: for a fast upload on a busy server,
/// megabytes in one allocation, kept alive by the body chunks viewing it.
const int _readSize = 64 * 1024;

final Uint8List _continue = ascii.encode('HTTP/1.1 100 Continue\r\n\r\n');

class _ConnectionInfo implements HttpConnectionInfo {
  @override
  final InternetAddress remoteAddress;
  @override
  final int remotePort;
  @override
  final int localPort;

  _ConnectionInfo(this.remoteAddress, this.remotePort, this.localPort);
}
