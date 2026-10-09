import 'dart:math';

import '../middleware.dart';
import '../request.dart';

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

/// Generates a random UUID v4 string.
String _uuid() {
  final b = List<int>.generate(16, (_) => _rng.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40; // version 4
  b[8] = (b[8] & 0x3f) | 0x80; // variant 1

  String h(int n) => n.toRadixString(16).padLeft(2, '0');
  return '${h(b[0])}${h(b[1])}${h(b[2])}${h(b[3])}'
      '-${h(b[4])}${h(b[5])}'
      '-${h(b[6])}${h(b[7])}'
      '-${h(b[8])}${h(b[9])}'
      '-${h(b[10])}${h(b[11])}${h(b[12])}${h(b[13])}${h(b[14])}${h(b[15])}';
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
