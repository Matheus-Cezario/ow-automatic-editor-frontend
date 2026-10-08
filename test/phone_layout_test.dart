import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart';
import 'package:ow_editor/montage.dart';
import 'package:ow_editor/screens/timeline_screen.dart';
import 'package:ow_editor/widgets/music_timeline.dart';

import 'timeline_screen_test.dart' show jobJson;

/// The editor on a phone: one column, the panels as tabs under the ruler.
void main() {
  Future<void> open(WidgetTester tester, Size size) async {
    // the screen's real size: the top bar reads it, not the layout
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: TimelineScreen(
          job: Job.fromJson(jobJson(withMusic: true)),
          api: _FakeApi(),
        ),
      ),
    );
    await tester.pump();
  }

  const phone = Size(390, 844);
  final kill = find.byKey(ValueKey('moment-${momentKey('kill', 30)}'));
  MusicTimeline ruler(WidgetTester tester) =>
      tester.widget<MusicTimeline>(find.byType(MusicTimeline));

  testWidgets('the panels are tabs, and the moments come first', (
    tester,
  ) async {
    await open(tester, phone);
    expect(find.byKey(const Key('panel-tabs')), findsOneWidget);
    expect(kill, findsOneWidget);
    // the settings are a tab away, not at the end of one long page
    expect(find.byKey(const Key('montage-panels')), findsNothing);
    expect(tester.takeException(), isNull, reason: 'nothing overflows');
  });

  testWidgets('a clip tapped on the ruler brings its settings forward', (
    tester,
  ) async {
    await open(tester, phone);
    await tester.tap(kill);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('montage-panels')), findsNothing);

    final clip = ruler(tester).layers.expand((l) => l.clips).single;
    ruler(tester).onSelect(clip.id);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('montage-panels')), findsOneWidget);
    expect(find.textContaining('Kill at'), findsOneWidget);
  });

  testWidgets('magnet and insert mode move to the menu', (tester) async {
    await open(tester, phone);
    expect(find.byKey(const Key('insert-mode')), findsNothing);
    await tester.tap(find.byKey(const Key('screen-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('menu-insert')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('screen-menu')));
    await tester.pumpAndSettle();
    final item = tester.widget<CheckedPopupMenuItem<String>>(
      find.byKey(const Key('menu-insert')),
    );
    expect(item.checked, isTrue);
  });

  testWidgets('the layer names take less of the ruler', (tester) async {
    await open(tester, phone);
    expect(ruler(tester).labelsWidth, MusicTimeline.narrowHeaderWidth);
  });

  testWidgets('a computer keeps the sidebar and the buttons', (tester) async {
    await open(tester, const Size(1000, 2400));
    expect(find.byKey(const Key('panel-tabs')), findsNothing);
    expect(find.byKey(const Key('insert-mode')), findsOneWidget);
    expect(ruler(tester).labelsWidth, MusicTimeline.headerWidth);
  });

  testWidgets('a phone on its side works too', (tester) async {
    await open(tester, const Size(844, 390));
    expect(find.byKey(const Key('panel-tabs')), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'nothing overflows');
  });
}

class _FakeApi extends ApiClient {
  @override
  Future<void> requestFrames(String jobId) async {}
}
