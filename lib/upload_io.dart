import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;

/// Envia o arquivo num multipart, em streaming.
///
/// Fora da web o `MultipartRequest` já lê o arquivo em pedaços e os escreve no
/// socket conforme saem, então não há o que consertar: o corpo nunca existe
/// inteiro na memória. Ver [upload.dart] para o motivo de a web precisar de
/// outra coisa.
Future<http.Response> uploadFile({
  required Uri url,
  required String field,
  required PlatformFile file,
  required int length,
  Map<String, String> fields = const {},
  void Function(double sent)? onProgress,
}) async {
  var sent = 0;
  Stream<List<int>> counting() async* {
    await for (final chunk in file.readAsByteStream()) {
      sent += chunk.length;
      onProgress?.call(length == 0 ? 1 : sent / length);
      yield chunk;
    }
  }

  final request = http.MultipartRequest('POST', url)
    ..fields.addAll(fields)
    ..files.add(
      http.MultipartFile(field, counting(), length, filename: file.name),
    );

  return http.Response.fromStream(await request.send());
}
