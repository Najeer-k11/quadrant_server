# Build from the repository root, as the app depends on the package beside it:
#   docker build -f example/Dockerfile -t quadrant-example .
# With a published package, you would need only your own app in the build.

# ─── Stage 1: Build ────────────────────────────────────────────
FROM dart:stable AS builder

WORKDIR /src
COPY pubspec.yaml pubspec.lock ./
COPY lib ./lib
COPY example/pubspec.yaml example/pubspec.lock ./example/

WORKDIR /src/example
RUN dart pub get --enforce-lockfile

COPY example/lib ./lib
RUN mkdir -p /out && dart compile exe lib/main.dart -o /out/server

# ─── Stage 2: Runtime ──────────────────────────────────────────
FROM debian:bookworm-slim

RUN useradd --system --uid 10001 --no-create-home --shell /usr/sbin/nologin quadrant \
    && mkdir /data \
    && chown quadrant:quadrant /data

COPY --from=builder /out/server /app/server

USER quadrant
ENV DATA_DIR=/data ADDRESS=0.0.0.0 PORT=5050
VOLUME /data
EXPOSE 5050

# Uses the app itself, as this image has no curl.
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=10s \
    CMD ["/app/server", "--healthcheck"]

CMD ["/app/server"]
