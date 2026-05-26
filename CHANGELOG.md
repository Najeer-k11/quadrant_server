## 1.0.0

- Initial release
- Core framework: `QuadrantServer`, `Request`, `Response`, `Route`, `Router`
- Middleware system with global and route-level support
- Built-in middlewares: `cors()`, `logger()`, `bodyParser()`
- Path parameter extraction (`:param` segments)
- Immutable response pattern with static constructors
- Zero external dependencies — built entirely on `dart:io`
