import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart';
import 'package:ow_editor/montage_state.dart';

/// A multi-selection moved across layers in one go.
void main() {
  TimelineClip clip(String id, double at) =>
      TimelineClip(id: id, atS: at, durationS: 2, startS: 100);

  MontageState state({List<Layer>? layers, Set<String> selected = const {}}) =>
      MontageState(
        layers:
            layers ??
            [
              Layer(clips: [clip('a', 0), clip('b', 5)]),
              Layer(clips: [clip('c', 10)]),
              const Layer(),
            ],
        selectionIds: selected,
      );

  test('every selected clip goes up by the same number of layers', () {
    final s = moveSelectionToLayers(state(selected: {'a', 'c'}), 1);
    expect([for (final c in s.layers[0].clips) c.id], ['b']);
    expect([for (final c in s.layers[1].clips) c.id]..sort(), ['a']);
    expect([for (final c in s.layers[2].clips) c.id], ['c']);
    expect(s.layers[1].clips.single.atS, 0, reason: 'same instant');
  });

  test('a clip moving out frees the room for one moving in', () {
    // c leaves layer 1 as a takes a spot there; b and c do not collide
    final s = moveSelectionToLayers(
      state(
        layers: [
          Layer(clips: [clip('a', 10)]),
          Layer(clips: [clip('c', 10)]),
          const Layer(),
        ],
        selected: {'a', 'c'},
      ),
      1,
    );
    expect(s.layers[1].clips.single.id, 'a');
    expect(s.layers[2].clips.single.id, 'c');
  });

  test('all or nothing, with the reason', () {
    final s = state(selected: {'a', 'c'});
    expect(selectionLayerRefusal(s, 2), 'There is no layer there.');
    expect(identical(moveSelectionToLayers(s, 2), s), isTrue);
    expect(selectionLayerRefusal(s, -1), 'There is no layer there.');

    final blocked = state(
      layers: [
        Layer(clips: [clip('a', 0)]),
        Layer(clips: [clip('x', 1)]),
      ],
      selected: {'a'},
    );
    expect(
      selectionLayerRefusal(blocked, 1),
      'Something is in the way on the other layer.',
    );

    final locked = state(
      layers: [
        Layer(clips: [clip('a', 0)]),
        const Layer(name: 'top', locked: true),
      ],
      selected: {'a'},
    );
    expect(selectionLayerRefusal(locked, 1), 'The layer "top" is locked.');

    final sound = state(
      layers: [
        Layer(clips: [clip('a', 0)]),
        const Layer(kind: 'audio'),
      ],
      selected: {'a'},
    );
    expect(
      selectionLayerRefusal(sound, 1),
      'This is a sound layer: pictures do not go in it.',
    );
  });
}
