// Where the undo history waits out a reload: the browser's storage on the
// web; off it, nowhere — an app is not reloaded by an F5.
export 'undo_store_io.dart' if (dart.library.js_interop) 'undo_store_web.dart';
