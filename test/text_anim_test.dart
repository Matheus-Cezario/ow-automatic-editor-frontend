import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart';
import 'package:ow_editor/text_anim.dart';
import 'package:ow_editor/widgets/preview_player.dart';

/// A text's entrance and exit — the formulas of `owcore/textfx.py`.
void main() {
  TimelineClip text(
    String t, {
    TextAnim animIn = TextAnim.none,
    TextAnim animOut = TextAnim.none,
    double animS = 0.4,
    double dur = 2,
  }) => TimelineClip(
    id: 't',
    atS: 0,
    durationS: dur,
    startS: 0,
    source: 'text',
    text: t,
    textStyle: ClipTextStyle(animIn: animIn, animOut: animOut, animS: animS),
  );

  test('no animation, the text as it is', () {
    final m = textMotion(text('ACE'), 0);
    expect((m.alpha, m.size, m.drop, m.text), (1.0, 1.0, 0.0, 'ACE'));
  });

  test('a fade comes in from nothing and goes out to nothing', () {
    final c = text('ACE', animIn: TextAnim.fade, animOut: TextAnim.fade);
    expect(textMotion(c, 0).alpha, 0);
    expect(textMotion(c, 0.2).alpha, closeTo(0.75, 1e-9), reason: 'ease-out');
    expect(textMotion(c, 1).alpha, 1);
    expect(textMotion(c, 2).alpha, 0);
  });

  test('a pop grows from half size', () {
    final c = text('ACE', animIn: TextAnim.pop);
    expect(textMotion(c, 0).size, 0.5);
    expect(textMotion(c, 0.4).size, 1);
  });

  test('a slide comes up from below and goes down', () {
    final c = text('ACE', animIn: TextAnim.slide, animOut: TextAnim.slide);
    expect(textMotion(c, 0).drop, closeTo(kSlideDistance, 1e-9));
    expect(textMotion(c, 1).drop, 0);
    expect(textMotion(c, 2).drop, closeTo(kSlideDistance, 1e-9));
  });

  test('the typewriter shows the steps the server draws', () {
    // three letters over 0.4 s: a step every 0.133 s
    final c = text('ACE', animIn: TextAnim.typewriter);
    expect(textMotion(c, 0).text, 'A');
    expect(textMotion(c, 0.15).text, 'AC');
    expect(textMotion(c, 0.3).text, 'ACE');
    expect(textMotion(c, 1.5).text, 'ACE');
  });

  test('a long text types at 25 letters a second', () {
    final long = 'X' * 50;
    final c = text(long, animIn: TextAnim.typewriter, animS: 0.2);
    expect(textMotion(c, 1.0).text.length, lessThan(50));
    expect(textMotion(c, 1.99).text.length, 50);
  });

  test('font and animations go to the server and come back', () {
    const style = ClipTextStyle(
      font: 'anton',
      animIn: TextAnim.typewriter,
      animOut: TextAnim.fade,
      animS: 0.5,
    );
    final json = style.toJson();
    expect(json['font'], 'anton');
    expect(json['anim_in'], 'typewriter');
    expect(json['anim_out'], 'fade');
    final back = ClipTextStyle.fromJson(json);
    expect(
      (back.font, back.animIn, back.animOut, back.animS),
      ('anton', TextAnim.typewriter, TextAnim.fade, 0.5),
    );
    // an untouched style sends nothing new
    expect(const ClipTextStyle().toJson().containsKey('anim_in'), isFalse);
  });

  testWidgets('the text is centred where drawtext centres it', (tester) async {
    // x = 1 puts the line's centre on the right edge, as the server does;
    // `Align` used to put its right edge there
    final clip = text(
      'KILL',
    ).copyWith(transform: const ClipTransform(x: 1, y: 0));
    await tester.pumpWidget(
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
    final frame = tester.getRect(find.byType(PreviewPlayer));
    final line = tester.getRect(find.byKey(const ValueKey('frame-text-t')));
    expect(line.center.dx, closeTo(frame.right, 1));
    expect(line.center.dy, closeTo(frame.center.dy, 1));
  });
}
