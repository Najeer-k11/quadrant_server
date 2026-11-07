import 'dart:io';
import 'dart:math';

import 'package:quadrant_server/quadrant_server.dart';

/// The biggest upload accepted. `client_max_body_size` in `deploy/nginx.conf`
/// must be a little more than this, or nginx answers first.
const maxUploadBytes = 100 * 1024 * 1024;

final _random = Random.secure();

/// POST /api/v1/files
///
/// `multipartParser()` has already streamed the upload to a temporary file,
/// which is deleted when this returns. `moveTo()` is what keeps it.
Handler uploadFiles(String uploadsDir) => (Request req) async {
      final files = req.context['files'] as List<UploadedFile>? ?? const [];
      if (files.isEmpty) return Response.badRequest('Send at least one file');

      final saved = <Map<String, Object>>[];
      for (final file in files) {
        // The client's filename must never become a path. The fixed extension
        // also means a download is never served as a page in a browser.
        final name = '${_randomId()}.bin';
        await file.moveTo('$uploadsDir${Platform.pathSeparator}$name');
        saved.add({
          'url': '/api/v1/files/$name',
          'originalName': file.filename,
          'size': file.size,
        });
      }
      return Response.created({'files': saved});
    };

String _randomId() => [
      for (var i = 0; i < 16; i++)
        _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
