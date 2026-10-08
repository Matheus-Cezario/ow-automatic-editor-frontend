import 'package:web/web.dart' as web;

/// Its own prefix: making room for the undo histories never touches these.
const _prefix = 'ow.prefs.';

/// The kept value, or `null` — none, or storage the browser refuses
/// (private mode, blocked site data).
String? readPref(String key) {
  try {
    return web.window.localStorage.getItem('$_prefix$key');
  } catch (_) {
    return null;
  }
}

/// Keeps [value]; `null` forgets it. A refusal costs only the preference.
void writePref(String key, String? value) {
  try {
    final storage = web.window.localStorage;
    if (value == null) {
      storage.removeItem('$_prefix$key');
    } else {
      storage.setItem('$_prefix$key', value);
    }
  } catch (_) {}
}
