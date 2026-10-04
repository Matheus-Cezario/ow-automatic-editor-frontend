import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart';
import 'package:ow_editor/export_options.dart';
import 'package:ow_editor/montage_state.dart';

/// In and out points: the stretch that loops and that is exported.
void main() {
  final blank = MontageState(layers: const [Layer()]);

  test('in, then out, make a range; clearing gives the whole video back', () {
    expect(hasRange(blank.export), isFalse);
    final s = setRangeOut(setRangeIn(blank, 2), 5);
    expect((s.export.fromS, s.export.toS), (2.0, 5.0));
    expect(hasRange(s.export), isTrue);
    expect(hasRange(exportAll(s).export), isFalse);
  });

  test('an in past the out drops the out; an out before the in drops the in',
      () {
    final s = setRangeOut(setRangeIn(blank, 2), 5);
    final late = setRangeIn(s, 6);
    expect((late.export.fromS, late.export.toS), (6.0, null));
    final early = setRangeOut(s, 1);
    expect((early.export.fromS, early.export.toS), (0.0, 1.0));
  });

  test('an out at zero is no range', () {
    expect(identical(setRangeOut(blank, 0), blank), isTrue);
  });
}
