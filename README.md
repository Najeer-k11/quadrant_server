# QuadrantServer

A Dart-first, batteries-included HTTP server framework built directly on `dart:io` with **zero external dependencies**.

[![pub package](https://img.shields.io/pub/v/quadrant_server.svg)](https://pub.dev/packages/quadrant_server)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)

## Features

- **Dart-first** — Named parameters, strong types, null safety
- **Functional responses** — Handlers return `Response` objects, never mutate
- **Declarative config** — Everything declared upfront in `QuadrantServer()`
- **Zero dependencies** — Pure Dart (`dart:io` + `dart:async` only)
- **Middleware system** — Global and route-level, short-circuiting, context propagation
- **Path parameters & Wildcards** — `/users/:id` extracts `params['id']`, `/files/*` captures rest
- **Route grouping** — `QuadrantRouter` for prefix-mounted route modules
- **Built-in Middlewares (14 total)**:
  - `cors()` — Cross-Origin Resource Sharing with preflight caching & `maxAge`
  - `logger()` — Structured request logging with custom sinks
  - `bodyParser()` — JSON parser with payload size limits (`413`)
  - `rateLimit()` — Sliding-window rate limiting
  - `bearerAuth()` — Bearer token authentication & principal injection
  - `staticFiles()` — Path-traversal-safe file server with ETag & 304 caching
  - `requestId()` — Automatic UUID v4 tracing & header propagation
  - `helmet()` — 8 essential web security headers
  - `timeout()` — Request cancellation with custom `408` timeout response
  - `cookieParser()` — Parses `Cookie` header & provides cookie setters
  - `formParser()` — Parses `application/x-www-form-urlencoded` forms
  - `ipFilter()` — CIDR and exact IP allow/deny lists
  - `compress()` — Gzip compression with `Accept-Encoding` negotiation
  - `etag()` — Weak ETag caching and `If-None-Match` handling
  - `multipartParser()` — File uploads & multipart form decoding
- **Real-time**:
  - **Server-Sent Events (`SseContext`)** — Event streaming with keep-alive pings
  - **WebSockets (`WebSocketRoute`)** — Upgrades, callbacks, and automatic heartbeat ping/pong
  - **`WebSocketGroup`** — Room/channel broadcasting utility
- **Streaming Responses** — `StreamResponse` to pipe streams without buffering in memory
- **Schema Validation** — `BodySchema` + `validate()` middleware for typed request validation (`422`)
- **Operations & Security**:
  - **HTTPS / TLS** — `listenSecure()` with certificate chains
  - **Graceful shutdown** — `close()` drains in-flight requests cleanly
  - **Health check** — Built-in `/health` endpoint reporting uptime, requests, and memory
  - **Auto-generated docs** — Swagger UI at `/quadrant_docs` (loopback-only by default)

---

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
  final body = req.bodyAsMap;
  return Response.created(body ?? {});
}

void main() async {
  final app = QuadrantServer(
    middlewares: [
      requestId(),
      helmet(),
      cors(),
      logger(),
      bodyParser(maxBodyBytes: 1024 * 1024), // 1MB limit
    ],
    routes: [
      Route.get(path: '/users', handler: getUsers),
      Route.get(path: '/users/:id', handler: getUser),
      Route.post(path: '/users', handler: createUser),
    ],
    healthCheck: true, // Enables GET /health
    docs: true,        // Enables GET /quadrant_docs
  );

  await app.listen(port: 3000);
  print('Server running on http://localhost:3000');
}
```

---

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  quadrant_server: ^2.5.2
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
final apiRouter = QuadrantRouter(prefix: '/api/v1')
  ..get('/users', getUsers)
  ..post('/users', createUser)
  ..get('/users/:id', getUser)
  ..delete('/users/:id', deleteUser);

final app = QuadrantServer(
  middlewares: [cors(), logger()],
  routes: [
    ...apiRouter.routes,
  ],
);
```

Router-level middlewares run before every route in that router:

```dart
final adminRouter = QuadrantRouter(
  prefix: '/admin',
  middlewares: [bearerAuth(validate: myValidator)], // runs on all /admin routes
)
  ..get('/dashboard', dashboardHandler)
  ..get('/users', listUsersHandler);
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
  req.body;           // dynamic — Map, List, or null
  req.bodyAsMap;      // Map<String, dynamic>? — safe cast
  req.bodyAsList;     // List? — safe cast
  req.context;        // Map<String, dynamic> — middleware-injected data
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

#### Setting & Clearing Cookies

Use `.withCookie()` and `.clearCookie()`:

```dart
return Response.ok({'status': 'logged_in'})
    .withCookie(
      'session_id',
      token,
      httpOnly: true,
      secure: true,
      sameSite: 'Strict',
      maxAge: Duration(days: 7),
    )
    .withCookie('theme', 'dark');

// Clearing a cookie:
return Response.ok({}).clearCookie('session_id');
```

---

## Middlewares Reference

| Middleware | Description | Key Options |
|------------|-------------|-------------|
| `helmet()` | Sets 8 standard HTTP security headers | `frameOptions`, `hsts`, `referrerPolicy` |
| `requestId()` | Assigns/echoes UUID v4 tracing header & injects into context | `headerName`, `contextKey` |
| `cors()` | Cross-Origin Resource Sharing with preflight cache | `origin`, `methods`, `allowedHeaders`, `maxAge` |
| `rateLimit()` | Sliding-window rate limiting per IP or custom key | `maxRequests`, `window`, `keyExtractor` |
| `bearerAuth()` | Bearer token auth; injects user into `req.context['user']` | `validate: (token) async => User?` |
| `bodyParser()` | JSON body parser with size guard | `maxBodyBytes` (default: 1 MB) |
| `formParser()` | Parses URL-encoded form submissions | `maxBodyBytes` (default: 64 KB) |
| `multipartParser()` | Decodes file uploads & multipart fields into context | `maxFileSize` (default: 10 MB), `maxTotalBytes` (default: 50 MB) |
| `cookieParser()` | Parses `Cookie` header into `req.context['cookies']` | `contextKey` |
| `ipFilter()` | Restricts access by exact IP or CIDR block | `allow: [...]` or `deny: [...]` |
| `compress()` | Gzip response compression with Accept-Encoding check | `minBytes` (default: 512 B) |
| `etag()` | Automatic weak ETag caching (`304 Not Modified`) | None |
| `staticFiles()` | Serves directory safely with MIME & ETag caching | `rootDir`, `indexFallback` |
| `timeout()` | Cancels slow requests with `408 Request Timeout` | `duration`, `onTimeout` |
| `logger()` | Logs method, path, status, and response time | `output: (line) => ...` |

---

### Middleware Examples

#### Security: `helmet()`, `requestId()`, `ipFilter()`

```dart
final app = QuadrantServer(
  middlewares: [
    requestId(),
    helmet(frameOptions: 'DENY'),
    ipFilter(allow: ['127.0.0.1', '10.0.0.0/8']),
  ],
  routes: [...],
);
```

#### Authentication: `bearerAuth()`

```dart
final auth = bearerAuth(
  validate: (token) async {
    return await myAuthService.verify(token); // returns null on failure
  },
);

Route.get(
  path: '/me',
  handler: (req) async {
    final user = req.context['user'] as UserProfile;
    return Response.ok({'id': user.id, 'name': user.name});
  },
  middlewares: [auth],
);
```

#### Rate Limiting: `rateLimit()`

```dart
// 100 requests per minute globally:
rateLimit(maxRequests: 100, window: Duration(minutes: 1))

// Sensitive endpoint: 5 attempts per 15 minutes:
Route.post(
  path: '/auth/login',
  handler: loginHandler,
  middlewares: [rateLimit(maxRequests: 5, window: Duration(minutes: 15))],
)
```

#### File Uploads: `multipartParser()`

```dart
Route.post(
  path: '/upload',
  handler: (req) async {
    final files = req.context['files'] as List<UploadedFile>;
    final fields = req.context['fields'] as Map<String, String>;

    for (final file in files) {
      print('Received: ${file.filename} (${file.size} bytes)');
      // Never use file.filename as a path - it is controlled by the client.
      final savedName = '${DateTime.now().microsecondsSinceEpoch}.bin';
      await File('uploads/$savedName').writeAsBytes(file.bytes);
    }

    return Response.ok({'uploaded': files.length});
  },
  middlewares: [multipartParser(maxFileSize: 5 * 1024 * 1024)],
)
```

---

## Request Validation

Create composable schemas and enforce them with `validate()`:

```dart
final userSchema = BodySchema({
  'username': Field.string().minLength(3).maxLength(20).required(),
  'email':    Field.string().email().required(),
  'age':      Field.int_().min(18).max(120).required(),
  'role':     Field.string().oneOf(['admin', 'member']).required(),
  'tags':     Field.list().minItems(1),
  'verified': Field.bool_(),
});

Route.post(
  path: '/register',
  handler: registerUser,
  middlewares: [validate(userSchema)],
)
// Invalid requests automatically return 422 with a structured error map:
// {"errors":{"email":"email must be a valid email address","age":"age must be ≥ 18"}}
```

---

## Static Files

Serve static directories safely with path traversal protection, MIME detection, ETag caching, and `index.html` fallback:

```dart
Route.get(path: '/public/*', handler: staticFiles('./public'))
```

---

## Streaming Responses

Use `StreamResponse` to stream large files or dynamic chunked data directly without buffering in memory:

```dart
Route.get(
  path: '/download/:file',
  handler: (req) async {
    final file = File('storage/${req.params['file']}');
    if (!await file.exists()) return Response.notFound('File not found');

    return StreamResponse(
      stream: file.openRead(),
      headers: {
        'content-type': 'application/octet-stream',
        'content-length': '${await file.length()}',
      },
    );
  },
)
```

---

## Real-Time

### Server-Sent Events (SSE)

Push-based event stream compatible with the browser's `EventSource` API:

```dart
Route.get(
  path: '/events',
  handler: (req) async {
    final sse = await SseContext.from(req);

    final timer = Timer.periodic(Duration(seconds: 1), (_) {
      sse.send(data: 'ping', event: 'heartbeat');
    });

    await sse.done; // Wait for client disconnection
    timer.cancel();
    return sse.response;
  },
)
```

### WebSockets

Declare WebSocket endpoints with lifecycle hooks and automatic ping/pong heartbeats:

```dart
WebSocketRoute(
  path: '/ws/chat/:roomId',
  heartbeat: Duration(seconds: 30), // auto ping/pong
  onStart: (ctx) async {
    ctx.sendJson({'event': 'connected'});
  },
  onMessage: (ctx, data) async {
    ctx.send(data);
  },
  onClose: (ctx, code, reason) async {
    print('Closed: $code');
  },
)
```

### WebSocketGroup — Rooms & Broadcasting

`WebSocketGroup` manages a set of connections for broadcasting:

```dart
final rooms = <String, WebSocketGroup>{};
WebSocketGroup _room(String id) => rooms.putIfAbsent(id, () => WebSocketGroup());

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

---

## HTTPS / TLS & Operations

### HTTPS / TLS

```dart
final app = QuadrantServer(routes: [...]);

await app.listenSecure(
  port: 443,
  certificateChain: File('cert.pem'),
  privateKey: File('key.pem'),
);
```

### Health Check

Enable `/health` for Kubernetes / load balancers:

```dart
final app = QuadrantServer(
  healthCheck: true,
  routes: [...],
);
// GET /health returns:
// {"status":"ok","uptime":3600,"requests":1024,"memoryMb":38.4}
```

### Graceful Shutdown

```dart
final server = await app.listen(port: 3000);

// Stops accepting new requests and drains all in-flight requests cleanly:
await app.close();
```

### Error Handling

```dart
final app = QuadrantServer(
  routes: [...],
  onError: (error, req) {
    print('Internal error on ${req.path}: $error');
    return Response.internalServerError('Something went wrong');
  },
);
```

---

## License

MIT
