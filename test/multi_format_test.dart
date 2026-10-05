import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart';
import 'package:ow_editor/export_options.dart';
import 'package:ow_editor/montage_state.dart';

/// Several formats in one render, and the vertical framings.
void main() {
  MontageState montage(ExportSpec e) => MontageState(
    layers: [
      Layer(clips: [TimelineClip(id: 'a', atS: 0, durationS: 2, startS: 10)]),
    ],
    title: 'Flank',
    export: e,
  );

  test('the new export fields travel and come back', () {
    const e = ExportSpec(
      killfeedInset: true,
      extraFormats: ['9:16', '1:1'],
      extraFit: 'blur',
      extraKillfeed: true,
    );
    final back = ExportSpec.fromJson(e.toJson());
    expect(back.killfeedInset, isTrue);
    expect(back.extraFormats, ['9:16', '1:1']);
    expect((back.extraFit, back.extraKillfeed), ('blur', true));
    expect(const ExportSpec().toJson().containsKey('extra_formats'), isFalse);
    expect(const ExportSpec(killfeedInset: true).standard, isFalse);
  });

  test('one render, the main output and one copy per extra format', () {
    final s = montage(
      const ExportSpec(
        extraFormats: ['9:16', '1:1', '16:9'],
        extraFit: 'cover',
        extraKillfeed: true,
      ),
    );
    final out = renderVariants(s, widthPx: 1920, heightPx: 1080);
    // 16:9 is what the recording already is: no duplicate
    expect(out.map((m) => m.title), ['Flank', 'Flank (9:16)', 'Flank (1:1)']);
    final vertical = out[1].export;
    expect((vertical.width, vertical.height), (1080, 1920));
    expect(vertical.killfeedInset, isTrue);
    expect(vertical.extraFormats, isEmpty);
    expect(out[2].export.killfeedInset, isFalse, reason: 'square is not portrait');
    expect(out[0].export.extraFormats, isNotEmpty, reason: 'kept for the draft');
  });

  test('a vertical main output makes 16:9 an extra', () {
    final s = montage(
      const ExportSpec(width: 1080, height: 1920, extraFormats: ['16:9', '9:16']),
    );
    final out = renderVariants(s, widthPx: 1920, heightPx: 1080);
    expect(out.map((m) => m.title), ['Flank', 'Flank (16:9)']);
    expect(out[1].export.fit, 'cover');
  });
}
