import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/montage.dart';
import 'package:ow_editor/widgets/music_timeline.dart';
import 'package:ow_editor/widgets/source_viewer.dart';

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

  group('the source viewer', () {
    Future<List<SourceSpan>> pump(WidgetTester tester) async {
      final added = <SourceSpan>[];
      await tester.binding.setSurfaceSize(const Size(400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SourceViewer(
                videoUrl: null,
                durationS: 600,
                onAdd: added.add,
              ),
            ),
          ),
        ),
      );
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

    testWidgets('in, out and play from the keyboard, then add', (tester) async {
      final added = await pump(tester);
      await tester.tap(find.byKey(const Key('source-clock')));
      await tester.pump();

      await key(tester, LogicalKeyboardKey.arrowRight, 2); // 2 s
      await key(tester, LogicalKeyboardKey.keyI);
      await key(tester, LogicalKeyboardKey.arrowRight, 3); // 5 s
      await key(tester, LogicalKeyboardKey.keyO);
      await key(tester, LogicalKeyboardKey.arrowLeft); // 4 s
      await key(tester, LogicalKeyboardKey.keyP);

      expect(find.text('3.0 s from the recording'), findsOneWidget);
      await tester.tap(find.byKey(const Key('add-span')));
      await tester.pump();

      final span = added.single;
      expect((span.inS, span.outS, span.playS), (2.0, 5.0, 4.0));
    });

    testWidgets('nothing to add until both ends are marked', (tester) async {
      await pump(tester);
      final add = tester.widget<FilledButton>(
        find.byKey(const Key('add-span')),
      );
      expect(add.onPressed, isNull);
      await tester.tap(find.byKey(const Key('mark-in')));
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('add-span')))
            .onPressed,
        isNull,
      );
    });

    testWidgets('an out before the in starts the stretch over', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('source-clock')));
      await key(tester, LogicalKeyboardKey.arrowRight, 5);
      await key(tester, LogicalKeyboardKey.keyI); // in at 5
      await key(tester, LogicalKeyboardKey.arrowLeft, 3);
      await key(tester, LogicalKeyboardKey.keyO); // out at 2: before the in
      expect(find.textContaining('In ('), findsOneWidget, reason: 'in cleared');
      expect(find.text('Out 00:02'), findsOneWidget);
    });
  });
}
