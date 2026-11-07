import 'dart:io';

import 'package:quadrant_server/quadrant_server.dart';

/// GET /api/v1/info
Future<Response> getInfo(Request req) async {
  return Response.ok({
    'name': 'QuadrantServer Example API',
    'environment': Platform.environment['APP_ENV'] ?? 'development',
    'endpoints': {
      'rest': '/api/v1',
      'websocket': '/ws',
      'health': '/health',
    },
  });
}

/// POST /api/v1/echo, which echoes a JSON object or array.
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

/// GET /api, which redirects to the current version.
Future<Response> redirectToV1(Request req) async {
  return Response.redirect('/api/v1/info');
}
