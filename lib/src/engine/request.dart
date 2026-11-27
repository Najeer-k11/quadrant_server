part of 'engine.dart';

/// An [HttpRequest] read by the engine.
///
/// Its body is this stream. As with dart:io, nothing past the header block is
/// read from the socket until the body is listened to.
class EngineRequest extends Stream<Uint8List> implements HttpRequest {
  final _Connection _connection;
  final _Head _head;
  late final StreamController<Uint8List> _body;

  @override
  late final EngineResponse response;

  EngineRequest._(this._connection, this._head) {
    _body = StreamController<Uint8List>(
      sync: true,
      onListen: _connection._onBodyListen,
      onResume: _connection._resumeReading,
      onCancel: _connection._onBodyCancel,
    );
    response = EngineResponse._(_connection, this);
  }

  /// The request target exactly as received, e.g. `/users?page=2`.
  String get target => _head.target;

  /// Header names (lower case) and values, alternating, in the order received.
  List<String> get headerPairs => _head.pairs;

  /// Whether a header named [name] (lower case) was sent. Cheaper than
  /// [headers], which builds a map on first use.
  bool hasHeader(String name) {
    final pairs = _head.pairs;
    for (var i = 0; i < pairs.length; i += 2) {
      if (pairs[i] == name) return true;
    }
    return false;
  }

  /// [uri]'s path, computed without building a [Uri] when the target is plain
  /// enough that `Uri.parse` would leave it as it is.
  String get path {
    final target = _head.target;
    if (!_isPlainTarget(target)) return uri.path;
    final question = target.indexOf('?');
    return question < 0 ? target : target.substring(0, question);
  }

  /// [uri]'s query, computed like [path].
  String get query {
    final target = _head.target;
    if (!_isPlainTarget(target)) return uri.query;
    final question = target.indexOf('?');
    return question < 0 ? '' : target.substring(question + 1);
  }

  @override
  String get method => _head.method;

  @override
  late final Uri uri = Uri.parse(_head.target);

  @override
  late final Uri requestedUri = _requestedUri();

  Uri _requestedUri() {
    final uri = this.uri;
    if (uri.hasScheme) return uri;
    final scheme = _connection._secure ? 'https' : 'http';
    final host = headers.value(HttpHeaders.hostHeader) ??
        '${_connection._localAddress.host}:${_connection._localPort}';
    return Uri.parse('$scheme://$host${_head.target}');
  }

  @override
  late final EngineHeaders headers = EngineHeaders._fromPairs(_head.pairs);

  @override
  int get contentLength => _head.chunked ? -1 : _head.contentLength;

  @override
  bool get persistentConnection => _head.keepAlive;

  @override
  String get protocolVersion => _head.http11 ? '1.1' : '1.0';

  @override
  HttpConnectionInfo? get connectionInfo => _connection._info;

  @override
  X509Certificate? get certificate => _connection._certificate;

  @override
  late final List<Cookie> cookies = _parseCookies();

  List<Cookie> _parseCookies() {
    final cookies = <Cookie>[];
    final pairs = _head.pairs;
    for (var i = 0; i < pairs.length; i += 2) {
      if (pairs[i] != HttpHeaders.cookieHeader) continue;
      for (final part in pairs[i + 1].split(';')) {
        final eq = part.indexOf('=');
        if (eq <= 0) continue;
        try {
          cookies.add(Cookie(part.substring(0, eq).trim(),
              _unquote(part.substring(eq + 1).trim())));
        } on FormatException {
          // Skipped, as dart:io does with a cookie it cannot parse.
        }
      }
    }
    return cookies;
  }

  static String _unquote(String value) =>
      value.length >= 2 && value.startsWith('"') && value.endsWith('"')
          ? value.substring(1, value.length - 1)
          : value;

  @override
  HttpSession get session => throw UnsupportedError(
      'Sessions are not supported by ServerEngine.quadrant.');

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _body.stream.listen(onData,
        onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }
}

/// Whether `Uri.parse(target)` would return [target] unchanged in its path
/// and query: an origin-form target with no percent-escapes, no dot segments,
/// and only characters a URI may hold as they are.
bool _isPlainTarget(String target) {
  if (target.isEmpty || target.codeUnitAt(0) != 0x2F) return false;
  if (target.length > 1 && target.codeUnitAt(1) == 0x2F) return false; // `//`
  var previous = 0;
  for (var i = 0; i < target.length; i++) {
    final c = target.codeUnitAt(i);
    if (c >= 128 || !_plainUriChar[c]) return false;
    if (c == 0x2E && previous == 0x2F) return false; // `/.`
    previous = c;
  }
  return true;
}

/// Unreserved characters, sub-delims, `:`, `@`, `/` and `?`.
final List<bool> _plainUriChar = () {
  final table = List<bool>.filled(128, false);
  for (final range in [
    [0x30, 0x39],
    [0x41, 0x5A],
    [0x61, 0x7A],
  ]) {
    for (var c = range[0]; c <= range[1]; c++) {
      table[c] = true;
    }
  }
  for (final c in "-._~!\$&'()*+,;=:@/?".codeUnits) {
    table[c] = true;
  }
  return table;
}();

/// The path and query [EngineRequest] computes for [target] without a [Uri],
/// or null when it would build one. For tests.
(String, String)? debugPlainTargetParts(String target) {
  if (!_isPlainTarget(target)) return null;
  final question = target.indexOf('?');
  return question < 0
      ? (target, '')
      : (target.substring(0, question), target.substring(question + 1));
}
