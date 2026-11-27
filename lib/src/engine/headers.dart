part of 'engine.dart';

/// [HttpHeaders] for the engine's requests and responses.
///
/// Names are stored in lower case, as dart:io does. A request's headers are
/// only turned into this map if something asks for `HttpRequest.headers`;
/// the framework itself reads the flat list the parser produced.
class EngineHeaders implements HttpHeaders {
  final Map<String, List<String>> _map = {};
  bool _mutable = true;

  /// Bumped on every change, so a cached encoding can tell it is stale.
  int _version = 0;

  bool _persistentConnection = true;

  EngineHeaders();

  EngineHeaders._fromPairs(List<String> pairs) {
    for (var i = 0; i < pairs.length; i += 2) {
      final name = pairs[i];
      final values = _map[name] ??= [];
      if (name == HttpHeaders.connectionHeader) {
        // One value per token, as dart:io does, so that the WebSocket upgrade
        // check finds `Upgrade` in `keep-alive, Upgrade`.
        for (final token in pairs[i + 1].split(',')) {
          final trimmed = token.trim();
          if (trimmed.isNotEmpty) values.add(trimmed);
        }
      } else {
        values.add(pairs[i + 1]);
      }
    }
    _mutable = false;
  }

  EngineHeaders._copy(EngineHeaders other) {
    other._map.forEach((name, values) => _map[name] = List.of(values));
  }

  void _checkMutable() {
    if (!_mutable) throw HttpException('HTTP headers are not mutable');
  }

  // ─── Core ────────────────────────────────────────────────────

  @override
  List<String>? operator [](String name) => _map[name.toLowerCase()];

  @override
  String? value(String name) {
    final values = _map[name.toLowerCase()];
    if (values == null) return null;
    if (values.length > 1) {
      throw HttpException('More than one value for header $name');
    }
    return values[0];
  }

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {
    _checkMutable();
    final key = _validateName(name);
    if (value is Iterable) {
      for (final v in value) {
        _addOne(key, v as Object);
      }
    } else {
      _addOne(key, value);
    }
  }

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _checkMutable();
    final key = _validateName(name);
    _map.remove(key);
    _version++;
    if (key == HttpHeaders.connectionHeader) _persistentConnection = true;
    add(key, value);
  }

  void _addOne(String key, Object value) {
    final string = _stringOf(value);
    _validateValue(string);
    if (key == HttpHeaders.contentLengthHeader) {
      // One value only, and it must be a number.
      if (int.tryParse(string) == null) {
        throw HttpException('Content-Length must be a number: $string');
      }
      _map[key] = [string];
    } else if (key == HttpHeaders.connectionHeader &&
        string.toLowerCase() == 'close') {
      _persistentConnection = false;
      (_map[key] ??= []).add(string);
    } else {
      (_map[key] ??= []).add(string);
    }
    _version++;
  }

  @override
  void remove(String name, Object value) {
    _checkMutable();
    final key = name.toLowerCase();
    final values = _map[key];
    if (values == null) return;
    values.remove(_stringOf(value));
    if (values.isEmpty) _map.remove(key);
    _version++;
  }

  @override
  void removeAll(String name) {
    _checkMutable();
    _map.remove(name.toLowerCase());
    _version++;
  }

  @override
  void forEach(void Function(String name, List<String> values) action) {
    _map.forEach(action);
  }

  @override
  void noFolding(String name) {}

  @override
  void clear() {
    _checkMutable();
    _map.clear();
    _version++;
  }

  // ─── Typed accessors ─────────────────────────────────────────

  @override
  int get contentLength {
    final value = _map[HttpHeaders.contentLengthHeader]?.first;
    return value == null ? -1 : int.tryParse(value) ?? -1;
  }

  @override
  set contentLength(int length) {
    _checkMutable();
    if (length < 0) {
      _map.remove(HttpHeaders.contentLengthHeader);
    } else {
      _map[HttpHeaders.contentLengthHeader] = ['$length'];
      if (chunkedTransferEncoding) chunkedTransferEncoding = false;
    }
    _version++;
  }

  @override
  bool get chunkedTransferEncoding =>
      _map[HttpHeaders.transferEncodingHeader]
          ?.any((v) => v.toLowerCase() == 'chunked') ??
      false;

  @override
  set chunkedTransferEncoding(bool chunked) {
    _checkMutable();
    if (chunked) {
      _map[HttpHeaders.transferEncodingHeader] = ['chunked'];
      _map.remove(HttpHeaders.contentLengthHeader);
    } else {
      _map.remove(HttpHeaders.transferEncodingHeader);
    }
    _version++;
  }

  @override
  bool get persistentConnection => _persistentConnection;

  @override
  set persistentConnection(bool persistent) {
    _checkMutable();
    _persistentConnection = persistent;
    _version++;
  }

  @override
  ContentType? get contentType {
    final value = _map[HttpHeaders.contentTypeHeader]?.first;
    return value == null ? null : ContentType.parse(value);
  }

  @override
  set contentType(ContentType? type) {
    if (type == null) {
      removeAll(HttpHeaders.contentTypeHeader);
    } else {
      set(HttpHeaders.contentTypeHeader, type.toString());
    }
  }

  @override
  String? get host {
    final value = _map[HttpHeaders.hostHeader]?.first;
    if (value == null) return null;
    final colon = _portColon(value);
    return colon < 0 ? value : value.substring(0, colon);
  }

  @override
  set host(String? host) {
    if (host == null) {
      removeAll(HttpHeaders.hostHeader);
    } else {
      final port = this.port;
      set(HttpHeaders.hostHeader, port == null ? host : '$host:$port');
    }
  }

  @override
  int? get port {
    final value = _map[HttpHeaders.hostHeader]?.first;
    if (value == null) return null;
    final colon = _portColon(value);
    return colon < 0 ? null : int.tryParse(value.substring(colon + 1));
  }

  @override
  set port(int? port) {
    final host = this.host;
    if (host == null) return;
    set(HttpHeaders.hostHeader, port == null ? host : '$host:$port');
  }

  /// The colon before the port, or -1. Skips the colons of an IPv6 literal.
  static int _portColon(String hostHeader) {
    final colon = hostHeader.lastIndexOf(':');
    if (colon < 0 || colon < hostHeader.lastIndexOf(']')) return -1;
    return colon;
  }

  @override
  DateTime? get date => _dateOf(HttpHeaders.dateHeader);
  @override
  set date(DateTime? date) => _setDate(HttpHeaders.dateHeader, date);

  @override
  DateTime? get expires => _dateOf(HttpHeaders.expiresHeader);
  @override
  set expires(DateTime? expires) =>
      _setDate(HttpHeaders.expiresHeader, expires);

  @override
  DateTime? get ifModifiedSince => _dateOf(HttpHeaders.ifModifiedSinceHeader);
  @override
  set ifModifiedSince(DateTime? ifModifiedSince) =>
      _setDate(HttpHeaders.ifModifiedSinceHeader, ifModifiedSince);

  DateTime? _dateOf(String name) {
    final value = _map[name]?.first;
    if (value == null) return null;
    try {
      return HttpDate.parse(value);
    } on Exception {
      return null;
    }
  }

  void _setDate(String name, DateTime? date) {
    if (date == null) {
      removeAll(name);
    } else {
      set(name, HttpDate.format(date.toUtc()));
    }
  }

  @override
  String toString() {
    final buffer = StringBuffer();
    _map.forEach((name, values) {
      for (final value in values) {
        buffer.write('$name: $value\n');
      }
    });
    return buffer.toString();
  }

  // ─── Validation ──────────────────────────────────────────────

  static String _stringOf(Object value) =>
      value is DateTime ? HttpDate.format(value.toUtc()) : value.toString();

  static String _validateName(String name) {
    if (name.isEmpty) throw const FormatException('Empty header name');
    for (var i = 0; i < name.length; i++) {
      final c = name.codeUnitAt(i);
      if (c > 127 || !_isTokenChar[c]) {
        throw FormatException('Invalid HTTP header field name: $name', name, i);
      }
    }
    return name.toLowerCase();
  }

  /// Rejects what would let a value end the header line early (response
  /// splitting) or that no HTTP peer accepts.
  static void _validateValue(String value) {
    for (var i = 0; i < value.length; i++) {
      final c = value.codeUnitAt(i);
      if ((c < 32 && c != 9) || c == 127) {
        throw FormatException('Invalid HTTP header field value', value, i);
      }
    }
  }
}

/// Characters allowed in a header name or method (RFC 9110 `token`).
final List<bool> _isTokenChar = () {
  final table = List<bool>.filled(128, false);
  for (var c = 0x21; c < 0x7F; c++) {
    table[c] = true;
  }
  for (final c in '"(),/:;<=>?@[\\]{}'.codeUnits) {
    table[c] = false;
  }
  return table;
}();
