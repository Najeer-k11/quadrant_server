import 'dart:io';

/// Thrown when the environment does not describe a usable configuration.
class ConfigException implements Exception {
  final String message;
  const ConfigException(this.message);

  @override
  String toString() => message;
}

/// Everything that differs between a laptop and a server.
///
/// A [Config] is sent to each isolate of the cluster, so it holds plain values
/// only: no open files, sockets or database connections.
class Config {
  /// Tokens used when `APP_ENV` is not `production`. Never accepted in
  /// production.
  static const demoTokens = {
    'secret-admin-token': 'admin',
    'secret-user-token': 'user',
  };

  static const _minTokenLength = 32;

  final bool production;
  final int port;
  final String address;
  final int isolates;
  final String dataDir;
  final int trustedProxyHops;

  /// The allowed browser origin, or null to send no CORS headers.
  final String? corsOrigin;

  /// Maps each accepted bearer token to its role.
  final Map<String, String> tokens;

  const Config({
    required this.production,
    required this.port,
    required this.address,
    required this.isolates,
    required this.dataDir,
    required this.trustedProxyHops,
    required this.corsOrigin,
    required this.tokens,
  });

  String get uploadsDir => '$dataDir/uploads';
  String get tempDir => '$dataDir/tmp';

  factory Config.fromEnvironment(Map<String, String> env) {
    final production = env['APP_ENV'] == 'production';

    return Config(
      production: production,
      port: portFrom(env),
      address: env['ADDRESS'] ?? '127.0.0.1',
      isolates: _intFrom(env, 'ISOLATES', fallback: 1, min: 1, max: 256),
      dataDir: Directory(env['DATA_DIR'] ?? 'data').absolute.path,
      trustedProxyHops:
          _intFrom(env, 'TRUSTED_PROXY_HOPS', fallback: 0, min: 0, max: 16),
      corsOrigin: env['CORS_ORIGIN'] ?? (production ? null : '*'),
      tokens: production ? _productionTokens(env) : demoTokens,
    );
  }

  /// Read on its own, so that `--healthcheck` works without any secrets.
  static int portFrom(Map<String, String> env) =>
      _intFrom(env, 'PORT', fallback: 5050, min: 0, max: 65535);

  static int _intFrom(
    Map<String, String> env,
    String name, {
    required int fallback,
    required int min,
    required int max,
  }) {
    final raw = env[name];
    if (raw == null || raw.isEmpty) return fallback;
    final value = int.tryParse(raw);
    if (value == null || value < min || value > max) {
      throw ConfigException('$name must be a number from $min to $max.');
    }
    return value;
  }

  static Map<String, String> _productionTokens(Map<String, String> env) {
    String token(String name) {
      final value = env[name] ?? '';
      if (value.length < _minTokenLength) {
        throw ConfigException(
          '$name must be at least $_minTokenLength characters in production. '
          'Generate one with: openssl rand -hex 32',
        );
      }
      if (demoTokens.containsKey(value)) {
        throw ConfigException('$name must not be a demo token.');
      }
      return value;
    }

    final admin = token('ADMIN_TOKEN');
    final user = token('USER_TOKEN');
    if (admin == user) {
      throw const ConfigException('ADMIN_TOKEN and USER_TOKEN must differ.');
    }
    return {admin: 'admin', user: 'user'};
  }
}
