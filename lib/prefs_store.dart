// Where the user's preferences (the keyboard shortcuts) are kept: the
// browser's storage on the web; off it, nowhere.
export 'prefs_store_io.dart'
    if (dart.library.js_interop) 'prefs_store_web.dart';
