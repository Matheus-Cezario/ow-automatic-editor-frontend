import 'package:web/web.dart' as web;

/// Download on the web, with no plugin at all.
///
/// The browser's canonical way: an `<a download>` clicked from code. The server
/// already answers with `Content-Disposition: attachment`, so the file name
/// comes from there and the page does not move.
///
/// This function exists because `url_launcher` failed here twice — the second
/// time with `MissingPluginException`, even with the plugin in the registrant.
/// Downloading a same-origin file needs no plugin: the browser does it
/// natively.
Future<void> openDownload(String url) async {
  final a = web.HTMLAnchorElement()
    ..href = url
    ..download = ''
    ..style.display = 'none';
  web.document.body!.append(a);
  a.click();
  a.remove();
}

/// Saves text made in the app (no server file behind it) as a download
/// called [name].
Future<void> saveTextFile(String name, String text) async {
  final a = web.HTMLAnchorElement()
    ..href = 'data:text/plain;charset=utf-8,${Uri.encodeComponent(text)}'
    ..download = name
    ..style.display = 'none';
  web.document.body!.append(a);
  a.click();
  a.remove();
}
