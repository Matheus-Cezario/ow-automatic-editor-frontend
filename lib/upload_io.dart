import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;

/// Sends the file in a multipart, streaming.
///
/// Off the web `MultipartRequest` already reads the file in chunks and writes
/// them to the socket as they come, so there is nothing to fix: the body never
/// exists whole in memory. See [upload.dart] for why the web needs something
/// else.
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
