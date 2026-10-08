import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'voice_recorder.dart';

/// The browser's `MediaRecorder` on the microphone.
class PlatformVoiceRecorder implements VoiceRecorder {
  web.MediaStream? _stream;
  web.MediaRecorder? _recorder;
  final _chunks = <web.Blob>[];

  /// What each container is sent as. `.weba` and not `.webm`: the server
  /// files `.webm` as video.
  static const _formats = [
    ('audio/webm;codecs=opus', 'weba'),
    ('audio/ogg;codecs=opus', 'ogg'),
    ('audio/mp4', 'm4a'),
  ];

  @override
  bool get isSupported =>
      web.window.navigator.mediaDevices.isDefinedAndNotNull &&
      _formats.any((f) => web.MediaRecorder.isTypeSupported(f.$1));

  @override
  Future<void> start() async {
    final stream = await web.window.navigator.mediaDevices
        .getUserMedia(web.MediaStreamConstraints(audio: true.toJS))
        .toDart;
    final format = _formats.firstWhere(
      (f) => web.MediaRecorder.isTypeSupported(f.$1),
    );
    final recorder = web.MediaRecorder(
      stream,
      web.MediaRecorderOptions(mimeType: format.$1),
    );
    _chunks.clear();
    recorder.ondataavailable = (web.BlobEvent e) {
      if (e.data.size > 0) _chunks.add(e.data);
    }.toJS;
    _stream = stream;
    _recorder = recorder;
    recorder.start();
  }

  @override
  Future<RecordedVoice> stop() async {
    final recorder = _recorder;
    if (recorder == null) throw StateError('not recording');
    final done = Completer<void>();
    recorder.onstop = (web.Event _) {
      done.complete();
    }.toJS;
    recorder.stop();
    await done.future;
    _release();
    final type = recorder.mimeType;
    final ext = _formats
        .firstWhere(
          (f) => type.startsWith(f.$1.split(';').first),
          orElse: () => _formats.first,
        )
        .$2;
    final blob = web.Blob(_chunks.toJS, web.BlobPropertyBag(type: type));
    _chunks.clear();
    final buffer = await blob.arrayBuffer().toDart;
    return RecordedVoice(Uint8List.view(buffer.toDart), 'voice-over.$ext');
  }

  @override
  void cancel() {
    final recorder = _recorder;
    if (recorder != null && recorder.state != 'inactive') recorder.stop();
    _chunks.clear();
    _release();
  }

  void _release() {
    final tracks = _stream?.getTracks().toDart ?? const [];
    for (final t in tracks) {
      t.stop();
    }
    _stream = null;
    _recorder = null;
  }
}
