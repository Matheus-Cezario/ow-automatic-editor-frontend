import 'dart:async';
import 'dart:js_interop';

import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

/// Envia o arquivo deixando o **navegador** carregá-lo.
///
/// O `Blob` escolhido no seletor não é uma cópia dos bytes: é uma referência
/// ao arquivo no disco. Entregá-lo ao `FormData` faz o navegador ler e enviar
/// em pedaços, sem que nada disso passe pela memória do Dart — que é o que
/// quebrava em gravações de partida (ver `upload.dart`).
///
/// Vai por `XMLHttpRequest`, e não por `fetch`, por um motivo só: o `fetch`
/// não conta quanto do corpo já subiu, e numa gravação de meia hora a barra de
/// envio é a única coisa que diz ao usuário que o sistema não travou.
Future<http.Response> uploadFile({
  required Uri url,
  required String field,
  required PlatformFile file,
  required int length,
  Map<String, String> fields = const {},
  void Function(double sent)? onProgress,
}) async {
  final form = web.FormData();
  fields.forEach((name, value) => form.append(name, value.toJS));
  form.append(field, await _blobOf(file), file.name);

  final done = Completer<http.Response>();
  final xhr = web.XMLHttpRequest()..open('POST', url.toString());

  void finish(http.Response r) {
    if (!done.isCompleted) done.complete(r);
  }

  void fail(Object error) {
    if (!done.isCompleted) done.completeError(error);
  }

  xhr.upload.onprogress = (web.ProgressEvent e) {
    if (onProgress == null) return;
    // `total` é o corpo inteiro, com o cabeçalho do multipart junto; a
    // diferença é de algumas centenas de bytes num arquivo de gigabytes
    final total = e.lengthComputable ? e.total : length;
    onProgress(total == 0 ? 0 : (e.loaded / total).clamp(0.0, 1.0));
  }.toJS;

  xhr.onload = (web.ProgressEvent _) {
    onProgress?.call(1);
    finish(
      http.Response(
        xhr.responseText,
        xhr.status,
        reasonPhrase: xhr.statusText,
        request: http.Request('POST', url),
      ),
    );
  }.toJS;

  // o navegador não conta por que a rede falhou -- e é só isso que se sabe
  xhr.onerror = (web.ProgressEvent _) {
    fail(http.ClientException('o envio de ${file.name} falhou', url));
  }.toJS;
  xhr.onabort = (web.ProgressEvent _) {
    fail(http.ClientException('o envio de ${file.name} foi cancelado', url));
  }.toJS;

  xhr.send(form);
  return done.future;
}

/// O `Blob` por trás do arquivo escolhido.
///
/// `PlatformFile` na web guarda uma URL `blob:` em vez do caminho; buscá-la
/// devolve o mesmo arquivo, sem cópia — o navegador só entrega de volta a
/// referência que ele já tinha.
Future<web.Blob> _blobOf(PlatformFile file) async {
  final response = await web.window.fetch(file.uri.toString().toJS).toDart;
  return response.blob().toDart;
}
