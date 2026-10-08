import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart';
import 'package:ow_editor/levels.dart';
import 'package:ow_editor/montage.dart';
import 'package:ow_editor/montage_state.dart';
import 'package:ow_editor/screens/timeline_screen.dart';
import 'package:ow_editor/voice_recorder.dart';
import 'package:ow_editor/widgets/music_timeline.dart';

import 'timeline_screen_test.dart' show jobJson;

/// Voice-overs: recorded in the editor, placed where the recording started,
/// mixed on their own, with the rest of the mix stepping back under them.
void main() {
  Track track(String id, double durationS, {List<double>? peaks}) => Track(
    id: id,
    status: 'ready',
    name: id,
    durationS: durationS,
    bpm: 0,
    beats: const [],
    peaks: peaks ?? const [],
    audioUrl: '',
  );

  MontageState withSong() =>
      putMusic(MontageState.blank(), track('song', 20), atS: 0, durationS: 10);

  group('the wire', () {
    test('a library item recorded as a voice says so', () {
      final item = Media.fromJson({
        'id': 'v',
        'kind': 'audio',
        'status': 'ready',
        'voice': true,
      });
      expect(item.isVoice, isTrue);
      expect(Media.fromJson({'id': 'm', 'kind': 'audio'}).isVoice, isFalse);
    });

    test('a voice block is neither music nor an effect', () {
      final s = putVoice(withSong(), track('vo', 2), atS: 3);
      final clip = s.layers.last.clips.single;
      expect(clip.isVoice, isTrue);
      expect(clip.isMusic, isFalse);
      expect(clip.isSoundEffect, isFalse);
      expect(clip.toJson()['kind'], 'voice');
    });
  });

  group('putVoice', () {
    test('goes over the music, where asked, on a Voice layer', () {
      final base = withSong();
      final s = putVoice(base, track('vo', 2.5), atS: 3);
      expect(s.layers, hasLength(base.layers.length + 1));
      expect(s.layers.last.name, kVoiceLayerName);
      expect(s.layers.last.isAudio, isTrue);
      final clip = s.layers.last.clips.single;
      expect((clip.atS, clip.durationS, clip.mediaId), (3.0, 2.5, 'vo'));
      expect(s.selectionIds, {clip.id});
    });

    test('the next one reuses the Voice layer when it is free', () {
      var s = putVoice(withSong(), track('vo', 2), atS: 1);
      final layers = s.layers.length;
      s = s.copyWith(activeLayer: 1);
      s = putVoice(s, track('vo2', 2), atS: 5);
      expect(s.layers, hasLength(layers));
      expect(s.layers.last.clips.map((c) => c.atS), [1, 5]);
    });
  });

  group('the dip', () {
    test('down just before the voice, held, back up after — as the server', () {
      final spans = [(2.0, 4.0)];
      expect(voiceDipAt(spans, 1.0), 0);
      expect(voiceDipAt(spans, 2.0 - kVoiceAttack / 2), closeTo(0.5, 1e-9));
      expect(voiceDipAt(spans, 2.0), 1);
      expect(voiceDipAt(spans, 3.9), 1);
      expect(voiceDipAt(spans, 4.0 + kVoiceRelease / 2), closeTo(0.5, 1e-9));
      expect(voiceDipAt(spans, 5.0), 0);
    });

    test('a muted voice, or one on a muted layer, does not dip anything', () {
      var s = putVoice(withSong(), track('vo', 2), atS: 2);
      expect(voiceSpans(s.layers), [(2.0, 4.0)]);
      final i = s.layers.length - 1;
      s = s.withLayer(i, s.layers[i].copyWith(muted: true));
      expect(voiceSpans(s.layers), isEmpty);
    });

    test('the level meter hears the music step back under a voice', () {
      final loud = [for (var i = 0; i < 400; i++) 1.0];
      final tracks = {
        'song': track('song', 20, peaks: loud),
        'vo': track('vo', 2),
      };
      final s = putVoice(withSong(), tracks['vo']!, atS: 4);
      double at(double t) => mixLevelAt(
        s,
        t,
        tracks: tracks,
        matchWave: const [],
        matchDurationS: 0,
      );
      expect(at(5), closeTo(at(1) * s.duckLevel, 1e-6));
    });
  });

  group('the screen', () {
    testWidgets(
      'record from the playhead, stop, and the voice lands where it started',
      (tester) async {
        final api = _FakeApi();
        final mic = _FakeRecorder();
        await tester.binding.setSurfaceSize(const Size(1000, 2400));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            home: TimelineScreen(
              job: Job.fromJson(jobJson(withMusic: true)),
              api: api,
              voiceRecorder: mic,
            ),
          ),
        );
        await tester.pump();

        List<Layer> layers() =>
            tester.widget<MusicTimeline>(find.byType(MusicTimeline)).layers;
        final before = layers().length;

        await tester.tap(find.byKey(const Key('record-voice')));
        await tester.pump();
        expect(mic.started, isTrue);
        expect(find.byTooltip('Stop recording'), findsOneWidget);

        await tester.tap(find.byKey(const Key('record-voice')));
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }

        expect(api.sent, ['voice-over.weba']);
        final after = layers();
        expect(after, hasLength(before + 1));
        final voice = after.firstWhere((l) => l.name == kVoiceLayerName);
        final clip = voice.clips.single;
        expect(clip.kind, kVoiceKind);
        expect(clip.mediaId, 'vo1');
        expect(clip.atS, 0, reason: 'where the playhead was at the start');
        expect(clip.durationS, 1.5);
      },
    );

    testWidgets('a refused microphone says so and records nothing', (
      tester,
    ) async {
      final mic = _FakeRecorder(refuse: true);
      await tester.binding.setSurfaceSize(const Size(1000, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: TimelineScreen(
            job: Job.fromJson(jobJson()),
            api: _FakeApi(),
            voiceRecorder: mic,
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('record-voice')));
      await tester.pump();
      expect(find.textContaining('Could not use the microphone'), findsOneWidget);
      expect(find.byTooltip('Stop recording'), findsNothing);
    });
  });
}

class _FakeRecorder implements VoiceRecorder {
  _FakeRecorder({this.refuse = false});

  final bool refuse;
  bool started = false;

  @override
  bool get isSupported => true;

  @override
  Future<void> start() async {
    if (refuse) throw Exception('NotAllowedError');
    started = true;
  }

  @override
  Future<RecordedVoice> stop() async =>
      RecordedVoice(Uint8List.fromList([1, 2, 3]), 'voice-over.weba');

  @override
  void cancel() {}
}

class _FakeApi extends ApiClient {
  final sent = <String>[];

  @override
  Future<Media> uploadVoice({
    required String jobId,
    required Uint8List bytes,
    required String fileName,
  }) async {
    sent.add(fileName);
    return Media(
      id: 'vo1',
      kind: 'audio',
      status: 'pending',
      name: 'voice-over.weba',
      durationS: 0,
      isVoice: true,
    );
  }

  @override
  Future<Media> waitForMedia(
    String id, {
    Duration timeout = const Duration(minutes: 3),
    Duration every = const Duration(seconds: 1),
  }) async => Media(
    id: 'vo1',
    kind: 'audio',
    status: 'ready',
    name: 'voice-over.weba',
    durationS: 1.5,
    audioUrl: 'http://localhost/api/media/vo1/file',
    isVoice: true,
  );

  @override
  Future<void> requestFrames(String jobId) async {}
}
