## 2.5.2

### Fixed

- **Memory spikes on request bodies** — `bodyParser()`, `formParser()` and `multipartParser()` collected the body in a `List<int>`, which takes 8 bytes per byte plus room to grow. They now use `BytesBuilder`, and `multipartParser()` no longer copies each file twice. A 45 MB multipart upload (rejected with `413` by the default 10 MB file limit) used to raise process memory to about 640 MB; it now stays around 140 MB.
- **`staticFiles()` loaded whole files into memory** — Files are now streamed from disk. Serving a 200 MB file used to take the process to 256 MB of memory; it now stays at 12 MB.
- **`WebSocketGroup` kept closed connections** — A closed connection stayed in its group until the next `broadcast()`, unless `onClose` called `remove()`. Members now leave the group by themselves when the connection closes. To make this work, the server now closes its side of a WebSocket when the client leaves, so `socket.done` completes. Calling `remove()` still works.
- **Errors in user callbacks crashed the server** — An exception thrown in a WebSocket `onMessage` or `onClose` callback, or in the server's own `onError`, ended the whole process. WebSocket callback errors now go to the route's `onError` (or are printed). A throwing `onError` now produces a plain `500`. A throwing `onClose` no longer makes `close()` hang. If `onStart` throws, the socket is now closed with code `1011`; before, it stayed open with nobody listening.
- **Malformed query strings crashed the server** — A request such as `/?a=%FF` (invalid UTF-8) threw before any handler ran, so any client could stop the process. Such bytes are now decoded as `U+FFFD`.

### Documentation

- **`SseContext.from(keepAliveInterval:)`** — Disabling the keep-alive pings means a client that went away is only noticed on the next `send()`, so the handler stays in memory until then. This is now documented.

## 2.5.1

### Security

- **Swagger UI SRI** — The `integrity` values shipped in 2.5.0 for `/quadrant_docs` were malformed and the CDN URL used a floating `@5` tag. The page now pins `swagger-ui-dist@5.33.1` with valid SHA-384 hashes.
- **`staticFiles()`** — The root-boundary check now requires a path separator, so a sibling directory whose name starts with the root's name (for example `/srv/public-private` for root `/srv/public`) is no longer reachable.
- **`multipartParser()`** — New `maxTotalBytes` option (default 50 MB) caps the whole request body, checked against `Content-Length` and again while streaming. Previously only per-file size was checked, after the full body had been buffered.

### Fixed

- **Dropped cookies** — `cors()` and `rateLimit()` no longer discard `Set-Cookie` values set with `Response.withCookie()`.
- **`StreamResponse` through middleware** — `helmet()`, `cors()`, `requestId()` and `rateLimit()` no longer replace a `StreamResponse` with an empty body.
- **`compress()` middleware order** — Compressed bodies now survive outer middlewares. Previously `compress()` only worked when it was the first middleware; otherwise clients received a gzip header with an empty body.
- **`bodyParser()` / `formParser()` 413 path** — Removed `req.raw.drain()` calls that ran after the request stream was already cancelled.
- **`rateLimit()`** — Idle clients are now evicted from memory. The docs now call it a sliding-window limiter (it never used a token bucket).

### Added

- `Response.copyWith()`, overridden by `StreamResponse`; `StreamResponse` now accepts `cookies`.
- `multipartParser(maxTotalBytes: ...)`.

### Changed

- `compress()` now returns a `StreamResponse`. The internal `consumeCompressedBody` helper was removed.

## 2.5.0

### Security & Hardening

- **`Response.redirect()` validation** — Replaced `assert` with runtime `ArgumentError` validation so invalid status codes throw in release mode.
- **`bodyParser()` error propagation** — Narrowed body parser try-catch to `on FormatException` so low-level socket and connection errors are not swallowed. Added `maxBodyBytes` guard to defend against body-size DoS (returns `413 Payload Too Large`).
- **`cors()` preflight caching** — Added `maxAge` parameter (defaults to 86,400s) emitting `Access-Control-Max-Age` header on OPTIONS preflights to prevent repeated OPTIONS round-trips.
- **`docs.dart` CDN asset integrity** — Added Subresource Integrity (SRI) hashes (`integrity` & `crossorigin`) to Swagger UI CDN scripts and stylesheets.
- **Static files path traversal security** — Path resolution in `staticFiles()` now normalizes paths with URI semantics to prevent directory traversal escapes (`..`).
- **`docsLocalOnly` option wiring** — Fixed constructor parameter passthrough in `QuadrantServer` so `docsLocalOnly: false` is honored when intentionally deployed behind a proxy.

### Added

- **`helmet()` middleware** — Injects 8 essential HTTP security headers (`X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy`, etc.).
- **`requestId()` middleware** — Generates and forwards `X-Request-ID` (UUID v4) for distributed request tracing, exposed in `req.context['requestId']`.
- **`rateLimit()` middleware** — Sliding-window rate limiting per client IP or custom key with `X-RateLimit-*` and `Retry-After` headers.
- **`bearerAuth()` middleware** — Extracts bearer token, validates against async callback, and injects principal into `req.context['user']`.
- **`ipFilter()` middleware** — Allow-list or deny-list client IP addresses supporting exact match and IPv4/IPv6 CIDR ranges.
- **`cookieParser()` middleware & Response cookie helpers** — Parses `Cookie` header into `req.context['cookies']`; added `Response.withCookie()` and `Response.clearCookie()` with `Set-Cookie` generation.
- **`formParser()` middleware** — Decodes `application/x-www-form-urlencoded` payloads into `req.body` with configurable byte limits.
- **`multipartParser()` middleware** — Handles multipart file uploads and form fields, exposing typed `UploadedFile` instances in `req.context['files']`.
- **`compress()` middleware** — Response gzip compression using `dart:io` `GZipCodec` with `Accept-Encoding` negotiation.
- **`etag()` middleware** — Generates weak ETags and handles `If-None-Match` conditional requests returning `304 Not Modified`.
- **`SseContext`** — Push-based Server-Sent Events (SSE) compatible with browser `EventSource` and automatic keep-alive comment pings.
- **`StreamResponse`** — Response subclass for streaming raw bytes directly to client sockets without memory buffering.
- **Request validation DSL** — `BodySchema` and `Field` (`string`, `int_`, `double_`, `bool_`, `list`) with `validate()` middleware returning `422 Unprocessable Entity`.
- **`listenSecure()`** — First-class HTTPS/TLS binding with `certificateChain` and `privateKey` files.
- **Health check endpoint** — Optional built-in `/health` reporting uptime, request counts, and RSS memory usage.
- **WebSocket heartbeats** — Configurable `heartbeat` duration on `WebSocketRoute` for automatic ping/pong keepalive.
- **Graceful in-flight request draining** — `app.close()` drains active requests before terminating.
- **`timeout(Duration, {onTimeout})` middleware** — Races the handler chain against a deadline; returns `408` with `{"error":"Request Timeout","timeoutMs":…}` or your `onTimeout` response.
- **`staticFiles(rootDir, {indexFallback})` route handler** — MIME detection, `ETag`/`Last-Modified` with `304` for `If-None-Match`/`If-Modified-Since`, `Cache-Control: public, max-age=3600`, `index.html` fallback.
- **`healthCheckPath` option** — Default `/health`. The endpoint is answered before middleware runs, so it skips auth, rate limiting and logging.
- **`app.close({force})`** — `force: true` skips draining in-flight requests.
- **TLS/binding options** — `listenSecure(password:)` for encrypted keys; `listen`/`listenSecure` accept `address`.
- **Validation rules** — `required`, `minLength`, `maxLength`, `matches(RegExp)`, `email`, `oneOf`, `min`, `max`, `minItems`, `maxItems`. String inputs are coerced for int/double/bool fields. Failures return `422 {"errors": {field: message}}`.
- **`SseContext` API** — `send(id:, retry:)`, `sendComment()`, `close()`, `isOpen`, `keepAliveInterval` (default 15 s, `Duration.zero` disables), `X-Accel-Buffering: no`.
- **`WebSocketGroup`** — `exclude:` on `broadcast`/`broadcastJson`, plus `isEmpty`, `isNotEmpty`, `length`, `members`.
- **Middleware options** — `bearerAuth(contextKey, realm)` with `WWW-Authenticate` on 401; `ipFilter(onDeny)`; `multipartParser(maxFileSize, filesContextKey, fieldsContextKey)` returning `413` for oversized files; `bodyParser`/`formParser` accept `maxBodyBytes: 0` to disable the limit; all 8 `helmet()` headers are overridable and `null` removes one.

### Fixed

- **WebSocket upgrade error handling** — Upgrades failing in `onError` now return an HTTP error response to the client rather than leaving the connection hanging.
- **WebSocket middleware chain sentinel** — Replaced dummy 200 response with `Response(204)` sentinel.
- **Connection close resilience** — Guarded `_writeResponse` against writing to already-closed HTTP sockets.
- **Banner ASCII padding** — Handled high route counts safely with `max(0, ...)`.

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
