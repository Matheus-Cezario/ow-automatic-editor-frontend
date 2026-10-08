import 'dart:typed_data';

import 'voice_recorder_stub.dart'
    if (dart.library.js_interop) 'voice_recorder_web.dart'
    as impl;

/// What a recording came out as: the bytes, and the file name that tells the
/// server what kind of audio they are.
class RecordedVoice {
  const RecordedVoice(this.bytes, this.fileName);

  final Uint8List bytes;
  final String fileName;
}

/// Records the microphone, for a voice-over.
///
/// On the web it is the browser's own `MediaRecorder`: Opus in WebM on
/// Chrome and Firefox's Ogg, AAC in MP4 on Safari — all of which the server
/// reads. Elsewhere [isSupported] is false and the button does not show.
abstract class VoiceRecorder {
  factory VoiceRecorder() = impl.PlatformVoiceRecorder;

  bool get isSupported;

  /// Asks for the microphone and starts. Throws when the person says no or
  /// there is no microphone.
  Future<void> start();

  /// Stops and hands back what was recorded.
  Future<RecordedVoice> stop();

  /// Stops and throws the recording away.
  void cancel();
}
