# QuadrantServer

[![pub version](https://img.shields.io/pub/v/quadrant_server.svg?label=pub.dev)](https://pub.dev/packages/quadrant_server)
[![pub points](https://img.shields.io/pub/points/quadrant_server)](https://pub.dev/packages/quadrant_server/score)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)

A batteries-included HTTP server framework for Dart, built directly on `dart:io` with **no runtime dependencies**.

Handlers take a `Request` and return a `Response`. Routes, middleware, WebSockets and server options are all declared up front, so you can read how a server behaves in one place.

```dart
final app = QuadrantServer(
  middlewares: [helmet(), logger(), bodyParser()],
  routes: [
    Route.get(path: '/users/:id', handler: getUser),
    Route.post(path: '/users', handler: createUser, middlewares: [validate(userSchema)]),
  ],
);
```

## What's included

| Area | Features |
|---|---|
| **Routing** | Path params, wildcards, route groups, automatic `404`, `405` and `HEAD` |
| **Middleware** | 15 built in: security headers, CORS, auth, rate limiting, body parsing, uploads, compression, caching and more |
| **Real-time** | WebSockets with rooms and heartbeats, Server-Sent Events |
| **Validation** | Schemas with nested objects, typed values and field-level errors |
| **Multi-core** | One server per isolate on a single port, with rate limits and broadcasts shared between them |
| **Operations** | TLS, graceful shutdown, health check, generated Swagger UI docs, streaming responses |

## Contents

- [Installation](#installation)
- [Quick start](#quick-start)
- [Routes](#routes)
- [Requests and responses](#requests-and-responses)
- [Middleware](#middleware)
- [Request validation](#request-validation)
- [Static files and streaming](#static-files-and-streaming)
- [Real-time](#real-time)
- [Using every CPU core](#using-every-cpu-core)
- [Running in production](#running-in-production)
- [Known limitations](#known-limitations)
- [Development](#development)

---

## Installation

Requires Dart 3.0 or later. It needs `dart:io`, so it runs on servers and desktops, not on the web.

```bash
dart pub add quadrant_server
```

This adds the latest version, which is shown on the badge above. See the [changelog](CHANGELOG.md) for what changed in each release.

## Quick start

```dart
import 'package:quadrant_server/quadrant_server.dart';

Future<Response> getUser(Request req) async {
  return Response.ok({'id': req.params['id'], 'name': 'Ada'});
}

Future<Response> createUser(Request req) async {
  return Response.created(req.bodyAsMap ?? {});
}

void main() async {
  final app = QuadrantServer(
    middlewares: [
      requestId(),
      helmet(),
      logger(),
      bodyParser(), // Fills req.body from JSON requests, up to 1 MB
    ],
    routes: [
      Route.get(path: '/users/:id', handler: getUser),
      Route.post(path: '/users', handler: createUser),
    ],
    healthCheck: true, // GET /health
    docs: true,        // GET /quadrant_docs, from this machine only
  );

  await app.listen(port: 3000);
}
```

```bash
curl localhost:3000/users/42
# {"id":"42","name":"Ada"}

curl -X POST localhost:3000/users -H 'content-type: application/json' -d '{"name":"Grace"}'
# {"name":"Grace"}
```

The [`example/`](example) directory has a larger app with authentication, CRUD routes, chat rooms and a Dockerfile.

---

## Routes

```dart
Route.get(path: '/users', handler: getUsers)
Route.post(path: '/users', handler: createUser)
Route.put(path: '/users/:id', handler: updateUser)
Route.patch(path: '/users/:id', handler: patchUser)
Route.delete(path: '/users/:id', handler: deleteUser)

// Any other method:
Route(method: 'OPTIONS', path: '/users', handler: usersOptions)
```

- **Path params:** `/users/:id` puts the decoded value in `req.params['id']`. A value that is not valid UTF-8, such as `/users/%FF`, gets a `400`.
- **Wildcards:** `/files/*` matches `/files/a/b` and puts `a/b` in `req.params['*']`. A wildcard goes at the end of the path.
- **Matching order:** the first registered route that matches wins, so put `/users/me` before `/users/:id`.
- **Slashes:** `/users/` and `/users` are the same route.
- **`HEAD`:** handled by the matching `GET` route if there is no `HEAD` route.

### Route groups

`QuadrantRouter` puts a shared prefix and shared middleware on a group of routes:

```dart
final admin = QuadrantRouter(
  prefix: '/admin',
  middlewares: [bearerAuth(validate: findAdmin)],
)
  ..get('/users', listUsers)
  ..delete('/users/:id', deleteUser)
  ..ws('/live', onMessage: onLiveMessage, heartbeat: Duration(seconds: 30));

final app = QuadrantServer(
  routes: [...admin.routes],
  webSocketRoutes: [...admin.webSocketRoutes],
);
```

## Requests and responses

### Request

```dart
req.method;      // 'GET'
req.path;        // '/users/123'
req.params;      // {'id': '123'}
req.query;       // {'page': '1'}
req.headers;     // {'content-type': 'application/json'}, with lowercase names
req.body;        // Parsed body, once a body parser has run
req.bodyAsMap;   // Map<String, dynamic>?, null for anything else
req.bodyAsList;  // List<dynamic>?, null for anything else
req.context;     // Values added by middleware
req.raw;         // The dart:io HttpRequest, if you need it

req.queryString('sort', defaultValue: 'asc');
req.queryInt('page', defaultValue: 1);
req.queryDouble('lat');
req.queryBool('active', defaultValue: true); // true/1/yes, false/0/no
```

`req.body` stays `null` unless `bodyParser()`, `formParser()` or similar has run.

### Response

Responses are immutable. Maps and lists are encoded as JSON, and text is sent as UTF-8 unless your `content-type` names another charset.

```dart
Response.ok(data)                       // 200
Response.created(data)                  // 201
Response.noContent()                    // 204
Response.redirect('/new-path')          // 302, or pass statusCode: 301, 307 or 308
Response.text('plain text')             // 200 text/plain
Response.html('<h1>Hello</h1>')         // 200 text/html
Response.badRequest('message')          // 400
Response.unauthorized('message')        // 401
Response.forbidden('message')           // 403
Response.notFound('message')            // 404
Response.conflict('message')            // 409
Response.unprocessableEntity('message') // 422
Response.internalServerError('message') // 500

// Anything else:
Response(statusCode: 202, headers: {'x-job': '42'}, body: 'Queued')
```

The body is a `String`. For binary data, use [`StreamResponse`](#streaming-responses).

### Cookies

```dart
return Response.ok({'status': 'logged_in'})
    .withCookie(
      'session_id',
      token,
      secure: true,
      sameSite: 'Strict',
      maxAge: Duration(days: 7),
    )
    .withCookie('theme', 'dark', httpOnly: false);

return Response.ok({}).clearCookie('session_id');
```

Cookies are `HttpOnly` and `SameSite=Lax` unless you say otherwise. Read incoming ones with `cookieParser()`.

---

## Middleware

Global middleware runs first, in order, followed by the route's own. A middleware either calls `next()` to continue or returns a `Response` to stop there.

Global middleware also runs for requests that match no route, so `404` and `405` responses get security headers and appear in your logs. A global `bearerAuth()` answers `401` for unknown paths too, which hides the routes you have, and a global `rateLimit()` counts those requests. Middleware on a route or `QuadrantRouter` only runs for that route, except that `cors()` also answers its preflights.

| Middleware | What it does | Options |
|---|---|---|
| `helmet()` | Sets 8 security headers, including HSTS | One per header; `null` removes it |
| `cors()` | Adds CORS headers and answers preflight `OPTIONS` requests | `origin`, `methods`, `allowedHeaders`, `maxAge` |
| `requestId()` | Reuses or generates an ID, in `req.context['requestId']` and the response | `headerName`, `contextKey` |
| `logger()` | Logs method, path, status and time | `output` |
| `bearerAuth()` | Checks `Authorization: Bearer`; puts the result in `req.context['user']` | `validate`, `contextKey`, `realm` |
| `rateLimit()` | Sliding-window limit per IP or custom key | `maxRequests`, `window`, `keyExtractor`, `trustedProxyHops`, `maxKeys` (100,000) |
| `ipFilter()` | Allows or denies exact IPs and CIDR ranges | `allow` or `deny`, `onDeny`, `trustedProxyHops` |
| `bodyParser()` | Parses JSON into `req.body`; `400` if invalid, `413` if too large | `maxBodyBytes` (1 MB) |
| `formParser()` | Parses URL-encoded forms into `req.body` | `maxBodyBytes` (64 KB) |
| `multipartParser()` | Parses uploads into `req.context['files']` and `['fields']` | `maxFileSize` (10 MB), `maxTotalBytes` (50 MB) |
| `cookieParser()` | Parses cookies into `req.context['cookies']` | `contextKey` |
| `compress()` | Gzips responses for clients that accept it | `minBytes` (512 B) |
| `etag()` | Adds weak ETags and answers `304 Not Modified` | None |
| `timeout()` | Returns `408` if the handler takes too long | `duration`, `onTimeout` |
| `validate()` | Checks the body against a schema; see [below](#request-validation) | `schema`, `contextKey` |

`helmet()` sends HSTS by default. On a server that only uses HTTP, turn it off with `helmet(hsts: null)`.

### Writing your own

Use `req.setContext()` to pass values to later middleware, the handler and WebSocket callbacks:

```dart
Future<Response> tenant(Request req, Next next) async {
  final id = req.headers['x-tenant-id'];
  if (id == null) return Response.badRequest('Missing tenant');

  req.setContext('tenant', id);
  final response = await next();

  // Runs after the handler. Use copyWith so cookies and streams are kept.
  return response.copyWith(
    headers: {...response.headers, 'x-tenant-id': id},
  );
}
```

### Authentication

```dart
final auth = bearerAuth(
  validate: (token) => myAuthService.verify(token), // Return null to reject
);

Route.get(
  path: '/me',
  middlewares: [auth],
  handler: (req) async {
    final user = req.context['user'] as UserProfile;
    return Response.ok({'id': user.id, 'name': user.name});
  },
)
```

Rejected requests get a `401` with a `WWW-Authenticate` header. On a `WebSocketRoute`, the check runs before the upgrade, and the user is available as `ctx.request.context['user']`.

### Rate limiting

```dart
// 100 requests per minute, per client IP:
rateLimit(maxRequests: 100, window: Duration(minutes: 1))

// Stricter on a sensitive route:
Route.post(
  path: '/auth/login',
  handler: login,
  middlewares: [rateLimit(maxRequests: 5, window: Duration(minutes: 15))],
)
```

Responses carry `X-RateLimit-*` headers, and a rejected request gets a `429` with `Retry-After`.

IPv6 clients are grouped by /64, because one client usually controls that whole range. At most `maxKeys` clients are tracked at once, so a flood of new keys cannot use up memory: past it, idle clients are forgotten first and then the oldest ones, whose counts start again.

**Behind a proxy**, every request appears to come from the proxy's IP, so all your clients would share one limit. Tell `rateLimit()` how many proxies you run, and it reads the client IP from the entries they appended to `X-Forwarded-For`:

```dart
rateLimit(maxRequests: 100, window: Duration(minutes: 1), trustedProxyHops: 1)
```

Leave it unset if you are not behind a proxy, or clients can pick their own IP by sending that header. `ipFilter()` has the same option, and it denies a request if the forwarded IP is missing or is not a plain address, rather than judging it by the proxy's IP.

### File uploads

```dart
Route.post(
  path: '/upload',
  middlewares: [multipartParser(maxFileSize: 5 * 1024 * 1024)],
  handler: (req) async {
    final files = req.context['files'] as List<UploadedFile>;
    final fields = req.context['fields'] as Map<String, String>;

    for (final file in files) {
      // file.filename comes from the client. Never use it as a path.
      final savedName = '${DateTime.now().microsecondsSinceEpoch}.bin';
      await File('uploads/$savedName').writeAsBytes(file.bytes);
    }

    return Response.ok({'uploaded': files.length, 'fields': fields.length});
  },
)
```

Uploads are held in memory until the handler finishes, so set limits that suit your server.

---

## Request validation

```dart
final userSchema = BodySchema({
  'username': Field.string().minLength(3).maxLength(20).required(),
  'email':    Field.string().email().required(),
  'age':      Field.int_().min(18).max(120).required(),
  'role':     Field.string().oneOf(['admin', 'member']).required(),
  'address':  Field.object({
    'city': Field.string().required(),
    'zip':  Field.int_(),
  }),
  'scores':   Field.list().maxItems(10).of(Field.int_().max(100)),
});

Route.post(
  path: '/register',
  handler: register,
  middlewares: [validate(userSchema)], // Needs a body parser to run first
)
```

Invalid requests get a `422` listing every problem, with nested fields named by their path:

```json
{"errors": {"email": "email must be a valid email address", "address.city": "address.city is required", "scores[2]": "scores[2] must be ≤ 100"}}
```

On success, `req.context['validated']` holds only the declared fields, converted to their types. `req.body` stays exactly as it was received.

```dart
final user = req.context['validated'] as Map<String, dynamic>;
final age = user['age'] as int; // "42" in the request becomes 42
```

Schemas on a route's own `middlewares` also appear as its request body in the generated docs.

---

## Static files and streaming

### Static files

```dart
Route.get(path: '/public/*', handler: staticFiles('./public'))
```

Files are streamed from disk. You get path traversal protection, MIME types, `ETag` and `Last-Modified` with `304` responses, and `index.html` for directories.

### Streaming responses

`StreamResponse` sends data as it becomes available, without holding it all in memory. It is also how you send binary data.

```dart
Route.get(
  path: '/reports/monthly',
  handler: (req) async {
    final file = File('reports/monthly.csv');
    return StreamResponse(
      stream: file.openRead(),
      headers: {
        'content-type': 'text/csv',
        'content-length': '${await file.length()}',
      },
    );
  },
)
```

> **Never build a file path from `req.params`.** Params are URL-decoded, so `/download/..%2Fsecret.txt` gives you `../secret.txt`. To serve files chosen by the client, use `staticFiles()`, which checks for this.

If a stream fails partway, the connection is dropped so the client can tell the response is incomplete.

---

## Real-time

### Server-Sent Events

Works with the browser's `EventSource`:

```dart
Route.get(
  path: '/events',
  handler: (req) async {
    final sse = await SseContext.from(req);

    final timer = Timer.periodic(Duration(seconds: 1), (_) {
      sse.send(data: 'tick', event: 'heartbeat');
    });

    await sse.done; // Until the client leaves or the server shuts down
    timer.cancel();
    return sse.response;
  },
)
```

### WebSockets

```dart
WebSocketRoute(
  path: '/ws/echo/:roomId',
  heartbeat: Duration(seconds: 30), // Closes connections that stop responding
  onStart: (ctx) async => ctx.sendJson({'room': ctx.request.params['roomId']}),
  onMessage: (ctx, data) async => ctx.send(data),
  onClose: (ctx, code, reason) async => print('Closed: $code'),
  onError: (ctx, error) async => print('Failed: $error'),
)
```

Pass these to `QuadrantServer(webSocketRoutes: [...])`. Only `onMessage` is required. Middleware runs before the upgrade, so it can reject a connection with a normal HTTP response.

### Rooms and broadcasting

```dart
final rooms = <String, WebSocketGroup>{};
WebSocketGroup room(String id) =>
    rooms.putIfAbsent(id, () => WebSocketGroup(name: 'room:$id'));

WebSocketRoute(
  path: '/ws/chat/:roomId',
  onStart: (ctx) async {
    final group = room(ctx.request.params['roomId']!);
    group.add(ctx);
    group.broadcastJson({'event': 'joined'}, exclude: ctx);
  },
  onMessage: (ctx, data) async {
    room(ctx.request.params['roomId']!).broadcast(data, exclude: ctx);
  },
  onClose: (ctx, code, reason) async {
    final id = ctx.request.params['roomId']!;
    if (room(id).isEmpty) rooms.remove(id);
  },
)
```

Connections leave their group automatically when they close. The `name` is only needed in a [cluster](#using-every-cpu-core), where it links groups across isolates.

---

## Using every CPU core

A Dart isolate runs your handlers on one thread. `QuadrantCluster` runs one server per isolate on the same port:

```dart
import 'dart:io';

import 'package:quadrant_server/quadrant_server.dart';

Future<Response> getUsers(Request req) async => Response.ok([]);

void main() async {
  final cluster = await QuadrantCluster.start(
    isolates: Platform.numberOfProcessors,
    port: 3000,
    build: () => QuadrantServer(
      middlewares: [
        logger(),
        rateLimit(maxRequests: 100, window: Duration(minutes: 1)),
      ],
      routes: [Route.get(path: '/users', handler: getUsers)],
    ),
  );

  print('Listening on port ${cluster.port}');
  // Later: await cluster.close();
}
```

`build` runs once inside each isolate. Open database connections and similar resources inside it, because they cannot be sent between isolates. For HTTPS, pass `certificateChain` and `privateKey` to `start()`.

### What is shared between isolates

Isolates do not share memory, so a variable in your code exists once per isolate.

| | Across isolates |
|---|---|
| `rateLimit()` | One count. Each limited request makes one round trip to the main isolate. `build` must create limiters in the same order every time. If the main isolate does not answer within 250 ms, the isolate counts on its own until it does, and prints a warning. |
| `WebSocketGroup(name: 'room:42')` | `broadcast()`, `broadcastJson()` and `closeAll()` reach every isolate. `length`, `isEmpty` and `members` cover the current one only. |
| `WebSocketGroup()` | Throws when you add a member, because it would silently miss clients. Use `WebSocketGroup.local()` if you mean to stay on one isolate. |
| Health check | Reports the total requests of all isolates, plus an `isolates` count. |
| **Your own variables** | **Not shared.** Keep caches, sessions and similar state in a database or external store. |

Nothing is shared with other processes or machines, so if you run several, rate limits apply to each one separately.

### When an isolate dies

It is replaced with a new one from `build`. The wait starts at `restartDelay` (1 second) and doubles with each failure in a row, up to 30 seconds. After `maxRestarts` (10) failures in a row, it is given up on and the others keep serving. The count starts again once an isolate has run for a minute, and `maxRestarts: 0` turns restarting off.

```dart
final cluster = await QuadrantCluster.start(
  isolates: Platform.numberOfProcessors,
  port: 3000,
  build: buildServer,
  onIsolateExit: (index, {required willRestart}) {
    // Let your process supervisor take over.
    if (!willRestart) exit(1);
  },
);
```

New connections go to the isolates that are alive, and the replacement takes its share as soon as it is listening. Its share of the health check's request total starts again from 0. `rateLimit()` counts are kept, because they live on the main isolate. `cluster.runningIsolates` tells you how many are listening.

Sockets the dead isolate had **stay open until the Dart VM next collects garbage**, which can take a while on a quiet server. Until then its clients get no error, so set a timeout on your clients or proxy. If you `close()` the cluster and bind its port again in the same process, that can fail for the same reason; a process that exits releases everything.

Restarting does not replace a process supervisor. A crash of the Dart VM ends every isolate, so run under systemd, Docker or similar.

### Performance

Measured with [`benchmark/`](benchmark) on an i7-13620H laptop, using a compiled build over loopback, with no TLS, 64 keep-alive connections, and the server pinned to 4 physical cores (8 hardware threads):

| Workload | 1 isolate | 8 isolates |
|---|--:|--:|
| Plain route | 66,692 req/s | 175,750 req/s (2.6x) |
| 1 ms of CPU work per request | 991 req/s | 7,478 req/s (7.5x) |
| `requestId`, `helmet`, `cors`, `logger`, `bodyParser` | 44,563 req/s | 120,550 req/s (2.7x) |
| Rate limited, count shared across isolates | 54,535 req/s | 138,860 req/s (2.5x) |

The more work your handlers do, the more isolates help. If they mostly wait on a database, one isolate may be enough: it handled 256 connections with a simulated 10 ms query at 39% of one core. These numbers are a guide, so measure your own app on your own hardware.

For the best performance, deploy a compiled build (`dart compile exe`) rather than using `dart run`.

---

## Running in production

### HTTPS

```dart
await app.listenSecure(
  port: 443,
  certificateChain: File('cert.pem'),
  privateKey: File('key.pem'),
);
```

### Health check

```dart
QuadrantServer(healthCheck: true, routes: [...]);

// GET /health
// {"status":"ok","uptime":3600,"requests":1024,"memoryMb":38.4}
```

It is answered before any middleware, so it skips auth, rate limiting and logging. Anyone who can reach it can read these numbers. Change the path with `healthCheckPath`.

### API docs

`docs: true` serves Swagger UI at `/quadrant_docs`, generated from your routes. By default it only answers requests from the same machine; `docsLocalOnly: false` opens it up. The page loads Swagger UI from a CDN, so the browser viewing it needs internet access.

### Graceful shutdown

```dart
ProcessSignal.sigterm.watch().listen((_) async {
  await app.close(timeout: Duration(seconds: 30));
  exit(0);
});
```

`close()` stops accepting connections, ends open WebSockets (with code `1001`) and SSE streams, and waits for in-flight requests and streaming responses. `timeout` limits that wait, so a stalled client cannot hold up shutdown; without it, the wait has no limit. `close(force: true)` drops everything straight away.

### Error handling

```dart
QuadrantServer(
  routes: [...],
  onError: (error, req) {
    print('Failed on ${req.path}: $error');
    return Response.internalServerError('Something went wrong');
  },
);
```

Without `onError`, an exception in a handler gives a `500` with a generic message, so internal details do not reach clients. WebSocket callback errors go to that route's `onError`.

### Checklist

- `listen()` binds to all network interfaces. To accept local connections only, such as behind a proxy on the same machine, pass `address: InternetAddress.loopbackIPv4`.
- Replace the `cors()` default of `origin: '*'` with your real origin.
- Set `trustedProxyHops` on `rateLimit()` and `ipFilter()` if you run behind a proxy.
- Check that `bodyParser()` and `multipartParser()` limits suit your app.

---

## Known limitations

- **A stuck cluster isolate is not detected.** One in an endless loop has not died, so it is not replaced, and requests it has accepted wait.
- **Connections on a cluster isolate that dies stay open until the next garbage collection.** Those clients may wait until their own timeout.
- **`rateLimit()` keeps its counts in memory.** They reset on restart and are not shared between processes or machines.
- **Uploads and JSON bodies are held in memory** until the request finishes.

---

## Development

```bash
dart pub get
dart test
dart analyze
```

### Benchmarks

Linux only. Requires `g++` and `taskset`.

```bash
dart run benchmark/run.dart --label=my-run           # About 15 minutes
dart run benchmark/report.dart --after=my-run        # Writes benchmark/results/report.html
```

The results compare the framework with plain `dart:io`, raw Dart sockets and a bare C++ server. The report opens in any browser and needs no network access.

### Releasing

Update the version in both `pubspec.yaml` and `lib/src/core/version.dart`; a test fails if they differ. The README has no version number to update.

## License

MIT
