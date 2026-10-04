import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Asks the browser for full screen. It may refuse — outside a click, or in
/// a frame that does not allow it — and then the monitor just fills the
/// window.
Future<void> enterFullscreen() async {
  try {
    await web.document.documentElement?.requestFullscreen().toDart;
  } catch (_) {}
}

Future<void> exitFullscreen() async {
  if (web.document.fullscreenElement == null) return;
  try {
    await web.document.exitFullscreen().toDart;
  } catch (_) {}
}

/// Calls [onExit] when the browser leaves full screen by itself — Esc is the
/// browser's, not the app's. Returns how to stop listening.
void Function() onFullscreenExit(void Function() onExit) {
  final listener = ((web.Event _) {
    if (web.document.fullscreenElement == null) onExit();
  }).toJS;
  web.document.addEventListener('fullscreenchange', listener);
  return () => web.document.removeEventListener('fullscreenchange', listener);
}
