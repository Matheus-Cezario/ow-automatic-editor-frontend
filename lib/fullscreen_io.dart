/// Off the web there is no page to take full screen.
Future<void> enterFullscreen() async {}

Future<void> exitFullscreen() async {}

/// Calls [onExit] when the browser leaves full screen by itself (Esc).
/// Returns how to stop listening.
void Function() onFullscreenExit(void Function() onExit) => () {};
