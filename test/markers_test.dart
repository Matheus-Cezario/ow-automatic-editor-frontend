import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart';
import 'package:ow_editor/montage_state.dart';

/// Markers: notes pinned to the ruler that the magnet snaps to.
void main() {
  final blank = MontageState(layers: const [Layer()]);

  test('the same key puts a marker and takes it away', () {
    final one = toggleMarker(blank, 4.0);
    expect(one.markers.single.tS, 4.0);
    expect(toggleMarker(one, 4.02).markers, isEmpty, reason: 'close enough');
    expect(toggleMarker(one, 5.0).markers, hasLength(2));
  });

  test('moved, named and removed; never before zero', () {
    var s = toggleMarker(toggleMarker(blank, 2), 8);
    s = moveMarker(s, 0, 10); // past the other: keeps its index
    expect([for (final m in s.markers) m.tS], [10.0, 8.0]);
    s = moveMarker(s, 1, -3);
    expect(s.markers[1].tS, 0.0);
    s = renameMarker(s, 0, '  the drop  ');
    expect(s.markers[0].label, 'the drop');
    s = renameMarker(s, 0, 'x' * 60);
    expect(s.markers[0].label, hasLength(40));
    expect(removeMarker(s, 0).markers.single.tS, 0.0);
  });

  test('the next marker, by time, wrapping round', () {
    final s = toggleMarker(toggleMarker(toggleMarker(blank, 9), 3), 6);
    expect(nextMarker(s, 0), 3.0);
    expect(nextMarker(s, 3), 6.0);
    expect(nextMarker(s, 9.5), 3.0);
    expect(nextMarker(blank, 0), isNull);
  });

  test('the magnet pulls toward markers', () {
    final s = toggleMarker(blank, 7.5);
    expect(
      magnetPoints(s, moving: const {}, beats: const []),
      contains(7.5),
    );
  });

  test('markers survive the draft round trip and are undoable state', () {
    final s = renameMarker(toggleMarker(blank, 4.5), 0, 'drop');
    final json = s.toPayload().toJson();
    expect(json['markers'], [
      {'t_s': 4.5, 'label': 'drop'},
    ]);
    final back = montageFromDraft(Montage.fromJson(json));
    expect(back.markers, [const Marker(tS: 4.5, label: 'drop')]);
    expect(blank.toPayload().toJson(), isNot(contains('markers')));
  });
}
