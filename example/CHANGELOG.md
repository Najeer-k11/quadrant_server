## 2.0.0

- Deployable: configuration from the environment, generated tokens in production, graceful shutdown, and a VPS guide in `DEPLOY.md`.
- Runs on `QuadrantCluster`, with chat rooms that work across isolates.
- Adds streaming file uploads, request validation and stricter rate limits.
- Fixes the Docker build and health check, which did not work.
- Fixes `500`s from `?limit=0` and from wrong types in a request body.
- `PUT` and `PATCH` no longer store fields that were not declared.

## 1.0.0

- Initial version.
