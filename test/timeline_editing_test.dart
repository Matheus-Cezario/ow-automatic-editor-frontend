import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart';
import 'package:ow_editor/montage_state.dart';

/// Cutting the right clip, ripple delete and insert mode.
void main() {
  TimelineClip clip(String id, double at, double dur) =>
      TimelineClip(id: id, atS: at, durationS: dur, startS: 100);

  MontageState layered(List<List<TimelineClip>> layers, {int active = 0}) =>
      MontageState(
        layers: [for (final l in layers) Layer(clips: l)],
        activeLayer: active,
      );

  List<double> starts(MontageState s, int layer) =>
      [for (final c in s.layers[layer].clips) c.atS]..sort();

  group('which clip a cut goes through', () {
    // a clip on each of two layers, both under the playhead at 1 s
    final s = layered([
      [clip('low', 0, 2)],
      [clip('high', 0, 2)],
    ]);

    test('the active layer first — never just the first clip in the list', () {
      expect(splitTargets(s.copyWith(activeLayer: 1), 1), ['high']);
      expect(splitTargets(s.copyWith(activeLayer: 0), 1), ['low']);
    });

    test('the chosen clip wins over the active layer', () {
      final chosen = s.copyWith(activeLayer: 0, selectionIds: {'high'});
      expect(splitTargets(chosen, 1), ['high']);
    });

    test('with nothing on the active layer, the top clip', () {
      final s2 = layered([
        [clip('low', 0, 2)],
        [clip('high', 0, 2)],
        [],
      ], active: 2);
      expect(splitTargets(s2, 1), ['high']);
    });

    test('every layer cuts all unlocked clips under the playhead', () {
      final locked = s.copyWith(
        layers: [s.layers[0], s.layers[1].copyWith(locked: true)],
      );
      expect(splitTargets(s, 1, everyLayer: true), ['low', 'high']);
      expect(splitTargets(locked, 1, everyLayer: true), ['low']);
    });

    test('nothing under the playhead, nothing to cut', () {
      expect(splitTargets(s, 5), isEmpty);
    });
  });

  group('ripple delete', () {
    test('the clips after move back by the removed length, gaps kept', () {
      final s = layered([
        [clip('a', 0, 2), clip('b', 2, 1), clip('c', 4, 1)],
      ]);
      final after = rippleDelete(s, {'b'});
      expect(starts(after, 0), [0, 3], reason: 'c keeps its 1 s gap');
    });

    test('several removed, each one pulls back what follows it', () {
      final s = layered([
        [clip('a', 0, 1), clip('b', 1, 1), clip('c', 2, 1), clip('d', 3, 1)],
      ]);
      expect(starts(rippleDelete(s, {'a', 'c'}), 0), [0, 1]);
    });

    test('other layers stay where they are', () {
      final s = layered([
        [clip('a', 0, 2), clip('b', 2, 1)],
        [clip('x', 3, 1)],
      ]);
      final after = rippleDelete(s, {'a'});
      expect(starts(after, 0), [0]);
      expect(starts(after, 1), [3]);
    });
  });

  group('insert mode', () {
    test('a free spot takes the clip without pushing anything', () {
      final (at, room) = makeRoom([clip('a', 0, 1), clip('b', 3, 1)], 1.5, 1);
      expect(at, 1.5);
      expect([for (final c in room) c.atS], [0, 3]);
    });

    test('falling inside a clip, it goes to the nearer edge and pushes', () {
      final clips = [clip('a', 0, 2), clip('b', 2, 1), clip('c', 5, 1)];
      final (at, room) = makeRoom(clips, 1.6, 1);
      expect(at, 2, reason: 'nearer to the end of a');
      expect([for (final c in room) c.atS], [0, 3, 6]);
    });

    test('a new clip at the start pushes the montage right', () {
      final s = layered([
        [clip('a', 0, 2)],
      ]);
      final after = addClip(
        s,
        clip('n', 0, 1),
        beats: const [],
        snap: false,
        insert: true,
      );
      expect(starts(after, 0), [0, 1]);
      final added = after.layers[0].clips.firstWhere(
        (c) => after.selectionIds.contains(c.id),
      );
      expect(added.atS, 0);
    });
  });
}
