/// Uploading a large file — one implementation per platform.
///
/// It exists because **on the web `package:http` does not stream requests**.
/// `BrowserClient` gathers the whole body into a single `Uint8List` before
/// calling `fetch` — "Responses are streamed but requests are not", says its
/// documentation. On a match recording of two or three gigabytes that
/// allocation fails; and it fails silently: the error blows up inside the sink
/// that accumulates the bytes, the stream's `runUnaryGuarded` swallows it, every
/// following chunk is dropped and `close()` hands over half the buffer.
/// `fetch` then goes out with a well-formed multipart, with the
/// `Content-Length` of what was left, and the server stores half a recording
/// with no way of suspecting — the damage only showed up later in the
/// preprocessor, as an `ffprobe exited with 1`.
///
/// On the web, therefore, the browser is what loads the file: the `Blob` is
/// handed to `FormData` and it reads it from disk while sending, without going
/// through Dart's memory. Off the web `MultipartRequest` already streams for
/// real and still does the job.
library;

export 'upload_io.dart' if (dart.library.js_interop) 'upload_web.dart';
