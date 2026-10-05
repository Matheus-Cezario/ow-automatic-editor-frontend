import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart';
import 'package:ow_editor/monitor/frame.dart';
import 'package:ow_editor/montage_state.dart';
import 'package:ow_editor/widgets/fx_panel.dart';

/// Look, blur, sharpen, vignette, shake and impact.
void main() {
  TimelineClip clip({ClipFx fx = const ClipFx(), String id = 'a'}) =>
      TimelineClip(id: id, atS: 0, durationS: 2, startS: 10, fx: fx);

  test('the effects travel to the server and back', () {
    const fx = ClipFx(look: Look.tealOrange, blur: 0.4, impact: 1);
    final json = fx.toJson();
    expect(json, {'look': 'teal_orange', 'blur': 0.4, 'impact': 1.0});
    final back = ClipFx.fromJson(json);
    expect((back.look, back.blur, back.impact), (Look.tealOrange, 0.4, 1.0));
    expect(clip().toJson().containsKey('fx'), isFalse);
    expect(clip(fx: fx).toJson()['fx'], json);
    expect(const ClipFx().isNeutral, isTrue);
  });

  test('the impact flashes white at the start of a clip with no play', () {
    final c = clip(fx: const ClipFx(impact: 1));
    final at0 = frameAt([Layer(clips: [c])], 0, matchUrl: 'x.mp4').pieces.single;
    expect(at0.veil, '#ffffff');
    expect(at0.veilOpacity, closeTo(0.6, 1e-9));
    final later = frameAt([Layer(clips: [c])], 1, matchUrl: 'x.mp4').pieces.single;
    expect(later.veil, isNull);
  });

  test('the shake moves the picture, harder right after the impact', () {
    final c = clip(fx: const ClipFx(impact: 1));
    double moved(double t) {
      final p = frameAt([Layer(clips: [c])], t, matchUrl: 'x.mp4').pieces.single;
      return p.shakeX.abs() + p.shakeY.abs();
    }

    final early = [for (var t = 0.02; t < 0.3; t += 0.03) moved(t)];
    final late = [for (var t = 1.5; t < 1.8; t += 0.03) moved(t)];
    expect(early.reduce((a, b) => a > b ? a : b), greaterThan(0.01));
    expect(late.reduce((a, b) => a > b ? a : b), lessThan(0.001));
    expect(clip().fx.shake, 0);
    expect(
      frameAt([Layer(clips: [clip()])], 0.1, matchUrl: 'x.mp4').pieces.single.shakeZoom,
      1,
    );
  });

  test('every look has its CSS but none', () {
    for (final l in Look.values) {
      expect(lookCss(l) == null, l == Look.none);
    }
  });

  test('pasting effects carries the look and fx', () {
    final from = clip(fx: const ClipFx(look: Look.noir, vignette: 0.5));
    final to = TimelineClip(id: 'b', atS: 3, durationS: 2, startS: 50);
    final s = pasteEffects(
      MontageState(layers: [Layer(clips: [from, to])]),
      {'b'},
      from,
    );
    expect(s.clipItem('b')!.fx.look, Look.noir);
    expect(s.clipItem('b')!.fx.vignette, 0.5);
  });

  testWidgets('the panel picks a look, sets an amount and resets', (
    tester,
  ) async {
    var fx = const ClipFx();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => SingleChildScrollView(
              child: FxPanel(fx: fx, onChanged: (v) => setState(() => fx = v)),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Look & FX'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('look-noir')));
    await tester.pump();
    expect(fx.look, Look.noir);
    await tester.drag(find.byKey(const ValueKey('fx-vignette')), const Offset(60, 0));
    await tester.pump();
    expect(fx.vignette, greaterThan(0));
    expect(find.text('2 in use'), findsOneWidget);
    await tester.tap(find.byKey(const Key('fx-reset')));
    await tester.pump();
    expect(fx.isNeutral, isTrue);
  });
}
