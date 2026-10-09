import 'dart:async';

import 'response.dart';

/// A [Response] variant that streams its body from a [Stream<List<int>>]
/// instead of buffering it as a `String`.
///
/// Use this for large file downloads, generated reports, or any response
/// where you want to pipe data directly to the client without reading it
/// all into memory first.
///
/// The framework detects [StreamResponse] in `_writeResponse` and uses
/// `HttpResponse.addStream()` to pipe the stream, then closes the connection.
///
/// ```dart
/// // Stream a file download:
/// Route.get(
///   path: '/download/:name',
///   handler: (req) async {
///     final file = File('data/${req.params['name']}');
///     if (!await file.exists()) return Response.notFound('File not found');
///
///     final stat = await file.stat();
///     return StreamResponse(
///       stream: file.openRead(),
///       headers: {
///         'content-type': 'application/octet-stream',
///         'content-length': '${stat.size}',
///         'content-disposition':
///             'attachment; filename="${req.params['name']}"',
///       },
///     );
///   },
/// )
///
/// // Stream generated CSV:
/// Route.get(
///   path: '/export.csv',
///   handler: (req) async {
///     final controller = StreamController<List<int>>();
///     _writeCsvRows(controller); // async, non-blocking
///     return StreamResponse(
///       stream: controller.stream,
///       headers: {
///         'content-type': 'text/csv',
///         'content-disposition': 'attachment; filename="export.csv"',
///         'transfer-encoding': 'chunked',
///       },
///     );
///   },
/// )
/// ```
///
/// [stream] — the byte stream to pipe to the client.
/// [statusCode] — HTTP status code. Defaults to `200`.
/// [headers] — response headers. Set `content-length` if the size is known
///   ahead of time; otherwise use `transfer-encoding: chunked`.
class StreamResponse extends Response {
  /// The byte stream to pipe directly to the HTTP response socket.
  final Stream<List<int>> stream;

  StreamResponse({
    required this.stream,
    super.statusCode = 200,
    super.headers = const {},
    super.cookies = const [],
  }) : super(
          body: '', // body field unused — framework pipes [stream] directly
        );

  /// Keeps the same [stream]; [body] is ignored because it is always empty.
  @override
  Response copyWith({
    int? statusCode,
    Map<String, String>? headers,
    String? body,
    List<String>? cookies,
  }) {
    return StreamResponse(
      stream: stream,
      statusCode: statusCode ?? this.statusCode,
      headers: headers ?? this.headers,
      cookies: cookies ?? this.cookies,
    );
  }
}
