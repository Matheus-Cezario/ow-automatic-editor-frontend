import 'package:flutter/material.dart';

// On the web it uses the browser's own `<a download>`; off it, url_launcher.
// The choice is made at compile time, so the web app does not even load the
// plugin.
import 'download_io.dart' if (dart.library.js_interop) 'download_web.dart';

/// Starts downloading a URL from the server.
Future<void> downloadFile(BuildContext context, String url) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await openDownload(url);
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Download failed: $e')));
  }
}

/// A download button that behaves the same on every screen.
class DownloadButton extends StatelessWidget {
  const DownloadButton({
    super.key,
    required this.url,
    required this.label,
    this.icon = Icons.download,
    this.compact = false,
  });

  final String url;
  final String label;
  final IconData icon;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return IconButton(
        onPressed: () => downloadFile(context, url),
        icon: Icon(icon),
        tooltip: label,
      );
    }
    return OutlinedButton.icon(
      onPressed: () => downloadFile(context, url),
      icon: Icon(icon),
      label: Text(label),
    );
  }
}
