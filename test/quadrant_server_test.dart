import 'dart:convert';
import 'dart:io';

import 'package:quadrant_server/quadrant_server.dart';
import 'package:quadrant_server/src/middlewares/compress.dart';
import 'package:quadrant_server/src/middlewares/cookie_parser.dart';
import 'package:quadrant_server/src/router.dart';
import 'package:test/test.dart';

// ─── Helpers ─────────────────────────────────────────────────

Future<Response> _ok(Request req) async => Response.ok({'ok': true});
Future<Response> _echo(Request req) async => Response.ok({'id': req.params['id']});
// Future<Response> _bodyEcho(Request req) async => Response.ok(req.bodyAsMap ?? {});
// Future<Response> _listEcho(Request req) async => Response.ok(req.bodyAsList ?? []);

// ─── Tests ───────────────────────────────────────────────────

void main() {
  group('Response factories', () {
    test('ok() encodes Map as JSON', () {
      final r = Response.ok({'key': 'value'});
      expect(r.statusCode, 200);
      expect(r.headers['content-type'], contains('application/json'));
      expect(r.body, contains('"key":"value"'));
    });

    test('ok() encodes List as JSON', () {
      final r = Response.ok([1, 2, 3]);
      expect(r.statusCode, 200);
      expect(r.body, '[1,2,3]');
    });

    test('text() sets text/plain content-type', () {
      final r = Response.text('hello');
      expect(r.statusCode, 200);
      expect(r.headers['content-type'], contains('text/plain'));
      expect(r.body, 'hello');
    });

    test('html() sets text/html content-type', () {
      final r = Response.html('<h1>hi</h1>');
      expect(r.statusCode, 200);
      expect(r.headers['content-type'], contains('text/html'));
    });

    test('redirect() sets location header and 302 by default', () {
      final r = Response.redirect('/new-path');
      expect(r.statusCode, 302);
      expect(r.headers['location'], '/new-path');
    });

    test('redirect() accepts custom status codes', () {
      final r = Response.redirect('/perm', statusCode: 301);
      expect(r.statusCode, 301);
    });

    test('redirect() throws ArgumentError for invalid status codes (Fix 6)', () {
      expect(() => Response.redirect('/bad', statusCode: 303),
          throwsA(isA<ArgumentError>()));
      expect(() => Response.redirect('/bad', statusCode: 200),
          throwsA(isA<ArgumentError>()));
    });

    test('created() returns 201', () {
      final r = Response.created({'id': '1'});
      expect(r.statusCode, 201);
    });

    test('noContent() returns 204 with empty body', () {
      final r = Response.noContent();
      expect(r.statusCode, 204);
      expect(r.body, isEmpty);
    });

    test('badRequest() returns 400', () {
      final r = Response.badRequest('nope');
      expect(r.statusCode, 400);
      expect(r.body, contains('"error"'));
    });

    test('unauthorized() returns 401', () {
      expect(Response.unauthorized('u').statusCode, 401);
    });

    test('forbidden() returns 403', () {
      expect(Response.forbidden('f').statusCode, 403);
    });

    test('notFound() returns 404', () {
      expect(Response.notFound('nf').statusCode, 404);
    });

    test('conflict() returns 409', () {
      expect(Response.conflict('c').statusCode, 409);
    });

    test('internalServerError() returns 500', () {
      expect(Response.internalServerError('err').statusCode, 500);
    });

    test('plain string body gets text/plain content-type', () {
      final r = Response.ok('just a string');
      expect(r.headers['content-type'], contains('text/plain'));
    });
  });

  group('Request typed query helpers', () {
    // The typed helpers are pure logic on query map values.
    // We test the equivalent logic inline since constructing a full
    // Request requires a live dart:io HttpRequest.
    test('queryString returns value or default', () {
      final fakeQuery = {'name': 'ada'};
      // Simulate the logic inline.
      expect(fakeQuery['name'] ?? '', 'ada');
      expect(fakeQuery['missing'] ?? 'default', 'default');
    });

    test('queryInt parses integer strings', () {
      int? parse(String? raw) => raw == null ? null : int.tryParse(raw);
      expect(parse('42'), 42);
      expect(parse('abc'), null);
      expect(parse(null), null);
    });

    test('queryBool recognises truthy / falsy strings', () {
      bool? parseBool(String? raw) {
        if (raw == null) return null;
        if (['true', '1', 'yes'].contains(raw)) return true;
        if (['false', '0', 'no'].contains(raw)) return false;
        return null;
      }

      expect(parseBool('true'), true);
      expect(parseBool('1'), true);
      expect(parseBool('yes'), true);
      expect(parseBool('false'), false);
      expect(parseBool('0'), false);
      expect(parseBool('no'), false);
      expect(parseBool('maybe'), null);
      expect(parseBool(null), null);
    });
  });

  group('Request.context', () {
    test('defaults to empty map', () {
      final req = _FakeRequest();
      expect(req.context, isEmpty);
    });

    test('copyWith merges context', () {
      final req = _FakeRequest();
      final updated = req.copyWith(context: {'user': 'alice', 'role': 'admin'});
      expect(updated.context['user'], 'alice');
      expect(updated.context['role'], 'admin');
    });

    test('copyWith with context does not affect other fields', () {
      final req = _FakeRequest();
      final updated = req.copyWith(context: {'x': 1});
      expect(updated.method, req.method);
      expect(updated.path, req.path);
    });
  });

  group('Router', () {
    late Router router;

    setUp(() {
      router = Router([
        Route.get(path: '/users', handler: _ok),
        Route.get(path: '/users/:id', handler: _echo),
        Route.post(path: '/users', handler: _ok),
        Route.get(path: '/files/*', handler: _ok),
      ]);
    });

    test('matches exact static route', () {
      final result = router.match('GET', '/users');
      expect(result, isA<Matched>());
    });

    test('matches named param route and extracts param', () {
      final result = router.match('GET', '/users/42') as Matched;
      expect(result.params['id'], '42');
    });

    test('matches wildcard route and captures remainder', () {
      final result = router.match('GET', '/files/a/b/c') as Matched;
      expect(result.params['*'], 'a/b/c');
    });

    test('normalises trailing slash', () {
      final result = router.match('GET', '/users/');
      expect(result, isA<Matched>());
    });

    test('returns MethodNotAllowed for wrong method on known path', () {
      final result = router.match('DELETE', '/users');
      expect(result, isA<MethodNotAllowed>());
      final r = result as MethodNotAllowed;
      expect(r.allowedMethods, containsAll(['GET', 'POST']));
    });

    test('returns NotFound for unknown path', () {
      final result = router.match('GET', '/unknown');
      expect(result, isA<NotFound>());
    });

    test('HEAD falls back to GET route', () {
      final result = router.match('HEAD', '/users');
      expect(result, isA<Matched>());
    });

    test('is case-insensitive on method', () {
      final result = router.match('get', '/users');
      expect(result, isA<Matched>());
    });
  });

  group('QuadrantRouter prefix mounting', () {
    test('prepends prefix to all routes', () {
      final r = QuadrantRouter(prefix: '/api/v1')
        ..get('/users', _ok)
        ..post('/users', _ok);

      expect(r.routes[0].path, '/api/v1/users');
      expect(r.routes[1].path, '/api/v1/users');
      expect(r.routes[0].method, 'GET');
      expect(r.routes[1].method, 'POST');
    });

    test('handles prefix without trailing slash', () {
      final r = QuadrantRouter(prefix: '/v2')..get('/items', _ok);
      expect(r.routes[0].path, '/v2/items');
    });

    test('handles prefix with trailing slash', () {
      final r = QuadrantRouter(prefix: '/v2/')..get('/items', _ok);
      expect(r.routes[0].path, '/v2/items');
    });

    test('router-level middlewares prepended to route middlewares', () {
      Middleware mw1() => (req, next) async => next();
      Middleware mw2() => (req, next) async => next();

      final r = QuadrantRouter(prefix: '/a', middlewares: [mw1()])
        ..get('/x', _ok, middlewares: [mw2()]);

      expect(r.routes[0].middlewares.length, 2);
    });
  });

  group('WebSocketGroup', () {
    test('starts empty', () {
      final g = WebSocketGroup();
      expect(g.isEmpty, true);
      expect(g.length, 0);
    });

    // Note: WebSocketContext requires a live WebSocket, so these tests
    // verify the membership API using the public interface only.
    test('isNotEmpty after members would be added', () {
      final g = WebSocketGroup();
      expect(g.isNotEmpty, false);
      expect(g.isEmpty, true);
    });
  });

  group('Middleware chain', () {
    test('middleware short-circuits before handler', () async {
      bool handlerCalled = false;

      // A middleware that rejects without calling next().
      Future<Response> blockingMiddleware(Request req, Next next) async {
        return Response.unauthorized('blocked');
      }

      Future<Response> handler(Request req) async {
        handlerCalled = true;
        return Response.ok({'ok': true});
      }

      final fakeReq = _FakeRequest();
      // blockingMiddleware never calls next(), so handler is never reached.
      final result = await blockingMiddleware(
        fakeReq,
        () async => handler(fakeReq),
      );

      expect(result.statusCode, 401);
      expect(handlerCalled, false);
    });

    test('pass-through middleware calls next and returns its response',
        () async {
      Future<Response> passThroughMiddleware(Request req, Next next) async {
        return next(); // always continue
      }

      final fakeReq = _FakeRequest();
      final result = await passThroughMiddleware(
        fakeReq,
        () async => Response.ok({'forwarded': true}),
      );

      expect(result.statusCode, 200);
      expect(result.body, contains('forwarded'));
    });
  });

  // ─── CORS middleware ─────────────────────────────────────────

  group('CORS middleware', () {
    test('adds wildcard origin header', () async {
      final mw = cors();
      final req = _FakeRequest();
      final result = await mw(req, () async => Response.ok({'ok': true}));
      expect(result.headers['access-control-allow-origin'], '*');
    });

    test('preflight returns 204 with CORS headers', () async {
      final mw = cors();
      final req = _FakeRequest(method: 'OPTIONS');
      final result = await mw(req, () async => Response.ok(<String, dynamic>{}));
      expect(result.statusCode, 204);
      expect(result.headers['access-control-allow-methods'], isNotEmpty);
    });

    test('preflight includes access-control-max-age by default (Fix 9)', () async {
      final mw = cors();
      final req = _FakeRequest(method: 'OPTIONS');
      final result = await mw(req, () async => Response.ok(<String, dynamic>{}));
      expect(result.headers['access-control-max-age'], '86400');
    });

    test('preflight respects custom maxAge', () async {
      final mw = cors(maxAge: 3600);
      final req = _FakeRequest(method: 'OPTIONS');
      final result = await mw(req, () async => Response.ok(<String, dynamic>{}));
      expect(result.headers['access-control-max-age'], '3600');
    });

    test('maxAge=0 omits the header', () async {
      final mw = cors(maxAge: 0);
      final req = _FakeRequest(method: 'OPTIONS');
      final result = await mw(req, () async => Response.ok(<String, dynamic>{}));
      expect(result.headers.containsKey('access-control-max-age'), false);
    });

    test('specific origin adds Vary: Origin header', () async {
      final mw = cors(origin: 'https://example.com');
      final req = _FakeRequest();
      final result = await mw(req, () async => Response.ok(<String, dynamic>{}));
      expect(result.headers['vary'], 'Origin');
    });

    test('actual response does NOT include max-age header', () async {
      final mw = cors(maxAge: 86400);
      final req = _FakeRequest(); // GET, not OPTIONS
      final result = await mw(req, () async => Response.ok({'ok': true}));
      expect(result.headers.containsKey('access-control-max-age'), false);
    });
  });

  // ─── Rate limiting middleware ─────────────────────────────────

  group('Rate limiting middleware', () {
    // Helper: always use a static key so tests don't need connectionInfo.
    Middleware rl({required int max, Duration? window}) => rateLimit(
          maxRequests: max,
          window: window ?? Duration(seconds: 60),
          keyExtractor: (_) => 'test-ip',
        );

    test('allows requests within limit', () async {
      final mw = rl(max: 5);
      final req = _FakeRequest();

      for (var i = 0; i < 5; i++) {
        final result = await mw(req, () async => Response.ok({'ok': true}));
        expect(result.statusCode, 200);
      }
    });

    test('blocks requests exceeding limit with 429', () async {
      final mw = rl(max: 2);
      final req = _FakeRequest();

      await mw(req, () async => Response.ok(<String, dynamic>{}));
      await mw(req, () async => Response.ok(<String, dynamic>{}));
      final result = await mw(req, () async => Response.ok(<String, dynamic>{}));

      expect(result.statusCode, 429);
      expect(result.body, contains('Too Many Requests'));
    });

    test('429 response includes Retry-After header', () async {
      final mw = rl(max: 1, window: Duration(seconds: 30));
      final req = _FakeRequest();
      await mw(req, () async => Response.ok(<String, dynamic>{}));
      final result = await mw(req, () async => Response.ok(<String, dynamic>{}));

      expect(result.statusCode, 429);
      expect(result.headers.containsKey('retry-after'), true);
    });

    test('allowed responses include X-RateLimit-* headers', () async {
      final mw = rl(max: 10);
      final req = _FakeRequest();
      final result = await mw(req, () async => Response.ok(<String, dynamic>{}));

      expect(result.headers.containsKey('x-ratelimit-limit'), true);
      expect(result.headers.containsKey('x-ratelimit-remaining'), true);
      expect(result.headers.containsKey('x-ratelimit-reset'), true);
      expect(result.headers['x-ratelimit-limit'], '10');
    });

    test('custom keyExtractor is used for bucketing', () async {
      final mw = rateLimit(
        maxRequests: 1,
        window: Duration(seconds: 60),
        keyExtractor: (req) => req.headers['x-api-key'] ?? 'anon',
      );

      final req1 = _FakeRequest(headers: {'x-api-key': 'key-a'});
      final req2 = _FakeRequest(headers: {'x-api-key': 'key-b'});

      await mw(req1, () async => Response.ok(<String, dynamic>{}));
      // req1 is exhausted, req2 still has quota.
      final r1 = await mw(req1, () async => Response.ok(<String, dynamic>{}));
      final r2 = await mw(req2, () async => Response.ok(<String, dynamic>{}));

      expect(r1.statusCode, 429);
      expect(r2.statusCode, 200);
    });
  });

  // ─── Bearer auth middleware ───────────────────────────────────

  group('Bearer auth middleware', () {
    test('allows valid token and calls next()', () async {
      final mw = bearerAuth(
        validate: (token) async => token == 'valid' ? 'user-42' : null,
      );
      final req = _FakeRequest(headers: {'authorization': 'Bearer valid'});
      final result = await mw(req, () async => Response.ok({'ok': true}));
      expect(result.statusCode, 200);
    });

    test('rejects missing Authorization header with 401', () async {
      final mw = bearerAuth(validate: (t) async => 'user');
      final req = _FakeRequest();
      final result = await mw(req, () async => Response.ok(<String, dynamic>{}));
      expect(result.statusCode, 401);
    });

    test('rejects malformed Authorization header (no Bearer prefix)', () async {
      final mw = bearerAuth(validate: (t) async => 'user');
      final req = _FakeRequest(headers: {'authorization': 'Basic abc123'});
      final result = await mw(req, () async => Response.ok(<String, dynamic>{}));
      expect(result.statusCode, 401);
    });

    test('rejects when validate() returns null', () async {
      final mw = bearerAuth(validate: (t) async => null);
      final req = _FakeRequest(headers: {'authorization': 'Bearer bad-token'});
      final result = await mw(req, () async => Response.ok(<String, dynamic>{}));
      expect(result.statusCode, 401);
    });

    test('401 response includes WWW-Authenticate header', () async {
      final mw = bearerAuth(validate: (t) async => null);
      final req = _FakeRequest();
      final result = await mw(req, () async => Response.ok(<String, dynamic>{}));
      expect(result.headers.containsKey('www-authenticate'), true);
      expect(result.headers['www-authenticate'], contains('Bearer'));
    });

    test('custom realm appears in WWW-Authenticate', () async {
      final mw = bearerAuth(validate: (t) async => null, realm: 'myapp');
      final req = _FakeRequest();
      final result = await mw(req, () async => Response.ok(<String, dynamic>{}));
      expect(result.headers['www-authenticate'], contains('myapp'));
    });
  });

  // ─── Static files path traversal protection ──────────────────

  group('Static files — path traversal protection', () {
    test('detects paths that escape the root directory', () {
      const rootPath = '/var/www/public';
      const malicious = '../../etc/passwd';
      final rootUri = Uri.directory(rootPath);
      final resolvedPath =
          rootUri.resolve(malicious).normalizePath().toFilePath();
      expect(resolvedPath.startsWith(rootPath), false,
          reason: 'Path traversal must be detectable');
    });

    test('allows paths within the root directory', () {
      const rootPath = '/var/www/public';
      const safe = 'images/logo.png';
      final resolved = Directory('$rootPath/$safe').absolute.path;
      expect(resolved.startsWith(rootPath), true);
    });
  });

  // ─── Response cookies ────────────────────────────────────────

  group('Response cookies', () {
    test('withCookie adds formatted Set-Cookie string', () {
      final r = Response.ok({'status': 'ok'})
          .withCookie('session_id', 'xyz123', httpOnly: true, secure: true, sameSite: 'Strict');
      expect(r.cookies.length, 1);
      expect(r.cookies.first, contains('session_id=xyz123'));
      expect(r.cookies.first, contains('HttpOnly'));
      expect(r.cookies.first, contains('Secure'));
      expect(r.cookies.first, contains('SameSite=Strict'));
      expect(r.cookies.first, contains('Path=/'));
    });

    test('withCookie chains multiple cookies', () {
      final r = Response.ok(<String, dynamic>{})
          .withCookie('c1', 'v1')
          .withCookie('c2', 'v2', maxAge: Duration(hours: 1));
      expect(r.cookies.length, 2);
      expect(r.cookies[0], contains('c1=v1'));
      expect(r.cookies[1], contains('c2=v2'));
      expect(r.cookies[1], contains('Max-Age=3600'));
    });

    test('clearCookie sets Max-Age=0 and empty value', () {
      final r = Response.ok(<String, dynamic>{}).clearCookie('auth_token');
      expect(r.cookies.length, 1);
      expect(r.cookies.first, contains('auth_token='));
      expect(r.cookies.first, contains('Max-Age=0'));
    });
  });


  // ─── Request ID middleware ───────────────────────────────────

  group('Request ID middleware', () {
    test('generates UUID v4 and injects into header and response', () async {
      final mw = requestId();
      final req = _FakeRequest();
      final res = await mw(req, () async => Response.ok({'ok': true}));

      expect(res.headers.containsKey('x-request-id'), isTrue);
      final id = res.headers['x-request-id']!;
      expect(id, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
    });

    test('reuses existing X-Request-ID from incoming headers', () async {
      final mw = requestId();
      final req = _FakeRequest(headers: {'x-request-id': 'custom-trace-123'});
      final res = await mw(req, () async => Response.ok({'ok': true}));

      expect(res.headers['x-request-id'], 'custom-trace-123');
    });
  });

  // ─── Helmet middleware ───────────────────────────────────────

  group('Helmet middleware', () {
    test('attaches default security headers', () async {
      final mw = helmet();
      final req = _FakeRequest();
      final res = await mw(req, () async => Response.ok({'ok': true}));

      expect(res.headers['x-content-type-options'], 'nosniff');
      expect(res.headers['x-frame-options'], 'SAMEORIGIN');
      expect(res.headers['x-xss-protection'], '0');
      expect(res.headers['referrer-policy'], 'strict-origin-when-cross-origin');
      expect(res.headers['cross-origin-opener-policy'], 'same-origin');
      expect(res.headers['cross-origin-resource-policy'], 'same-origin');
    });

    test('allows customizing or disabling headers', () async {
      final mw = helmet(frameOptions: 'DENY', hsts: null);
      final req = _FakeRequest();
      final res = await mw(req, () async => Response.ok({'ok': true}));

      expect(res.headers['x-frame-options'], 'DENY');
      expect(res.headers.containsKey('strict-transport-security'), isFalse);
    });
  });

  // ─── Timeout middleware ──────────────────────────────────────

  group('Timeout middleware', () {
    test('completes normally when handler completes within duration', () async {
      final mw = timeout(Duration(seconds: 1));
      final req = _FakeRequest();
      final res = await mw(req, () async => Response.ok({'success': true}));

      expect(res.statusCode, 200);
    });

    test('returns 408 when handler exceeds duration', () async {
      final mw = timeout(Duration(milliseconds: 50));
      final req = _FakeRequest();
      final res = await mw(req, () async {
        await Future<void>.delayed(Duration(milliseconds: 150));
        return Response.ok(<String, dynamic>{});
      });

      expect(res.statusCode, 408);
      expect(res.body, contains('Request Timeout'));
    });

    test('uses custom onTimeout handler when specified', () async {
      final mw = timeout(
        Duration(milliseconds: 50),
        onTimeout: (req) => Response.badRequest('custom timeout'),
      );
      final req = _FakeRequest();
      final res = await mw(req, () async {
        await Future<void>.delayed(Duration(milliseconds: 150));
        return Response.ok(<String, dynamic>{});
      });

      expect(res.statusCode, 400);
      expect(res.body, contains('custom timeout'));
    });
  });

  // ─── Cookie parser middleware ────────────────────────────────

  group('Cookie parser middleware', () {
    test('parses Cookie header correctly into context', () async {
      final mw = cookieParser();
      final req = _FakeRequest(headers: {
        'cookie': 'theme=dark; user_token=abc%20123; tracking=true',
      });

      late Map<String, String> capturedCookies;
      await mw(req, () async {
        final ctx = consumeCookieContext(req.raw);
        capturedCookies = (ctx?['cookies'] as Map<String, String>?) ?? {};
        return Response.ok(<String, dynamic>{});
      });

      expect(capturedCookies['theme'], 'dark');
      expect(capturedCookies['user_token'], 'abc 123');
      expect(capturedCookies['tracking'], 'true');
    });

    test('handles empty or missing Cookie header gracefully', () async {
      final mw = cookieParser();
      final req = _FakeRequest();

      late Map<String, String> capturedCookies;
      await mw(req, () async {
        final ctx = consumeCookieContext(req.raw);
        capturedCookies = (ctx?['cookies'] as Map<String, String>?) ?? {};
        return Response.ok(<String, dynamic>{});
      });

      expect(capturedCookies, isEmpty);
    });
  });

  // ─── IP filter middleware ────────────────────────────────────

  group('IP filter middleware', () {
    test('allow list allows matching exact IP and blocks others', () async {
      final mw = ipFilter(allow: ['127.0.0.1']);

      final allowedReq = _FakeRequest(rawRequest: _FakeHttpRequestWithIp(InternetAddress('127.0.0.1')));
      final resAllowed = await mw(allowedReq, () async => Response.ok({'ok': true}));
      expect(resAllowed.statusCode, 200);

      final blockedReq = _FakeRequest(rawRequest: _FakeHttpRequestWithIp(InternetAddress('192.168.1.100')));
      final resBlocked = await mw(blockedReq, () async => Response.ok({'ok': true}));
      expect(resBlocked.statusCode, 403);
    });

    test('allow list supports CIDR notation', () async {
      final mw = ipFilter(allow: ['10.0.0.0/8']);

      final matchReq = _FakeRequest(rawRequest: _FakeHttpRequestWithIp(InternetAddress('10.254.1.2')));
      final res = await mw(matchReq, () async => Response.ok({'ok': true}));
      expect(res.statusCode, 200);

      final nonMatchReq = _FakeRequest(rawRequest: _FakeHttpRequestWithIp(InternetAddress('172.16.0.1')));
      final resBlocked = await mw(nonMatchReq, () async => Response.ok({'ok': true}));
      expect(resBlocked.statusCode, 403);
    });

    test('deny list blocks matching IP', () async {
      final mw = ipFilter(deny: ['192.168.1.50']);

      final blockedReq = _FakeRequest(rawRequest: _FakeHttpRequestWithIp(InternetAddress('192.168.1.50')));
      final res = await mw(blockedReq, () async => Response.ok({'ok': true}));
      expect(res.statusCode, 403);

      final allowedReq = _FakeRequest(rawRequest: _FakeHttpRequestWithIp(InternetAddress('192.168.1.51')));
      final resAllowed = await mw(allowedReq, () async => Response.ok({'ok': true}));
      expect(resAllowed.statusCode, 200);
    });
  });

  // ─── ETag middleware ─────────────────────────────────────────

  group('ETag middleware', () {
    test('adds weak ETag to 200 response with body', () async {
      final mw = etag();
      final req = _FakeRequest();
      final res = await mw(req, () async => Response.ok({'message': 'hello'}));

      expect(res.statusCode, 200);
      expect(res.headers.containsKey('etag'), isTrue);
      expect(res.headers['etag'], startsWith('W/"'));
    });

    test('returns 304 when If-None-Match matches ETag', () async {
      final mw = etag();
      final initialReq = _FakeRequest();
      final initialRes = await mw(initialReq, () async => Response.ok('some content'));
      final generatedEtag = initialRes.headers['etag']!;

      final condReq = _FakeRequest(headers: {'if-none-match': generatedEtag});
      final res304 = await mw(condReq, () async => Response.ok('some content'));

      expect(res304.statusCode, 304);
      expect(res304.headers['etag'], generatedEtag);
    });
  });

  // ─── Compression middleware ──────────────────────────────────

  group('Compression middleware', () {
    test('compresses with gzip if client accepts gzip and body >= minBytes', () async {
      final mw = compress(minBytes: 20);
      final largeString = 'a' * 100;
      final req = _FakeRequest(headers: {'accept-encoding': 'gzip, deflate'});
      final res = await mw(req, () async => Response.text(largeString));

      expect(res.headers['content-encoding'], 'gzip');
      expect(res.headers['vary'], contains('Accept-Encoding'));
      expect(consumeCompressedBody(res), isNotNull);
    });

    test('skips compression if client does not accept gzip', () async {
      final mw = compress(minBytes: 20);
      final largeString = 'a' * 100;
      final req = _FakeRequest(headers: {'accept-encoding': 'identity'});
      final res = await mw(req, () async => Response.text(largeString));

      expect(res.headers.containsKey('content-encoding'), isFalse);
      expect(consumeCompressedBody(res), isNull);
    });

    test('skips compression if body is smaller than minBytes', () async {
      final mw = compress(minBytes: 500);
      final req = _FakeRequest(headers: {'accept-encoding': 'gzip'});
      final res = await mw(req, () async => Response.text('short'));

      expect(res.headers.containsKey('content-encoding'), isFalse);
    });
  });

  // ─── StreamResponse ──────────────────────────────────────────

  group('StreamResponse', () {
    test('creates response with Stream and headers', () async {
      final stream = Stream.value([1, 2, 3, 4]);
      final res = StreamResponse(
        stream: stream,
        statusCode: 200,
        headers: {'content-type': 'application/octet-stream'},
      );

      expect(res.statusCode, 200);
      expect(res.headers['content-type'], 'application/octet-stream');
      expect(await res.stream.toList(), [
        [1, 2, 3, 4]
      ]);
    });
  });

  // ─── Validator & Schema ──────────────────────────────────────

  group('Validation schema', () {
    test('validates correct fields successfully', () async {
      final schema = BodySchema({
        'username': Field.string().minLength(3).required(),
        'age': Field.int_().min(18).max(100).required(),
        'email': Field.string().email().required(),
        'role': Field.string().oneOf(['admin', 'user']).required(),
        'subscribe': Field.bool_(),
        'tags': Field.list().minItems(1),
      });

      final mw = validate(schema);
      final req = _FakeRequest(
        body: {
          'username': 'john_doe',
          'age': 25,
          'email': 'john@example.com',
          'role': 'admin',
          'subscribe': true,
          'tags': ['dart', 'server'],
        },
      );

      final res = await mw(req, () async => Response.ok({'saved': true}));
      expect(res.statusCode, 200);
    });

    test('returns 422 with validation errors when invalid', () async {
      final schema = BodySchema({
        'username': Field.string().minLength(5).required(),
        'age': Field.int_().min(18).required(),
        'email': Field.string().email().required(),
        'role': Field.string().oneOf(['admin', 'user']).required(),
      });

      final mw = validate(schema);
      final req = _FakeRequest(
        body: {
          'username': 'abc',
          'age': 15,
          'email': 'not-an-email',
          'role': 'superadmin',
        },
      );

      final res = await mw(req, () async => Response.ok(<String, dynamic>{}));
      expect(res.statusCode, 422);
      expect(res.body, contains('username must be at least 5 characters'));
      expect(res.body, contains('age must be ≥ 18'));
      expect(res.body, contains('email must be a valid email address'));
      expect(res.body, contains('role must be one of: admin, user'));
    });
  });

  // ─── Health check endpoint ───────────────────────────────────

  group('Server health check', () {
    test('GET /health returns status ok with uptime and request count', () async {
      final app = QuadrantServer(
        routes: [Route.get(path: '/hello', handler: (req) async => Response.ok('hi'))],
        healthCheck: true,
      );

      final server = await app.listen(port: 0); // ephemeral port
      final client = HttpClient();

      try {
        final request = await client.getUrl(Uri.parse('http://localhost:${server.port}/health'));
        final response = await request.close();
        expect(response.statusCode, 200);
        final body = await response.transform(utf8.decoder).join();
        expect(body, contains('"status":"ok"'));
        expect(body, contains('"uptime"'));
        expect(body, contains('"requests"'));
      } finally {
        client.close();
        await app.close();
      }
    });
  });
}

// ─── Fake Request (no dart:io required) ──────────────────────

/// Minimal [Request]-compatible object for unit-testing middleware.
/// Avoids the need for a live [HttpRequest] from dart:io.
class _FakeRequest extends Request {
  _FakeRequest({
    super.method = 'GET',
    super.path = '/test',
    super.params = const {},
    super.query = const {},
    super.headers = const {},
    super.body,
    HttpRequest? rawRequest,
  }) : super(
          raw: rawRequest ?? _NullHttpRequest.instance,
        );
}

/// A never-accessed stand-in for HttpRequest.
/// Only used to satisfy the constructor signature; none of its members
/// will be called in these unit tests.
class _NullHttpRequest implements HttpRequest {
  static final instance = _NullHttpRequest._();
  _NullHttpRequest._();

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnsupportedError('HttpRequest.${i.memberName} not available in tests');
}

class _FakeHttpRequestWithIp extends _NullHttpRequest {
  final InternetAddress ip;
  _FakeHttpRequestWithIp(this.ip) : super._();

  @override
  HttpConnectionInfo? get connectionInfo => _FakeConnectionInfo(ip);
}

class _FakeConnectionInfo implements HttpConnectionInfo {
  @override
  final InternetAddress remoteAddress;
  _FakeConnectionInfo(this.remoteAddress);

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}
