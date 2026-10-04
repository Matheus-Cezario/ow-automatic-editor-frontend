import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart';
import 'package:ow_editor/monitor/frame.dart';
import 'package:ow_editor/montage_state.dart';
import 'package:ow_editor/widgets/crop_panel.dart';

/// Crop, rotate and mirror a clip.
void main() {
  test('the transform carries crop and turn to the server and back', () {
    const t = ClipTransform(
      cropLeft: 0.25,
      cropBottom: 0.1,
      rotation: 90,
      flipH: true,
    );
    final json = t.toJson();
    expect(json['crop_left'], 0.25);
    expect(json['rotation'], 90.0);
    expect(json['flip_h'], isTrue);
    expect(json.containsKey('crop_top'), isFalse);
    final back = ClipTransform.fromJson(json);
    expect((back.cropLeft, back.cropBottom, back.rotation, back.flipH),
        (0.25, 0.1, 90.0, true));
    expect(t.isNeutral, isFalse);
    expect(const ClipTransform(rotation: 360).isNeutral, isTrue);
    expect(t.withoutCropTurn.isNeutral, isTrue);
  });

  test('moving the clip on the frame keeps its crop', () {
    final clip = TimelineClip(
      id: 'a',
      atS: 0,
      durationS: 2,
      startS: 10,
      transform: const ClipTransform(cropTop: 0.2, rotation: 15),
    );
    var s = MontageState(layers: [Layer(clips: [clip])]);
    s = positionOnFrame(s, 'a', x: 0.5);
    final t = s.clipItem('a')!.transform;
    expect((t.x, t.cropTop, t.rotation), (0.5, 0.2, 15.0));
  });

  test('the monitor gets the crop with the piece', () {
    final clip = TimelineClip(
      id: 'a',
      atS: 0,
      durationS: 2,
      startS: 10,
      transform: const ClipTransform(cropRight: 0.3, flipV: true),
    );
    final f = frameAt([Layer(clips: [clip])], 1, matchUrl: 'x.mp4');
    expect(f.pieces.single.crop.cropRight, 0.3);
    expect(f.pieces.single.crop.flipV, isTrue);
  });

  testWidgets('the panel turns, mirrors and resets', (tester) async {
    var t = const ClipTransform(scale: 0.5);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => SingleChildScrollView(
              child: CropPanel(
                transform: t,
                onChanged: (v) => setState(() => t = v),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Crop & rotate'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('rotate-left')));
    await tester.pump();
    expect(t.rotation, -90);
    await tester.tap(find.byKey(const Key('rotate-left')));
    await tester.pump();
    expect(t.rotation, 180);
    await tester.tap(find.byKey(const Key('rotate-left')));
    await tester.pump();
    expect(t.rotation, 90, reason: '-270 wraps to 90');

    await tester.tap(find.byKey(const Key('flip-h')));
    await tester.pump();
    expect(t.flipH, isTrue);
    expect(find.textContaining('mirrored'), findsOneWidget);

    await tester.drag(find.byKey(const Key('crop-left')), const Offset(80, 0));
    await tester.pump();
    expect(t.cropLeft, greaterThan(0));
    expect(t.cropLeft, lessThanOrEqualTo(CropPanel.maxCrop));

    await tester.tap(find.byKey(const Key('crop-reset')));
    await tester.pump();
    expect(t.isNeutral, isFalse, reason: 'the size stays');
    expect((t.hasCrop, t.hasTurn, t.scale), (false, false, 0.5));
  });
}
