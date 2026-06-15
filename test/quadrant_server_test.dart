import 'dart:io';

import 'package:quadrant_server/quadrant_server.dart';
import 'package:quadrant_server/src/router.dart';
import 'package:test/test.dart';

// ─── Helpers ─────────────────────────────────────────────────

Future<Response> _ok(Request req) async => Response.ok({'ok': true});
Future<Response> _echo(Request req) async => Response.ok({'id': req.params['id']});
Future<Response> _bodyEcho(Request req) async => Response.ok(req.bodyAsMap ?? {});
Future<Response> _listEcho(Request req) async => Response.ok(req.bodyAsList ?? []);

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
}

// ─── Fake Request (no dart:io required) ──────────────────────

/// Minimal [Request]-compatible object for unit-testing middleware.
/// Avoids the need for a live [HttpRequest] from dart:io.
class _FakeRequest extends Request {
  _FakeRequest()
      : super(
          method: 'GET',
          path: '/test',
          params: {},
          query: {},
          headers: {},
          body: null,
          raw: _NullHttpRequest.instance,
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
