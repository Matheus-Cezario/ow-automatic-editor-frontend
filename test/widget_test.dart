import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ow_editor/main.dart';

void main() {
  testWidgets('a tela inicial abre e oferece criar uma partida', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const OwEditorApp());
    await tester.pump();

    expect(find.text('Melhores momentos'), findsOneWidget);
    expect(find.text('Nova partida'), findsOneWidget);
  });

  testWidgets('PhoneWidth limita a largura em telas grandes', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: PhoneWidth(child: SizedBox(key: Key('alvo'), height: 10)),
      ),
    );
    final box = tester.getSize(find.byKey(const Key('alvo')));
    expect(box.width, lessThanOrEqualTo(640));
  });
}
