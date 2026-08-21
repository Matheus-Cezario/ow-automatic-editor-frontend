import 'package:web/web.dart' as web;

/// Download na web, sem plugin nenhum.
///
/// O jeito canônico do navegador: um `<a download>` clicado por código. O
/// servidor já responde com `Content-Disposition: attachment`, então o nome do
/// arquivo vem de lá e a página não sai do lugar.
///
/// Esta função existe porque o `url_launcher` falhou aqui duas vezes — a
/// segunda com `MissingPluginException`, mesmo com o plugin no registrant. Para
/// baixar um arquivo da mesma origem não é preciso plugin: o navegador faz
/// isso nativamente.
Future<void> abrirDownload(String url) async {
  final a = web.HTMLAnchorElement()
    ..href = url
    ..download = ''
    ..style.display = 'none';
  web.document.body!.append(a);
  a.click();
  a.remove();
}
