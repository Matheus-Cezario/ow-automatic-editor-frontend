import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart';
import 'package:ow_editor/montage_state.dart';

/// The magnet: beats, the other clips' edges on any layer, and the playhead.
void main() {
  TimelineClip clip(String id, double at, double dur) =>
      TimelineClip(id: id, atS: at, durationS: dur, startS: 100);

  // a on the bottom layer ends at 2; b on the top layer starts at 5
  MontageState state() => MontageState(
    layers: [
      Layer(clips: [clip('a', 0, 2), clip('m', 8, 1)]),
      Layer(clips: [clip('b', 5, 1)]),
    ],
  );

  test('the points: other clips\' edges on every layer, beats, playhead', () {
    final points = magnetPoints(
      state(),
      moving: {'m'},
      beats: const [10],
      playheadS: 3.3,
    );
    expect(points.toSet(), {10, 0, 2, 5, 6, 3.3});
  });

  test('a hidden layer pulls nothing', () {
    final s = state();
    final hidden = s.copyWith(
      layers: [s.layers[0], s.layers[1].copyWith(hidden: true)],
    );
    final points = magnetPoints(hidden, moving: {'m'}, beats: const []);
    expect(points, isNot(contains(5)));
  });

  double atOf(MontageState s, String id) => s.clipItem(id)!.atS;

  test('moving close to another clip\'s end makes them touch', () {
    final s = state();
    final moved = moveBlock(
      s,
      'm',
      2.08,
      beats: magnetPoints(s, moving: {'m'}, beats: const []),
      snap: true,
    );
    expect(atOf(moved, 'm'), 2, reason: 'snapped to the end of a');
    expect(stuckTo(moved, 'm'), 2);
  });

  test('the end edge snaps too, to a clip on another layer', () {
    final s = state();
    // m lasts 1 s: dropped at 3.95, its end (4.95) is pulled to b's start
    final moved = moveBlock(
      s,
      'm',
      3.95,
      beats: magnetPoints(s, moving: {'m'}, beats: const []),
      snap: true,
    );
    expect(atOf(moved, 'm'), closeTo(4, 1e-9));
  });

  test('the playhead pulls as well', () {
    final s = state();
    final moved = moveBlock(
      s,
      'm',
      3.25,
      beats: magnetPoints(s, moving: {'m'}, beats: const [], playheadS: 3.3),
      snap: true,
    );
    expect(atOf(moved, 'm'), closeTo(3.3, 1e-9));
    expect(stuckTo(moved, 'm', playheadS: 3.3), closeTo(3.3, 1e-9));
  });

  test('stretching snaps the end to a neighbour\'s edge', () {
    final s = MontageState(
      layers: [
        Layer(clips: [clip('a', 0, 1)]),
        Layer(clips: [clip('b', 3, 1)]),
      ],
    );
    final stretched = stretchBlock(
      s,
      'a',
      2.94,
      beats: magnetPoints(s, moving: {'a'}, beats: const []),
      snap: true,
    );
    expect(stretched.clipItem('a')!.untilS, closeTo(3, 1e-9));
  });

  test('away from every point, it stays where it was dropped', () {
    final s = state();
    final moved = moveBlock(
      s,
      'm',
      3.6,
      beats: magnetPoints(s, moving: {'m'}, beats: const []),
      snap: true,
    );
    expect(atOf(moved, 'm'), 3.6);
    expect(stuckTo(moved, 'm'), isNull);
  });
}
