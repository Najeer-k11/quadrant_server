## 2.0.0

### Added

- **`QuadrantRouter`** — prefix-mounted route grouping; organise large apps without repeating path prefixes. Supports router-level middlewares applied to all routes in the group.
- **`WebSocketGroup`** — built-in broadcast/room utility. `add()`, `remove()`, `broadcast()`, `broadcastJson()`, `closeAll()` with lazy cleanup of stale connections.
- **`WebSocketContext.isOpen` / `isClosed`** — check connection state before sending to avoid throwing on a closed socket.
- **`WebSocketContext.sendJson()`** — convenience JSON-encode-and-send shortcut.
- **Wildcard route segments** — `Route.get(path: '/files/*', ...)` captures the full remaining path as `req.params['*']`.
- **`Response.redirect()`** — 301/302/307/308 redirect with `location` header.
- **`Response.text()`** — plain-text response with `content-type: text/plain`.
- **`Response.html()`** — HTML response with `content-type: text/html`.
- **`Response.conflict()`** — 409 Conflict.
- **`Response.unprocessableEntity()`** — 422 Unprocessable Entity.
- **Typed query helpers on `Request`** — `queryString()`, `queryInt()`, `queryDouble()`, `queryBool()` with default value support.
- **`Request.bodyAsMap` / `bodyAsList`** — safe typed casts for the parsed body.
- **`app.close()`** — graceful shutdown that waits for in-flight requests.
- **`docsLocalOnly` parameter** — control whether `/quadrant_docs` is loopback-only (default: `true`).
- **`logger()` output sink** — injectable log destination: `logger(output: myLogger.info)`.
- **`cors()` named parameters** — `methods` and `allowedHeaders` now configurable.
- **Startup banner** — printed when `docs: true` showing host, route counts, and docs URL.
- Unit test suite (`test/quadrant_server_test.dart`) covering router, response factories, QuadrantRouter, and middleware.
- `analysis_options.yaml` with `lints/recommended` and strict type-checking.

### Fixed

- **`RequestHolder` hash collision** — replaced `hashCode`-based `Map` key with `Expando<Object>` keyed on the `HttpRequest` object itself. Eliminates body cross-contamination under concurrent load.
- **`bodyParser` silently dropped JSON array bodies** — `req.body` is now `dynamic` and accepts top-level `List` payloads.
- **Plain-string responses lacked `Content-Type`** — all string response bodies now carry `content-type: text/plain; charset=utf-8`.
- **WebSocket upgrade errors silently swallowed** — upgrade failures now delegate to `onError` or print a warning.
- **`/quadrant_docs` accessible from external IPs** — loopback guard is now active by default (`docsLocalOnly: true`).
- **`internalServerError` leaked raw exception messages** — default error handler now returns a generic safe message; users opt in to detail via `onError`.

### Improved

- **`cors()`** now sets `Vary: Origin` when `origin != '*'` for correct CDN/proxy caching behaviour.
- **`WebSocketContext.send()`** is now a no-op when the socket is closed instead of throwing.

## 1.2.0


### Added

- **WebSocket support** — declarative `WebSocketRoute` with four named callbacks (`onStart`, `onMessage`, `onClose`, `onError`)
- **`WebSocketContext`** — per-connection context with `send()`, `close()`, and access to the original upgrade request (params, query, headers)
- **`webSocketRoutes` parameter** on `QuadrantServer` — declare WS endpoints alongside HTTP routes
- **Middleware support for WebSocket** — route-level middlewares run before upgrade; rejection prevents the upgrade entirely
- **Path parameters on WS routes** — `/ws/chat/:roomId` extracts params just like HTTP routes
- **`MatchedWebSocket` sealed type** — router distinguishes WS upgrades from HTTP requests at the type level
- **Docs: WebSocket section** — `/quadrant_docs` now renders WS endpoints in a table below Swagger UI

### Improved

- **Router** — `match()` accepts `isUpgradeRequest` flag; WS upgrades never fall through to HTTP GET routes

## 1.1.1

### Added

- **`/quadrant_docs` endpoint** — opt-in interactive API explorer powered by Swagger UI (CDN-loaded), enabled via `docs: true`
- **405 Method Not Allowed** — router now distinguishes "path exists, wrong method" from "path not found", returns proper `Allow` header
- **HEAD request support** — HEAD automatically falls back to GET handlers per HTTP spec
- **Trailing slash normalization** — `/users/` and `/users` now match the same route
- **URI-decoded path params** — `%20` and other encoded characters decoded automatically
- **`Route.paramNames` getter** — extracts parameter names from path pattern for introspection

### Improved

- **Router performance** — routes grouped by HTTP method for faster lookup (O(n/m) vs O(n))
- **Method normalization** — `'get'` and `'GET'` both resolve correctly

### Security

- `/quadrant_docs` locked to loopback addresses only — external IPs always get 404
- Docs route excluded from generated OpenAPI spec (no self-referencing)

## 1.0.0

- Initial release
- Core framework: `QuadrantServer`, `Request`, `Response`, `Route`, `Router`
- Middleware system with global and route-level support
- Built-in middlewares: `cors()`, `logger()`, `bodyParser()`
- Path parameter extraction (`:param` segments)
- Immutable response pattern with static constructors
- Zero external dependencies — built entirely on `dart:io`
