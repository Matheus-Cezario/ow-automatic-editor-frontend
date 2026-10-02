import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart';
import 'package:ow_editor/export_options.dart';
import 'package:ow_editor/montage_state.dart';

/// Exporting is a window onto the montage, not an edit of it.
void main() {
  TimelineClip clipItem(String id, double at, double dur) =>
      TimelineClip(id: id, atS: at, durationS: dur, startS: 10);

  MontageState state(List<TimelineClip> clips, {Set<String> selectionIds = const {}}) =>
      MontageState(layers: [Layer(clips: clips)], selectionIds: selectionIds);

  group('range', () {
    test('without a range, the whole montage comes out', () {
      final t = stretchOf(const ExportSpec(), 12.0);
      expect(t.startTime, 0);
      expect(t.endTime, 12.0);
      expect(exportedDuration(const ExportSpec(), 12.0), 12.0);
    });

    test('an open end resolves against the current duration', () {
      // the spec does not know how long the montage is; the caller does
      const e = ExportSpec(fromS: 4);
      expect(exportedDuration(e, 12.0), 8.0);
      expect(exportedDuration(e, 20.0), 16.0);
    });

    test('a range past the end is trimmed, not overflowed', () {
      // it happens on its own: you range the selection and then delete clips
      const e = ExportSpec(fromS: 2, toS: 30);
      expect(exportedDuration(e, 10.0), 8.0);
    });

    test('a range left entirely outside the montage goes back to everything', () {
      const e = ExportSpec(fromS: 50, toS: 60);
      expect(exportedDuration(e, 10.0), 10.0);
    });
  });

  group('export the selection', () {
    test('the window goes from the first to the last frame of the selection', () {
      final s = exportSelection(
        state([
          clipItem('a', 0, 2),
          clipItem('b', 5, 3),
          clipItem('c', 20, 1),
        ], selectionIds: {'b', 'c'}),
      );

      expect(s.export.fromS, 5);
      expect(s.export.toS, 21);
    });

    test('does not touch the montage — only the window', () {
      final beforeState = state([clipItem('a', 0, 2), clipItem('b', 5, 3)], selectionIds: {'b'});
      final afterState = exportSelection(beforeState);

      expect(afterState.clips.map((c) => c.atS), beforeState.clips.map((c) => c.atS));
      expect(afterState.clips, hasLength(2), reason: 'nothing was deleted');
    });

    test('without a selection, nothing changes', () {
      final beforeState = state([clipItem('a', 0, 2)]);
      expect(exportSelection(beforeState).export.toS, isNull);
    });

    test('you can go back and export everything', () {
      var s = exportSelection(state([clipItem('a', 4, 2)], selectionIds: {'a'}));
      expect(s.export.fromS, 4);

      s = exportAll(s);
      expect(s.export.fromS, 0);
      expect(s.export.toS, isNull);
    });
  });

  group('formats', () {
    test('the original fixes no size', () {
      final original = outputFormats.first;
      expect(original.width, 0);
      expect(original.aspect, isNull);
      expect(original.matches(const ExportSpec()), isTrue);
    });

    test('vertical is truly 9:16', () {
      final v = outputFormats.firstWhere((f) => f.displayName == 'Vertical');
      expect(v.aspect, closeTo(9 / 16, 0.001));
    });

    test('recognises the format already chosen', () {
      const e = ExportSpec(width: 1080, height: 1920);
      final found = outputFormats.where((f) => f.matches(e));
      expect(found.single.displayName, 'Vertical');
    });
  });

  group('quality', () {
    test('the system default is the middle one', () {
      expect(qualityOf(const ExportSpec()).displayName, 'Good');
    });

    test('a hand-typed crf falls back to the default without breaking', () {
      expect(qualityOf(const ExportSpec(crf: 23)).displayName, 'Good');
    });

    test('better quality is a lower crf', () {
      final high = qualities.firstWhere((q) => q.displayName == 'High');
      final light = qualities.firstWhere((q) => q.displayName == 'Light');
      expect(high.crf, lessThan(light.crf));
    });
  });

  group('size estimate', () {
    double mb(ExportSpec e) =>
        estimatedSizeMB(e, durationSecs: 30, widthPx: 1920, heightPx: 1080);

    test('answers the order of magnitude, which is what is asked', () {
      // 30s of 1080p30 at the default quality: tens of MB, not hundreds
      final r = mb(const ExportSpec());
      expect(r, greaterThan(5));
      expect(r, lessThan(80));
    });

    test('half the pixels, half the file', () {
      final full = mb(const ExportSpec(width: 1920, height: 1080));
      final middle = mb(const ExportSpec(width: 1280, height: 720));
      expect(middle, lessThan(full));
      expect(middle / full, closeTo((1280 * 720) / (1920 * 1080), 0.01));
    });

    test('every +6 of crf roughly halves the file', () {
      final a = mb(const ExportSpec(crf: 20));
      final b = mb(const ExportSpec(crf: 26));
      expect(b / a, closeTo(0.5, 0.05));
    });

    test('a range weighs only the range', () {
      final everything = mb(const ExportSpec());
      final excerpt = mb(const ExportSpec(fromS: 0, toS: 15));
      expect(excerpt / everything, closeTo(0.5, 0.01));
    });
  });

  test('the summary says size, duration and weight', () {
    final r = exportSummary(
      const ExportSpec(width: 1080, height: 1920, fps: 60, fromS: 0, toS: 65),
      durationSecs: 120,
      widthPx: 1920,
      heightPx: 1080,
    );

    expect(r, contains('1080x1920'));
    expect(r, contains('60fps'));
    expect(r, contains('1:05'));
    expect(r, contains('MB'));
  });

  test('the format travels with the draft', () {
    // switching machines and continuing must not send the video back to 16:9
    const e = ExportSpec(width: 1080, height: 1920, crf: 26, fit: 'contain');
    final outbound = Montage(export: e).toJson();
    final back = Montage.fromJson(outbound).export;

    expect(back.width, 1080);
    expect(back.height, 1920);
    expect(back.crf, 26);
    expect(back.fit, 'contain');
  });
}
