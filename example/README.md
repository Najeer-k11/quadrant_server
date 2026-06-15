# QuadrantServer — Example App

A fully-featured reference application demonstrating every feature of the `quadrant_server` package.

## Project Structure

```
example/
├── lib/
│   ├── main.dart                  ← Entry point — wires everything together
│   ├── handlers/
│   │   ├── users.dart             ← CRUD REST API with pagination & validation
│   │   ├── chat.dart              ← WebSocket chat rooms using WebSocketGroup
│   │   └── system.dart            ← Health, echo, redirect, catch-all routes
│   └── middlewares/
│       └── auth.dart              ← Bearer-token auth & admin-only guard
├── Dockerfile                     ← Multi-stage AOT build → lean ~10MB image
├── docker-compose.yml             ← Single-command deployment with healthcheck
└── README.md
```

## Features Demonstrated

| Feature | Where |
|---|---|
| `QuadrantRouter` prefix mounting | `main.dart` — `/api/v1` router |
| Route-level middleware | `main.dart` — `requireAuth()` / `requireAdmin()` per route |
| Global middleware | `main.dart` — `cors()`, `logger()`, `bodyParser()` |
| Full CRUD REST API | `handlers/users.dart` |
| Typed query helpers | `handlers/users.dart` — `queryInt`, `queryString` |
| JSON body parsing | `handlers/users.dart` — `req.bodyAsMap` |
| JSON array body | `handlers/system.dart` — `/echo` accepts both Map and List |
| `Response.redirect()` | `handlers/system.dart` — `/api` → `/api/v1/info` |
| `Response.text/html` | Available; use `Response.text('plain')` |
| Wildcard catch-all route | `main.dart` — `/api/v1/unknown/*` |
| WebSocket rooms | `handlers/chat.dart` — `WebSocketGroup` broadcast |
| WS presence tracking | `handlers/chat.dart` — display name assignment |
| WS ping/echo endpoint | `main.dart` + `handlers/chat.dart` — `/ws/ping` |
| WS middleware guard | Extend: add `middlewares: [requireAuth()]` to `WebSocketRoute` |
| `onError` global handler | `main.dart` — logs server-side, returns safe client message |
| `PORT` env variable | `main.dart` — `int.tryParse(Platform.environment['PORT'])` |
| Docker multi-stage build | `Dockerfile` — AOT compile → `debian:slim` runtime |

## Running Locally

```bash
dart pub get
dart run lib/main.dart
```

Server starts on **http://localhost:5050**.

## Running with Docker

```bash
docker compose up --build
```

## API Reference

### Public endpoints (no auth)

```bash
# Health check
curl http://localhost:5050/health

# API info
curl http://localhost:5050/api/v1/info

# List users (with optional filter & pagination)
curl http://localhost:5050/api/v1/users
curl "http://localhost:5050/api/v1/users?role=admin&page=1&limit=5"

# Get user by ID
curl http://localhost:5050/api/v1/users/1

# Echo body (object or array)
curl -X POST http://localhost:5050/api/v1/echo \
  -H 'Content-Type: application/json' \
  -d '{"hello":"world"}'
```

### Protected endpoints (require auth)

Use one of the demo tokens:
- `secret-admin-token` — admin role (all write operations)
- `secret-user-token` — user role (create/update, not delete)

```bash
# Create user
curl -X POST http://localhost:5050/api/v1/users \
  -H 'Authorization: Bearer secret-admin-token' \
  -H 'Content-Type: application/json' \
  -d '{"name": "Linus Torvalds", "role": "user"}'

# Update user
curl -X PUT http://localhost:5050/api/v1/users/1 \
  -H 'Authorization: Bearer secret-admin-token' \
  -H 'Content-Type: application/json' \
  -d '{"name": "Ada Lovelace", "role": "admin"}'

# Partial update (PATCH)
curl -X PATCH http://localhost:5050/api/v1/users/2 \
  -H 'Authorization: Bearer secret-user-token' \
  -H 'Content-Type: application/json' \
  -d '{"name": "Grace M. Hopper"}'

# Delete user (admin only)
curl -X DELETE http://localhost:5050/api/v1/users/3 \
  -H 'Authorization: Bearer secret-admin-token'
```

## WebSocket

### Chat rooms

Connect with any WebSocket client to: `ws://localhost:5050/ws/chat/<roomId>`

```js
const ws = new WebSocket('ws://localhost:5050/ws/chat/general');

ws.onmessage = (e) => console.log(JSON.parse(e.data));

// Set your display name
ws.send(JSON.stringify({ name: 'Alice' }));

// Send a chat message
ws.send('Hello everyone!');

// Send structured JSON
ws.send(JSON.stringify({ text: 'Hello from JSON!', emoji: '👋' }));
```

Server events you will receive:

| Event | When |
|---|---|
| `welcome` | On connect — includes room name and current online count |
| `user_joined` | Another user connected to your room |
| `user_left` | Another user disconnected |
| `user_renamed` | Another user set their display name |
| `name_set` | Your name was set successfully |
| `message` | A chat message from another user |

### Ping / echo

```js
const ws = new WebSocket('ws://localhost:5050/ws/ping');
ws.send('hello');
// Receives: {"event":"pong","echo":"hello","ts":1718000000000}
```

## Swagger UI Docs

Visit **http://localhost:5050/quadrant_docs** for the interactive API explorer.
