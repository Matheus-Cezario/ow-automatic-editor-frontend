import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/montage.dart';
import 'package:ow_editor/widgets/music_timeline.dart';
import 'package:ow_editor/widgets/source_cutter.dart';

/// Cutting by hand from the whole recording.
void main() {
  group('a marked stretch', () {
    test('becomes a cut of the recording, starting at its in point', () {
      final c = spanClip(const SourceSpan(inS: 100, outS: 103.5), atS: 4);
      expect(
        (c.source, c.kind, c.startS, c.durationS, c.atS),
        ('recording', 'custom', 100.0, 3.5, 4.0),
      );
      expect(momentInVideo(c), isNull, reason: 'no play was marked');
    });

    test('a play marked inside it is the clip\'s play', () {
      final c = spanClip(
        const SourceSpan(inS: 100, outS: 104, playS: 102.5),
        atS: 10,
      );
      expect(momentInVideo(c), closeTo(12.5, 1e-9));
    });

    test('a play outside the stretch is ignored', () {
      final c = spanClip(
        const SourceSpan(inS: 100, outS: 104, playS: 110),
        atS: 0,
      );
      expect(c.sourceT, 0);
    });

    test('its name becomes the clip\'s name', () {
      final c = spanClip(
        const SourceSpan(inS: 1, outS: 3, name: '  ace on A  '),
        atS: 0,
      );
      expect(c.label, 'ace on A');
      expect(c.toJson()['label'], 'ace on A');
      expect(spanClip(const SourceSpan(inS: 1, outS: 3), atS: 0).toJson(),
          isNot(contains('label')));
    });

    test('too short is not a stretch', () {
      expect(const SourceSpan(inS: 1, outS: 1.01).isValid, isFalse);
    });

    test('dragged, it is as long on the ruler as it is', () {
      const drop = RulerDrop.span(SourceSpan(inS: 5, outS: 7.5));
      expect(drop.durationSecs, 2.5);
      expect(drop.blockLabel, 'Cut');
      expect(drop.isSound, isFalse);
    });
  });

  group('the source cutter', () {
    Future<List<SourceSpan>> pump(WidgetTester tester) async {
      final added = <SourceSpan>[];
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SourceCutter(
              videoUrl: null,
              durationS: 600,
              onAdd: added.add,
            ),
          ),
        ),
      );
      await tester.pump();
      return added;
    }

    Future<void> key(
      WidgetTester tester,
      LogicalKeyboardKey k, [
      int n = 1,
    ]) async {
      for (var i = 0; i < n; i++) {
        await tester.sendKeyEvent(k);
      }
      await tester.pump();
    }

    String spanText(WidgetTester tester) =>
        tester.widget<Text>(find.byKey(const Key('cutter-span'))).data!;

    testWidgets('starts as a short cut where the recording begins', (
      tester,
    ) async {
      await pump(tester);
      expect(spanText(tester), '00:00.0 → 00:03.0 · 3.0 s');
    });

    testWidgets('in, out and play from the keyboard, named, then added', (
      tester,
    ) async {
      final added = await pump(tester);
      await key(tester, LogicalKeyboardKey.arrowRight, 2); // 2 s
      await key(tester, LogicalKeyboardKey.keyI);
      await key(tester, LogicalKeyboardKey.arrowRight, 4); // 6 s
      await key(tester, LogicalKeyboardKey.keyO);
      await key(tester, LogicalKeyboardKey.arrowLeft); // 5 s
      await key(tester, LogicalKeyboardKey.keyP);
      expect(spanText(tester), '00:02.0 → 00:06.0 · 4.0 s');

      await tester.enterText(find.byKey(const Key('cut-name')), 'flank on B');
      await tester.tap(find.byKey(const Key('cutter-add')));
      await tester.pump();

      final span = added.single;
      expect(
        (span.inS, span.outS, span.playS, span.name),
        (2.0, 6.0, 5.0, 'flank on B'),
      );
      expect(find.text('Added "flank on B" to the timeline.'), findsOneWidget);
      // ready for the next cut
      expect(
        tester.widget<TextField>(find.byKey(const Key('cut-name'))).controller!.text,
        isEmpty,
      );
    });

    testWidgets('typing the name is not a shortcut', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('cut-name')));
      await tester.pump();
      await key(tester, LogicalKeyboardKey.keyO);
      expect(spanText(tester), '00:00.0 → 00:03.0 · 3.0 s');
    });

    testWidgets('dragging the OUT line moves the end of the cut', (
      tester,
    ) async {
      await pump(tester);
      final strip = tester.getSize(find.byKey(const Key('cutter-strip')));
      // the strip shows 30 s: this many pixels are 3 s
      final threeSeconds = strip.width / 10;
      await tester.drag(
        find.byKey(const Key('cutter-out')),
        Offset(threeSeconds, 0),
      );
      await tester.pump();
      final out = double.parse(
        RegExp(r'· ([\d.]+) s').firstMatch(spanText(tester))!.group(1)!,
      );
      expect(out, closeTo(6.0, 0.2));
    });

    testWidgets('the lines never cross', (tester) async {
      await pump(tester);
      final strip = tester.getSize(find.byKey(const Key('cutter-strip')));
      await tester.drag(
        find.byKey(const Key('cutter-in')),
        Offset(strip.width / 2, 0),
      );
      await tester.pump();
      expect(spanText(tester), '00:02.8 → 00:03.0 · 0.2 s');
    });

    testWidgets('an IN past the end carries the cut along', (tester) async {
      await pump(tester);
      await key(tester, LogicalKeyboardKey.arrowRight, 10);
      await key(tester, LogicalKeyboardKey.keyI);
      expect(spanText(tester), '00:10.0 → 00:13.0 · 3.0 s');
    });
  });
}
