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
