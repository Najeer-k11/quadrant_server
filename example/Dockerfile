FROM dart:stable

WORKDIR /app

# Copy pubspec files first
COPY pubspec.yaml pubspec.lock ./

# Clean any stale cache and fetch fresh
RUN dart pub cache clean -f && dart pub get

# Copy the rest
COPY . .

EXPOSE 5050

CMD ["dart", "run", "lib/main.dart"]
