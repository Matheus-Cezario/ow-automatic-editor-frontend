import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart';
import 'package:ow_editor/widgets/crop_overlay.dart';

/// The crop window on the monitor: dragging its handles and body edits the
/// same fractions the panel's sliders do.
void main() {
  Future<List<ClipTransform>> pump(
    WidgetTester tester,
    ClipTransform start,
  ) async {
    final seen = <ClipTransform>[];
    var current = start;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 400,
            height: 200,
            child: StatefulBuilder(
              builder: (context, setState) => CropOverlay(
                transform: current,
                onChanged: (t) => setState(() {
                  current = t;
                  seen.add(t);
                }),
              ),
            ),
          ),
        ),
      ),
    );
    return seen;
  }

  testWidgets('dragging the left handle crops the left edge', (tester) async {
    final seen = await pump(tester, const ClipTransform());
    await tester.drag(
      find.byKey(const Key('crop-handle-l')),
      const Offset(80, 0),
    );
    await tester.pump();
    expect(seen.last.cropLeft, closeTo(0.2, 1e-6));
    expect(seen.last.cropRight, 0);
  });

  testWidgets('a corner moves two edges, and stops at the panel limit', (
    tester,
  ) async {
    final seen = await pump(tester, const ClipTransform());
    await tester.drag(
      find.byKey(const Key('crop-handle-br')),
      const Offset(-390, -190),
    );
    await tester.pump();
    expect(seen.last.cropRight, closeTo(0.45, 1e-6));
    expect(seen.last.cropBottom, closeTo(0.45, 1e-6));
  });

  testWidgets('dragging inside moves the window without resizing it', (
    tester,
  ) async {
    final seen = await pump(
      tester,
      const ClipTransform(
        cropLeft: 0.1,
        cropRight: 0.5 - 0.1,
        cropTop: 0.1,
        cropBottom: 0.3,
      ),
    );
    await tester.drag(find.byKey(const Key('crop-move')), const Offset(40, 0));
    await tester.pump();
    final t = seen.last;
    expect(t.cropLeft, closeTo(0.2, 1e-6));
    expect(t.cropRight, closeTo(0.3, 1e-6));
    expect(1 - t.cropLeft - t.cropRight, closeTo(0.5, 1e-6));
  });
}
