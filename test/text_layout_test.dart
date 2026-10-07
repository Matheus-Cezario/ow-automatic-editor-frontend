import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart';
import 'package:ow_editor/text_anim.dart';
import 'package:ow_editor/text_layout.dart';
import 'package:ow_editor/widgets/preview_player.dart';

/// Several lines, a box, alignment and a shadow — the rules of
/// `owcore/textlayout.py` and `owcore/textfx.py`.
void main() {
  TimelineClip text(String t, ClipTextStyle style) => TimelineClip(
    id: 't',
    atS: 0,
    durationS: 2,
    startS: 0,
    source: 'text',
    text: t,
    textStyle: style,
  );

  const measure = TextStyle(fontSize: 20);

  test('a typed break always breaks; without a box nothing else does', () {
    expect(breakTextLines('TRIPLE KILL\nby ana', measure, null), [
      'TRIPLE KILL',
      'by ana',
    ]);
    expect(breakTextLines('the quick brown fox', measure, null), [
      'the quick brown fox',
    ]);
  });

  test(
    'inside a box the words break greedily, and a long word stays whole',
    () {
      final full = lineWidth('the quick brown fox', measure);
      final lines = breakTextLines('the quick brown fox', measure, full * 0.6);
      expect(lines.length, greaterThan(1));
      expect(lines.join(' '), 'the quick brown fox');
      for (final l in lines) {
        expect(lineWidth(l, measure), lessThanOrEqualTo(full * 0.6));
      }
      expect(breakTextLines('unbreakable', measure, 5), ['unbreakable']);
    },
  );

  test('the typewriter fills the lines already broken', () {
    final c = text(
      'ab\ncd',
      const ClipTextStyle(animIn: TextAnim.typewriter, animS: 0.4),
    );
    final lines = ['ab', 'cd'];
    // 4 letters (the break does not count), one a step over 0.4 s
    expect(typedLines(c, lines, 0), ['a', '']);
    expect(typedLines(c, lines, 0.25), ['ab', 'c']);
    expect(typedLines(c, lines, 1.5), ['ab', 'cd']);
    // without the typewriter, the lines whole
    expect(typedLines(text('ab', const ClipTextStyle()), ['ab'], 0), ['ab']);
  });

  test('box, shadow, alignment and width go to the server and come back', () {
    const style = ClipTextStyle(
      align: TextLineAlign.left,
      width: 0.4,
      box: 'black',
      boxOpacity: 0.8,
      shadow: 'red',
    );
    final json = style.toJson();
    expect(json['align'], 'left');
    expect(json['width'], 0.4);
    expect(json['box'], 'black');
    expect(json['box_opacity'], 0.8);
    expect(json['shadow'], 'red');
    final back = ClipTextStyle.fromJson(json);
    expect(
      (back.align, back.width, back.box, back.boxOpacity, back.shadow),
      (TextLineAlign.left, 0.4, 'black', 0.8, 'red'),
    );
    // an untouched style sends none of it
    final plain = const ClipTextStyle().toJson();
    for (final k in ['align', 'width', 'box', 'box_opacity', 'shadow']) {
      expect(plain.containsKey(k), isFalse, reason: k);
    }
  });

  Future<void> show(WidgetTester tester, TimelineClip clip) =>
      tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 640,
              height: 360,
              child: PreviewPlayer(
                videoUrl: null,
                layers: const [],
                cuts: const [],
                atS: 0.5,
                playing: false,
                texts: [clip],
              ),
            ),
          ),
        ),
      );

  testWidgets('the monitor draws the lines, the box and the alignment', (
    tester,
  ) async {
    await show(
      tester,
      text(
        'A\nBBBB',
        const ClipTextStyle(
          size: 0.1,
          align: TextLineAlign.right,
          box: 'black',
          boxOpacity: 0.5,
          shadow: 'red',
        ),
      ),
    );
    final lines = tester.widgetList<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('text-box-t')),
        matching: find.byType(Text),
      ),
    );
    expect(lines, isNotEmpty);
    for (final t in lines) {
      expect(t.data, 'A\nBBBB');
      expect(t.textAlign, TextAlign.right);
    }
    final box = tester.widget<Container>(
      find.byKey(const ValueKey('text-box-t')),
    );
    expect(box.color, Colors.black.withValues(alpha: 0.5));
    expect(
      lines.any((t) => t.style?.shadows?.isNotEmpty ?? false),
      isTrue,
      reason: 'the shadow',
    );
    // two lines a line height apart: the block is about 2.4 letters tall
    final r = tester.getRect(find.byKey(const ValueKey('text-box-t')));
    final letter = 0.1 * 360;
    final pad = kTextBoxPad * letter;
    expect(r.height - 2 * pad, closeTo(2 * kTextLineHeight * letter, 4));
  });

  testWidgets('a box width breaks the words on the monitor', (tester) async {
    await show(
      tester,
      text(
        'the quick brown fox jumps',
        const ClipTextStyle(size: 0.08, width: 0.3),
      ),
    );
    final t = tester
        .widgetList<Text>(
          find.descendant(
            of: find.byKey(const ValueKey('text-box-t')),
            matching: find.byType(Text),
          ),
        )
        .first;
    expect(t.data!.contains('\n'), isTrue);
    final r = tester.getRect(find.byKey(const ValueKey('text-box-t')));
    expect(r.width, closeTo(0.3 * 640, 2));
  });
}
