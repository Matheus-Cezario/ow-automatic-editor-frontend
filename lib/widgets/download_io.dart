import 'package:url_launcher/url_launcher.dart';

/// Download fora da web (Android/iOS/desktop): abre no navegador do sistema,
/// que é quem sabe salvar o arquivo e mostrar o progresso.
Future<void> abrirDownload(String url) async {
  final ok = await launchUrl(
    Uri.parse(url),
    mode: LaunchMode.externalApplication,
  );
  if (!ok) throw Exception('o sistema recusou abrir $url');
}
