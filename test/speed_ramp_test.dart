import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart';
import 'package:ow_editor/monitor/frame.dart';
import 'package:ow_editor/montage.dart';
import 'package:ow_editor/montage_state.dart';

/// Speed ramps: the integral of the speed everywhere clip time turns into
/// source time — the same sums as the server's `source_offset`.
void main() {
  // 0.5x → 2x across a 2 s clip, linear: speed(t) = 0.5 + 0.75 t
  const ramp = [
    ClipKey(prop: KeyProp.speed, t: 0, value: 0.5),
    ClipKey(prop: KeyProp.speed, t: 1, value: 2),
  ];
  double offset(double t) => 0.5 * t + 0.375 * t * t;

  TimelineClip clip({
    List<ClipKey> keys = ramp,
    double speed = 1,
    double dur = 2,
    double sourceT = 0,
  }) => TimelineClip(
    id: 'c',
    atS: 10,
    durationS: dur,
    startS: 100,
    sourceT: sourceT,
    speed: speed,
    keys: keys,
  );

  MontageState stateWith(TimelineClip c) => MontageState(
    layers: [
      Layer(clips: [c]),
    ],
  );

  group('the integral', () {
    test('a ramp runs the source unevenly, and back', () {
      final c = clip();
      expect(c.isRamped, isTrue);
      expect(c.speedAt(1), closeTo(1.25, 1e-9));
      expect(c.sourceOffsetAt(1), closeTo(offset(1), 1e-4));
      expect(c.sourceConsumedS, closeTo(offset(2), 1e-4));
      expect(c.localForSourceOffset(offset(1.3)), closeTo(1.3, 1e-3));
    });

    test('a constant speed is the old multiplication', () {
      final c = clip(keys: const [], speed: 2);
      expect(c.sourceConsumedS, 4);
      expect(c.localForSourceOffset(3), 1.5);
    });
  });

  group('the play mark', () {
    test('at 2x the play shows in half the time', () {
      // the play is 1 s into the source; at 2x that is half a second in
      final c = clip(keys: const [], speed: 2, sourceT: 101);
      expect(momentInVideo(c), closeTo(10.5, 1e-9));
    });

    test('under a ramp it shows where the integral reaches it', () {
      final c = clip(sourceT: 100 + offset(1.2));
      expect(momentInVideo(c), closeTo(11.2, 1e-3));
    });
  });

  group('splitting', () {
    test('the right half starts where the left stopped in the source', () {
      final s = split(stateWith(clip(keys: const [], speed: 2)), 'c', 11);
      final right = s.layers.single.clips.last;
      expect(right.startS, closeTo(102, 1e-9), reason: '1 s at 2x');
    });

    test('keyframes are carried to each half, as fractions of it', () {
      final c = clip(
        dur: 4,
        keys: const [
          ClipKey(prop: KeyProp.opacity, t: 0, value: 0),
          ClipKey(prop: KeyProp.opacity, t: 1, value: 1),
        ],
      );
      final s = split(stateWith(c), 'c', 12);
      final [left, right] = s.layers.single.clips;
      expect(
        [for (final k in left.keys) (k.t, k.value)],
        [(0.0, 0.0), (1.0, 0.5)],
      );
      expect(
        [for (final k in right.keys) (k.t, k.value)],
        [(0.0, 0.5), (1.0, 1.0)],
      );
    });

    test('a ramp splits without the picture jumping', () {
      final s = split(stateWith(clip()), 'c', 11);
      final right = s.layers.single.clips.last;
      expect(right.startS, closeTo(100 + offset(1), 1e-3));
      expect(right.speedAt(0), closeTo(1.25, 1e-3));
    });
  });

  test('the monitor follows the ramp', () {
    final p = frameAt(
      [
        Layer(clips: [clip()]),
      ],
      11,
      matchUrl: 'm',
    ).pieces.single;
    expect(p.sourceT, closeTo(100 + offset(1), 1e-3));
    expect(p.rate, closeTo(1.25, 1e-9));
  });

  group('ramp into the play', () {
    test('slow motion through the play, full speed around it', () {
      // a 4 s clip with the play 2.8 s into the source
      final c = clip(keys: const [], dur: 4, sourceT: 102.8);
      final s = rampIntoMoment(stateWith(c), 'c')!;
      final r = s.layers.single.clips.single;

      final playAt = r.localForSourceOffset(2.8);
      expect(
        r.speedAt(playAt),
        closeTo(0.35, 0.01),
        reason: 'the play is slow',
      );
      expect(r.speedAt(0), 1, reason: 'full speed in');
      expect(r.speedAt(r.durationS), 1, reason: 'full speed out');
      final ts = [for (final k in r.keysFor(KeyProp.speed)) k.t];
      expect(ts.toSet(), hasLength(ts.length), reason: 'no two keys together');
      expect(ts, orderedEquals([...ts]..sort()));
      expect(momentMark(r), isNotNull, reason: 'the play is still in the clip');
    });

    test('a short moment clip grows to fit the slow motion', () {
      // the default moment clip: 1.2 s, the play at 70%
      final c = clip(keys: const [], dur: 1.2, sourceT: 100.84);
      final r = rampIntoMoment(stateWith(c), 'c')!.layers.single.clips.single;
      expect(r.durationS, greaterThan(1.2));
      expect(r.speedAt(r.localForSourceOffset(0.84)), closeTo(0.35, 0.01));
      // the recording after the ramp still plays to where it used to end
      expect(r.sourceConsumedS, closeTo(1.2, 0.05));
    });

    test('the next clip limits how much it can grow', () {
      final c = clip(keys: const [], dur: 1.2, sourceT: 100.84);
      final next = TimelineClip(id: 'n', atS: 11.3, durationS: 1, startS: 0);
      final s = MontageState(
        layers: [
          Layer(clips: [c, next]),
        ],
      );
      expect(rampIntoMoment(s, 'c'), isNull);
    });

    test('a clip with no play has nothing to ramp around', () {
      expect(rampIntoMoment(stateWith(clip(keys: const [])), 'c'), isNull);
    });

    test('freezing drops the ramp', () {
      final s = adjustEffect(stateWith(clip()), 'c', freeze: true);
      expect(s.layers.single.clips.single.isRamped, isFalse);
    });
  });
}
