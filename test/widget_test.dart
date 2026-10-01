import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ow_editor/main.dart';

void main() {
  testWidgets('the home screen opens and offers to create a match', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const OwEditorApp());
    await tester.pump();

    expect(find.text('Matches'), findsOneWidget);
    expect(find.text('New match'), findsOneWidget);
  });

  testWidgets('PhoneWidth limits the width on large screens', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: PhoneWidth(child: SizedBox(key: Key('target'), height: 10)),
      ),
    );
    final box = tester.getSize(find.byKey(const Key('target')));
    expect(box.width, lessThanOrEqualTo(640));
  });
}
