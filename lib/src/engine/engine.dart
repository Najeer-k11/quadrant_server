/// A pure-Dart HTTP/1.1 server on [RawServerSocket], used by
/// `QuadrantServer(engine: ServerEngine.quadrant)`.
///
/// It implements dart:io's [HttpServer], [HttpRequest] and [HttpResponse]
/// interfaces, so `Request.raw`, the middlewares, SSE and WebSocket upgrades
/// work unchanged. What it saves over dart:io's server is mostly allocation:
/// headers are parsed straight from the socket's bytes into flat lists, the
/// header block and a small body go out in one write, and requests the
/// framework answers with a plain [Response] skip the [IOSink] machinery.
///
/// This is an **internal** library — not part of the public surface.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'options.dart';

export 'options.dart';

part 'headers.dart';
part 'parser.dart';
part 'connection.dart';
part 'request.dart';
part 'response.dart';
part 'detached_socket.dart';
part 'server.dart';
