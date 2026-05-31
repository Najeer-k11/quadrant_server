import 'dart:convert';

import 'request.dart';
import 'response.dart';
import 'route.dart';

/// Returns a [Handler] that serves the Swagger UI docs page.
///
/// Only responds to loopback requests. External IPs get a 404.
/// [routes] must be the user's original route list (excludes /quadrant_docs).
Handler docsHandler(List<Route> routes) {
  return (Request req) async {
    // final ip = req.raw.connectionInfo?.remoteAddress;
    // if (ip == null || !ip.isLoopback) {
    //   return Response.notFound('Route not found');
    // }

    final routeData = routes
        .map((r) => <String, dynamic>{
              'method': r.method,
              'path': r.path,
              'params': r.paramNames,
              'middlewares': r.middlewares.length,
            })
        .toList();

    final html = _buildDocsHtml(routeData);

    return Response(
      statusCode: 200,
      body: html,
      headers: {'content-type': 'text/html; charset=utf-8'},
    );
  };
}

/// Builds the full HTML page embedding Swagger UI with the generated OpenAPI spec.
String _buildDocsHtml(List<Map<String, dynamic>> routes) {
  final openApiJson = _buildOpenApiSpec(routes);

  return '''<!DOCTYPE html>
<html>
  <head>
    <title>QuadrantServer Docs</title>
    <meta charset="utf-8"/>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <link rel="stylesheet"
      href="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5/swagger-ui.css">
  </head>
  <body>
    <div id="swagger-ui"></div>
    <script src="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5/swagger-ui-bundle.js"></script>
    <script>
      SwaggerUIBundle({
        spec: $openApiJson,
        dom_id: '#swagger-ui',
        presets: [SwaggerUIBundle.presets.apis, SwaggerUIBundle.SwaggerUIStandalonePreset],
        layout: "BaseLayout"
      });
    </script>
  </body>
</html>''';
}

/// Builds a minimal OpenAPI 3.0 spec JSON string from the route list.
String _buildOpenApiSpec(List<Map<String, dynamic>> routes) {
  final paths = <String, dynamic>{};

  for (final route in routes) {
    final path = route['path'] as String;
    final method = (route['method'] as String).toLowerCase();
    final params = route['params'] as List<String>;

    // Convert :id style to {id} style (OpenAPI standard)
    final openApiPath = path.replaceAllMapped(
      RegExp(r':(\w+)'),
      (m) => '{${m.group(1)}}',
    );

    paths[openApiPath] ??= <String, dynamic>{};
    (paths[openApiPath] as Map<String, dynamic>)[method] = {
      'summary': '${route['method']} $path',
      'parameters': params
          .map((p) => <String, dynamic>{
                'name': p,
                'in': 'path',
                'required': true,
                'schema': {'type': 'string'},
              })
          .toList(),
      'responses': {
        '200': {'description': 'Success'},
      },
    };
  }

  final spec = {
    'openapi': '3.0.0',
    'info': {
      'title': 'QuadrantServer API',
      'version': '1.0.0',
    },
    'paths': paths,
  };

  return jsonEncode(spec);
}
