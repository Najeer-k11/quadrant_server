// The router indexes routes by method and first segment. It must still pick
// exactly the route a plain scan in registration order would.
import 'dart:math';

import 'package:quadrant_server/quadrant_server.dart';
import 'package:quadrant_server/src/routing/router.dart';
import 'package:test/test.dart';

Future<Response> _handler(Request req) async => Response.text('');

void main() {
  test('picks the same route as a linear scan', () {
    final random = Random(7);
    const words = ['a', 'b', 'users', 'me', ':id', ':x', '*'];
    const methods = ['GET', 'POST', 'HEAD'];

    for (var table = 0; table < 300; table++) {
      final routes = <Route>[
        for (var r = 0; r < 1 + random.nextInt(12); r++)
          _route(methods[random.nextInt(methods.length)], _randomPattern(random, words)),
      ];
      final router = Router(routes);

      for (var p = 0; p < 40; p++) {
        final path = '/${[
          for (var s = 0; s < random.nextInt(4); s++)
            ['a', 'b', 'users', 'me', '42'][random.nextInt(5)]
        ].join('/')}';
        final method = methods[random.nextInt(methods.length)];
        final expected = _linearMatch(routes, method, path);
        final actual = router.match(method, path);
        final reason = '$method $path in ${routes.map((r) => '${r.method} ${r.path}')}';
        if (expected == null) {
          expect(actual, isNot(isA<Matched>()), reason: reason);
        } else {
          expect(actual, isA<Matched>(), reason: reason);
          expect(identical((actual as Matched).route, expected), isTrue,
              reason: reason);
        }
      }
    }
  });
}

Route _route(String method, String path) => switch (method) {
      'GET' => Route.get(path: path, handler: _handler),
      'POST' => Route.post(path: path, handler: _handler),
      _ => Route(method: method, path: path, handler: _handler),
    };

String _randomPattern(Random random, List<String> words) {
  final length = random.nextInt(4);
  final segments = <String>[];
  for (var i = 0; i < length; i++) {
    final word = words[random.nextInt(words.length)];
    segments.add(word);
    if (word == '*') break; // Only last.
  }
  return '/${segments.join('/')}';
}

/// The reference: every route in order, HEAD falling back to GET.
Route? _linearMatch(List<Route> routes, String method, String path) {
  final segments = path.split('/').where((s) => s.isNotEmpty).toList();
  for (final m in method == 'HEAD' ? ['HEAD', 'GET'] : [method]) {
    for (final route in routes) {
      if (route.method != m) continue;
      final pattern = route.path.split('/').where((s) => s.isNotEmpty).toList();
      final wildcard = pattern.isNotEmpty && pattern.last == '*';
      final fixed = wildcard ? pattern.length - 1 : pattern.length;
      if (wildcard ? segments.length < fixed : segments.length != fixed) {
        continue;
      }
      var ok = true;
      for (var i = 0; i < fixed; i++) {
        if (!pattern[i].startsWith(':') && pattern[i] != segments[i]) ok = false;
      }
      if (ok) return route;
    }
  }
  return null;
}
