import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

// dart:io has two behaviours that get in the way of rejecting a request whose
// body has not all arrived:
//
// - Cancelling the read closes the connection, losing the response.
// - Never starting one makes it read the whole body before it sends a response.
//
// Keeping a read going, and throwing the data away, avoids both. The response
// goes out at once, and dart:io then closes the connection, because the body
// was not read to its end.

/// The chunks of [request]'s body, for use in an `await for` that may stop
/// early. Stopping leaves the connection able to deliver the response.
Stream<Uint8List> readBody(HttpRequest request) {
  late StreamSubscription<Uint8List> source;
  var finished = false;
  late final StreamController<Uint8List> chunks;
  chunks = StreamController<Uint8List>(
    sync: true,
    onListen: () {
      source = request.listen(
        chunks.add,
        onError: chunks.addError,
        onDone: () {
          finished = true;
          chunks.close();
        },
      );
    },
    onPause: () => source.pause(),
    onResume: () => source.resume(),
    onCancel: () {
      if (finished) return;
      _discard(source);
      request.response.persistentConnection = false;
    },
  );
  return chunks.stream;
}

/// For a request rejected without reading its body.
void abandonBody(HttpRequest request) {
  _discard(request.listen(null));
  request.response.persistentConnection = false;
}

void _discard(StreamSubscription<Uint8List> source) {
  source
    ..onData(null)
    ..onError((Object _) {})
    ..onDone(null);
  while (source.isPaused) {
    source.resume();
  }
}

/// Reads all of [request]'s body, or returns null as soon as it passes
/// [maxBytes] (0 for no limit).
///
/// With a `content-length`, the bytes go straight into one buffer of that
/// size. Collecting chunks and joining them at the end would hold the body
/// twice at its peak.
Future<Uint8List?> readBodyBytes(HttpRequest request, int maxBytes) async {
  final declared = request.contentLength;
  if (declared >= 0 && (maxBytes <= 0 || declared <= maxBytes)) {
    final bytes = Uint8List(declared);
    var length = 0;
    BytesBuilder? overflow; // Only if more arrives than was declared.
    await for (final chunk in readBody(request)) {
      if (overflow == null && length + chunk.length <= declared) {
        bytes.setRange(length, length + chunk.length, chunk);
        length += chunk.length;
        continue;
      }
      overflow ??= BytesBuilder(copy: false)
        ..add(Uint8List.sublistView(bytes, 0, length));
      overflow.add(chunk);
      if (maxBytes > 0 && overflow.length > maxBytes) return null;
    }
    if (overflow != null) return overflow.takeBytes();
    return length == declared ? bytes : Uint8List.sublistView(bytes, 0, length);
  }

  final builder = BytesBuilder(copy: false);
  await for (final chunk in readBody(request)) {
    builder.add(chunk);
    if (maxBytes > 0 && builder.length > maxBytes) return null;
  }
  return builder.takeBytes();
}
