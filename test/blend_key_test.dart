import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart';
import 'package:ow_editor/monitor/frame.dart';
import 'package:ow_editor/montage_state.dart';
import 'package:ow_editor/widgets/blend_panel.dart';

/// Blend modes and the chroma key.
void main() {
  TimelineClip clip({
    String id = 'a',
    ClipBlend blend = ClipBlend.normal,
    ChromaKey? chroma,
  }) => TimelineClip(
    id: id,
    atS: 0,
    durationS: 2,
    startS: 10,
    blend: blend,
    chroma: chroma,
  );

  test('blend and key travel to the server and back', () {
    final c = clip(blend: ClipBlend.screen, chroma: const ChromaKey(color: '#0000ff'));
    final json = c.toJson();
    expect(json['blend'], 'screen');
    expect(json['chroma'], {'color': '#0000ff', 'similarity': 0.3, 'softness': 0.1});
    final back = TimelineClip.fromJson(json);
    expect(back.blend, ClipBlend.screen);
    expect(back.chroma?.color, '#0000ff');
    expect(clip().toJson().containsKey('blend'), isFalse);
    expect(clip().toJson().containsKey('chroma'), isFalse);
  });

  test('the key matrix takes the key colour away and keeps greys', () {
    final values = chromaMatrix(const ChromaKey())!
        .split(RegExp(r'\s+'))
        .map(double.parse)
        .toList();
    double alpha(double r, double g, double b) =>
        (values[15] * r + values[16] * g + values[17] * b + values[19])
            .clamp(0.0, 1.0);
    expect(alpha(0, 1, 0), 0, reason: 'pure green goes');
    expect(alpha(0.1, 0.9, 0.1), 0, reason: 'near green goes');
    expect(alpha(0.5, 0.5, 0.5), 1, reason: 'grey stays');
    expect(alpha(0.9, 0.2, 0.2), 1, reason: 'red stays');
    expect(chromaMatrix(const ChromaKey(color: '#808080')), isNull);
  });

  test('the monitor piece carries blend and key', () {
    final c = clip(blend: ClipBlend.multiply, chroma: const ChromaKey());
    final p = frameAt([Layer(clips: [c])], 1, matchUrl: 'x.mp4').pieces.single;
    expect(p.blend, ClipBlend.multiply);
    expect(p.chroma, isNotNull);
    expect(ClipBlend.add.css, 'plus-lighter');
  });

  test('setting and clearing; pasting effects carries them', () {
    var s = MontageState(
      layers: [
        Layer(clips: [clip(), clip(id: 'b').copyWith(atS: 3)]),
      ],
    );
    s = setBlendKey(s, 'a', blend: ClipBlend.overlay, chroma: const ChromaKey());
    expect(s.clipItem('a')!.chroma, isNotNull);
    s = pasteEffects(s, {'b'}, s.clipItem('a')!);
    expect(s.clipItem('b')!.blend, ClipBlend.overlay);
    expect(s.clipItem('b')!.chroma, isNotNull);
    s = setBlendKey(s, 'a', blend: ClipBlend.normal, chroma: null);
    expect(s.clipItem('a')!.chroma, isNull);
  });

  testWidgets('the panel picks a mode and keys out a colour', (tester) async {
    var blend = ClipBlend.normal;
    ChromaKey? chroma;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => SingleChildScrollView(
              child: BlendPanel(
                blend: blend,
                chroma: chroma,
                overSomething: false,
                onChanged: (b, k) => setState(() {
                  blend = b;
                  chroma = k;
                }),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Blend & key'));
    await tester.pumpAndSettle();
    expect(find.textContaining('black background'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('blend-screen')));
    await tester.pump();
    expect(blend, ClipBlend.screen);
    await tester.tap(find.byKey(const Key('chroma-switch')));
    await tester.pumpAndSettle();
    expect(chroma?.color, '#00ff00');
    await tester.tap(find.byKey(const ValueKey('key-colour-blue')));
    await tester.pump();
    expect(chroma?.color, '#0000ff');
    await tester.enterText(find.byKey(const Key('key-colour-hex')), '12ab34');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(chroma?.color, '#12ab34');
    expect(blend, ClipBlend.screen, reason: 'the mode stays');
  });
}
