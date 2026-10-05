import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart';
import 'package:ow_editor/widgets/render_queue.dart';

/// The render queue: progress, time left, place in line, cancel.
void main() {
  Render render(
    String id, {
    String status = 'rendering',
    double progress = 0.5,
    double? eta,
    int? position,
    List<String> titles = const ['Flank'],
  }) => Render.fromJson({
    'id': id,
    'job_id': 'j1',
    'job_name': 'match.mp4',
    'status': status,
    'stage': status == 'rendering' ? 'rendering' : status,
    'progress': progress,
    'created_at': '2026-10-05T10:00:00Z',
    'eta_s': eta,
    'queue_position': position,
    'timelines': [for (final t in titles) {'title': t}],
    'clips': const [],
  });

  test('the new fields come off the wire', () {
    final r = render('a', eta: 130, titles: const ['Flank', 'Flank (9:16)']);
    expect(r.titles, ['Flank', 'Flank (9:16)']);
    expect(r.jobName, 'match.mp4');
    expect(r.remainingText, '~2 min');
    expect(render('b', status: 'cancelled').isCancelled, isTrue);
    expect(render('b', status: 'cancelled').isActive, isFalse);
  });

  Future<void> line(WidgetTester tester, Render r, {VoidCallback? cancel}) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: RenderProgressLine(render: r, onCancel: cancel)),
        ),
      );

  testWidgets('rendering: percent and time left; waiting: how many ahead', (
    tester,
  ) async {
    var cancelled = false;
    await line(
      tester,
      render('a', progress: 0.45, eta: 130),
      cancel: () => cancelled = true,
    );
    expect(find.text('45% · ~2 min left'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('cancel-render-a')));
    expect(cancelled, isTrue);

    await line(tester, render('b', status: 'pending', position: 2));
    expect(find.text('waiting · 2 ahead'), findsOneWidget);
    expect(find.byKey(const ValueKey('cancel-render-b')), findsNothing,
        reason: 'no cancel handler, no button');
    await line(tester, render('c', status: 'pending', position: 0));
    expect(find.text('next in the queue'), findsOneWidget);
  });

  testWidgets('the badge counts what runs; the dialog cancels', (tester) async {
    var queue = [
      render('a', eta: 40),
      render('b', status: 'pending', position: 1),
      render('c', status: 'done', progress: 1),
    ];
    final asked = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            actions: [
              RenderQueueButton(
                load: () async => queue,
                cancel: (id) async {
                  asked.add(id);
                  queue = [
                    for (final r in queue)
                      r.id == id ? render(id, status: 'cancelled') : r,
                  ];
                },
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('2'), findsOneWidget, reason: 'two running or waiting');

    // a waiting request's bar never stops moving: pump, do not settle
    Future<void> settle() async {
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await tester.tap(find.byKey(const Key('render-queue')));
    await settle();
    expect(find.byKey(const ValueKey('queue-item-c')), findsOneWidget);
    expect(find.textContaining('under 1 min left'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('cancel-render-b')));
    await tester.pump();
    await tester.pump();
    expect(asked, ['b']);
    expect(find.byKey(const ValueKey('cancel-render-b')), findsNothing);

    await tester.tap(find.text('Close'));
    await settle();
    expect(find.text('1'), findsOneWidget, reason: 'one still running');
    // let the polling timers go before the tree does
    await tester.pumpWidget(const SizedBox());
  });
}
