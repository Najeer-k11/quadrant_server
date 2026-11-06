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

final _rng = Random.secure();

final _hexByte = [
  for (var i = 0; i < 256; i++) i.toRadixString(16).padLeft(2, '0'),
];

/// Generates a random UUID v4 string.
///
/// Each call to the secure generator is expensive, so it takes four 32-bit
/// values rather than sixteen single bytes.
String _uuid() {
  final a = _rng.nextInt(_twoTo32);
  final b = _rng.nextInt(_twoTo32);
  final c = _rng.nextInt(_twoTo32);
  final d = _rng.nextInt(_twoTo32);

  String h(int word, int shift) => _hexByte[(word >> shift) & 0xff];
  final version = (b >> 8) & 0x0f | 0x40; // version 4
  final variant = (c >> 24) & 0x3f | 0x80; // variant 1

  return '${h(a, 24)}${h(a, 16)}${h(a, 8)}${h(a, 0)}'
      '-${h(b, 24)}${h(b, 16)}'
      '-${_hexByte[version]}${h(b, 0)}'
      '-${_hexByte[variant]}${h(c, 16)}'
      '-${h(c, 8)}${h(c, 0)}${h(d, 24)}${h(d, 16)}${h(d, 8)}${h(d, 0)}';
}

const _twoTo32 = 1 << 32;

// ─── Context propagation ──────────────────────────────────────

final _requestIdOverrides =
    Expando<Map<String, dynamic>>('quadrant_request_id');

/// Internal — consumed by [QuadrantServer._executeChain].
Map<String, dynamic>? consumeRequestIdContext(Object rawRequest) {
  final val = _requestIdOverrides[rawRequest];
  if (val != null) _requestIdOverrides[rawRequest] = null;
  return val;
}
