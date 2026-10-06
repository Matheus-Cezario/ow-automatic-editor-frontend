import 'package:web/web.dart' as web;

/// Every key this app writes starts with this, so making room never touches
/// anything else on the site.
const _prefix = 'ow.undo.';

/// The saved history, or `null` — none, or storage the browser refuses
/// (private mode, blocked site data).
String? readUndo(String key) {
  try {
    return web.window.localStorage.getItem('$_prefix$key');
  } catch (_) {
    return null;
  }
}

/// Keeps [value]. When the browser says it is full, the histories of the
/// other montages go first: the one being edited is the one worth keeping.
/// Returns whether it was kept.
bool writeUndo(String key, String value) {
  final storage = web.window.localStorage;
  try {
    storage.setItem('$_prefix$key', value);
    return true;
  } catch (_) {}
  try {
    final others = [
      for (var i = 0; i < storage.length; i++)
        if (storage.key(i) case final k?
            when k.startsWith(_prefix) && k != '$_prefix$key')
          k,
    ];
    if (others.isEmpty) return false;
    for (final k in others) {
      storage.removeItem(k);
    }
    storage.setItem('$_prefix$key', value);
    return true;
  } catch (_) {
    return false;
  }
}
