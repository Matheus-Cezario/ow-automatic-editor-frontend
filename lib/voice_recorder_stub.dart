import 'voice_recorder.dart';

/// Off the web there is no recorder: the editor is a web app.
class PlatformVoiceRecorder implements VoiceRecorder {
  @override
  bool get isSupported => false;

  @override
  Future<void> start() async =>
      throw UnsupportedError('recording works in the browser');

  @override
  Future<RecordedVoice> stop() async =>
      throw UnsupportedError('recording works in the browser');

  @override
  void cancel() {}
}
