// Closed-loop HTTP/1.1 keep-alive load generator: each connection sends one
// request, waits for the full response, then sends the next.
//
// Usage: loader <port> <connections> <warmupMs> <durationMs> <method> <path> <bodyBytes>
//
// Prints one JSON object with the counts for the measured window. Run several
// processes rather than isolates: isolates in a process share one I/O thread.
//
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const _maxLatencyUs = 1000000;

final _clock = Stopwatch()..start();
final _histogram = Int32List(_maxLatencyUs + 1);
final _connections = <_Connection>[];
var _recording = false;
var _running = true;
var _completed = 0;
var _errors = 0;
var _non2xx = 0;
late Uint8List _request;

Future<void> main(List<String> args) async {
  final port = int.parse(args[0]);
  final connections = int.parse(args[1]);
  final warmupMs = int.parse(args[2]);
  final durationMs = int.parse(args[3]);
  final method = args[4];
  final path = args[5];
  final bodyBytes = int.parse(args[6]);

  final body = bodyBytes > 0 ? _jsonBody(bodyBytes) : '';
  _request = ascii.encode('$method $path HTTP/1.1\r\n'
      'Host: localhost\r\n'
      'Accept: */*\r\n'
      'User-Agent: quadrant-bench\r\n'
      '${bodyBytes > 0 ? 'Content-Type: application/json\r\n'
          'Content-Length: ${body.length}\r\n' : ''}'
      '\r\n'
      '$body');

  for (var i = 0; i < connections; i++) {
    final socket = await RawSocket.connect(InternetAddress.loopbackIPv4, port);
    socket.setOption(SocketOption.tcpNoDelay, true);
    socket.writeEventsEnabled = false;
    _connections.add(_Connection(socket)..send());
  }

  await Future<void>.delayed(Duration(milliseconds: warmupMs));
  final cpuStart = _cpuSeconds();
  _recording = true;
  await Future<void>.delayed(Duration(milliseconds: durationMs));
  _recording = false;
  _running = false;
  final cpuSeconds = _cpuSeconds() - cpuStart;

  final latency = <String, int>{};
  for (var us = 0; us < _histogram.length; us++) {
    if (_histogram[us] > 0) latency['$us'] = _histogram[us];
  }
  print(jsonEncode({
    'completed': _completed,
    'errors': _errors,
    'non2xx': _non2xx,
    'cpuSeconds': cpuSeconds,
    'latency': latency,
  }));
  await stderr.flush();
  exit(0);
}

String _jsonBody(int size) {
  const prefix = '{"data":"';
  const suffix = '"}';
  return '$prefix${'x' * (size - prefix.length - suffix.length)}$suffix';
}

/// CPU seconds used so far by this process, from /proc (ticks are 1/100 s).
double _cpuSeconds() {
  final stat = File('/proc/self/stat').readAsStringSync();
  final fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
  return (int.parse(fields[11]) + int.parse(fields[12])) / 100;
}

class _Connection {
  final RawSocket socket;
  Uint8List? _pending;
  int _startUs = 0;

  _Connection(this.socket) {
    socket.listen(_onEvent, onError: (Object _) => _fail());
  }

  void send() {
    _startUs = _clock.elapsedMicroseconds;
    if (socket.write(_request) != _request.length) _fail();
  }

  void _onEvent(RawSocketEvent event) {
    if (event == RawSocketEvent.read) {
      final chunk = socket.read();
      if (chunk != null) _onData(chunk);
    } else if (event == RawSocketEvent.readClosed) {
      _fail();
    }
  }

  void _onData(Uint8List chunk) {
    final pending = _pending;
    final buffer = pending == null
        ? chunk
        : (BytesBuilder(copy: false)
              ..add(pending)
              ..add(chunk))
            .takeBytes();

    final headerEnd = _findHeaderEnd(buffer);
    if (headerEnd < 0) {
      _pending = buffer;
      return;
    }
    final length = _contentLength(buffer, headerEnd);
    final complete = length >= 0
        ? buffer.length >= headerEnd + 4 + length
        : _endsLastChunk(buffer, headerEnd + 4);
    if (!complete) {
      _pending = buffer;
      return;
    }
    _pending = null;

    if (_recording) {
      final us = _clock.elapsedMicroseconds - _startUs;
      _histogram[us < _maxLatencyUs ? us : _maxLatencyUs]++;
      _completed++;
      if (buffer[9] != 0x32) {
        // First digit of the status code. Keep one sample for diagnosis.
        if (_non2xx++ == 0) stderr.writeln(latin1.decode(buffer));
      }
    }
    if (_running) send();
  }

  void _fail() {
    if (_running) _errors++;
    socket.close();
  }
}

int _findHeaderEnd(Uint8List b) {
  for (var i = 0; i + 3 < b.length; i++) {
    if (b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10) {
      return i;
    }
  }
  return -1;
}

/// True when a chunked body has ended. dart:io sends a response chunked unless
/// it has a Content-Length, so the body must end with the last-chunk marker.
/// Only the body counts: a header value ending in `0` can look the same.
bool _endsLastChunk(Uint8List b, int bodyStart) {
  final n = b.length;
  return n - bodyStart >= 5 &&
      b[n - 5] == 48 &&
      b[n - 4] == 13 &&
      b[n - 3] == 10 &&
      b[n - 2] == 13 &&
      b[n - 1] == 10;
}

final _lengthHeader = ascii.encode('\r\ncontent-length:');

/// Returns the Content-Length value, or -1 when the header is missing.
int _contentLength(Uint8List b, int headerEnd) {
  outer:
  for (var i = 0; i + _lengthHeader.length < headerEnd; i++) {
    for (var j = 0; j < _lengthHeader.length; j++) {
      final c = b[i + j];
      final lower = c >= 65 && c <= 90 ? c + 32 : c;
      if (lower != _lengthHeader[j]) continue outer;
    }
    var value = 0;
    for (var k = i + _lengthHeader.length; k < headerEnd; k++) {
      final c = b[k];
      if (c == 13) break;
      if (c >= 48 && c <= 57) value = value * 10 + c - 48;
    }
    return value;
  }
  return -1;
}
