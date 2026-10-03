import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart';
import 'package:ow_editor/montage.dart';
import 'package:ow_editor/montage_state.dart';

/// Ducking at the plays — the server's shape (`_duck_curve`).
void main() {
  TimelineClip moment(
    double at,
    double start,
    double play, {
    double speed = 1,
  }) => TimelineClip(
    id: 'm$at',
    atS: at,
    durationS: 2,
    startS: start,
    sourceT: play,
    speed: speed,
  );

  test('a play is where the clip reaches its moment, speed included', () {
    final layers = [
      Layer(clips: [moment(0, 10, 11), moment(3, 20, 21, speed: 2)]),
      // music and text have no plays
      Layer(kind: 'audio', clips: [moment(0, 0, 1)]),
    ];
    expect(playTimes(layers), [1.0, 3.5]);
  });

  test('fully down around the play, ramping in and out', () {
    const plays = [2.0];
    expect(duckAt(plays, 0), 0);
    expect(
      duckAt(plays, 2 - kDuckBefore - kDuckAttack / 2),
      closeTo(0.5, 1e-9),
    );
    expect(duckAt(plays, 2), closeTo(1, 1e-9));
    expect(duckAt(plays, 2 + kDuckAfter), closeTo(1, 1e-9));
    expect(
      duckAt(plays, 2 + kDuckAfter + kDuckRelease / 2),
      closeTo(0.5, 1e-9),
    );
    expect(duckAt(plays, 4), 0);
  });

  test('two plays close together stay down between them', () {
    // 0.6 s apart: the second ducks before the first lets go
    for (var t = 2.0; t <= 3.1; t += 0.05) {
      expect(duckAt(const [2.0, 2.6], t), greaterThan(0.999), reason: '$t');
    }
    // 1.2 s apart the music comes part of the way back between them
    expect(duckAt(const [2.0, 3.2], 2.8), closeTo(0.25, 1e-9));
  });

  test('the setting goes to the server and comes back', () {
    final s = MontageState.blank().copyWith(duckPlays: true, duckLevel: 0.2);
    final json = s.toPayload().toJson();
    expect(json['duck_plays'], true);
    expect(json['duck_level'], 0.2);
    final back = montageFromDraft(Montage.fromJson(json));
    expect((back.duckPlays, back.duckLevel), (true, 0.2));
    expect(
      MontageState.blank().toPayload().toJson().containsKey('duck_plays'),
      isFalse,
    );
  });
}
