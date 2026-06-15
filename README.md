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
- **Wildcard routes** — `/files/*` captures the full remaining path
- **Route grouping** — `QuadrantRouter` for prefix-mounted route modules
- **Built-in middlewares** — CORS, logger, and JSON body parser included
- **WebSocket support** — Declare WS endpoints with the same style as REST routes
- **WebSocketGroup** — Built-in broadcast/room utility for multi-client scenarios
- **Auto-generated docs** — Swagger UI at `/quadrant_docs` (loopback-only by default)

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
  final body = req.bodyAsMap;          // Map<String, dynamic>? — safe cast
  return Response.created(body ?? {});
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
  quadrant_server: ^2.0.0
```

Then run:

```bash
dart pub get
```

---

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

**Wildcard segments** — capture everything after a prefix:

```dart
Route.get(path: '/files/*', handler: serveFile)
// GET /files/images/logo.png → req.params['*'] == 'images/logo.png'
```

### Route Grouping — `QuadrantRouter`

Organise large apps into prefix-mounted modules without repeating path segments:

```dart
final usersRouter = QuadrantRouter(prefix: '/api/v1')
  ..get('/users', getUsers)
  ..post('/users', createUser)
  ..get('/users/:id', getUser)
  ..delete('/users/:id', deleteUser);

final app = QuadrantServer(
  middlewares: [cors(), logger()],
  routes: [
    ...usersRouter.routes,
  ],
);
```

Router-level middlewares run before every route in that router:

```dart
final adminRouter = QuadrantRouter(
  prefix: '/admin',
  middlewares: [auth()],   // runs before every admin route
)
  ..get('/dashboard', dashboard)
  ..get('/users', listUsers);
```

### Request

Immutable wrapper around `dart:io` `HttpRequest`:

```dart
Future<Response> handler(Request req) async {
  req.method;         // 'GET', 'POST', etc.
  req.path;           // '/users/123'
  req.params;         // {'id': '123'} — path params
  req.query;          // {'page': '1'} — raw query string map
  req.headers;        // {'content-type': 'application/json'}
  req.body;           // dynamic — null, Map, or List (requires bodyParser)
  req.bodyAsMap;      // Map<String, dynamic>? — safe cast for JSON objects
  req.bodyAsList;     // List? — safe cast for JSON arrays
  req.raw;            // dart:io HttpRequest escape hatch

  // Typed query helpers
  req.queryString('sort', defaultValue: 'asc');  // String
  req.queryInt('page', defaultValue: 1);          // int?
  req.queryDouble('lat');                          // double?
  req.queryBool('active', defaultValue: true);    // bool?
}
```

### Response

Immutable. Always returned from handlers, never mutated:

```dart
Response.ok(data)                       // 200 — Map/List auto-JSON-encoded
Response.created(data)                  // 201
Response.noContent()                    // 204
Response.redirect('/new-path')          // 302 (or 301, 307, 308)
Response.text('plain text')             // 200 text/plain
Response.html('<h1>Hello</h1>')         // 200 text/html
Response.badRequest('message')          // 400
Response.unauthorized('message')        // 401
Response.forbidden('message')           // 403
Response.notFound('message')            // 404
Response.conflict('message')            // 409
Response.unprocessableEntity('message') // 422
Response.internalServerError('msg')     // 500
```

Maps and Lists are automatically JSON-encoded with `content-type: application/json`.
Strings get `content-type: text/plain; charset=utf-8`.

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
  docs: true,
);
```

### Built-in Middlewares

| Middleware     | Description |
| -------------- | ----------- |
| `cors()`       | Adds CORS headers. Accepts `origin`, `methods`, `allowedHeaders`. Sets `Vary: Origin` automatically when `origin != '*'`. |
| `logger()`     | Logs method, path, status, and response time. Accepts optional `output` sink. |
| `bodyParser()` | Parses JSON request bodies (objects and arrays) into `req.body`. |

```dart
// Custom logger sink
logger(output: (line) => myLogger.info(line))

// Specific CORS origin
cors(origin: 'https://myapp.com')
```

### Error Handling

```dart
final app = QuadrantServer(
  routes: [...],
  onError: (error, req) {
    // Log the real error server-side, return a safe message to the client.
    print('Error: $error');
    return Response.internalServerError('Something went wrong');
  },
);
```

---

## WebSocket Support

Declare WebSocket endpoints with `WebSocketRoute` — the same style as REST routes.

```dart
final app = QuadrantServer(
  routes: [...],
  webSocketRoutes: [
    WebSocketRoute(
      path: '/ws/chat/:roomId',
      onStart: (ctx) async {
        ctx.sendJson({'event': 'welcome', 'room': ctx.request.params['roomId']});
      },
      onMessage: (ctx, data) async {
        // data is String (text frame) or List<int> (binary frame)
        ctx.send(data); // echo back
      },
      onClose: (ctx, code, reason) async {
        print('Closed: $code $reason');
      },
      onError: (ctx, error) async {
        print('Error: $error');
      },
    ),
  ],
);
```

Connect with: `ws://localhost:3000/ws/chat/general`

### WebSocketContext

The context object passed to every WebSocket callback:

```dart
ctx.request         // original HTTP upgrade Request (params, query, headers)
ctx.isOpen          // bool — check before sending
ctx.isClosed        // bool
ctx.send(data)      // send String or List<int>; no-op if closed
ctx.sendJson(map)   // JSON-encodes and sends; no-op if closed
ctx.close(1000, 'bye')
```

### WebSocketGroup — Rooms & Broadcasting

`WebSocketGroup` manages a set of connections for broadcasting:

```dart
final rooms = <String, WebSocketGroup>{};

WebSocketGroup _room(String id) =>
    rooms.putIfAbsent(id, () => WebSocketGroup());

WebSocketRoute(
  path: '/ws/chat/:roomId',
  onStart: (ctx) async {
    final room = _room(ctx.request.params['roomId']!);
    room.add(ctx);
    room.broadcastJson({'event': 'joined'}, exclude: ctx);
  },
  onMessage: (ctx, data) async {
    _room(ctx.request.params['roomId']!).broadcast(data, exclude: ctx);
  },
  onClose: (ctx, code, reason) async {
    final id = ctx.request.params['roomId']!;
    _room(id).remove(ctx);
    if (_room(id).isEmpty) rooms.remove(id);
  },
)
```

### WebSocket Middleware Guard

Middleware runs before the upgrade. A rejection prevents the connection:

```dart
WebSocketRoute(
  path: '/ws/secure',
  middlewares: [auth()],   // rejects unauthenticated clients with HTTP 401
  onMessage: (ctx, data) async { ... },
)
```

### Graceful Shutdown

```dart
final server = await app.listen(port: 3000);

// Later — wait for in-flight requests, then close.
await app.close();
```

---

## Real-World Example

Check the [`example/`](example/) folder for a production-ready project structure including a `Dockerfile` for containerized deployment. It demonstrates REST routing with `QuadrantRouter`, wildcard file routes, WebSocket rooms using `WebSocketGroup`, middleware composition, and Docker-based deployment.
