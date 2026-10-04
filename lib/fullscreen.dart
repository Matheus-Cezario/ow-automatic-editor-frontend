// The browser's full-screen mode on the web; off it, nothing — the monitor
// still fills the window, which is what matters.
export 'fullscreen_io.dart' if (dart.library.js_interop) 'fullscreen_web.dart';
