import 'dart:async';
import 'dart:js_interop';

import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

/// Sends the file letting the **browser** load it.
///
/// The `Blob` picked in the file chooser is not a copy of the bytes: it is a
/// reference to the file on disk. Handing it to `FormData` makes the browser
/// read and send it in chunks, without any of it going through Dart's memory —
/// which is what broke on match recordings (see `upload.dart`).
///
/// It goes through `XMLHttpRequest`, and not `fetch`, for one reason only:
/// `fetch` does not report how much of the body has been sent, and on a
/// half-hour recording the upload bar is the only thing telling the user the
/// system has not frozen.
Future<http.Response> uploadFile({
  required Uri url,
  required String field,
  required PlatformFile file,
  required int length,
  Map<String, String> fields = const {},
  void Function(double sent)? onProgress,
}) async {
  final form = web.FormData();
  fields.forEach((name, value) => form.append(name, value.toJS));
  form.append(field, await _blobOf(file), file.name);

  final done = Completer<http.Response>();
  final xhr = web.XMLHttpRequest()..open('POST', url.toString());

  void finish(http.Response r) {
    if (!done.isCompleted) done.complete(r);
  }

  void fail(Object error) {
    if (!done.isCompleted) done.completeError(error);
  }

  xhr.upload.onprogress = (web.ProgressEvent e) {
    if (onProgress == null) return;
    // `total` is the whole body, multipart header included; the difference is
    // a few hundred bytes on a file of gigabytes
    final total = e.lengthComputable ? e.total : length;
    onProgress(total == 0 ? 0 : (e.loaded / total).clamp(0.0, 1.0));
  }.toJS;

  xhr.onload = (web.ProgressEvent _) {
    onProgress?.call(1);
    finish(
      http.Response(
        xhr.responseText,
        xhr.status,
        reasonPhrase: xhr.statusText,
        request: http.Request('POST', url),
      ),
    );
  }.toJS;

  // the browser does not say why the network failed -- and that is all we know
  xhr.onerror = (web.ProgressEvent _) {
    fail(http.ClientException('uploading ${file.name} failed', url));
  }.toJS;
  xhr.onabort = (web.ProgressEvent _) {
    fail(http.ClientException('uploading ${file.name} was cancelled', url));
  }.toJS;

  xhr.send(form);
  return done.future;
}

/// The `Blob` behind the picked file.
///
/// On the web `PlatformFile` holds a `blob:` URL instead of the path; fetching
/// it returns the same file, without a copy — the browser just hands back the
/// reference it already had.
Future<web.Blob> _blobOf(PlatformFile file) async {
  final response = await web.window.fetch(file.uri.toString().toJS).toDart;
  return response.blob().toDart;
}
