import 'request.dart';
import 'response.dart';

/// Function that produces the next [Response] in the middleware chain.
typedef Next = Future<Response> Function();

/// A middleware function that receives a [Request] and a [Next] callback.
///
/// Can either call [next] to continue the chain, or return a [Response]
/// directly to short-circuit.
typedef Middleware = Future<Response> Function(Request req, Next next);
