# QuadrantServer example app

A small API you can run and deploy, showing the `quadrant_server` features you would use in production. It has a users API, file uploads, WebSocket chat, and configuration from the environment.

To put it on a server, follow **[DEPLOY.md](DEPLOY.md)**.

## Run it

```bash
cd example
dart pub get
dart run lib/main.dart
```

The server listens on **http://localhost:5050**, with API docs at **http://localhost:5050/quadrant_docs**. In development it accepts two demo tokens, `secret-admin-token` and `secret-user-token`.

Run the tests with `dart test`.

## Layout

```
example/
├── lib/
│   ├── main.dart            Starts the cluster, handles shutdown signals
│   ├── app.dart             Routes and middleware, in buildServer()
│   ├── config.dart          Settings from the environment
│   ├── handlers/
│   │   ├── users.dart       REST API with validation and paging
│   │   ├── files.dart       Streaming uploads and downloads
│   │   ├── chat.dart        WebSocket rooms
│   │   └── system.dart      Info, echo, redirect
│   └── middlewares/
│       └── auth.dart        Bearer tokens and an admin check
├── deploy/
│   ├── quadrant-example.service   systemd unit
│   ├── nginx.conf                 Reverse proxy
│   ├── app.env.example            Production settings
│   └── update.sh                  Build, deploy, and go back on failure
├── Dockerfile
├── docker-compose.yml
├── DEPLOY.md
└── test/
```

## Settings

All are environment variables, and all are optional in development.

| Variable | Default | Purpose |
|---|---|---|
| `APP_ENV` | | `production` turns off the docs and demo tokens, and turns on HSTS |
| `ADMIN_TOKEN`, `USER_TOKEN` | | Required in production, at least 32 characters each |
| `PORT` | `5050` | Port to listen on |
| `ADDRESS` | `127.0.0.1` | Address to listen on. `0.0.0.0` accepts connections from anywhere |
| `ISOLATES` | `1` | Number of isolates. See [the note on isolates](#isolates) |
| `TRUSTED_PROXY_HOPS` | `0` | Proxies in front of the app. Set to `1` behind nginx, and leave at `0` without a proxy, or clients can dodge rate limits |
| `CORS_ORIGIN` | `*` in development, otherwise none | Browser origin allowed to call the API |
| `DATA_DIR` | `./data` | Where uploads are kept |

The app exits with code `78` if a setting is wrong, and the systemd unit does not retry on that code.

## What to look at

| Feature | Where |
|---|---|
| `QuadrantCluster`, restarts and graceful shutdown | `lib/main.dart` |
| Middleware, on all routes and on one route | `lib/app.dart` |
| `rateLimit()` behind a proxy, with `trustedProxyHops` | `lib/app.dart` |
| `validate()` with schemas | `lib/handlers/users.dart` |
| `bearerAuth()` and roles | `lib/middlewares/auth.dart` |
| `multipartParser(diskThreshold:)` and `moveTo()` | `lib/app.dart`, `lib/handlers/files.dart` |
| `WebSocketGroup(name:)` across isolates | `lib/handlers/chat.dart` |
| Built-in health check | `healthCheck: true` in `lib/app.dart` |

### Isolates

`ISOLATES` defaults to `1`, because users are kept in a variable, and a variable exists once per isolate. With more than one, a user created on one isolate would be missing on the others, and all of them are lost on restart. Rate limits and chat already work across isolates, so once users are in a database, open its connection inside `buildServer()` and raise `ISOLATES`.

## Try the API

```bash
export API=http://localhost:5050
export ADMIN='Authorization: Bearer secret-admin-token'
export USER_TOKEN='Authorization: Bearer secret-user-token'

curl $API/health
curl $API/api/v1/info

# Reading is public
curl "$API/api/v1/users?role=admin&page=1&limit=5"
curl $API/api/v1/users/1

# Writing needs a token
curl -X POST $API/api/v1/users -H "$USER_TOKEN" \
  -H 'Content-Type: application/json' -d '{"name": "Linus Torvalds"}'

curl -X PUT $API/api/v1/users/1 -H "$ADMIN" \
  -H 'Content-Type: application/json' -d '{"name": "Ada", "role": "admin"}'

curl -X PATCH $API/api/v1/users/2 -H "$USER_TOKEN" \
  -H 'Content-Type: application/json' -d '{"name": "Grace M. Hopper"}'

# Deleting needs an admin
curl -X DELETE $API/api/v1/users/3 -H "$ADMIN"

# Upload a file, up to 100 MB, then download it from the URL in the response
curl -X POST $API/api/v1/files -H "$USER_TOKEN" -F 'file=@photo.jpg'
curl -H "$USER_TOKEN" -o copy.jpg $API/api/v1/files/<name-from-the-response>.bin
```

Invalid bodies get a `422` listing the problems, and going over a rate limit gets a `429` with `Retry-After`.

## Try the WebSockets

The chat is public, so anyone who can reach it can join. It has rate limits on connecting and a size limit on messages, but add `requireAuth()` to its route if yours should be private.

```js
const ws = new WebSocket('ws://localhost:5050/ws/chat/general');
ws.onmessage = (e) => console.log(JSON.parse(e.data));

ws.send(JSON.stringify({ name: 'Alice' })); // Set your display name
ws.send('Hello everyone!');                 // Send a message
```

| Event | When |
|---|---|
| `welcome` | You connected. Includes the room and your guest name |
| `name_set` | Your display name changed |
| `user_joined`, `user_left`, `user_renamed` | Someone else in the room did that |
| `message` | Someone else in the room sent a message |
| `error` | Your message was refused, for being binary or too long |

`/ws/ping` answers each message with `{"event":"pong","echo":"...","ts":...}`, to test a connection.
