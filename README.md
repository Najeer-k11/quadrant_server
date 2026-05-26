# QuadrantServer

A Dart-first, batteries-included HTTP server framework built directly on `dart:io` with **zero external dependencies**.

[![pub package](https://img.shields.io/pub/v/quadrant_server.svg)](https://pub.dev/packages/quadrant_server)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)

## Features

- **Dart-first** — Named parameters, strong types, null safety
- **Functional responses** — Handlers return `Response` objects, never mutate
- **Declarative config** — Everything declared upfront in the `QuadrantServer()` constructor
- **Zero dependencies** — Built only on `dart:io`
- **Middleware system** — Global and route-level, with short-circuit support
- **Path parameters** — `/users/:id` extracts `{'id': '123'}`
- **Built-in middlewares** — CORS, logger, and JSON body parser included

## Quick Start

```dart
import 'package:quadrant_server/quadrant_server.dart';

Future<Response> getUsers(Request req) async {
  return Response.ok([
    {'id': '1', 'name': 'Ada'},
    {'id': '2', 'name': 'Grace'},
  ]);
}

Future<Response> getUser(Request req) async {
  final id = req.params['id'];
  return Response.ok({'id': id, 'name': 'Ada'});
}

Future<Response> createUser(Request req) async {
  final body = req.body;
  return Response.created(body);
}

void main() async {
  final app = QuadrantServer(
    middlewares: [cors(), logger(), bodyParser()],
    routes: [
      Route.get(path: '/users', handler: getUsers),
      Route.get(path: '/users/:id', handler: getUser),
      Route.post(path: '/users', handler: createUser),
    ],
  );

  await app.listen(port: 3000);
  print('QuadrantServer running on http://localhost:3000');
}
```

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  quadrant_server: ^1.0.0
```

Then run:

```bash
dart pub get
```

## Core Concepts

### Routes

Define routes using named constructors for each HTTP method:

```dart
Route.get(path: '/users', handler: getUsers)
Route.post(path: '/users', handler: createUser)
Route.put(path: '/users/:id', handler: updateUser)
Route.delete(path: '/users/:id', handler: deleteUser)
Route.patch(path: '/users/:id', handler: patchUser)
```

### Request

Immutable wrapper around `dart:io` `HttpRequest`:

```dart
Future<Response> handler(Request req) async {
  req.method;   // 'GET', 'POST', etc.
  req.path;     // '/users/123'
  req.params;   // {'id': '123'} — path params
  req.query;    // {'page': '1'} — query string
  req.headers;  // {'content-type': 'application/json'}
  req.body;     // {'name': 'Ada'} — parsed JSON (requires bodyParser)
  req.raw;      // dart:io HttpRequest escape hatch
}
```

### Response

Immutable. Always returned from handlers, never mutated:

```dart
Response.ok(data)                     // 200
Response.created(data)                // 201
Response.noContent()                  // 204
Response.badRequest('message')        // 400
Response.unauthorized('message')      // 401
Response.forbidden('message')         // 403
Response.notFound('message')          // 404
Response.internalServerError('msg')   // 500
```

Maps and Lists are automatically JSON-encoded with `content-type: application/json`.

### Middleware

A function that receives a `Request` and a `next()` callback:

```dart
Middleware auth() {
  return (req, next) async {
    final token = req.headers['authorization'];
    if (token == null) return Response.unauthorized('Missing token');
    return next(); // continue to handler
  };
}
```

Apply globally or per-route:

```dart
final app = QuadrantServer(
  middlewares: [cors(), logger()],  // global
  routes: [
    Route.get(
      path: '/admin',
      handler: adminHandler,
      middlewares: [auth()],  // route-level
    ),
  ],
);
```

### Built-in Middlewares

| Middleware     | Description                                                     |
| -------------- | --------------------------------------------------------------- |
| `cors()`       | Adds CORS headers. Optional `origin` parameter (default `'*'`). |
| `logger()`     | Logs method, path, status code, and response time.              |
| `bodyParser()` | Parses JSON request bodies into `req.body`.                     |

### Error Handling

```dart
final app = QuadrantServer(
  routes: [...],
  onError: (error, req) => Response.internalServerError(error.toString()),
);
```

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full design document.

## License

MIT — see [LICENSE](LICENSE).
