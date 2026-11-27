part of 'engine.dart';

/// The [Socket] that [EngineResponse.detachSocket] returns, which is what
/// `WebSocketTransformer.upgrade` runs the WebSocket over.
///
/// Bytes that arrived after the upgrade request come first on the stream.
class _DetachedSocket extends Stream<Uint8List> implements Socket {
  final _Connection _connection;
  final Stream<Uint8List> _stream;
  final Completer<void> _done = Completer<void>();
  bool _closed = false;
  bool _bound = false;

  @override
  Encoding encoding = utf8;

  _DetachedSocket(this._connection, this._stream) {
    _done.future.catchError((Object _) {});
  }

  void _onClosed() {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _stream.listen(onData,
        onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  @override
  void add(List<int> data) {
    if (_closed) throw StateError('StreamSink is closed');
    if (_bound) throw StateError('StreamSink is bound to a stream');
    _connection._write(data);
  }

  @override
  void write(Object? object) {
    final string = '$object';
    if (string.isNotEmpty) add(encoding.encode(string));
  }

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      write(objects.join(separator));

  @override
  void writeln([Object? object = '']) => write('$object\n');

  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));

  @override
  void addError(Object error, [StackTrace? stackTrace]) => destroy();

  @override
  Future<void> addStream(Stream<List<int>> stream) {
    if (_closed) throw StateError('StreamSink is closed');
    if (_bound) throw StateError('StreamSink is bound to a stream');
    _bound = true;
    final completer = Completer<void>();
    late StreamSubscription<List<int>> subscription;
    subscription = stream.listen(
      (data) {
        _connection._write(data);
        if (_connection._queuedBytes > _highWaterMark) {
          subscription.pause(_connection._drained());
        }
      },
      onError: (Object error, StackTrace stack) {
        _bound = false;
        completer.completeError(error, stack);
      },
      onDone: () {
        _bound = false;
        completer.complete();
      },
      cancelOnError: true,
    );
    _connection._onGone(() {
      if (completer.isCompleted) return;
      unawaited(subscription.cancel());
      _bound = false;
      completer.complete();
    });
    return completer.future;
  }

  @override
  Future<void> flush() => _connection._drained();

  @override
  Future<void> close() {
    if (!_closed) {
      _closed = true;
      _connection._closeAfterDetach();
    }
    return done;
  }

  @override
  Future<void> get done => _done.future;

  @override
  void destroy() {
    _closed = true;
    _connection._destroy();
  }

  @override
  bool setOption(SocketOption option, bool enabled) =>
      _connection._socket.setOption(option, enabled);

  @override
  Uint8List getRawOption(RawSocketOption option) =>
      _connection._socket.getRawOption(option);

  @override
  void setRawOption(RawSocketOption option) =>
      _connection._socket.setRawOption(option);

  @override
  int get port => _connection._localPort;

  @override
  InternetAddress get address => _connection._localAddress;

  @override
  InternetAddress get remoteAddress =>
      _connection._info?.remoteAddress ?? InternetAddress.loopbackIPv4;

  @override
  int get remotePort => _connection._info?.remotePort ?? 0;
}
