import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart';
import 'package:ow_editor/levels.dart';
import 'package:ow_editor/montage_state.dart';
import 'package:ow_editor/widgets/level_meter.dart';

/// The mix level meter and the export loudness.
void main() {
  // a song at a steady 0.5, and a match at a steady 0.4
  final song = Track.fromJson({
    'id': 's1',
    'status': 'ready',
    'name': 'song',
    'duration_s': 60.0,
    'bpm': 120.0,
    'beats': <double>[],
    'peaks': List.filled(600, 0.5),
    'audio_url': '/a',
  });
  final match = List.filled(600, 0.4);

  TimelineClip cut({double volume = 1}) => TimelineClip(
    id: 'c',
    atS: 0,
    durationS: 10,
    startS: 20,
    audio: ClipAudio(volume: volume),
  );
  TimelineClip block({double volume = 1}) => TimelineClip(
    id: 'm',
    atS: 0,
    durationS: 10,
    startS: 0,
    source: 'music',
    mediaId: 's1',
    audio: ClipAudio(volume: volume),
  );

  double level(MontageState s, [double t = 5]) => mixLevelAt(
    s,
    t,
    tracks: {'s1': song},
    matchWave: match,
    matchDurationS: 60,
  );

  test('with no music the game sound plays at its own level', () {
    final s = MontageState(layers: [Layer(clips: [cut()])]);
    expect(level(s), closeTo(0.4, 1e-9));
    expect(level(s, 12), 0, reason: 'after the clip, silence');
    expect(
      level(MontageState(layers: [Layer(clips: [cut(volume: 0.5)])])),
      closeTo(0.2, 1e-9),
    );
  });

  test('under music, the mix volumes and the block volume count', () {
    var s = MontageState(
      layers: [
        Layer(clips: [cut()]),
        Layer(kind: 'audio', clips: [block(volume: 2)]),
      ],
      musicVolume: 1,
      gameVolume: 0.5,
    );
    // song 0.5 x2, game 0.4 x0.5
    expect(level(s), closeTo(1.2, 1e-9));
    s = s.withLayer(1, s.layers[1].copyWith(muted: true));
    expect(level(s), closeTo(0.2, 1e-9));
  });

  test('dB for the caption', () {
    expect(dbfs(1), '+0.0 dB');
    expect(dbfs(0.5), '−6.0 dB');
    expect(dbfs(0), '−∞ dB');
  });

  testWidgets('the meter warns past full scale', (tester) async {
    Future<String?> tip(double level) async {
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: LevelMeter(level: level))),
      );
      return tester.widget<Tooltip>(find.byType(Tooltip)).message;
    }

    expect(await tip(0.5), 'Mix level −6.0 dB');
    expect(await tip(1.3), contains('over full scale'));
  });

  test('the loudness target travels and clears', () {
    const e = ExportSpec(loudness: -14);
    expect(e.toJson()['loudness'], -14.0);
    expect(ExportSpec.fromJson(e.toJson()).loudness, -14);
    expect(e.standard, isFalse);
    expect(e.copyWith(clearLoudness: true).loudness, isNull);
    expect(const ExportSpec().toJson().containsKey('loudness'), isFalse);
  });

  test('a rendered clip tells how loud it came out', () {
    final c = Clip.fromJson({
      'id': 'x',
      'kind': 'custom',
      'start_s': 0,
      'end_s': 10,
      'title': 'v',
      'score': 0,
      'meta': {'loudness': -14.1, 'true_peak': -1.6},
    });
    expect((c.loudness, c.truePeak), (-14.1, -1.6));
  });
}
