import '../middleware.dart';
import '../request.dart';
import '../response.dart';

/// CORS middleware. Adds CORS headers to every response.
///
/// [origin] — Allowed origin. Defaults to '*' (all origins).
Middleware cors({String origin = '*'}) {
  return (Request req, Next next) async {
    // Handle preflight OPTIONS requests
    if (req.method == 'OPTIONS') {
      return Response(
        statusCode: 204,
        headers: {
          'access-control-allow-origin': origin,
          'access-control-allow-methods':
              'GET, POST, PUT, DELETE, PATCH, OPTIONS',
          'access-control-allow-headers': 'Content-Type, Authorization',
        },
      );
    }

    final response = await next();

    // Add CORS headers to the actual response
    final mergedHeaders = Map<String, String>.from(response.headers);
    mergedHeaders['access-control-allow-origin'] = origin;
    mergedHeaders['access-control-allow-methods'] =
        'GET, POST, PUT, DELETE, PATCH, OPTIONS';
    mergedHeaders['access-control-allow-headers'] =
        'Content-Type, Authorization';

    return Response(
      statusCode: response.statusCode,
      headers: mergedHeaders,
      body: response.body,
    );
  };
}
