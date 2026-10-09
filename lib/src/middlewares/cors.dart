import '../middleware.dart';
import '../request.dart';
import '../response.dart';

/// CORS middleware. Adds CORS headers to every response.
///
/// [origin] — Allowed origin. Defaults to `'*'` (all origins).
/// [methods] — Allowed HTTP methods. Defaults to all common methods.
/// [allowedHeaders] — Allowed request headers.
/// [maxAge] — How long (in seconds) browsers may cache the preflight result.
///   Defaults to `86400` (24 hours). Set to `0` to disable caching.
///
/// When [origin] is not `'*'`, a `Vary: Origin` header is automatically
/// added so CDNs and proxies cache responses correctly per origin.
Middleware cors({
  String origin = '*',
  String methods = 'GET, POST, PUT, DELETE, PATCH, OPTIONS',
  String allowedHeaders = 'Content-Type, Authorization',
  int maxAge = 86400,
}) {
  final corsHeaders = <String, String>{
    'access-control-allow-origin': origin,
    'access-control-allow-methods': methods,
    'access-control-allow-headers': allowedHeaders,
    // Required when origin is specific (not '*') so caches key on Origin.
    if (origin != '*') 'vary': 'Origin',
  };

  // Preflight-only headers (not needed on actual responses).
  final preflightHeaders = <String, String>{
    ...corsHeaders,
    if (maxAge > 0) 'access-control-max-age': '$maxAge',
  };

  return (Request req, Next next) async {
    // Handle preflight OPTIONS requests.
    if (req.method == 'OPTIONS') {
      return Response(
        statusCode: 204,
        headers: preflightHeaders,
      );
    }

    final response = await next();

    // Merge CORS headers into the actual response.
    final mergedHeaders = Map<String, String>.from(response.headers)
      ..addAll(corsHeaders);

    return response.copyWith(headers: mergedHeaders);
  };
}
