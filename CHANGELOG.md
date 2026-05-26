## 1.1.0

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
