# ─── Stage 1: Build ────────────────────────────────────────────
FROM dart:stable AS builder

WORKDIR /app

# Copy the parent package (quadrant_server) first.
# In a real publish scenario this would be a pub.dev dependency.
COPY ../pubspec.yaml ../pubspec.lock /quadrant_server/
COPY ../lib /quadrant_server/lib/

# Copy the example app.
COPY pubspec.yaml pubspec.lock ./
RUN dart pub get

COPY . .

# AOT compile to a self-contained executable.
RUN dart compile exe lib/main.dart -o bin/server

# ─── Stage 2: Minimal runtime ──────────────────────────────────
FROM debian:bookworm-slim

WORKDIR /app

# Copy only the compiled binary.
COPY --from=builder /app/bin/server ./server

EXPOSE 5050

CMD ["./server"]
