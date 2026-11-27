part of 'engine.dart';

/// Bodies up to this size are buffered and sent with a `content-length`.
/// Past it, the headers go out and the rest streams.
const int _bufferLimit = 64 * 1024;

/// Bytes queued for the socket at which a streamed body waits for it.
const int _highWaterMark = 1024 * 1024;

/// An [HttpResponse] written by the engine.
///
/// [sendDirect] is the fast path the framework uses for a plain [Response].
/// Everything else (SSE, [StreamResponse], WebSocket upgrades, code using
/// `req.raw.response`) goes through the [IOSink] side.
class EngineResponse implements HttpResponse {
  final _Connection _connection;
  final EngineRequest _request;

  EngineHeaders? _headers;
  List<Cookie>? _cookies;

  @override
  int statusCode = HttpStatus.ok;

  String? _reasonPhrase;

  @override
  bool bufferOutput = true;

  Encoding? _encoding;

  @override
  Encoding get encoding => _effectiveEncoding;

  @override
  set encoding(Encoding value) => _encoding = value;

  bool _persistent;

  bool _headersSent = false;
  bool _closed = false;
  bool _ignoreBody = false;
  bool _chunked = false;

  /// From the `content-length` sent, or -1.
  int _declaredLength = -1;
  int _bodyBytes = 0;

  BytesBuilder? _buffer;
  Future<void>? _streaming;
  final Completer<void> _done = Completer<void>();

  Duration? _deadline;
  Timer? _deadlineTimer;

  EngineResponse._(this._connection, this._request)
      : _persistent = _request._head.keepAlive {
    // So that an unobserved failure is not reported as unhandled.
    _done.future.catchError((Object _) {});
  }

  /// Whether nothing about this response has been touched yet, so that
  /// [sendDirect] can write it.
  bool get canSendDirect =>
      !_headersSent && !_closed && _headers == null && _cookies == null;

  @override
  EngineHeaders get headers => _headers ??= _connection._server._newHeaders();

  @override
  List<Cookie> get cookies => _cookies ??= [];

  @override
  String get reasonPhrase => _reasonPhrase ?? _reasonFor(statusCode);

  @override
  set reasonPhrase(String phrase) {
    if (_headersSent) throw StateError('Headers already sent');
    _reasonPhrase = phrase;
  }

  @override
  bool get persistentConnection => _persistent;

  @override
  set persistentConnection(bool persistent) {
    // Once the headers are out, the client has been told; turning it off
    // still makes this side close afterwards.
    if (_headersSent && persistent) return;
    _persistent = persistent;
  }

  @override
  int get contentLength => headers.contentLength;

  @override
  set contentLength(int length) => headers.contentLength = length;

  @override
  Duration? get deadline => _deadline;

  @override
  set deadline(Duration? d) {
    _deadlineTimer?.cancel();
    _deadline = d;
    if (d == null) return;
    _deadlineTimer = Timer(d, () => _connection._destroy());
  }

  @override
  HttpConnectionInfo? get connectionInfo => _connection._info;

  @override
  Future<void> get done => _done.future;

  // ─── Fast path ───────────────────────────────────────────────

  /// Writes a complete response in one go. Only valid while [canSendDirect].
  ///
  /// Header names may be in any case. Values are checked as
  /// [HttpHeaders.set] would check them.
  Future<void> sendDirect(int status, Map<String, String> responseHeaders,
      List<String> setCookies, String body) {
    final names = <String>[];
    try {
      responseHeaders.forEach((name, value) {
        final key = EngineHeaders._validateName(name);
        EngineHeaders._validateValue(value);
        names.add(key);
      });
      for (final cookie in setCookies) {
        EngineHeaders._validateValue(cookie);
      }
    } on FormatException {
      // Sending it would let the value end the header early. A bare 500 is
      // what can still be said safely.
      return sendDirect(HttpStatus.internalServerError,
          const {'connection': 'close'}, const [], '');
    }

    statusCode = status;
    _headersSent = true;
    _closed = true;
    final server = _connection._server;

    final out = StringBuffer(_statusLine(status, null));
    String? contentType;
    String? contentLength;
    var chunked = false;
    var userConnection = false;

    // Defaults first, unless the response sets the same header.
    final defaults = server._defaultPairs();
    for (var i = 0; i < defaults.length; i += 2) {
      final name = defaults[i];
      if (names.contains(name)) continue;
      if (name == HttpHeaders.contentTypeHeader) contentType = defaults[i + 1];
      out
        ..write(name)
        ..write(': ')
        ..write(defaults[i + 1])
        ..write('\r\n');
    }

    var index = 0;
    responseHeaders.forEach((_, value) {
      final name = names[index++];
      switch (name) {
        case HttpHeaders.contentTypeHeader:
          contentType = value;
        case HttpHeaders.contentLengthHeader:
          contentLength = value;
          return;
        case HttpHeaders.transferEncodingHeader:
          if (value.toLowerCase() == 'chunked') {
            chunked = true;
            return;
          }
        case HttpHeaders.connectionHeader:
          userConnection = true;
          if (value.toLowerCase() == 'close') _persistent = false;
      }
      out
        ..write(name)
        ..write(': ')
        ..write(value)
        ..write('\r\n');
    });
    for (final cookie in setCookies) {
      out
        ..write('set-cookie: ')
        ..write(cookie)
        ..write('\r\n');
    }

    final noBody = _statusHasNoBody(status);
    final List<int> bytes = body.isEmpty || noBody
        ? _empty
        : _bodyEncodingFor(contentType).encode(body);
    if (!noBody) {
      if (contentLength != null &&
          int.tryParse(contentLength!) != bytes.length &&
          !(_request.method == 'HEAD' && bytes.isEmpty)) {
        _fail(HttpException('Content size does not match the specified '
            'content-length ($contentLength) for ${bytes.length} bytes'));
        return Future.error(HttpException('Content-length mismatch'));
      }
      if (chunked && bytes.isNotEmpty) {
        // Asked for, so honoured: the whole body as one chunk.
        out.write('transfer-encoding: chunked\r\n');
      } else {
        chunked = false;
        out
          ..write('content-length: ')
          ..write(contentLength ?? bytes.length)
          ..write('\r\n');
      }
    }
    if (server.serverHeader != null && !names.contains('server')) {
      out.write('server: ${server.serverHeader}\r\n');
    }
    if (!userConnection) _writeConnectionHeader(out);
    out.write('\r\n');

    final head = _encodeHead(out.toString());
    final sendBody = bytes.isNotEmpty && _request.method != 'HEAD';
    if (!sendBody) {
      _connection._write(head);
    } else if (chunked) {
      _connection._write(head);
      _connection._write(ascii.encode('${bytes.length.toRadixString(16)}\r\n'));
      _connection._write(bytes);
      _connection._write(_lastChunkAfterData);
    } else if (bytes.length <= 16 * 1024) {
      // One write, one syscall.
      final all = Uint8List(head.length + bytes.length)
        ..setRange(0, head.length, head)
        ..setRange(head.length, head.length + bytes.length, bytes);
      _connection._write(all);
    } else {
      _connection._write(head);
      _connection._write(bytes);
    }
    return _finish();
  }

  // ─── IOSink ──────────────────────────────────────────────────

  @override
  void add(List<int> data) {
    if (_closed) throw StateError('StreamSink is closed');
    if (_streaming != null) throw StateError('StreamSink is bound to a stream');
    _add(data);
  }

  void _add(List<int> data) {
    if (data.isEmpty) return;
    if (!_headersSent && bufferOutput) {
      final buffer = _buffer ??= BytesBuilder(copy: true);
      buffer.add(data);
      if (buffer.length > _bufferLimit) _startStreaming();
      return;
    }
    if (!_headersSent) _startStreaming();
    _writeBody(data);
  }

  @override
  void write(Object? object) {
    final string = '$object';
    if (string.isEmpty) return;
    add(_effectiveEncoding.encode(string));
  }

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) {
    var first = true;
    for (final object in objects) {
      if (!first) write(separator);
      first = false;
      write(object);
    }
  }

  @override
  void writeln([Object? object = '']) {
    write(object);
    write('\n');
  }

  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    // There is no way to tell the client, so the connection is dropped.
    _fail(error, stackTrace);
  }

  @override
  Future<void> addStream(Stream<List<int>> stream) {
    if (_closed) throw StateError('StreamSink is closed');
    if (_streaming != null) throw StateError('StreamSink is bound to a stream');
    final completer = Completer<void>();
    late StreamSubscription<List<int>> subscription;
    subscription = stream.listen(
      (data) {
        try {
          // Each chunk goes out as it comes, as with dart:io: a stream is
          // usually slow because it is live, not because it is large.
          if (!_headersSent && data.isNotEmpty) _startStreaming();
          _add(data);
        } catch (error, stack) {
          unawaited(subscription.cancel());
          _streaming = null;
          completer.completeError(error, stack);
          _fail(error, stack);
          return;
        }
        if (_connection._queuedBytes > _highWaterMark) {
          subscription.pause(_connection._drained());
        }
      },
      onError: (Object error, StackTrace stack) {
        unawaited(subscription.cancel());
        _streaming = null;
        // Dropped rather than ended, so the client cannot take a truncated
        // body for a complete one.
        completer.completeError(error, stack);
        _fail(error, stack);
      },
      onDone: () {
        _streaming = null;
        completer.complete();
      },
      cancelOnError: true,
    );
    _connection._onGone(() {
      if (completer.isCompleted) return;
      unawaited(subscription.cancel());
      _streaming = null;
      completer.completeError(const SocketException('Connection closed'));
    });
    return _streaming = completer.future;
  }

  @override
  Future<void> flush() {
    if (_closed) return Future.value();
    if (!_headersSent) _startStreaming();
    return _connection._drained();
  }

  @override
  Future<void> close() {
    if (_closed) return done;
    if (_streaming != null) throw StateError('StreamSink is bound to a stream');
    _closed = true;
    if (!_headersSent) {
      final buffer = _buffer;
      _buffer = null;
      _sendHead(contentLength: buffer?.length ?? 0, streaming: false);
      if (buffer != null && !_ignoreBody) {
        _bodyBytes = buffer.length;
        _connection._write(buffer.takeBytes());
      }
    } else if (_chunked) {
      _connection._write(_lastChunk);
    }
    if (_declaredLength >= 0 && _bodyBytes < _declaredLength && !_ignoreBody) {
      final error = HttpException('Content size below specified '
          'contentLength. $_bodyBytes bytes written but expected '
          '$_declaredLength.');
      _fail(error);
      return done;
    }
    return _finish();
  }

  @override
  Future<void> redirect(Uri location,
      {int status = HttpStatus.movedTemporarily}) {
    statusCode = status;
    headers.set(HttpHeaders.locationHeader, location.toString());
    return close();
  }

  @override
  Future<Socket> detachSocket({bool writeHeaders = true}) {
    if (_headersSent) throw StateError('Headers already sent');
    _deadlineTimer?.cancel();
    if (writeHeaders) {
      _sendHead(contentLength: -1, streaming: false, upgrade: true);
    }
    _headersSent = true;
    _closed = true;
    if (!_done.isCompleted) _done.complete();
    return Future.value(_connection._detach());
  }

  // ─── Internals ───────────────────────────────────────────────

  Encoding get _effectiveEncoding {
    final explicit = _encoding;
    if (explicit != null) return explicit;
    return _encodingFor(_headers?.value(HttpHeaders.contentTypeHeader) ??
        _connection._server._defaultContentType());
  }

  /// As dart:io: the charset of the content type, or Latin-1.
  static Encoding _encodingFor(String? contentType) {
    if (contentType == null) return latin1;
    final lower = contentType.toLowerCase();
    if (lower.contains('charset=utf-8')) return utf8;
    final charset = ContentType.parse(contentType).charset;
    return (charset == null ? null : Encoding.getByName(charset)) ?? latin1;
  }

  /// As the framework's dart:io path: the charset of the content type, or
  /// UTF-8. Latin-1 would corrupt JSON.
  static Encoding _bodyEncodingFor(String? contentType) {
    if (contentType == null) return utf8;
    final lower = contentType.toLowerCase();
    if (!lower.contains('charset=') || lower.contains('charset=utf-8')) {
      return utf8;
    }
    final charset = ContentType.parse(contentType).charset;
    return (charset == null ? null : Encoding.getByName(charset)) ?? utf8;
  }

  void _startStreaming() {
    final buffer = _buffer;
    _buffer = null;
    _sendHead(contentLength: -1, streaming: true);
    if (buffer != null) _writeBody(buffer.takeBytes());
  }

  void _writeBody(List<int> data) {
    if (_ignoreBody || data.isEmpty) return;
    _bodyBytes += data.length;
    if (_declaredLength >= 0 && _bodyBytes > _declaredLength) {
      throw HttpException('Content size exceeds specified contentLength. '
          '$_bodyBytes bytes written while expected $_declaredLength.');
    }
    if (_chunked) {
      final size = ascii.encode('${data.length.toRadixString(16)}\r\n');
      if (data.length <= 16 * 1024) {
        // One write per chunk: an SSE event is usually one small chunk.
        final framed = Uint8List(size.length + data.length + 2)
          ..setRange(0, size.length, size)
          ..setRange(size.length, size.length + data.length, data);
        framed[framed.length - 2] = _cr;
        framed[framed.length - 1] = _lf;
        _connection._write(framed);
      } else {
        _connection._write(size);
        _connection._write(data);
        _connection._write(_crlf);
      }
    } else {
      _connection._write(data);
    }
  }

  /// Writes the status line and headers. With [streaming] the body's size is
  /// unknown: it is sent chunked unless a `content-length` was set.
  void _sendHead(
      {required int contentLength,
      required bool streaming,
      bool upgrade = false}) {
    _headersSent = true;
    final headers = this.headers;
    final server = _connection._server;
    final noBody = _statusHasNoBody(statusCode) || _request.method == 'HEAD';
    _ignoreBody = noBody;

    _declaredLength = headers.contentLength;
    if (!upgrade && !_statusHasNoBody(statusCode)) {
      if (_declaredLength < 0 && !headers.chunkedTransferEncoding) {
        if (!streaming) {
          headers._map[HttpHeaders.contentLengthHeader] = ['$contentLength'];
          if (_request.method != 'HEAD') _declaredLength = contentLength;
        } else if (_request._head.http11) {
          headers._map[HttpHeaders.transferEncodingHeader] = ['chunked'];
        } else {
          // HTTP/1.0 has no chunking: the end of the body is the close.
          _persistent = false;
        }
      }
      _chunked = headers.chunkedTransferEncoding && !noBody;
      if (_chunked) _declaredLength = -1;
    }
    if (!headers.persistentConnection) _persistent = false;
    if (noBody) _declaredLength = -1;

    final out = StringBuffer(_statusLine(statusCode, _reasonPhrase));
    var userConnection = false;
    headers._map.forEach((name, values) {
      if (name == HttpHeaders.connectionHeader) userConnection = true;
      for (final value in values) {
        out
          ..write(name)
          ..write(': ')
          ..write(value)
          ..write('\r\n');
      }
    });
    final cookies = _cookies;
    if (cookies != null) {
      for (final cookie in cookies) {
        out.write('set-cookie: $cookie\r\n');
      }
    }
    if (server.serverHeader != null && headers._map['server'] == null) {
      out.write('server: ${server.serverHeader}\r\n');
    }
    if (!userConnection && !upgrade) _writeConnectionHeader(out);
    out.write('\r\n');
    headers._mutable = false;
    _connection._write(_encodeHead(out.toString()));
  }

  void _writeConnectionHeader(StringBuffer out) {
    if (!_persistent || _connection._server._closing) {
      _persistent = false;
      out.write('connection: close\r\n');
    } else if (!_request._head.http11) {
      out.write('connection: keep-alive\r\n');
    }
  }

  Future<void> _finish() {
    _deadlineTimer?.cancel();
    _connection._onResponseDone(this);
    if (_connection._queuedBytes == 0) {
      if (!_done.isCompleted) _done.complete();
    } else {
      _connection._drained().then((_) {
        if (!_done.isCompleted) _done.complete();
      });
    }
    return _done.future;
  }

  void _fail(Object error, [StackTrace? stack]) {
    _closed = true;
    _deadlineTimer?.cancel();
    if (!_done.isCompleted) _done.completeError(error, stack);
    _connection._destroy();
  }

  /// The connection went away before this response finished.
  void _gone() {
    _closed = true;
    _deadlineTimer?.cancel();
    if (!_done.isCompleted) {
      _done.completeError(const SocketException('Connection closed'));
    }
  }
}

final Uint8List _empty = Uint8List(0);
final Uint8List _crlf = Uint8List.fromList(const [_cr, _lf]);
final Uint8List _lastChunk = ascii.encode('0\r\n\r\n');
final Uint8List _lastChunkAfterData = ascii.encode('\r\n0\r\n\r\n');

Uint8List _encodeHead(String head) {
  // Header values are Latin-1 in HTTP. Anything wider is sent as UTF-8
  // rather than thrown, since a handler cannot easily recover from that.
  for (var i = 0; i < head.length; i++) {
    if (head.codeUnitAt(i) > 255) return utf8.encode(head);
  }
  return latin1.encode(head);
}

bool _statusHasNoBody(int status) =>
    status < 200 ||
    status == HttpStatus.noContent ||
    status == HttpStatus.notModified;

final Map<int, String> _statusLines = {};

String _statusLine(int status, String? reason) {
  if (reason != null) return 'HTTP/1.1 $status $reason\r\n';
  return _statusLines[status] ??= 'HTTP/1.1 $status ${_reasonFor(status)}\r\n';
}

String _reasonFor(int status) => switch (status) {
      100 => 'Continue',
      101 => 'Switching Protocols',
      200 => 'OK',
      201 => 'Created',
      202 => 'Accepted',
      203 => 'Non-Authoritative Information',
      204 => 'No Content',
      205 => 'Reset Content',
      206 => 'Partial Content',
      300 => 'Multiple Choices',
      301 => 'Moved Permanently',
      302 => 'Found',
      303 => 'See Other',
      304 => 'Not Modified',
      305 => 'Use Proxy',
      307 => 'Temporary Redirect',
      308 => 'Permanent Redirect',
      400 => 'Bad Request',
      401 => 'Unauthorized',
      402 => 'Payment Required',
      403 => 'Forbidden',
      404 => 'Not Found',
      405 => 'Method Not Allowed',
      406 => 'Not Acceptable',
      407 => 'Proxy Authentication Required',
      408 => 'Request Time-out',
      409 => 'Conflict',
      410 => 'Gone',
      411 => 'Length Required',
      412 => 'Precondition Failed',
      413 => 'Request Entity Too Large',
      414 => 'Request-URI Too Long',
      415 => 'Unsupported Media Type',
      416 => 'Requested range not satisfiable',
      417 => 'Expectation Failed',
      422 => 'Unprocessable Entity',
      423 => 'Locked',
      424 => 'Failed Dependency',
      426 => 'Upgrade Required',
      428 => 'Precondition Required',
      429 => 'Too Many Requests',
      431 => 'Request Header Fields Too Large',
      500 => 'Internal Server Error',
      501 => 'Not Implemented',
      502 => 'Bad Gateway',
      503 => 'Service Unavailable',
      504 => 'Gateway Time-out',
      505 => 'Http Version not supported',
      _ => 'Status $status',
    };
