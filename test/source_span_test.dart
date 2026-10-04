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

    testWidgets('the bar between the lines slides the whole cut', (
      tester,
    ) async {
      await pump(tester);
      final strip = tester.getSize(find.byKey(const Key('cutter-strip')));
      // 30 s on screen: a fifth of it is 6 s
      await tester.drag(
        find.byKey(const Key('cutter-range')),
        Offset(strip.width / 5, 0),
      );
      await tester.pump();
      final m = RegExp(r'([\d:.]+) → ([\d:.]+) · ([\d.]+) s')
          .firstMatch(spanText(tester))!;
      expect(m.group(3), '3.0', reason: 'the length is kept');
      expect(double.parse(m.group(1)!.split(':').last), closeTo(6.0, 0.2));
    });

    testWidgets('the cut cannot slide past the recording', (tester) async {
      await pump(tester);
      await tester.drag(
        find.byKey(const Key('cutter-range')),
        const Offset(-300, 0),
      );
      await tester.pump();
      expect(spanText(tester), '00:00.0 → 00:03.0 · 3.0 s');
    });

    testWidgets('the length is typed or picked', (tester) async {
      await pump(tester);
      await key(tester, LogicalKeyboardKey.arrowRight, 10);
      await key(tester, LogicalKeyboardKey.keyI); // 10 → 13
      await tester.enterText(find.byKey(const Key('cut-length')), '7,5');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(spanText(tester), '00:10.0 → 00:17.5 · 7.5 s');

      await tester.tap(find.byKey(const ValueKey('cut-length-5.0')));
      await tester.pump();
      expect(spanText(tester), '00:10.0 → 00:15.0 · 5.0 s');
      expect(
        tester.widget<TextField>(find.byKey(const Key('cut-length'))).controller!.text,
        '5.0',
      );

      // dragging a line keeps the field honest
      await key(tester, LogicalKeyboardKey.arrowRight, 10); // 20 s
      await key(tester, LogicalKeyboardKey.keyO);
      expect(
        tester.widget<TextField>(find.byKey(const Key('cut-length'))).controller!.text,
        '10.0',
      );
    });

    testWidgets('a length past the end of the recording moves the start', (
      tester,
    ) async {
      final added = <SourceSpan>[];
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SourceCutter(videoUrl: null, durationS: 8, onAdd: added.add),
          ),
        ),
      );
      await tester.pump();
      await key(tester, LogicalKeyboardKey.arrowRight, 6);
      await key(tester, LogicalKeyboardKey.keyI); // 6 → 8 (clamped)
      await tester.tap(find.byKey(const ValueKey('cut-length-5.0')));
      await tester.pump();
      expect(spanText(tester), '00:03.0 → 00:08.0 · 5.0 s');
    });

    testWidgets('playing the cut loops between the lines', (tester) async {
      await pump(tester);
      await key(tester, LogicalKeyboardKey.arrowRight, 20); // away from it
      await tester.tap(find.byKey(const Key('cutter-play-cut')));
      await tester.pump();
      expect(find.text('Stop'), findsOneWidget);

      String clock() =>
          tester.widget<Text>(find.byKey(const Key('cutter-clock'))).data!;
      expect(clock(), startsWith('00:00.0'), reason: 'starts at IN');

      // 3 s of cut, then 1 s more: back near the start, never past OUT
      var latest = 0.0;
      for (var i = 0; i < 80; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        latest = double.parse(clock().split(' ').first.split(':').last);
        expect(latest, lessThanOrEqualTo(3.0));
      }
      expect(latest, lessThan(1.5));

      await tester.tap(find.byKey(const Key('cutter-play-cut')));
      await tester.pump();
      expect(find.text('Play the cut'), findsOneWidget);
    });
  });
}
