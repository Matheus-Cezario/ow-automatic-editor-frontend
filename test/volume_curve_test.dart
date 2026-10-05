import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart' hide Clip;
import 'package:ow_editor/montage_state.dart';
import 'package:ow_editor/widgets/volume_curve.dart';

/// The volume line over a clip's block.
void main() {
  TimelineClip clip({double level = 1, List<ClipKey> keys = const []}) =>
      TimelineClip(
        id: 'a',
        atS: 0,
        durationS: 4,
        startS: 0,
        audio: ClipAudio(volume: level),
        keys: keys,
      );

  test('setting the level or the points keeps the other keyframes', () {
    final c = clip(
      keys: const [ClipKey(prop: KeyProp.opacity, t: 0, value: 0.5)],
    );
    var s = MontageState(layers: [Layer(clips: [c])]);
    s = setVolumeCurve(s, 'a', level: 0.4);
    expect(s.clipItem('a')!.audio.volume, 0.4);
    s = setVolumeCurve(
      s,
      'a',
      keys: const [ClipKey(prop: KeyProp.volume, t: 0.5, value: 0.2)],
    );
    final keys = s.clipItem('a')!.keys;
    expect(keys.map((k) => k.prop), containsAll([KeyProp.opacity, KeyProp.volume]));
  });

  test('the gain follows the curve, the fades and the mute', () {
    final c = clip(
      keys: const [
        ClipKey(prop: KeyProp.volume, t: 0, value: 1),
        ClipKey(prop: KeyProp.volume, t: 1, value: 0),
      ],
    );
    expect(gainAt(c, 2), closeTo(0.5, 1e-9));
    final faded = clip().copyWith(
      audio: const ClipAudio(fadeInS: 2, fadeOutS: 1),
    );
    expect(gainAt(faded, 1), closeTo(0.5, 1e-9));
    expect(gainAt(faded, 3.5), closeTo(0.5, 1e-9));
    expect(gainAt(clip().copyWith(audio: const ClipAudio(mute: true)), 1), 0);
  });

  Future<(TimelineClip Function(), List<String?>)> pump(
    WidgetTester tester,
    TimelineClip start,
  ) async {
    var c = start;
    final labels = <String?>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              height: 100,
              child: StatefulBuilder(
                builder: (context, setState) => VolumeCurve(
                  clip: c,
                  colour: Colors.orange,
                  onLevel: (v) => setState(
                    () => c = c.copyWith(audio: c.audio.copyWith(volume: v)),
                  ),
                  onKeys: (k) => setState(() => c = c.copyWith(keys: k)),
                  onLabel: labels.add,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return (() => c, labels);
  }

  testWidgets('dragging the flat line sets the level, snapping to 100%', (
    tester,
  ) async {
    final (current, labels) = await pump(tester, clip(level: 0.5));
    final box = tester.getRect(find.byType(VolumeCurve));
    // 50% sits three quarters of the way down
    final onLine = Offset(box.center.dx, box.top + box.height * 0.75);
    await tester.dragFrom(onLine, const Offset(0, -26));
    await tester.pump();
    expect(current().audio.volume, 1, reason: 'snapped onto 100%');
    expect(labels.last, isNull, reason: 'the caption clears at the end');
    expect(labels, contains('Volume 100%'));

    // off the line, the drag is not the curve's
    await tester.dragFrom(Offset(box.center.dx, box.top + 5), const Offset(0, 30));
    await tester.pump();
    expect(current().audio.volume, 1);
  });

  testWidgets('a click adds a point; points drag and go away', (tester) async {
    final (current, _) = await pump(tester, clip());
    final box = tester.getRect(find.byType(VolumeCurve));
    await tester.tapAt(Offset(box.left + 100, box.center.dy));
    await tester.pump();
    var keys = current().keysFor(KeyProp.volume);
    expect(keys.single.t, closeTo(0.25, 0.01));
    expect(keys.single.value, 1);

    await tester.tapAt(Offset(box.left + 300, box.center.dy));
    await tester.pump();
    expect(current().keysFor(KeyProp.volume), hasLength(2));

    // the second point down to 50%: a quarter of the height
    await tester.drag(
      find.byKey(const ValueKey('volume-point-a-1')),
      const Offset(0, 25),
    );
    await tester.pump();
    keys = current().keysFor(KeyProp.volume);
    expect(keys[1].value, lessThan(0.75));
    expect(keys[1].t, closeTo(0.75, 0.02));

    await tester.tap(
      find.byKey(const ValueKey('volume-point-a-0')),
      buttons: kSecondaryButton,
    );
    await tester.pump();
    expect(current().keysFor(KeyProp.volume), hasLength(1));
    await tester.pump(const Duration(seconds: 1)); // let the tap timers run out
  });
}
