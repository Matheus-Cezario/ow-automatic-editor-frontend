import 'package:url_launcher/url_launcher.dart';

/// Download off the web (Android/iOS/desktop): opens it in the system's
/// browser, which is what knows how to save the file and show progress.
Future<void> openDownload(String url) async {
  final ok = await launchUrl(
    Uri.parse(url),
    mode: LaunchMode.externalApplication,
  );
  if (!ok) throw Exception('the system refused to open $url');
}
