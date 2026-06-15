import 'dart:io';

import 'package:quadrant_server/quadrant_server.dart';

final _startTime = DateTime.now();

// ─── Health handler ───────────────────────────────────────────

/// GET /health
///
/// Returns server health and uptime. No auth required.
Future<Response> getHealth(Request req) async {
  final uptime = DateTime.now().difference(_startTime);
  return Response.ok({
    'status': 'ok',
    'uptime': _formatDuration(uptime),
    'pid': pid,
    'dart': Platform.version,
  });
}

// ─── Info handler ─────────────────────────────────────────────

/// GET /api/v1/info
///
/// Returns API metadata. Demonstrates Response.ok with a nested map.
Future<Response> getInfo(Request req) async {
  return Response.ok({
    'name': 'QuadrantServer Example API',
    'version': '1.3.0',
    'environment': Platform.environment['APP_ENV'] ?? 'development',
    'endpoints': {
      'rest': '/api/v1',
      'websocket': '/ws',
      'docs': '/quadrant_docs',
      'health': '/health',
    },
  });
}

// ─── Echo handler ─────────────────────────────────────────────

/// POST /api/v1/echo
///
/// Echoes the request body back. Demonstrates bodyAsList support.
Future<Response> echo(Request req) async {
  if (req.body == null) {
    return Response.badRequest('Send a JSON body (object or array)');
  }
  return Response.ok({
    'method': req.method,
    'path': req.path,
    'query': req.query,
    'body': req.body,
    'bodyType': req.bodyAsMap != null ? 'object' : 'array',
  });
}

// ─── Redirect demo ────────────────────────────────────────────

/// GET /api
///
/// Redirects legacy /api → /api/v1/info.
Future<Response> redirectToV1(Request req) async {
  return Response.redirect('/api/v1/info');
}

// ─── Not found fallback ───────────────────────────────────────

/// Wildcard catch-all: GET /api/v1/unknown/*
Future<Response> notFoundFallback(Request req) async {
  return Response.notFound(
    'Endpoint "${req.path}" does not exist. '
    'Visit /quadrant_docs for the API reference.',
  );
}

// ─── Helpers ─────────────────────────────────────────────────

String _formatDuration(Duration d) {
  final h = d.inHours.toString().padLeft(2, '0');
  final m = (d.inMinutes % 60).toString().padLeft(2, '0');
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '${h}h ${m}m ${s}s';
}
