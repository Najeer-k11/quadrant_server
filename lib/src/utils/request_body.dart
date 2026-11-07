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
