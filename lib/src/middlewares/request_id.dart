import 'dart:math';

import '../core/middleware.dart';
import '../core/request.dart';

/// Request ID middleware.
///
/// Assigns a unique identifier to every request and exposes it via:
/// - `req.context['requestId']` — available to all downstream middlewares/handlers
/// - `X-Request-ID` response header — returned to the client for distributed tracing
///
/// If the incoming request already carries an `X-Request-ID` header (forwarded
/// by an upstream proxy or API gateway), that value is reused and echoed back.
/// This enables end-to-end tracing across service boundaries.
///
/// ```dart
/// middlewares: [requestId(), logger()]
///
/// // In a handler:
/// final id = req.context['requestId'] as String;
/// print('Handling request $id');
/// ```
///
/// [headerName] — name of the request/response header. Defaults to `'x-request-id'`.
/// [contextKey] — key under which the ID is stored in [Request.context]. Defaults to `'requestId'`.
Middleware requestId({
  String headerName = 'x-request-id',
  String contextKey = 'requestId',
}) {
  return (Request req, Next next) async {
    // Reuse an upstream ID if present, otherwise generate a new UUID v4.
    final id = req.headers[headerName] ?? _uuid();

    // Inject into context via the shared Expando so _executeChain propagates it.
    _requestIdOverrides[req.raw] = {...req.context, contextKey: id};

    final response = await next();

    _requestIdOverrides[req.raw] = null;

    // Append the ID to the response headers.
    return response.copyWith(headers: {...response.headers, headerName: id});
  };
}

// ─── UUID v4 generator (no external dependencies) ────────────

/// Generates a random UUID v4 string.
///
/// The bits come from xorshift128+, seeded once per isolate from
/// [Random.secure]. That is about 40 times faster than four calls to the
/// secure generator, each of which goes into native code. A request ID needs
/// to be unique, not unguessable: with 128 bits of seeded state, isolates and
/// processes do not repeat each other's IDs. Do not use these IDs as secrets.
String _uuid() {
  final a = _next();
  final b = _next();
  final out = _uuidChars;
  var o = 0;
  void hex(int byte) {
    out[o++] = _hexDigits[byte >> 4];
    out[o++] = _hexDigits[byte & 0x0f];
  }

  for (var i = 0; i < 16; i++) {
    if (i == 4 || i == 6 || i == 8 || i == 10) out[o++] = 0x2d; // -
    final word = i < 8 ? a : b;
    var byte = (word >>> ((i & 7) * 8)) & 0xff;
    if (i == 6) byte = byte & 0x0f | 0x40; // version 4
    if (i == 8) byte = byte & 0x3f | 0x80; // variant 1
    hex(byte);
  }
  return String.fromCharCodes(out);
}

final _uuidChars = List<int>.filled(36, 0);
const _hexDigits = [
  0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, //
  0x38, 0x39, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66,
];

int _s0 = _seed();
int _s1 = _seed() | 1; // The state must not be all zeros.

int _seed() {
  final secure = Random.secure();
  return secure.nextInt(1 << 32) << 32 | secure.nextInt(1 << 32);
}

/// xorshift128+: 64 random bits.
int _next() {
  var x = _s0;
  final y = _s1;
  _s0 = y;
  x ^= x << 23;
  x ^= x >>> 17;
  x ^= y ^ (y >>> 26);
  _s1 = x;
  return x + y;
}

// ─── Context propagation ──────────────────────────────────────

final _requestIdOverrides =
    Expando<Map<String, dynamic>>('quadrant_request_id');

/// Internal — consumed by [QuadrantServer._executeChain].
Map<String, dynamic>? consumeRequestIdContext(Object rawRequest) {
  final val = _requestIdOverrides[rawRequest];
  if (val != null) _requestIdOverrides[rawRequest] = null;
  return val;
}
