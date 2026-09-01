/// Envio de arquivo grande — uma implementação por plataforma.
///
/// Existe porque **na web o `package:http` não faz streaming de requisição**.
/// O `BrowserClient` junta o corpo inteiro num único `Uint8List` antes de
/// chamar o `fetch` — "Responses are streamed but requests are not", diz a
/// documentação dele. Numa gravação de partida, de dois ou três gigabytes,
/// essa alocação falha; e falha calada: o erro estoura dentro do sink que
/// acumula os bytes, o `runUnaryGuarded` do stream o engole, todos os pedaços
/// seguintes são descartados e o `close()` entrega o buffer pela metade. O
/// `fetch` sai então com um multipart bem-formado, com o `Content-Length` do
/// que sobrou, e o servidor guarda meia gravação sem ter como desconfiar — o
/// estrago só aparecia lá no preprocessador, como um `ffprobe saiu com 1`.
///
/// Na web, portanto, quem carrega o arquivo é o navegador: entrega-se o `Blob`
/// ao `FormData` e ele o lê do disco enquanto envia, sem passar pela memória
/// do Dart. Fora da web o `MultipartRequest` já faz streaming de verdade e
/// continua servindo.
library;

export 'upload_io.dart' if (dart.library.js_interop) 'upload_web.dart';
