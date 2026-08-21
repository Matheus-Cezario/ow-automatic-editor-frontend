import 'package:flutter/material.dart';

// Na web usa o `<a download>` do próprio navegador; fora dela, o url_launcher.
// A escolha é feita na compilação, então o app web nem carrega o plugin.
import 'download_io.dart' if (dart.library.js_interop) 'download_web.dart';

/// Dispara o download de uma URL do servidor.
Future<void> baixar(BuildContext context, String url) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await abrirDownload(url);
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Download falhou: $e')));
  }
}

/// Botão de download com o mesmo comportamento em todas as telas.
class BotaoBaixar extends StatelessWidget {
  const BotaoBaixar({
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
        onPressed: () => baixar(context, url),
        icon: Icon(icon),
        tooltip: label,
      );
    }
    return OutlinedButton.icon(
      onPressed: () => baixar(context, url),
      icon: Icon(icon),
      label: Text(label),
    );
  }
}
