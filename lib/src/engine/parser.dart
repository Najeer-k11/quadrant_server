part of 'engine.dart';

const int _cr = 13;
const int _lf = 10;
const int _sp = 32;
const int _ht = 9;
const int _colon = 58;

/// A request the engine refuses before it reaches the framework. The
/// connection gets [status] and is closed.
class _HttpError implements Exception {
  final int status;
  final String message;
  const _HttpError(this.status, this.message);

  @override
  String toString() => 'HTTP $status: $message';
}

/// A parsed request line and header block.
class _Head {
  final String method;
  final String target;
  final bool http11;

  /// Lower-case name, value, name, value, …, in the order received.
  final List<String> pairs;

  /// From `content-length`, or -1 when there is none.
  final int contentLength;
  final bool chunked;
  final bool keepAlive;
  final bool expectContinue;

  const _Head(this.method, this.target, this.http11, this.pairs,
      this.contentLength, this.chunked, this.keepAlive, this.expectContinue);
}

/// Where the header block that starts at [start] ends: the index just after
/// its blank line, or -1 if it has not all arrived. [from] is where to resume
/// scanning, so a block arriving in small pieces is not rescanned each time.
///
/// Lines may end in CRLF or a bare LF, as dart:io accepts.
int _findHeadEnd(Uint8List b, int start, int from, int end) {
  for (var i = from < start ? start : from; i < end; i++) {
    if (b[i] != _lf) continue;
    final next = i + 1;
    if (next < end && b[next] == _lf) return next + 1;
    if (next + 1 < end && b[next] == _cr && b[next + 1] == _lf) {
      return next + 2;
    }
  }
  return -1;
}

/// Parses the head in `b[start, end)`, which [_findHeadEnd] has delimited.
_Head _parseHead(Uint8List b, int start, int end, int maxHeaders) {
  var lineEnd = _lineEnd(b, start, end);
  final contentEnd = _contentEnd(b, start, lineEnd);

  // ─── Request line: METHOD SP target SP HTTP/x.y ──────────────
  var i = start;
  while (i < contentEnd && b[i] < 128 && _isTokenChar[b[i]]) {
    i++;
  }
  if (i == start || i >= contentEnd || b[i] != _sp) {
    throw const _HttpError(400, 'Malformed request line');
  }
  final method = String.fromCharCodes(b, start, i);

  final targetStart = ++i;
  while (i < contentEnd && b[i] > _sp && b[i] < 127) {
    i++;
  }
  if (i == targetStart || i >= contentEnd || b[i] != _sp) {
    throw const _HttpError(400, 'Malformed request target');
  }
  final target = String.fromCharCodes(b, targetStart, i);

  final versionStart = i + 1;
  if (contentEnd - versionStart != 8 ||
      b[versionStart] != 0x48 || // H
      b[versionStart + 1] != 0x54 || // T
      b[versionStart + 2] != 0x54 || // T
      b[versionStart + 3] != 0x50 || // P
      b[versionStart + 4] != 0x2F || // /
      b[versionStart + 6] != 0x2E) {
    throw const _HttpError(400, 'Malformed HTTP version');
  }
  final major = b[versionStart + 5];
  final minor = b[versionStart + 7];
  if (major != 0x31 || (minor != 0x31 && minor != 0x30)) {
    throw const _HttpError(505, 'HTTP version not supported');
  }
  final http11 = minor == 0x31;

  // ─── Header lines ────────────────────────────────────────────
  final pairs = <String>[];
  var contentLength = -1;
  var chunked = false;
  var transferEncoding = false;
  var connectionClose = false;
  var connectionKeepAlive = false;
  var expectContinue = false;

  var lineStart = lineEnd + 1;
  while (lineStart < end) {
    lineEnd = _lineEnd(b, lineStart, end);
    final lineContentEnd = _contentEnd(b, lineStart, lineEnd);
    if (lineContentEnd == lineStart) break; // The blank line.

    final first = b[lineStart];
    if (first == _sp || first == _ht) {
      throw const _HttpError(400, 'Obsolete line folding is not accepted');
    }
    var colon = lineStart;
    while (colon < lineContentEnd && b[colon] < 128 && _isTokenChar[b[colon]]) {
      colon++;
    }
    if (colon == lineStart || colon >= lineContentEnd || b[colon] != _colon) {
      throw const _HttpError(400, 'Malformed header line');
    }

    var valueStart = colon + 1;
    while (valueStart < lineContentEnd &&
        (b[valueStart] == _sp || b[valueStart] == _ht)) {
      valueStart++;
    }
    var valueEnd = lineContentEnd;
    while (valueEnd > valueStart &&
        (b[valueEnd - 1] == _sp || b[valueEnd - 1] == _ht)) {
      valueEnd--;
    }
    for (var j = valueStart; j < valueEnd; j++) {
      final c = b[j];
      if ((c < _sp && c != _ht) || c == 127) {
        throw const _HttpError(400, 'Invalid character in header value');
      }
    }

    if (pairs.length >= maxHeaders * 2) {
      throw const _HttpError(431, 'Too many header fields');
    }
    final name = _headerName(b, lineStart, colon);
    final value = String.fromCharCodes(b, valueStart, valueEnd);
    pairs
      ..add(name)
      ..add(value);

    switch (name) {
      case 'content-length':
        final length = _parseContentLength(value);
        if (contentLength >= 0 && contentLength != length) {
          throw const _HttpError(400, 'Conflicting Content-Length headers');
        }
        contentLength = length;
      case 'transfer-encoding':
        // Only `chunked`, and only once: anything else could be read
        // differently by a proxy in front, which is how requests get
        // smuggled.
        if (transferEncoding || value.toLowerCase() != 'chunked') {
          throw const _HttpError(501, 'Unsupported Transfer-Encoding');
        }
        transferEncoding = true;
        chunked = true;
      case 'connection':
        for (final token in value.split(',')) {
          final t = token.trim().toLowerCase();
          if (t == 'close') connectionClose = true;
          if (t == 'keep-alive') connectionKeepAlive = true;
        }
      case 'expect':
        if (value.toLowerCase() == '100-continue') expectContinue = true;
    }

    lineStart = lineEnd + 1;
  }

  if (chunked && contentLength >= 0) {
    throw const _HttpError(
        400, 'Both Content-Length and Transfer-Encoding are set');
  }

  final keepAlive = http11 ? !connectionClose : connectionKeepAlive;
  return _Head(method, target, http11, pairs, contentLength, chunked, keepAlive,
      expectContinue);
}

/// Index of the LF ending the line that starts at [start].
int _lineEnd(Uint8List b, int start, int end) {
  for (var i = start; i < end; i++) {
    if (b[i] == _lf) return i;
  }
  return end;
}

/// End of the line's content: before its CR, if it has one. A CR anywhere
/// else is refused, since peers disagree on what it means.
int _contentEnd(Uint8List b, int start, int lineEnd) {
  final contentEnd =
      lineEnd > start && b[lineEnd - 1] == _cr ? lineEnd - 1 : lineEnd;
  for (var i = start; i < contentEnd; i++) {
    if (b[i] == _cr) throw const _HttpError(400, 'Bare CR in header block');
  }
  return contentEnd;
}

/// The header name in lower case, reusing the string for common names.
String _headerName(Uint8List b, int start, int end) {
  final name = String.fromCharCodes(b, start, end);
  for (var i = 0; i < name.length; i++) {
    final c = name.codeUnitAt(i);
    if (c >= 0x41 && c <= 0x5A) return name.toLowerCase();
  }
  return name;
}

int _parseContentLength(String value) {
  if (value.isEmpty || value.length > 15) {
    throw const _HttpError(400, 'Invalid Content-Length');
  }
  var length = 0;
  for (var i = 0; i < value.length; i++) {
    final digit = value.codeUnitAt(i) - 0x30;
    if (digit < 0 || digit > 9) {
      throw const _HttpError(400, 'Invalid Content-Length');
    }
    length = length * 10 + digit;
  }
  return length;
}

// ─── Chunked request bodies ──────────────────────────────────

const int _chunkSize = 0;
const int _chunkSizeLf = 1;
const int _chunkExtension = 2;
const int _chunkData = 3;
const int _chunkDataCr = 4;
const int _chunkDataLf = 5;
const int _chunkTrailerLineStart = 6;
const int _chunkTrailerLine = 7;
const int _chunkTrailerEndLf = 8;
const int _chunkDone = 9;

/// Decodes a `transfer-encoding: chunked` body as it arrives. Trailers are
/// read and discarded, as dart:io does.
class _ChunkedDecoder {
  int _state = _chunkSize;
  int _size = 0;
  int _digits = 0;
  int _extensionBytes = 0;
  int _trailerBytes = 0;

  bool get isDone => _state == _chunkDone;

  /// Consumes bytes from `b[start, end)`, passing chunk data to [emit].
  /// Returns where it stopped: [end], or just after the body once [isDone].
  int feed(Uint8List b, int start, int end, void Function(Uint8List) emit) {
    var i = start;
    while (i < end) {
      switch (_state) {
        case _chunkSize:
          final c = b[i++];
          final digit = _hexValue(c);
          if (digit >= 0) {
            if (++_digits > 15) throw const _HttpError(400, 'Chunk too large');
            _size = _size * 16 + digit;
          } else if (_digits == 0) {
            throw const _HttpError(400, 'Malformed chunk size');
          } else if (c == _cr) {
            _state = _chunkSizeLf;
          } else if (c == _lf) {
            _endSizeLine();
          } else if (c == 0x3B || c == _sp || c == _ht) {
            // `;` starts an extension; whitespace may precede it.
            _state = _chunkExtension;
          } else {
            throw const _HttpError(400, 'Malformed chunk size');
          }
        case _chunkSizeLf:
          if (b[i++] != _lf) throw const _HttpError(400, 'Malformed chunk');
          _endSizeLine();
        case _chunkExtension:
          final c = b[i++];
          if (c == _lf) {
            _endSizeLine();
          } else if (c == _cr) {
            _state = _chunkSizeLf;
          } else if (++_extensionBytes > 4096) {
            throw const _HttpError(400, 'Chunk extension too long');
          }
        case _chunkData:
          final available = end - i;
          final n = available < _size ? available : _size;
          emit(Uint8List.sublistView(b, i, i + n));
          i += n;
          _size -= n;
          if (_size == 0) _state = _chunkDataCr;
        case _chunkDataCr:
          final c = b[i++];
          if (c == _cr) {
            _state = _chunkDataLf;
          } else if (c == _lf) {
            _state = _chunkSize;
          } else {
            throw const _HttpError(400, 'Missing CRLF after chunk');
          }
        case _chunkDataLf:
          if (b[i++] != _lf) {
            throw const _HttpError(400, 'Missing CRLF after chunk');
          }
          _state = _chunkSize;
        case _chunkTrailerLineStart:
          final c = b[i++];
          if (c == _lf) {
            _state = _chunkDone;
            return i;
          } else if (c == _cr) {
            _state = _chunkTrailerEndLf;
          } else {
            _countTrailer();
            _state = _chunkTrailerLine;
          }
        case _chunkTrailerLine:
          final c = b[i++];
          _countTrailer();
          if (c == _lf) _state = _chunkTrailerLineStart;
        case _chunkTrailerEndLf:
          if (b[i++] != _lf) throw const _HttpError(400, 'Malformed trailer');
          _state = _chunkDone;
          return i;
        case _chunkDone:
          return i;
      }
    }
    return i;
  }

  void _endSizeLine() {
    _digits = 0;
    _extensionBytes = 0;
    _state = _size == 0 ? _chunkTrailerLineStart : _chunkData;
  }

  void _countTrailer() {
    if (++_trailerBytes > 8192) {
      throw const _HttpError(431, 'Trailer section too large');
    }
  }

  static int _hexValue(int c) {
    if (c >= 0x30 && c <= 0x39) return c - 0x30;
    if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
    if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;
    return -1;
  }
}
