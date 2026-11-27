// Runs the server test suites again on ServerEngine.quadrant.
//
// The cluster tests are left out: their servers run in isolates of their own,
// where this override does not reach.
import 'package:quadrant_server/src/core/quadrant_app.dart';
import 'package:test/test.dart';

import 'lifecycle_test.dart' as lifecycle;
import 'middleware_context_test.dart' as middleware_context;
import 'multipart_parser_test.dart' as multipart_parser;
import 'quadrant_server_test.dart' as quadrant_server;
import 'unmatched_routes_test.dart' as unmatched_routes;

void main() {
  setUpAll(() => debugEngineOverride = ServerEngine.quadrant);
  tearDownAll(() => debugEngineOverride = null);

  group('lifecycle', lifecycle.main);
  group('middleware context', middleware_context.main);
  group('multipart parser', multipart_parser.main);
  group('quadrant server', quadrant_server.main);
  group('unmatched routes', unmatched_routes.main);
}
