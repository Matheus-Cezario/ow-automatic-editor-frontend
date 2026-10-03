import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/widgets/exact_preview.dart';

void main() {
  group('the stretch an exact preview covers', () {
    test('a short montage goes whole', () {
      expect(exactPreviewWindow(12, 7), (from: 0.0, to: 12.0));
    });

    test('a long one, from a little before the playhead', () {
      expect(exactPreviewWindow(90, 30), (from: 28.0, to: 38.0));
    });

    test('at the start it does not go before zero', () {
      expect(exactPreviewWindow(90, 1), (from: 0.0, to: 10.0));
    });

    test('near the end the window slides back instead of shrinking', () {
      expect(exactPreviewWindow(90, 89), (from: 80.0, to: 90.0));
    });
  });

  testWidgets('the status says how far it is, or why it failed', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: ExactPreviewStatus(progress: 0.3)),
      ),
    );
    expect(find.text('Rendering exact preview… 30%'), findsOneWidget);

    var dismissed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ExactPreviewStatus(
            progress: 0,
            error: 'boom',
            onDismiss: () => dismissed = true,
          ),
        ),
      ),
    );
    expect(find.text('Exact preview failed: boom'), findsOneWidget);
    await tester.tap(find.byTooltip('Dismiss'));
    expect(dismissed, isTrue);
  });
}
