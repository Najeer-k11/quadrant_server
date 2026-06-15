import '../middleware.dart';
import '../request.dart';
import '../response.dart';

/// CORS middleware. Adds CORS headers to every response.
///
/// [origin] — Allowed origin. Defaults to `'*'` (all origins).
/// [methods] — Allowed HTTP methods. Defaults to all common methods.
/// [allowedHeaders] — Allowed request headers.
///
/// When [origin] is not `'*'`, a `Vary: Origin` header is automatically
/// added so CDNs and proxies cache responses correctly per origin.
Middleware cors({
  String origin = '*',
  String methods = 'GET, POST, PUT, DELETE, PATCH, OPTIONS',
  String allowedHeaders = 'Content-Type, Authorization',
}) {
  final corsHeaders = <String, String>{
    'access-control-allow-origin': origin,
    'access-control-allow-methods': methods,
    'access-control-allow-headers': allowedHeaders,
    // Required when origin is specific (not '*') so caches key on Origin.
    if (origin != '*') 'vary': 'Origin',
  };

  return (Request req, Next next) async {
    // Handle preflight OPTIONS requests.
    if (req.method == 'OPTIONS') {
      return Response(
        statusCode: 204,
        headers: corsHeaders,
      );
    }

    final response = await next();

    // Merge CORS headers into the actual response.
    final mergedHeaders = Map<String, String>.from(response.headers)
      ..addAll(corsHeaders);

    return Response(
      statusCode: response.statusCode,
      headers: mergedHeaders,
      body: response.body,
    );
  };
}
