import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart';
import 'package:ow_editor/clip_nav.dart';
import 'package:ow_editor/montage.dart';
import 'package:ow_editor/screens/timeline_screen.dart';
import 'package:ow_editor/widgets/music_timeline.dart';

import 'timeline_screen_test.dart' show jobJson;

/// The editor without a mouse: from cut to cut on the keyboard, and every cut
/// heard by a screen reader.
void main() {
  const a = TimelineClip(id: 'a', atS: 0, durationS: 2, startS: 10);
  const b = TimelineClip(id: 'b', atS: 2, durationS: 1, startS: 20);
  const top = TimelineClip(
    id: 't',
    atS: 2,
    durationS: 3,
    startS: 0,
    label: 'Title',
  );
  final layers = [
    Layer(clips: const [b, a]),
    Layer(clips: const [top]),
  ];

  group('the order', () {
    test('by start, then from the top layer', () {
      expect([for (final (c, _) in clipsInOrder(layers)) c.id], [
        'a',
        'b',
        't',
      ]);
    });

    test('from the selected cut, one step each way', () {
      (TimelineClip, int)? step(String? from, bool forward, {double at = 0}) =>
          neighbourClip(layers, fromId: from, cursor: at, forward: forward);
      expect(step('a', true)!.$1.id, 'b');
      expect(step('b', true)!.$1, top);
      expect(step('b', true)!.$2, 1, reason: 'and says which layer');
      expect(step('t', true), isNull);
      expect(step('b', false)!.$1.id, 'a');
      expect(step('a', false), isNull);
    });

    test('with nothing selected, from the playhead', () {
      expect(
        neighbourClip(layers, fromId: null, cursor: 1, forward: true)!.$1.id,
        'b',
      );
      expect(
        neighbourClip(layers, fromId: null, cursor: 1, forward: false)!.$1.id,
        'a',
      );
    });

    test('the edges of the cuts, for the playhead', () {
      expect(nextEdit(layers, 0, forward: true), 2);
      expect(nextEdit(layers, 2, forward: true), 3);
      expect(nextEdit(layers, 5, forward: true), isNull);
      expect(nextEdit(layers, 2.5, forward: false), 2);
    });
  });

  test('a cut is one sentence', () {
    expect(
      describeClip(top, layer: 1, locked: true),
      'Title, layer 2, from 00:02 to 00:05, 3.0 seconds, locked',
    );
    expect(describeClip(a, layer: 0), startsWith('Event, layer 1'));
    expect(
      describeClip(a, layer: 1, layerName: 'Layer 2'),
      startsWith('Event, layer 2,'),
      reason: 'the default name is not read out as a name',
    );
    expect(
      describeClip(a, layer: 0, layerName: 'Music'),
      startsWith('Event, layer "Music",'),
    );
  });

  group('the screen', () {
    Future<List<String>> open(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final said = <String>[];
      tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<
        dynamic
      >(SystemChannels.accessibility, (m) async {
        final data = (m as Map)['data'] as Map;
        if (m['type'] == 'announce') said.add(data['message'] as String);
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger
            .setMockDecodedMessageHandler(SystemChannels.accessibility, null),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: TimelineScreen(
            job: Job.fromJson(jobJson()),
            api: _FakeApi(),
          ),
        ),
      );
      await tester.pump();
      return said;
    }

    Finder moment(double t) =>
        find.byKey(ValueKey('moment-${momentKey('kill', t)}'));
    MusicTimeline ruler(WidgetTester tester) =>
        tester.widget<MusicTimeline>(find.byType(MusicTimeline));

    Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(key);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
    }

    testWidgets('Alt + arrows go from cut to cut and say each one', (
      tester,
    ) async {
      final said = await open(tester);
      await tester.tap(moment(30));
      await tester.pump();
      await tester.tap(
        find.byKey(ValueKey('moment-${momentKey('headshot', 140)}')),
      );
      await tester.pump();
      final order = [
        for (final (c, _) in clipsInOrder(ruler(tester).layers)) c.id,
      ];
      expect(order, hasLength(2));

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      ruler(tester).onSeek(0);
      await tester.pump();
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(ruler(tester).selectionIds, {order[0]});
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(ruler(tester).selectionIds, {order[1]});
      expect(said.last, startsWith('Headshot, layer 1'));
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(said.last, 'No more cuts after this.');
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(ruler(tester).selectionIds, {order[0]});
      expect(ruler(tester).playheadS, 0, reason: 'the playhead goes with it');

      // down: to the next edge, where the first cut ends
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      final first = ruler(tester).layers.first.clips.firstWhere(
        (c) => c.id == order[0],
      );
      expect(ruler(tester).playheadS, closeTo(first.untilS, 1e-6));
    });

    testWidgets('a screen reader hears the cuts and the moments', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await open(tester);
      expect(
        find.bySemanticsLabel('Kill at 00:30, not in the montage yet'),
        findsOneWidget,
      );
      await tester.tap(moment(30));
      await tester.pump();
      expect(
        find.bySemanticsLabel('Kill at 00:30, already in the montage'),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel(RegExp(r'^Kill, layer 1, from')),
          findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Timeline: 1 cut on 1 layer')),
          findsOneWidget);
      handle.dispose();
    });

    testWidgets('every icon button says what it does', (tester) async {
      final handle = tester.ensureSemantics();
      await open(tester);
      await tester.tap(moment(30));
      await tester.pump();
      // the selected cut's settings, with the +/- steps
      final clip = ruler(tester).layers.first.clips.single;
      ruler(tester).onSelect(clip.id);
      await tester.pump();
      for (final e in find.byType(IconButton).evaluate()) {
        final b = e.widget as IconButton;
        expect(
          b.tooltip,
          isNotNull,
          reason: 'an icon with no tooltip is a silent button: ${b.icon}',
        );
      }
      handle.dispose();
    });
  });
}

class _FakeApi extends ApiClient {
  @override
  Future<void> requestFrames(String jobId) async {}
}
