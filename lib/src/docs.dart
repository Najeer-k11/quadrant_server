import 'dart:convert';

import 'request.dart';
import 'response.dart';
import 'route.dart';
import 'websocket_route.dart';

/// Returns a [Handler] that serves the Swagger UI docs page.
///
/// Only responds to loopback requests. External IPs get a 404.
/// [routes] must be the user's original route list (excludes /quadrant_docs).
/// [webSocketRoutes] are rendered in a separate section below Swagger UI.
Handler docsHandler(List<Route> routes,
    {List<WebSocketRoute> webSocketRoutes = const []}) {
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

    final html = _buildDocsHtml(routeData, webSocketRoutes);

    return Response(
      statusCode: 200,
      body: html,
      headers: {'content-type': 'text/html; charset=utf-8'},
    );
  };
}

/// Builds the full HTML page embedding Swagger UI with the generated OpenAPI spec.
String _buildDocsHtml(
    List<Map<String, dynamic>> routes, List<WebSocketRoute> wsRoutes) {
  final openApiJson = _buildOpenApiSpec(routes);
  final wsSection = wsRoutes.isEmpty ? '' : _buildWebSocketSection(wsRoutes);

  return '''<!DOCTYPE html>
<html>
  <head>
    <title>QuadrantServer Docs</title>
    <meta charset="utf-8"/>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <link rel="stylesheet"
      href="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5/swagger-ui.css">
    <style>
      .code-samples { margin: 1rem 0; padding: 0 1rem; }
      .code-samples summary { cursor: pointer; font-weight: 600; color: #333; margin-bottom: 0.5rem; }
      .code-samples pre { background: #1e1e1e; color: #d4d4d4; padding: 1rem; border-radius: 6px; overflow-x: auto; font-size: 0.85rem; margin: 0.25rem 0; }
      .code-samples .tab-bar { display: flex; gap: 0; border-bottom: 2px solid #ddd; margin-bottom: 0.5rem; }
      .code-samples .tab-btn { padding: 0.4rem 1rem; border: none; background: transparent; cursor: pointer; font-size: 0.85rem; border-bottom: 2px solid transparent; margin-bottom: -2px; }
      .code-samples .tab-btn.active { border-bottom-color: #61affe; color: #61affe; font-weight: 600; }
      .code-samples .tab-content { display: none; }
      .code-samples .tab-content.active { display: block; }
    </style>
  </head>
  <body>
    <div id="swagger-ui"></div>
    <script src="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5/swagger-ui-bundle.js"></script>
    <script>
      const spec = $openApiJson;

      // Custom plugin to render x-codeSamples below each operation
      const CodeSamplesPlugin = () => ({
        wrapComponents: {
          response: (Original, system) => (props) => {
            const React = system.React;
            const el = React.createElement;
            const operation = props.specSelectors?.operationWithMeta?.() || null;
            return el('div', null, el(Original, props));
          }
        }
      });

      SwaggerUIBundle({
        spec: spec,
        dom_id: '#swagger-ui',
        presets: [SwaggerUIBundle.presets.apis, SwaggerUIBundle.SwaggerUIStandalonePreset],
        layout: "BaseLayout"
      });

      // After Swagger UI renders, inject code sample tabs into each operation
      setTimeout(() => {
        const paths = spec.paths || {};
        Object.keys(paths).forEach(path => {
          Object.keys(paths[path]).forEach(method => {
            const op = paths[path][method];
            const samples = op['x-codeSamples'];
            if (!samples || !samples.length) return;

            // Find the matching operation block in the DOM
            const opId = method + '-' + path.replace(/[{}]/g, '_').replace(/\\//g, '_');
            const opBlocks = document.querySelectorAll('.opblock');
            for (const block of opBlocks) {
              const summary = block.querySelector('.opblock-summary-path');
              const methodEl = block.querySelector('.opblock-summary-method');
              if (!summary || !methodEl) continue;
              const blockPath = summary.textContent.trim().replace(/\\s/g, '');
              const blockMethod = methodEl.textContent.trim().toLowerCase();
              if (blockPath === path && blockMethod === method) {
                // Only inject once
                if (block.querySelector('.code-samples')) break;
                const container = document.createElement('div');
                container.className = 'code-samples';

                const tabBar = document.createElement('div');
                tabBar.className = 'tab-bar';

                const contents = [];
                samples.forEach((sample, i) => {
                  const btn = document.createElement('button');
                  btn.className = 'tab-btn' + (i === 0 ? ' active' : '');
                  btn.textContent = sample.lang;
                  btn.onclick = () => {
                    tabBar.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
                    btn.classList.add('active');
                    contents.forEach((c, j) => c.classList.toggle('active', j === i));
                  };
                  tabBar.appendChild(btn);

                  const content = document.createElement('div');
                  content.className = 'tab-content' + (i === 0 ? ' active' : '');
                  const pre = document.createElement('pre');
                  pre.textContent = sample.source;
                  content.appendChild(pre);
                  contents.push(content);
                });

                container.appendChild(tabBar);
                contents.forEach(c => container.appendChild(c));

                const body = block.querySelector('.opblock-body');
                if (body) {
                  body.insertBefore(container, body.firstChild);
                } else {
                  block.appendChild(container);
                }
                break;
              }
            }
          });
        });
      }, 1500);
    </script>
$wsSection
  </body>
</html>''';
}

/// Builds the WebSocket endpoints HTML section.
String _buildWebSocketSection(List<WebSocketRoute> wsRoutes) {
  final rows = wsRoutes.map(_wsRouteRow).join('\n');

  return '''
    <section id="ws-routes" style="font-family: inherit; padding: 2rem; border-top: 1px solid #ddd;">
      <h2 style="font-size: 1.25rem; margin-bottom: 1rem;">WebSocket Endpoints</h2>
      <table style="width: 100%; border-collapse: collapse;">
        <thead>
          <tr>
            <th style="text-align:left; padding: 0.5rem; border-bottom: 2px solid #ddd;">Path</th>
            <th style="text-align:left; padding: 0.5rem; border-bottom: 2px solid #ddd;">Callbacks</th>
            <th style="text-align:left; padding: 0.5rem; border-bottom: 2px solid #ddd;">Middlewares</th>
          </tr>
        </thead>
        <tbody>
$rows
        </tbody>
      </table>
    </section>''';
}

/// Generates a single table row for a WebSocket route.
String _wsRouteRow(WebSocketRoute ws) {
  final callbacks = [
    if (ws.onStart != null) 'onStart',
    'onMessage',
    if (ws.onClose != null) 'onClose',
    if (ws.onError != null) 'onError',
  ].join(', ');

  final middlewareCount =
      ws.middlewares.isEmpty ? '\u2014' : '${ws.middlewares.length}';

  return '''
          <tr>
            <td style="padding:0.5rem;border-bottom:1px solid #eee;">
              <code>ws://&lt;host&gt;${ws.path}</code>
            </td>
            <td style="padding:0.5rem;border-bottom:1px solid #eee;">$callbacks</td>
            <td style="padding:0.5rem;border-bottom:1px solid #eee;">$middlewareCount</td>
          </tr>''';
}

/// Builds a minimal OpenAPI 3.0 spec JSON string from the route list.
/// Includes auto-generated x-codeSamples for Dart, cURL, JavaScript, and Python.
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
      'x-codeSamples': _generateCodeSamples(method, openApiPath, params),
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

/// Generates auto-generated code samples for Dart, cURL, JavaScript, and Python.
List<Map<String, String>> _generateCodeSamples(
    String method, String openApiPath, List<String> params) {
  // Build a sample URL with placeholder values for path params.
  final samplePath = openApiPath.replaceAllMapped(
    RegExp(r'\{(\w+)\}'),
    (m) => '<${m.group(1)}>',
  );
  final upperMethod = method.toUpperCase();

  final hasBody =
      upperMethod == 'POST' || upperMethod == 'PUT' || upperMethod == 'PATCH';

  return [
    {'lang': 'cURL', 'source': _curlSample(upperMethod, samplePath, hasBody)},
    {'lang': 'Dart', 'source': _dartSample(upperMethod, samplePath, hasBody)},
    {
      'lang': 'JavaScript',
      'source': _jsSample(upperMethod, samplePath, hasBody)
    },
    {
      'lang': 'Python',
      'source': _pythonSample(upperMethod, samplePath, hasBody)
    },
  ];
}

String _curlSample(String method, String path, bool hasBody) {
  final buf = StringBuffer("curl -X $method 'http://localhost:3000$path'");
  if (hasBody) {
    buf.write(
        " \\\n  -H 'Content-Type: application/json' \\\n  -d '{\"key\": \"value\"}'");
  }
  return buf.toString();
}

String _dartSample(String method, String path, bool hasBody) {
  final buf = StringBuffer();
  buf.writeln("import 'package:http/http.dart' as http;");
  buf.writeln();
  buf.writeln("final url = Uri.parse('http://localhost:3000$path');");

  if (hasBody) {
    buf.writeln("final response = await http.${method.toLowerCase()}(");
    buf.writeln("  url,");
    buf.writeln("  headers: {'Content-Type': 'application/json'},");
    buf.writeln("  body: jsonEncode({'key': 'value'}),");
    buf.writeln(");");
  } else {
    buf.writeln("final response = await http.${method.toLowerCase()}(url);");
  }

  buf.writeln("print(response.body);");
  return buf.toString();
}

String _jsSample(String method, String path, bool hasBody) {
  final buf = StringBuffer();
  buf.writeln("const response = await fetch('http://localhost:3000$path', {");
  buf.writeln("  method: '$method',");
  if (hasBody) {
    buf.writeln("  headers: { 'Content-Type': 'application/json' },");
    buf.writeln("  body: JSON.stringify({ key: 'value' }),");
  }
  buf.writeln("});");
  buf.writeln("const data = await response.json();");
  buf.writeln("console.log(data);");
  return buf.toString();
}

String _pythonSample(String method, String path, bool hasBody) {
  final buf = StringBuffer();
  buf.writeln("import requests");
  buf.writeln();

  if (hasBody) {
    buf.writeln("response = requests.${method.toLowerCase()}(");
    buf.writeln("    'http://localhost:3000$path',");
    buf.writeln("    json={'key': 'value'},");
    buf.writeln(")");
  } else {
    buf.writeln(
        "response = requests.${method.toLowerCase()}('http://localhost:3000$path')");
  }

  buf.writeln("print(response.json())");
  return buf.toString();
}
