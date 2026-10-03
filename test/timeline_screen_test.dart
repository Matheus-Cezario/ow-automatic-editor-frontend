import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart';
import 'package:ow_editor/montage.dart';
import 'package:ow_editor/screens/timeline_screen.dart';
import 'package:ow_editor/widgets/music_timeline.dart';
import 'package:ow_editor/widgets/preview_player.dart';

/// The montage screen, with no server at all.
///
/// What is checked is the path of whoever arrives at it: the match moments
/// show up, tapping one places a block, and the screen starts saying what video
/// will come out. Nothing here touches the network — the match is built by hand.
/// A song already analysed, with a beat every half second.
///
/// It exercises the magnet: it is precisely with it on that dragging
/// quebrava.
Map<String, dynamic> readyMusic() => {
  'id': 'm1',
  'kind': 'audio',
  'status': 'ready',
  'name': 'song.mp3',
  'duration_s': 120.0,
  'bpm': 120.0,
  'beats': [for (var i = 0; i < 240; i++) i * 0.5],
  'peaks': [for (var i = 0; i < 400; i++) 0.5],
  'audio_url': '/api/tracks/m1/audio',
};

Map<String, dynamic> jobJson({bool withMusic = false}) => {
  // on the server the song is audio media in the library, and shows up in both
  // lists: `media` is the whole library, `tracks` is the audio subset
  if (withMusic) 'tracks': [readyMusic()],
  if (withMusic) 'media': [readyMusic()],
  // without the recording there is no monitor: the preview seeks frames from it
  'video_url': '/api/jobs/j1/video',
  'id': 'j1',
  'status': 'ready',
  'stage': 'choose what to render',
  'progress': 1.0,
  'video_name': 'match.mp4',
  'duration_s': 600.0,
  'width': 1920,
  'height': 1080,
  'created_at': DateTime.now().toIso8601String(),
  'n_clips': 0,
  'events': [
    {'kind': 'kill', 't': 30.0, 'confidence': 1.0},
    {'kind': 'sleep', 't': 75.0, 'confidence': 1.0},
    {'kind': 'stun', 't': 120.0, 'confidence': 1.0},
    // the headshot and the ability kill are the play you look for
    // in a montage — they were left off the shelf by mistake
    {'kind': 'headshot', 't': 140.0, 'confidence': 1.0},
    {
      'kind': 'ability_kill',
      't': 160.0,
      'confidence': 1.0,
      'meta': {'ability': 'orisa/energy_javelin'},
    },
    // context, not a play: it must not become a block
    {'kind': 'death', 't': 200.0, 'confidence': 1.0},
    {'kind': 'low_hp', 't': 210.0, 'confidence': 1.0},
  ],
};

Job jobWithMoments({bool withMusic = false}) =>
    Job.fromJson(jobJson(withMusic: withMusic));

void main() {
  Future<void> open(WidgetTester tester, {bool withMusic = false}) async {
    // The screen is a long list, and `ListView` only builds what would fit in the
    // viewport. In a default test window (800x600) the render button would not
    // even exist in the widget tree, and the test would fail for a reason that is
    // not its own. A tall window puts the whole screen in view.
    await tester.binding.setSurfaceSize(const Size(1000, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: TimelineScreen(job: jobWithMoments(withMusic: withMusic)),
      ),
    );
    await tester.pump();
  }

  /// The clips of every layer, in the order the video shows them.
  List<TimelineClip> cutList(WidgetTester tester) => [
    for (final l
        in tester.widget<MusicTimeline>(find.byType(MusicTimeline)).layers)
      ...l.clips,
  ];

  TimelineClip firstCut(WidgetTester tester) => cutList(tester).first;

  /// Puts the playhead at [seconds] by clicking the ruler.
  ///
  /// The maths discounts the header column, which sits outside the scroll: without
  /// it the tap lands about two and a half seconds before the intended point.
  Future<void> cursorAt(WidgetTester tester, double seconds) async {
    final timelineWidget = tester.getRect(find.byType(MusicTimeline));
    await tester.tapAt(
      Offset(
        timelineWidget.left + MusicTimeline.headerWidth + 1 + seconds * 60,
        timelineWidget.top + 20,
      ),
    );
    await tester.pump();
  }

  /// Switches to the sidebar tab, giving the animation time.
  /// Lets the screen react without waiting for it to stop entirely.
  ///
  /// `pumpAndSettle` does not work here: the monitor keeps timers alive and the
  /// screen never "settles".
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> tab(WidgetTester tester, String displayName) async {
    await tester.tap(find.text(displayName));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// The block on the ruler, by its order in the montage.
  ///
  /// The key is the block id, which is generated at runtime — so the test
  /// asks the widget who is there instead of trying to guess.
  Finder block(WidgetTester tester, int i) =>
      find.byKey(ValueKey('block-${cutList(tester)[i].id}'));

  /// The item on the moment shelf, by the instant it happened.
  ///
  /// The key carries the kind too — a headshot kill lights up two
  /// detectors almost on the same frame, and the instant alone would not identify
  /// the card. The kind comes from the same event list that fed the screen, so the
  /// test does not have to repeat it.
  Finder moment(double t) {
    final event = (jobJson()['events'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((e) => e['t'] == t);
    final keyValue = momentKey(event['kind'] as String, t);
    return find.byKey(ValueKey('moment-$keyValue'));
  }

  testWidgets('offers the match moments, and only those that become cuts', (
    tester,
  ) async {
    await open(tester);

    expect(moment(30.0), findsOneWidget);
    expect(moment(75.0), findsOneWidget);
    expect(moment(120.0), findsOneWidget);
    expect(moment(140.0), findsOneWidget);
    expect(moment(160.0), findsOneWidget);
    // low health and interruption are the play's context, not the play
    expect(find.textContaining('Interruption'), findsNothing);
    expect(find.textContaining('Low health'), findsNothing);
  });

  testWidgets('the ability kill says which ability it was', (
    tester,
  ) async {
    await open(tester);

    // "Orisa: Energy Javelin", and not "Ability kill": in a match with
    // five different abilities the generic label would give five identical
    // cards, and choosing among them would be choosing in the dark
    expect(
      find.descendant(
        of: moment(160.0),
        matching: find.text('Orisa: Energy Javelin'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the headshot becomes a block like any other play', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(moment(140.0));
    await tester.pump();

    final blocks = cutList(tester);
    expect(blocks, hasLength(1));
    expect(blocks.first.sourceT, 140.0);
    expect(blocks.first.kind, 'headshot');
  });

  testWidgets('without cuts, there is nothing to render', (tester) async {
    await open(tester);

    expect(find.text('Add at least one cut'), findsOneWidget);
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
  });

  testWidgets('tapping a moment places a cut and the video comes to exist', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(moment(30.0));
    await tester.pump();

    expect(find.textContaining('1 cut(s)'), findsOneWidget);
    expect(find.text('Render this video'), findsOneWidget);
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNotNull);
  });

  testWidgets('the same moment can go in more than once', (tester) async {
    // using a moment in a video does not consume it — it is the same promise as
    // the proposals, and it holds just the same in the manual montage
    await open(tester);
    await tester.tap(moment(30.0));
    await tester.pump();
    await tester.tap(moment(30.0));
    await tester.pump();

    expect(find.textContaining('2 cut(s)'), findsOneWidget);
  });

  testWidgets('the selected block shows where it came from and where it enters', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(moment(75.0));
    await tester.pump();

    expect(find.textContaining('Sleep dart at 01:15'), findsOneWidget);
    expect(find.textContaining('enters at 00:00 of the video'), findsOneWidget);
    expect(find.text('Duration'), findsOneWidget);
    expect(find.text('Framing'), findsOneWidget);
  });

  testWidgets('music comes through the Library, and only through it', (tester) async {
    // there were two ways of adding sound, and they did not work the same. One was
    // left: music is media from outside the match like any other
    await open(tester, withMusic: true);

    expect(find.text('No music'), findsNothing);
    expect(find.text('Put on the timeline'), findsNothing);

    await tab(tester, 'Library');
    expect(find.byKey(const ValueKey('media-m1')), findsOneWidget);
    expect(find.textContaining('120 BPM'), findsOneWidget);
  });

  // ── arrastar ──────────────────────────────────────────────────────────────
  //
  // The test block that was missing when dragging did not work. Applying
  // `delta.dx` frame by frame, each 3px step became 0.05s and the magnet snapped
  // back to the same beat: the block did not move. The gesture now accumulates
  // from where it started, and that is what these tests lock down.

  /// The gesture recogniser only accepts the drag after beating
  /// `kTouchSlop` (18px), and what the finger moved until then does not count. In
  /// 3px steps that eats 21px — without discounting them, the maths of the tests
  /// below is off by a third of a second.
  const eatenBySlop = 21.0;
  const px = 60.0; // the screen's default zoom

  /// Drags in small steps, like a finger moving slowly.
  ///
  /// This is the shape that matters: `tester.drag` delivers the movement in two
  /// big jumps, and with big jumps even the broken code worked. The bug only
  /// showed up on the slow drag, where each frame moves a few pixels.
  Future<void> dragSlowly(
    WidgetTester tester,
    Finder target,
    double total, {
    double step = 3,
  }) async {
    final gesture = await tester.startGesture(tester.getCenter(target));
    for (var moved = 0.0; moved < total.abs(); moved += step) {
      await gesture.moveBy(Offset(total.isNegative ? -step : step, 0));
      await tester.pump();
    }
    await gesture.up();
    await tester.pump();
  }

  testWidgets('dragging slowly moves the block, with the magnet on', (
    tester,
  ) async {
    // With the magnet on and the block already on a beat, each 3px step
    // is worth 0.05s — within the magnet tolerance. Applied step by step, it
    // snapped back and the block did not move however much you dragged.
    await open(tester, withMusic: true);
    await tester.tap(moment(30.0));
    await tester.pump();
    expect(firstCut(tester).atS, 0);

    await dragSlowly(tester, block(tester, 0), 120);

    expect(
      firstCut(tester).atS,
      closeTo((120 - eatenBySlop) / px, 0.05),
    );
  });

  testWidgets('dragging near a beat snaps to it', (tester) async {
    await open(tester, withMusic: true);
    await tester.tap(moment(75.0));
    await tester.pump();
    // the grid comes from the song playing there: without music on the ruler there
    // is no beat to snap to
    await tab(tester, 'Library');
    await tester.tap(find.byKey(const ValueKey('media-m1')));
    await settle(tester);
    await tab(tester, 'Moments');

    // Dropped at 1.55s: 0.05 after the 1.5s beat, within the magnet tolerance.
    // Without the magnet it would stop at 1.55; with it, it must land exactly on the beat.
    const loose = 1.55;
    await dragSlowly(
      tester,
      block(tester, 0),
      loose * px + eatenBySlop,
    );

    expect(firstCut(tester).atS, closeTo(1.5, 1e-9));
  });

  testWidgets('dragging does not let the block leave on the left', (tester) async {
    await open(tester, withMusic: true);
    await tester.tap(moment(30.0));
    await tester.pump();

    await dragSlowly(tester, block(tester, 0), -200);

    expect(firstCut(tester).atS, 0);
  });

  testWidgets('dragging the right handle stretches the cut', (tester) async {
    await open(tester, withMusic: true);
    await tester.tap(moment(30.0));
    await tester.pump();

    final beforeState = firstCut(tester).durationS;

    // the handle sits on the right edge of the selected block
    final box = tester.getRect(block(tester, 0));
    await tester.dragFrom(
      Offset(box.right - 8, box.center.dy),
      const Offset(60, 0),
    );
    await tester.pump();

    final afterState = firstCut(tester);
    expect(afterState.durationS, greaterThan(beforeState));
    expect(afterState.atS, 0, reason: 'stretching does not move the block');
  });

  testWidgets('the monitor warns when the playhead is on empty space', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('no cuts yet'), findsOneWidget);
  });

  // ── a prateleira e o monitor ──────────────────────────────────────────────

  testWidgets('each moment shows up with its frame', (tester) async {
    // without a picture, choosing among thirty kills is choosing among thirty
    // identical clocks
    await open(tester);

    final picture = tester.widget<Image>(
      find.descendant(of: moment(30.0), matching: find.byType(Image)),
    );
    final network = picture.image as NetworkImage;
    expect(network.url, contains('/api/jobs/j1/frame'));
    expect(network.url, contains('t=30.00'));
  });

  testWidgets('on a wide screen the shelf sits on the side', (tester) async {
    await open(tester); // the test window is 1000px
    final sidebar = tester.getTopLeft(moment(30.0));
    final timelineWidget = tester.getTopLeft(find.byType(MusicTimeline));

    expect(
      sidebar.dx,
      lessThan(timelineWidget.dx),
      reason: 'the shelf has to be to the left of the ruler',
    );
  });

  testWidgets('on a narrow screen it goes back below the ruler', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(500, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(home: TimelineScreen(job: jobWithMoments())),
    );
    await tester.pump();

    expect(
      tester.getTopLeft(moment(30.0)).dy,
      greaterThan(tester.getTopLeft(find.byType(MusicTimeline)).dy),
    );
  });

  testWidgets('the handle drags the monitor height', (tester) async {
    await open(tester);
    final beforeState = tester.getSize(find.byType(PreviewPlayer)).height;

    await tester.drag(
      find.byKey(const Key('monitor-handle')),
      const Offset(0, 120),
    );
    await tester.pump();

    expect(
      tester.getSize(find.byType(PreviewPlayer)).height,
      greaterThan(beforeState),
    );
  });

  testWidgets('the monitor does not shrink below the minimum', (tester) async {
    await open(tester);

    await tester.drag(
      find.byKey(const Key('monitor-handle')),
      const Offset(0, -900),
    );
    await tester.pump();

    expect(
      tester.getSize(find.byType(PreviewPlayer)).height,
      greaterThanOrEqualTo(120.0),
    );
  });

  // ── o rascunho ────────────────────────────────────────────────────────────
  //
  // Reloading the page used to cost the whole montage. Now it lives on the server
  // and comes back with the match.

  testWidgets('the earlier montage comes back when the screen opens', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final job = Job.fromJson({
      ...jobJson(withMusic: true),
      'draft': {
        'title': 'My montage from yesterday',
        'track_id': 'm1',
        'music_start_s': 8.0,
        'cuts': [
          {
            'source_t': 30.0,
            'start_s': 29.0,
            'duration_s': 1.5,
            'at_s': 0.0,
            'kind': 'kill',
          },
          {
            'source_t': 75.0,
            'start_s': 74.0,
            'duration_s': 1.0,
            'at_s': 2.0,
            'kind': 'sleep',
          },
        ],
      },
    });

    await tester.pumpWidget(MaterialApp(home: TimelineScreen(job: job)));
    await tester.pump();

    final cuts = cutList(tester);
    // two cuts and the music block the continuous track was converted into
    final fromRecording = cuts.where((c) => c.source == 'recording').toList();
    expect(fromRecording, hasLength(2));
    expect(fromRecording[0].sourceT, 30.0);
    expect(fromRecording[1].atS, 2.0);
    expect(find.textContaining('2 cut(s)'), findsOneWidget);

    // the name survives, and the earlier song comes back as a block on the ruler: it
    // came in at 8s of the track and covered the whole video
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'My montage from yesterday',
    );
    final music = cuts.singleWhere((c) => c.source == 'media');
    expect(music.mediaId, 'm1');
    expect(music.atS, 0);
    expect(music.startS, 8.0);
    expect(music.durationS, closeTo(3.0, 1e-6));
  });

  testWidgets('without a draft, the screen opens empty', (tester) async {
    await open(tester);
    expect(cutList(tester), isEmpty);
  });

  // ── what Phase 1 brought ──────────────────────────────────────────────────
  //
  // V1 had none of this: every change overwrote the previous one, and a single
  // block was the only one you could touch at a time.

  /// Presses a key, with whatever modifiers come.
  Future<void> press(
    WidgetTester tester,
    LogicalKeyboardKey keyName, {
    bool ctrl = false,
    bool shift = false,
  }) async {
    if (ctrl) await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
    await tester.sendKeyEvent(keyName);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
    if (ctrl) await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
    await tester.pump();
  }

  /// The clips of every layer, in the order the video shows them.
  testWidgets('Ctrl+Z undoes a whole drag, not pixel by pixel', (
    tester,
  ) async {
    await open(tester, withMusic: true);
    await tester.tap(moment(30.0));
    await tester.pump();
    expect(cutList(tester).first.atS, 0);

    await dragSlowly(tester, block(tester, 0), 120);
    expect(cutList(tester).first.atS, greaterThan(1.0));

    await press(tester, LogicalKeyboardKey.keyZ, ctrl: true);

    expect(cutList(tester).first.atS, 0, reason: 'one step brought everything back');
  });

  testWidgets('Ctrl+Shift+Z redoes what was undone', (tester) async {
    await open(tester, withMusic: true);
    await tester.tap(moment(30.0));
    await tester.pump();
    await dragSlowly(tester, block(tester, 0), 120);
    final afterDrag = cutList(tester).first.atS;

    await press(tester, LogicalKeyboardKey.keyZ, ctrl: true);
    await press(tester, LogicalKeyboardKey.keyZ, ctrl: true, shift: true);

    expect(cutList(tester).first.atS, afterDrag);
  });

  testWidgets('undo also takes back a freshly placed block', (tester) async {
    await open(tester, withMusic: true);
    await tester.tap(moment(30.0));
    await tester.pump();
    expect(cutList(tester), hasLength(1));

    await press(tester, LogicalKeyboardKey.keyZ, ctrl: true);

    expect(cutList(tester), isEmpty);
    expect(find.text('Add at least one cut'), findsOneWidget);
  });

  testWidgets(
    'the undo buttons are only active when there is something to undo',
    (tester) async {
      await open(tester, withMusic: true);
      IconButton button(IconData icon) =>
          tester.widget<IconButton>(find.widgetWithIcon(IconButton, icon));

      expect(button(Icons.undo).onPressed, isNull);
      expect(button(Icons.redo).onPressed, isNull);

      await tester.tap(moment(30.0));
      await tester.pump();

      expect(button(Icons.undo).onPressed, isNotNull);
      expect(button(Icons.redo).onPressed, isNull);
    },
  );

  testWidgets('S splits the cut under the playhead', (tester) async {
    await open(tester, withMusic: true);
    await tester.tap(moment(30.0));
    await tester.pump();
    final original = cutList(tester).first;

    // moves the cursor to the middle of the block and cuts
    await cursorAt(tester, original.durationS / 2);
    await press(tester, LogicalKeyboardKey.keyS);

    final afterState = cutList(tester);
    expect(afterState, hasLength(2));
    // the seam is invisible: the second half continues where the first stopped
    expect(afterState[1].startS, closeTo(afterState[0].endS, 1e-6));
    expect(afterState[1].untilS, closeTo(original.untilS, 1e-6));
  });

  testWidgets('splitting outside a cut warns instead of doing nothing', (
    tester,
  ) async {
    await open(tester, withMusic: true);
    await press(tester, LogicalKeyboardKey.keyS);

    expect(find.textContaining('over a cut'), findsOneWidget);
  });

  testWidgets('Delete removes the selected cuts', (tester) async {
    await open(tester, withMusic: true);
    await tester.tap(moment(30.0));
    await tester.pump();

    await press(tester, LogicalKeyboardKey.delete);

    expect(cutList(tester), isEmpty);
  });

  testWidgets('Ctrl+D duplicates what is selected', (tester) async {
    await open(tester, withMusic: true);
    await tester.tap(moment(30.0));
    await tester.pump();

    await press(tester, LogicalKeyboardKey.keyD, ctrl: true);

    final afterState = cutList(tester);
    expect(afterState, hasLength(2));
    expect(afterState[1].atS, closeTo(afterState[0].untilS, 1e-6));
    expect(afterState[0].id, isNot(afterState[1].id));
  });

  testWidgets('copy and paste puts the copy where the cursor is', (
    tester,
  ) async {
    await open(tester, withMusic: true);
    await tester.tap(moment(30.0));
    await tester.pump();

    await press(tester, LogicalKeyboardKey.keyC, ctrl: true);
    await cursorAt(tester, 5);
    await press(tester, LogicalKeyboardKey.keyV, ctrl: true);

    final afterState = cutList(tester);
    expect(afterState, hasLength(2));
    expect(afterState[1].atS, closeTo(5.0, 0.3));
  });

  testWidgets('shift+click adds to the selection, and the batch panel shows up', (
    tester,
  ) async {
    await open(tester, withMusic: true);
    await tester.tap(moment(30.0));
    await tester.pump();
    await tester.tap(moment(75.0));
    await tester.pump();

    // only the last one placed is selected
    expect(find.textContaining('cuts selected'), findsNothing);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
    await tester.tap(block(tester, 0));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
    await tester.pump();

    expect(find.text('2 cuts selected'), findsOneWidget);
  });

  testWidgets('Ctrl+A selects everything and Delete takes them all', (tester) async {
    await open(tester, withMusic: true);
    for (final t in [30.0, 75.0, 120.0]) {
      await tester.tap(moment(t));
      await tester.pump();
    }
    expect(cutList(tester), hasLength(3));

    await press(tester, LogicalKeyboardKey.keyA, ctrl: true);
    expect(find.text('3 cuts selected'), findsOneWidget);

    await press(tester, LogicalKeyboardKey.delete);
    expect(cutList(tester), isEmpty);
  });

  testWidgets('Shift+arrow nudges the selection without moving the cursor', (
    tester,
  ) async {
    await open(tester, withMusic: true);
    await tester.tap(moment(30.0));
    await tester.pump();
    final beforeState = cutList(tester).first.atS;

    await press(tester, LogicalKeyboardKey.arrowRight, shift: true);

    expect(cutList(tester).first.atS, closeTo(beforeState + 0.1, 1e-6));
  });

  testWidgets('the shortcut list is within reach', (tester) async {
    await open(tester, withMusic: true);
    // `pumpAndSettle` does not work here: with no video plugin in tests, the monitor
    // keeps a spinner going forever and the tree never "settles".
    await tester.tap(find.byKey(const Key('screen-menu')));
    // the menu route comes in animating, and while it animates it absorbs the tap
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(
      find.widgetWithText(PopupMenuItem<String>, 'Keyboard shortcuts'),
    );
    // the menu closes, only then does `onSelected` fire, and only then does the dialog open:
    // that is three animation frames, not one
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    expect(find.text('split the cut under the cursor'), findsOneWidget);
  });

  // ── camadas ───────────────────────────────────────────────────────────────

  testWidgets('the screen opens with one layer, and the button creates another', (
    tester,
  ) async {
    await open(tester, withMusic: true);
    MusicTimeline timelineWidget() =>
        tester.widget<MusicTimeline>(find.byType(MusicTimeline));

    expect(timelineWidget().layers, hasLength(1));

    await tester.tap(find.byTooltip('New layer'));
    await tester.pump();

    expect(timelineWidget().layers, hasLength(2));
    expect(timelineWidget().activeLayer, 1, reason: 'work moves to the new one');
  });

  testWidgets('the last layer cannot be removed', (tester) async {
    await open(tester, withMusic: true);
    final button = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.layers_clear_outlined),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('the new clip goes into the active layer', (tester) async {
    await open(tester, withMusic: true);
    await tester.tap(find.byTooltip('New layer'));
    await tester.pump();
    await tester.tap(moment(30.0));
    await tester.pump();

    final timelineWidget = tester.widget<MusicTimeline>(find.byType(MusicTimeline));
    expect(timelineWidget.layers[0].clips, isEmpty);
    expect(timelineWidget.layers[1].clips, hasLength(1));
  });

  testWidgets('hiding a layer removes its clips from the ruler', (
    tester,
  ) async {
    await open(tester, withMusic: true);
    await tester.tap(moment(30.0));
    await tester.pump();
    expect(block(tester, 0), findsOneWidget);

    await tester.tap(find.byTooltip('hide'));
    await tester.pump();

    // the clip stays in the montage, but vanishes from the drawing
    final timelineWidget = tester.widget<MusicTimeline>(find.byType(MusicTimeline));
    expect(timelineWidget.layers.first.clips, hasLength(1));
    expect(timelineWidget.layers.first.hidden, isTrue);
    expect(
      find.byKey(ValueKey('block-${timelineWidget.layers.first.clips.first.id}')),
      findsNothing,
    );
  });

  testWidgets('undo brings back the hiding', (tester) async {
    // touching a layer is an edit like any other
    await open(tester, withMusic: true);
    await tester.tap(moment(30.0));
    await tester.pump();
    await tester.tap(find.byTooltip('hide'));
    await tester.pump();

    await press(tester, LogicalKeyboardKey.keyZ, ctrl: true);

    expect(
      tester
          .widget<MusicTimeline>(find.byType(MusicTimeline))
          .layers
          .first
          .hidden,
      isFalse,
    );
  });

  testWidgets('a locked layer does not let the clip be dragged', (tester) async {
    await open(tester, withMusic: true);
    await tester.tap(moment(30.0));
    await tester.pump();
    await tester.tap(find.byTooltip('lock'));
    await tester.pump();

    await dragSlowly(tester, block(tester, 0), 120);

    expect(firstCut(tester).atS, 0, reason: 'locked is locked');
  });

  // ── media library ─────────────────────────────────────────────────────────

  testWidgets('the sidebar has both shelves', (tester) async {
    await open(tester, withMusic: true);

    expect(find.text('Moments'), findsOneWidget);
    expect(find.text('Library'), findsOneWidget);
  });

  testWidgets('an empty library says it is empty', (tester) async {
    // without `withMusic` the match has no media at all -- the music lives here
    await open(tester);
    await tab(tester, 'Library');

    expect(find.text('Nothing here yet.'), findsOneWidget);
    expect(find.text('Import'), findsOneWidget);
  });

  testWidgets('a library item becomes a clip on the ruler', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final job = Job.fromJson({
      ...jobJson(withMusic: true),
      'media': [
        {
          'id': 'm1',
          'kind': 'image',
          'status': 'ready',
          'name': 'badge.png',
          'width': 320,
          'height': 180,
          'duration_s': 0.0,
        },
      ],
    });
    await tester.pumpWidget(MaterialApp(home: TimelineScreen(job: job)));
    await tester.pump();

    await tab(tester, 'Library');
    // the name shows up in the library and also in the output watermark list
    expect(find.text('badge.png'), findsWidgets);
    expect(find.byKey(const ValueKey('media-m1')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('media-m1')));
    await tester.pump();

    final clip = cutList(tester).single;
    expect(clip.source, 'media');
    expect(clip.mediaId, 'm1');
    expect(clip.durationS, greaterThan(0));
  });

  testWidgets('does not let you remove from the library what is in the montage', (
    tester,
  ) async {
    // a clip pointing at it would be orphaned, and the request would be refused
    await tester.binding.setSurfaceSize(const Size(1000, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final job = Job.fromJson({
      ...jobJson(withMusic: true),
      'media': [
        {
          'id': 'm1',
          'kind': 'image',
          'status': 'ready',
          'name': 'badge.png',
          'width': 320,
          'height': 180,
        },
      ],
    });
    await tester.pumpWidget(MaterialApp(home: TimelineScreen(job: job)));
    await tester.pump();
    await tab(tester, 'Library');
    await tester.tap(find.byKey(const ValueKey('media-m1')));
    await tester.pump();

    await tester.tap(find.byTooltip('Remove from the library'));
    await tester.pump();

    expect(find.textContaining('is in the montage'), findsOneWidget);
    expect(find.byKey(const ValueKey('media-m1')), findsOneWidget);
  });

  // ── efeitos ───────────────────────────────────────────────────────────────

  testWidgets('the effects panel opens on the selected block', (tester) async {
    await open(tester, withMusic: true);
    await tester.tap(moment(30.0));
    await tester.pump();

    expect(find.text('Effects'), findsOneWidget);

    await tester.tap(find.text('Effects'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.text('Speed'), findsOneWidget);
    expect(find.text('Fade in'), findsOneWidget);
    expect(find.text('Colour'), findsOneWidget);
    expect(find.text('Zoom in'), findsOneWidget);
    expect(find.text('Freeze'), findsOneWidget);
  });

  testWidgets('the punch comes ready-made, in one tap', (tester) async {
    await open(tester, withMusic: true);
    await tester.tap(moment(30.0));
    await tester.pump();
    await tester.tap(find.text('Effects'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    await tester.tap(find.text('medium'));
    await tester.pump();

    final clip = firstCut(tester);
    expect(clip.zoom, hasLength(3));
    expect(clip.zoom[1].scale, 1.6);
    // and it can be removed
    await tester.tap(find.text('remove'));
    await tester.pump();
    expect(firstCut(tester).zoom, isEmpty);
  });

  testWidgets('the mix shows up when there is music on the ruler', (tester) async {
    // having the song in the library is not having music in the video: there is
    // only something to balance after it goes on the ruler
    await open(tester, withMusic: true);
    expect(find.text('Mix'), findsNothing);

    await tab(tester, 'Library');
    await tester.tap(find.byKey(const ValueKey('media-m1')));
    await settle(tester);
    await tab(tester, 'Moments');

    expect(find.text('Mix'), findsOneWidget);
    expect(find.textContaining('gunfire comes through under it'), findsOneWidget);
  });

  testWidgets('without music there is no mix to do', (tester) async {
    await open(tester);
    expect(find.text('Mix'), findsNothing);
  });

  // ── texto ─────────────────────────────────────────────────────────────────

  /// Opens the write-on-screen menu and picks an item.
  Future<void> write(WidgetTester tester, String item) async {
    await tester.tap(find.byTooltip('Write on screen'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.text(item));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  testWidgets('free text goes into a new layer, on top', (tester) async {
    await open(tester, withMusic: true);
    await tester.tap(moment(30.0));
    await tester.pump();

    await write(tester, 'Free text');

    final timelineWidget = tester.widget<MusicTimeline>(find.byType(MusicTimeline));
    expect(timelineWidget.layers, hasLength(2), reason: 'text goes over the picture');
    expect(timelineWidget.layers[1].clips.single.isText, isTrue);
    expect(timelineWidget.layers[1].clips.single.text, 'TEXT');
  });

  testWidgets('the kill counter writes itself', (tester) async {
    await open(tester, withMusic: true);
    // two kills in the montage
    await tester.tap(moment(30.0));
    await tester.pump();
    await tester.tap(moment(30.0));
    await tester.pump();

    await write(tester, 'Kill counter');

    final timelineWidget = tester.widget<MusicTimeline>(find.byType(MusicTimeline));
    final texts = [
      for (final l in timelineWidget.layers)
        for (final c in l.clips)
          if (c.isText) c.text,
    ];
    expect(texts, ['1', '2']);
  });

  testWidgets('without kills, the counter warns instead of doing nothing', (
    tester,
  ) async {
    await open(tester, withMusic: true);
    await tester.tap(moment(75.0)); // a sleep dart, not a kill
    await tester.pump();

    await write(tester, 'Kill counter');

    expect(find.textContaining('There are no'), findsOneWidget);
  });

  group('typing on the video', () {
    TimelineClip text(WidgetTester tester) => tester
        .widget<MusicTimeline>(find.byType(MusicTimeline))
        .layers
        .last
        .clips
        .single;

    Future<void> withText(WidgetTester tester) async {
      await open(tester);
      await tester.tap(moment(30.0));
      await tester.pump();
      await write(tester, 'Free text');
    }

    testWidgets('the panel no longer has a field for the text', (tester) async {
      await withText(tester);

      expect(find.text('What is written'), findsNothing);
      expect(find.byKey(const Key('type-on-frame')), findsOneWidget);
    });

    testWidgets('tapping the selected text types on the frame itself', (
      tester,
    ) async {
      await withText(tester);
      final id = text(tester).id;

      // it is born selected: one tap opens typing
      await tester.tap(find.byKey(ValueKey('frame-text-$id')));
      await tester.pump();
      final field = find.byKey(ValueKey('typing-$id'));
      expect(field, findsOneWidget);

      await tester.enterText(field, 'GG');
      await tester.pump();
      expect(text(tester).text, 'GG');

      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(field, findsNothing);
      expect(find.text('GG'), findsWidgets);
    });

    /// Is the keyboard really on the field? `enterText` writes straight into
    /// the controller and would pass with focus elsewhere — and the bug the
    /// user saw was exactly that: the field open, and keys going to the
    /// montage shortcuts.
    bool keyboardOnField(WidgetTester tester, String id) {
      final ctx = FocusManager.instance.primaryFocus?.context;
      if (ctx == null) return false;
      final field = ctx.findAncestorWidgetOfExactType<TextField>();
      return field?.key == ValueKey('typing-$id');
    }

    testWidgets('typing takes the keyboard even with the montage focused', (
      tester,
    ) async {
      await withText(tester);
      final id = text(tester).id;
      // the screen's normal state: focus on the montage, so shortcuts work —
      // and with it there, the field's `autofocus` did nothing
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'montage');

      await tester.tap(find.byKey(ValueKey('frame-text-$id')));
      await tester.pump();
      await tester.pump();
      expect(keyboardOnField(tester, id), isTrue);

      // and again, through the panel button, after leaving
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.tap(find.byKey(const Key('type-on-frame')));
      await tester.pump();
      await tester.pump();
      expect(keyboardOnField(tester, id), isTrue);

      // a one-key shortcut must not steal the letter: "s" would split the clip
      final before = cutList(tester).length;
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.pump();
      expect(cutList(tester), hasLength(before));
    });

    testWidgets('the panel button opens typing on the frame', (tester) async {
      await withText(tester);
      final id = text(tester).id;

      await tester.tap(find.byKey(const Key('type-on-frame')));
      await tester.pump();

      expect(find.byKey(ValueKey('typing-$id')), findsOneWidget);
    });

    testWidgets('clearing everything and leaving restores the text', (
      tester,
    ) async {
      // empty text is not text the server draws
      await withText(tester);
      final id = text(tester).id;
      final before = text(tester).text;

      await tester.tap(find.byKey(const Key('type-on-frame')));
      await tester.pump();
      await tester.enterText(find.byKey(ValueKey('typing-$id')), '  ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(text(tester).text, before);
    });

    testWidgets('a whole typing session is a single undo step', (tester) async {
      await withText(tester);
      final id = text(tester).id;
      final before = text(tester).text;

      await tester.tap(find.byKey(const Key('type-on-frame')));
      await tester.pump();
      final field = find.byKey(ValueKey('typing-$id'));
      for (final partial in ['G', 'GG', 'GG W', 'GG WP']) {
        await tester.enterText(field, partial);
        await tester.pump();
      }
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(text(tester).text, 'GG WP');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(text(tester).text, before);
    });
  });

  testWidgets('scrolling the panels keeps the monitor and ruler on screen', (
    tester,
  ) async {
    await open(tester);
    // a short window, where the panels do not fit and the screen must scroll
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    await tester.pump();
    await tester.tap(moment(30.0));
    await tester.pump();

    final monitor = tester.getRect(find.byType(PreviewPlayer));
    final ruler = tester.getRect(find.byType(MusicTimeline));

    await tester.drag(
      find.byKey(const Key('montage-panels')),
      const Offset(0, -600),
    );
    await tester.pump();

    final scrolled = tester
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byKey(const Key('montage-panels')),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position
        .pixels;
    expect(scrolled, greaterThan(100), reason: 'the panels really scrolled');
    expect(tester.getRect(find.byType(PreviewPlayer)), monitor);
    expect(tester.getRect(find.byType(MusicTimeline)), ruler);
  });

  group('output panel', () {
    /// The summary is the only thing on the screen that says what will really come out.
    String summary(WidgetTester tester) =>
        tester.widget<Text>(find.textContaining(RegExp(r'^\d+x\d+'))).data!;

    testWidgets('choosing nothing, it comes out at the recording size', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(moment(30.0));
      await tester.pump();

      expect(summary(tester), startsWith('1920x1080'));
      // and there is nothing to undo: the back-to-default button does not even show
      expect(find.text('Default'), findsNothing);
    });

    testWidgets('choosing vertical changes the output, and only it', (tester) async {
      await open(tester);
      await tester.tap(moment(30.0));
      await tester.pump();
      final beforeState = cutList(tester).single;

      await tester.tap(find.text('Vertical'));
      await tester.pump();

      expect(summary(tester), startsWith('1080x1920'));
      // the montage did not move: it is a window, not an edit
      final afterState = cutList(tester).single;
      expect(afterState.atS, beforeState.atS);
      expect(afterState.durationS, beforeState.durationS);
      expect(afterState.startS, beforeState.startS);
    });

    testWidgets('the choice between cropping and fitting only shows when it matters', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(moment(30.0));
      await tester.pump();

      // 720p from a 16:9 recording has the same proportion: there is nothing to decide
      await tester.tap(find.text('720p'));
      await tester.pump();
      expect(find.text('Fill'), findsNothing);

      await tester.tap(find.text('Vertical'));
      await tester.pump();
      expect(find.text('Fill'), findsOneWidget);
      expect(find.text('Contain'), findsOneWidget);
    });

    testWidgets('you can go back to the default at once', (tester) async {
      await open(tester);
      await tester.tap(moment(30.0));
      await tester.pump();

      await tester.tap(find.text('Vertical'));
      await tester.pump();
      await tester.tap(find.text('Light'));
      await tester.pump();
      expect(summary(tester), startsWith('1080x1920'));

      await tester.tap(find.text('Default'));
      await tester.pump();
      expect(summary(tester), startsWith('1920x1080'));
      expect(find.text('Default'), findsNothing);
    });

    testWidgets('changing the output is undone like any other edit', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(moment(30.0));
      await tester.pump();

      await tester.tap(find.text('Vertical'));
      await tester.pump();
      expect(summary(tester), startsWith('1080x1920'));

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(summary(tester), startsWith('1920x1080'));
      expect(cutList(tester), hasLength(1), reason: 'the cut is still there');
    });

    testWidgets('without a selection you cannot export only the selection', (
      tester,
    ) async {
      // a freshly placed cut comes in selected, so the case to test is the
      // blank montage — and that of whoever just cleared the selection
      await open(tester);

      final chip = tester.widget<ChoiceChip>(
        find.ancestor(
          of: find.text('Selection only'),
          matching: find.byType(ChoiceChip),
        ),
      );
      expect(chip.onSelected, isNull);
    });

    testWidgets('exporting the selection crops the time without deleting anything', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(moment(30.0));
      await tester.tap(moment(75.0));
      await tester.pump();

      // the second cut stays selected when it comes in; just ask for the range
      await tester.tap(find.text('Selection only'));
      await tester.pump();

      expect(cutList(tester), hasLength(2), reason: 'nothing was deleted');
      // the announced duration becomes the range's, not the whole video's
      final durationValue = cutList(tester)[1].durationS;
      expect(summary(tester), contains('0:0${durationValue.round()}'));
    });
  });

  group('match montages', () {
    Map<String, dynamic> montageJson({
      required String id,
      required String displayName,
      double at = 0,
      String heading = '',
      int versions = 0,
    }) => {
      'id': id,
      'job_id': 'j1',
      'name': displayName,
      'n_clips': 1,
      'duration_s': 2.0,
      'has_music': false,
      'n_versions': versions,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
      'data': {
        'title': heading,
        'layers': [
          {
            'clips': [
              {'at_s': at, 'duration_s': 2.0, 'start_s': 30.0, 'kind': 'kill'},
            ],
          },
        ],
      },
    };

    Future<void> openWith(
      WidgetTester tester,
      List<Map<String, dynamic>> montageList,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1000, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final job = Job.fromJson({...jobJson(), 'montages': montageList});
      await tester.pumpWidget(MaterialApp(home: TimelineScreen(job: job)));
      await tester.pump();
    }

    testWidgets('opens the most recent one, and says which it is', (tester) async {
      // it is the one being edited, and the one you want back
      await openWith(tester, [
        montageJson(id: 'm1', displayName: 'short vertical', at: 4),
        montageJson(id: 'm2', displayName: 'the long one'),
      ]);

      expect(find.text('short vertical'), findsOneWidget);
      expect(cutList(tester).single.atS, 4.0);
    });

    testWidgets('without any montage, the screen opens blank', (tester) async {
      await openWith(tester, const []);

      expect(find.text('Montage'), findsOneWidget);
      expect(cutList(tester), isEmpty);
    });

    testWidgets('the picker lists the others, with the length of each', (
      tester,
    ) async {
      await openWith(tester, [
        montageJson(id: 'm1', displayName: 'short vertical'),
        montageJson(id: 'm2', displayName: 'the long one'),
      ]);

      await tester.tap(find.byKey(const Key('montage-picker')));
      await settle(tester);

      expect(find.byKey(const ValueKey('open-m1')), findsOneWidget);
      expect(find.byKey(const ValueKey('open-m2')), findsOneWidget);
      expect(find.textContaining('1 cut(s)'), findsWidgets);
      expect(find.text('New montage'), findsOneWidget);
    });

    testWidgets('switching montages switches the cuts on the ruler', (tester) async {
      await openWith(tester, [
        montageJson(id: 'm1', displayName: 'first', at: 0),
        montageJson(id: 'm2', displayName: 'second', at: 9),
      ]);
      expect(cutList(tester).single.atS, 0.0);

      await tester.tap(find.byKey(const Key('montage-picker')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('open-m2')));
      await settle(tester);

      expect(cutList(tester).single.atS, 9.0);
      expect(find.text('second'), findsOneWidget);
    });

    testWidgets('undo does not cross a montage switch', (tester) async {
      // it is the memory of a work session *on one* montage; undoing
      // into another would erase what was just opened
      await openWith(tester, [
        montageJson(id: 'm1', displayName: 'first', at: 0),
        montageJson(id: 'm2', displayName: 'second', at: 9),
      ]);

      await tester.tap(moment(30.0));
      await tester.pump();
      expect(cutList(tester), hasLength(2));

      await tester.tap(find.byKey(const Key('montage-picker')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('open-m2')));
      await settle(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(cutList(tester).single.atS, 9.0, reason: 'the second one is still there');
    });

    testWidgets('the menu offers duplicate, versions and presets', (
      tester,
    ) async {
      await openWith(tester, [montageJson(id: 'm1', displayName: 'one')]);

      await tester.tap(find.byKey(const Key('screen-menu')));
      await settle(tester);

      expect(find.text('Duplicate this montage'), findsOneWidget);
      expect(find.text('Rename'), findsOneWidget);
      expect(find.text('Version history…'), findsOneWidget);
      expect(find.text('Apply preset…'), findsOneWidget);
      expect(find.text('Save as preset…'), findsOneWidget);
    });

    testWidgets('the title saved in the montage comes back in the name field', (
      tester,
    ) async {
      await openWith(tester, [
        montageJson(id: 'm1', displayName: 'one', heading: 'Ana carrying'),
      ]);

      expect(find.widgetWithText(TextField, 'Ana carrying'), findsOneWidget);
    });
  });

  group('music on the timeline', () {
    /// The sound layer of the montage on screen, if there is one already.
    Layer? audioLayer(WidgetTester tester) => tester
        .widget<MusicTimeline>(find.byType(MusicTimeline))
        .layers
        .where((l) => l.isAudio)
        .firstOrNull;

    /// Puts the song on the ruler the real way: through the Library.
    Future<void> putOnRuler(WidgetTester tester) async {
      await tab(tester, 'Library');
      await tester.tap(find.byKey(const ValueKey('media-m1')));
      await settle(tester);
      await tab(tester, 'Moments');
    }

    testWidgets('the button opens a sound-only layer', (tester) async {
      await open(tester, withMusic: true);

      await tester.tap(find.byKey(const Key('new-music-layer')));
      await settle(tester);

      expect(audioLayer(tester), isNotNull);
      expect(audioLayer(tester)!.clips, isEmpty);
    });

    testWidgets('the library song opens the sound layer on its own', (
      tester,
    ) async {
      // asking for music and getting a request for a layer would be red tape
      await open(tester, withMusic: true);
      await tester.tap(moment(30.0));
      await tester.pump();

      await putOnRuler(tester);

      final block = audioLayer(tester)!.clips.single;
      expect(block.mediaId, 'm1');
      expect(block.source, 'media');
      expect(block.atS, 0);
    });

    testWidgets('putting it on the ruler goes in at the playhead', (tester) async {
      await open(tester, withMusic: true);
      await tester.tap(moment(30.0));
      await tester.pump();
      await cursorAt(tester, 3.2);

      await putOnRuler(tester);

      final block = audioLayer(tester)!.clips.single;
      expect(block.mediaId, 'm1');
      expect(block.atS, closeTo(3.2, 0.2));
    });

    testWidgets('two songs fit on the same layer, one after the other', (
      tester,
    ) async {
      await open(tester, withMusic: true);
      await tester.tap(moment(30.0));
      await tester.pump();

      await putOnRuler(tester);
      await putOnRuler(tester);

      // the second does not push the first: it goes after what is already there
      final blocks = audioLayer(tester)!.clips;
      expect(blocks, hasLength(2));
      expect(blocks.last.atS, closeTo(blocks.first.untilS, 1e-6));
    });

    /// Drags a block until dropping it **exactly** at [targetS].
    ///
    /// `dragSlowly` moves in 3px steps and overshoots the requested point: to
    /// measure where the magnet snapped you need to know where it started, or the
    /// leftover of the last step answers for the magnet.
    Future<void> dragTo(
      WidgetTester tester,
      Finder target,
      double targetS,
      double startedS,
    ) async {
      final total = (targetS - startedS) * px + eatenBySlop;
      final gesture = await tester.startGesture(tester.getCenter(target));
      var moved = 0.0;
      while (moved < total) {
        final step = total - moved < 3 ? total - moved : 3.0;
        await gesture.moveBy(Offset(step, 0));
        await tester.pump();
        moved += step;
      }
      await gesture.up();
      await tester.pump();
    }

    testWidgets('the panel of a library video says which file it came from', (
      tester,
    ) async {
      // "Event at 00:00" is a match moment label; an imported clip
      // did not come from any moment
      await tester.binding.setSurfaceSize(const Size(1000, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final job = Job.fromJson({
        ...jobJson(),
        'media': [
          {
            'id': 'v1',
            'kind': 'video',
            'status': 'ready',
            'name': 'intro.mp4',
            'duration_s': 4.0,
            'width': 1920,
            'height': 1080,
          },
        ],
      });
      await tester.pumpWidget(MaterialApp(home: TimelineScreen(job: job)));
      await tester.pump();

      await tab(tester, 'Library');
      await tester.tap(find.byKey(const ValueKey('media-v1')));
      await settle(tester);

      expect(find.text('intro.mp4'), findsWidgets);
      expect(find.textContaining('Event at'), findsNothing);
      // images have effects: what does not have them is sound
      expect(find.text('Effects'), findsOneWidget);
      expect(find.text('Framing'), findsOneWidget);
    });

    testWidgets('the block panel talks about music, not an event', (
      tester,
    ) async {
      // the block did not come from a match moment, and draws nothing: saying
      // "Event at 00:00" and offering zoom would be lying twice
      await open(tester, withMusic: true);
      await tester.tap(moment(30.0));
      await tester.pump();
      await putOnRuler(tester);

      expect(find.text('song.mp3'), findsWidgets);
      expect(
        find.textContaining('from 00:00 of the song'),
        findsOneWidget,
      );
      expect(find.text('Song span'), findsOneWidget);
      expect(find.text('Framing'), findsNothing);
      expect(find.text('Effects'), findsNothing);
    });

    testWidgets('the magnet starts following the song that is playing', (
      tester,
    ) async {
      // that is why the grid is per block: a video with two tracks has two
      // tempos, and snapping to the other one's beat would be worse than not snapping
      await open(tester, withMusic: true);
      await tester.tap(moment(30.0));
      await tester.pump();
      await cursorAt(tester, 3.2);
      await putOnRuler(tester);

      // the song came in off the half-second grid of the continuous
      // track, and the grid starts counting from where it came in
      final entry = audioLayer(tester)!.clips.single.atS;
      expect(entry % 0.5, closeTo(0.2, 1e-6));

      // dropped 0.04s before a beat *of the song on the ruler* — which on the old
      // grid is no beat at all, and would stay where it was dropped
      await dragTo(
        tester,
        block(tester, 0),
        entry + 0.46,
        firstCut(tester).atS,
      );

      expect(firstCut(tester).atS, closeTo(entry + 0.5, 1e-6));
    });
  });

  // ── dragging from the shelf to the ruler ──────────────────────────────────
  //
  // Clicking places at the playhead, which suits whoever is building in
  // order. Dragging is for whoever already knows where they want the thing — and
  // it is the gesture every editor has.

  group('dropping on the ruler', () {
    /// Drags [origin] to [seconds] on the ruler, on **track** [line].
    ///
    /// A track is what you see: the top one is line 0. The matching layer is the
    /// inverse maths — the layer list goes from bottom to top.
    Future<void> dragOnto(
      WidgetTester tester,
      Finder origin,
      double seconds, {
      int line = 0,
    }) async {
      final timelineWidget = tester.getRect(find.byType(MusicTimeline));
      final destination = Offset(
        timelineWidget.left + MusicTimeline.headerWidth + 1 + seconds * 60,
        timelineWidget.top +
            MusicTimeline.waveHeight +
            line * MusicTimeline.blockHeight +
            MusicTimeline.blockHeight / 2,
      );
      final gesture = await tester.startGesture(tester.getCenter(origin));
      // small steps: the `Draggable` is only born after beating the slop, and it is
      // by moving that the target gets `onWillAccept`
      final from = tester.getCenter(origin);
      for (var i = 1; i <= 20; i++) {
        await gesture.moveTo(Offset.lerp(from, destination, i / 20)!);
        await tester.pump();
      }
      await gesture.up();
      await settle(tester);
    }

    testWidgets('a moment dropped on the ruler becomes a block where it landed', (
      tester,
    ) async {
      await open(tester);

      await dragOnto(tester, moment(30.0), 4.0);

      expect(cutList(tester), hasLength(1));
      expect(cutList(tester).single.sourceT, 30.0);
      expect(cutList(tester).single.atS, closeTo(4.0, 0.2));
    });

    testWidgets('the playhead does not move with the drag', (
      tester,
    ) async {
      // dropping at a point says where the block enters, not where the video is
      await open(tester);
      await cursorAt(tester, 1);

      await dragOnto(tester, moment(30.0), 6.0);

      expect(cutList(tester).single.atS, closeTo(6.0, 0.2));
      expect(find.text('00:01'), findsOneWidget);
    });

    testWidgets('dropping on the top track puts the block on the top layer', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(find.byTooltip('New layer'));
      await settle(tester);

      // track 0 is the top one on screen, and the top one is the last in the list
      await dragOnto(tester, moment(30.0), 2.0);

      final layerList = tester
          .widget<MusicTimeline>(find.byType(MusicTimeline))
          .layers;
      expect(layerList[0].clips, isEmpty);
      expect(layerList[1].clips, hasLength(1));
    });

    testWidgets('a library song dropped on the ruler becomes a block', (
      tester,
    ) async {
      await open(tester, withMusic: true);
      await tester.tap(moment(30.0));
      await tester.pump();
      await tab(tester, 'Library');

      await dragOnto(tester, find.byKey(const ValueKey('media-m1')), 3.0);

      final sound = tester
          .widget<MusicTimeline>(find.byType(MusicTimeline))
          .layers
          .where((l) => l.isAudio)
          .single;
      expect(sound.clips.single.mediaId, 'm1');
      expect(sound.clips.single.atS, closeTo(3.0, 0.2));
    });

    testWidgets('a moment dropped on the sound layer is refused', (
      tester,
    ) async {
      // a layer draws or plays; the server would refuse, and refusing here
      // explains it better
      await open(tester, withMusic: true);
      await tester.tap(find.byKey(const Key('new-music-layer')));
      await settle(tester);

      // the sound layer is born last, and so it sits on the top track
      await dragOnto(tester, moment(30.0), 2.0);

      expect(cutList(tester), isEmpty);
      expect(find.textContaining('is a sound layer'), findsOneWidget);
    });
  });

  // ── the clock ─────────────────────────────────────────────────────────────

  group('playback', () {
    testWidgets('with nothing built there is nothing to play', (tester) async {
      await open(tester);
      final button = tester.widget<IconButton>(
        find.ancestor(
          of: find.byIcon(Icons.play_arrow),
          matching: find.byType(IconButton),
        ),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('playing moves the playhead through the video', (tester) async {
      // the clock is the video, not the song: a video with no track at all
      // is still a video to review
      await open(tester);
      await tester.tap(moment(30.0));
      await tester.pump();

      await tester.tap(find.byIcon(Icons.play_arrow));
      await tester.pump();
      expect(find.byIcon(Icons.pause), findsOneWidget);

      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final timelineWidget = tester.widget<MusicTimeline>(find.byType(MusicTimeline));
      expect(timelineWidget.playheadS, greaterThan(0.3), reason: 'the playhead moved');

      await tester.tap(find.byIcon(Icons.pause));
      await tester.pump();
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    });

    testWidgets('at the end of the video it stops on its own', (tester) async {
      await open(tester);
      await tester.tap(moment(30.0));
      await tester.pump();

      await tester.tap(find.byIcon(Icons.play_arrow));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    });
  });

  // ── o texto no monitor ────────────────────────────────────────────────────
  //
  // The text existed on the ruler and in the rendered video, and nowhere in
  // between: to know where the phrase would land you had to render the video.

  group('text on the monitor', () {
    /// The text clip in the montage.
    TimelineClip textOnRuler(WidgetTester tester) =>
        cutList(tester).firstWhere((c) => c.isText);

    testWidgets('the phrase shows over the picture', (tester) async {
      await open(tester);
      await tester.tap(moment(30.0));
      await tester.pump();
      await write(tester, 'Free text');

      expect(
        find.byKey(ValueKey('text-on-frame-${textOnRuler(tester).id}')),
        findsOneWidget,
      );
    });

    testWidgets('vanishes when the playhead leaves it', (
      tester,
    ) async {
      // the monitor shows what will come out at that instant, and nothing else
      await open(tester);
      await tester.tap(moment(30.0));
      await tester.pump();
      await write(tester, 'Free text');
      final id = textOnRuler(tester).id;

      await cursorAt(tester, 6);

      expect(find.byKey(ValueKey('frame-text-$id')), findsNothing);
    });

    testWidgets('dragging the phrase on the monitor repositions it in the frame', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(moment(30.0));
      await tester.pump();
      await write(tester, 'Free text');
      final id = textOnRuler(tester).id;
      expect(textOnRuler(tester).transform.x, 0);

      final beforeState = textOnRuler(tester);
      final target = find.byKey(ValueKey('frame-text-$id'));
      final monitor = tester.getSize(find.byType(PreviewPlayer));
      await tester.drag(target, Offset(monitor.width / 3, 0));
      await settle(tester);

      final afterState = textOnRuler(tester);
      // to the right and only to the right — `y` does not move on a horizontal
      // drag, and the block does not move on the ruler
      expect(afterState.transform.x, greaterThan(0.2));
      expect(afterState.transform.y, closeTo(beforeState.transform.y, 0.01));
      expect(afterState.atS, beforeState.atS);
    });

    testWidgets('the phrase does not leave the frame', (tester) async {
      await open(tester);
      await tester.tap(moment(30.0));
      await tester.pump();
      await write(tester, 'Free text');
      final id = textOnRuler(tester).id;

      // a drag past the edge: the phrase touches it and stops
      final target = find.byKey(ValueKey('frame-text-$id'));
      final monitor = tester.getSize(find.byType(PreviewPlayer));
      await tester.drag(
        target,
        Offset(monitor.width * 0.8, monitor.height * 0.8),
      );
      await settle(tester);

      expect(textOnRuler(tester).transform.x, 1.0);
      expect(textOnRuler(tester).transform.y, 1.0);
    });

    testWidgets('repositioning goes into undo', (tester) async {
      await open(tester);
      await tester.tap(moment(30.0));
      await tester.pump();
      await write(tester, 'Free text');
      final id = textOnRuler(tester).id;

      final monitor = tester.getSize(find.byType(PreviewPlayer));
      await tester.drag(
        find.byKey(ValueKey('frame-text-$id')),
        Offset(monitor.width / 3, 0),
      );
      await settle(tester);
      expect(textOnRuler(tester).transform.x, greaterThan(0.2));

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(textOnRuler(tester).transform.x, 0);
    });
  });

  // ── layer order ───────────────────────────────────────────────────────────

  group('reordering layers', () {
    testWidgets('dragging one header over the other swaps the order', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(moment(30.0));
      await tester.pump();
      // a second layer, with a block that identifies it
      await tester.tap(find.byTooltip('New layer'));
      await settle(tester);
      await cursorAt(tester, 8);
      await tester.tap(moment(75.0));
      await tester.pump();

      List<double> each(WidgetTester t) => [
        for (final l
            in t.widget<MusicTimeline>(find.byType(MusicTimeline)).layers)
          if (l.clips.isNotEmpty) l.clips.first.sourceT else -1,
      ];
      expect(each(tester), [30.0, 75.0]);

      final from = tester.getCenter(find.byKey(const ValueKey('header-0')));
      final to = tester.getCenter(find.byKey(const ValueKey('header-1')));
      final gesture = await tester.startGesture(from);
      // long press, which is the finger path; with a pointer there is the handle, which
      // arrasta na hora
      await tester.pump(const Duration(milliseconds: 400));
      for (var i = 1; i <= 10; i++) {
        await gesture.moveTo(Offset.lerp(from, to, i / 10)!);
        await tester.pump();
      }
      await gesture.up();
      await settle(tester);

      expect(each(tester), [75.0, 30.0], reason: 'the bottom one went up');
    });

    testWidgets('the handle drags right away, without waiting for a long press', (
      tester,
    ) async {
      // on desktop nobody holds the mouse button to drag a track
      await open(tester);
      await tester.tap(moment(30.0));
      await tester.pump();
      await tester.tap(find.byTooltip('New layer'));
      await settle(tester);

      expect(
        find.byTooltip('Drag to change the order of the layers'),
        findsNWidgets(2),
      );

      final from = tester.getCenter(
        find.descendant(
          of: find.byKey(const ValueKey('header-0')),
          matching: find.byTooltip('Drag to change the order of the layers'),
        ),
      );
      final to = tester.getCenter(find.byKey(const ValueKey('header-1')));
      final gesture = await tester.startGesture(from);
      for (var i = 1; i <= 10; i++) {
        await gesture.moveTo(Offset.lerp(from, to, i / 10)!);
        await tester.pump();
      }
      await gesture.up();
      await settle(tester);

      final layerList = tester
          .widget<MusicTimeline>(find.byType(MusicTimeline))
          .layers;
      expect(layerList[1].clips, hasLength(1), reason: 'the bottom one went up');
    });
  });

  // ── moving between layers ────────────────────────────────────────────────

  group('moving a block to another layer', () {
    testWidgets('dragging up takes the block to the top layer', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(moment(30.0));
      await tester.pump();
      await tester.tap(find.byTooltip('New layer'));
      await settle(tester);

      final id = cutList(tester).first.id;
      // up on screen: one track up is one layer up in the stack
      await tester.drag(
        find.byKey(ValueKey('block-$id')),
        const Offset(0, -MusicTimeline.blockHeight),
      );
      await settle(tester);

      final layerList = tester
          .widget<MusicTimeline>(find.byType(MusicTimeline))
          .layers;
      expect(layerList[0].clips, isEmpty);
      expect(layerList[1].clips.single.id, id);
    });

    List<Layer> layersOf(WidgetTester tester) =>
        tester.widget<MusicTimeline>(find.byType(MusicTimeline)).layers;

    testWidgets('a drag that starts sideways can still change layer', (
      tester,
    ) async {
      // the horizontal recogniser used to win the gesture and ignore the
      // vertical part: dragging a clip diagonally only ever moved it in time
      await open(tester);
      await tester.tap(moment(30.0));
      await tester.pump();
      await tester.tap(find.byTooltip('New layer'));
      await settle(tester);

      final id = cutList(tester).first.id;
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(ValueKey('block-$id'))),
      );
      for (var i = 0; i < 20; i++) {
        await gesture.moveBy(const Offset(6, 0));
        await tester.pump();
      }
      for (var i = 0; i < 24; i++) {
        await gesture.moveBy(const Offset(0, -3));
        await tester.pump();
      }
      await gesture.up();
      await settle(tester);

      final layerList = layersOf(tester);
      expect(layerList[0].clips, isEmpty);
      expect(layerList[1].clips.single.id, id);
      expect(layerList[1].clips.single.atS, greaterThan(1.0));
    });

    testWidgets('dragging a clip over its neighbour swaps the two', (
      tester,
    ) async {
      // the neighbour used to stop the drag: the clip could not get past it
      await open(tester);
      await tester.tap(moment(30.0));
      await tester.pump();
      await cursorAt(tester, 0);
      await tester.tap(moment(30.0));
      await tester.pump();
      final [a, b] = cutList(tester);
      expect(b.atS, closeTo(a.untilS, 1e-9), reason: 'back to back');

      // the centre of the dragged clip lands on the centre of the other
      await dragSlowly(
        tester,
        find.byKey(ValueKey('block-${a.id}')),
        (b.atS + b.durationS / 2 - a.durationS / 2 - a.atS) * px + eatenBySlop,
      );
      await settle(tester);

      final at = {for (final c in cutList(tester)) c.id: c.atS};
      expect(at[b.id], closeTo(0, 1e-9));
      expect(at[a.id], closeTo(b.durationS, 1e-9));
    });

    testWidgets('dragging above the top layer opens a new one', (tester) async {
      await open(tester);
      await tester.tap(moment(30.0));
      await tester.pump();
      expect(layersOf(tester), hasLength(1));

      final id = cutList(tester).first.id;
      await tester.drag(
        find.byKey(ValueKey('block-$id')),
        const Offset(0, -MusicTimeline.blockHeight),
      );
      await settle(tester);

      final layerList = layersOf(tester);
      expect(layerList, hasLength(2));
      expect(layerList[0].clips, isEmpty);
      expect(layerList[1].clips.single.id, id);
    });

    testWidgets('a moment clicked after adding music goes to a picture layer', (
      tester,
    ) async {
      await open(tester, withMusic: true);
      await tester.tap(find.byKey(const Key('new-music-layer')));
      await settle(tester);

      await tester.tap(moment(30.0));
      await tester.pump();

      final layerList = layersOf(tester);
      expect(layerList.last.isAudio, isTrue);
      expect(layerList.last.clips, isEmpty);
      expect(layerList.first.clips, hasLength(1));
    });

    testWidgets('for the sound layer, it explains instead of just refusing', (
      tester,
    ) async {
      // refusing silently is the worst of both worlds: the block goes back and whoever
      // dragged it cannot tell whether the gesture missed or it was impossible
      await open(tester, withMusic: true);
      await tester.tap(moment(30.0));
      await tester.pump();
      await tester.tap(find.byKey(const Key('new-music-layer')));
      await settle(tester);

      final id = cutList(tester).first.id;
      await tester.drag(
        find.byKey(ValueKey('block-$id')),
        const Offset(0, -MusicTimeline.blockHeight),
      );
      await settle(tester);

      expect(find.textContaining('is a sound layer'), findsOneWidget);
      final layerList = tester
          .widget<MusicTimeline>(find.byType(MusicTimeline))
          .layers;
      expect(layerList[0].clips.single.id, id, reason: 'it stayed where it was');
    });
  });

  group('layer right-click menu', () {
    List<Layer> layersOf(WidgetTester tester) =>
        tester.widget<MusicTimeline>(find.byType(MusicTimeline)).layers;

    Future<void> rightClick(WidgetTester tester, Finder target) async {
      await tester.tap(target, buttons: kSecondaryButton);
      await settle(tester);
    }

    testWidgets('delete removes the layer and what is on it', (tester) async {
      await open(tester);
      await tester.tap(find.byTooltip('New layer'));
      await settle(tester);
      await tester.tap(moment(30.0));
      await tester.pump();
      expect(layersOf(tester)[1].clips, hasLength(1));

      await rightClick(tester, find.byKey(const ValueKey('header-1')));
      await tester.tap(find.text('Delete layer'));
      await settle(tester);

      expect(layersOf(tester), hasLength(1));
      expect(cutList(tester), isEmpty);
    });

    testWidgets('right-clicking a clip offers to delete it', (tester) async {
      await open(tester);
      await tester.tap(moment(30.0));
      await tester.pump();

      await rightClick(tester, block(tester, 0));
      expect(find.text('Move to layer above'), findsOneWidget);
      await tester.tap(find.byKey(const Key('clip-menu-delete')));
      await settle(tester);

      expect(cutList(tester), isEmpty);
    });

    testWidgets('the last layer cannot be deleted', (tester) async {
      await open(tester);
      await rightClick(tester, find.byKey(const ValueKey('header-0')));

      final item = tester.widget<PopupMenuItem<String>>(
        find.byKey(const Key('layer-menu-delete')),
      );
      expect(item.enabled, isFalse);
    });

    testWidgets('rename asks for the name', (tester) async {
      await open(tester);
      await rightClick(tester, find.byKey(const ValueKey('header-0')));
      await tester.tap(find.text('Rename…'));
      await settle(tester);

      await tester.enterText(find.byKey(const Key('layer-name')), 'Kills');
      await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
      await settle(tester);

      expect(layersOf(tester).single.name, 'Kills');
    });

    testWidgets('right-clicking the empty track opens the same menu', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(find.byTooltip('New layer'));
      await settle(tester);

      // the lower track (layer 0) is the second row, from the top
      final ruler = tester.getTopLeft(find.byType(MusicTimeline));
      await tester.tapAt(
        ruler +
            const Offset(
              MusicTimeline.headerWidth + 400,
              MusicTimeline.waveHeight + MusicTimeline.blockHeight * 1.5,
            ),
        buttons: kSecondaryButton,
      );
      await settle(tester);
      await tester.tap(find.text('Move layer up'));
      await settle(tester);

      // the new layer was on top; now the first one is
      expect(layersOf(tester).first.name, 'Layer 2');
    });
  });

  // ── the keyboard and the text fields ──────────────────────────────────────
  //
  // Shortcuts are single keys: "S" splits the cut, Delete deletes the block.
  // Over a text field that is a disaster — it is what showed up when renaming the
  // montage: the name did not get the "s" and deleting ate a block off the ruler.

  group('shortcuts and text fields', () {
    /// Puts the playhead in the middle of the first block, where splitting works.
    Future<void> withOneBlockAndCursorInside(WidgetTester tester) async {
      await open(tester);
      await tester.tap(moment(30.0));
      await tester.pump();
      await cursorAt(tester, 0.6);
    }

    testWidgets('with focus on the ruler, "S" keeps splitting', (tester) async {
      await withOneBlockAndCursorInside(tester);
      expect(cutList(tester), hasLength(1));

      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.pump();

      expect(cutList(tester), hasLength(2));
    });

    /// The shortcuts registered right now.
    ///
    /// A shortcut that "handles" the key while doing nothing is worse than none:
    /// `CallbackShortcuts` marks the key as handled as soon as some shortcut
    /// accepts it, and in the browser a handled key becomes `preventDefault` — the
    /// letter does not reach the field. That is why the fix is to **register no**
    /// shortcut while someone is typing.
    Map<ShortcutActivator, VoidCallback> shortcuts(WidgetTester tester) => tester
        .widget<CallbackShortcuts>(find.byType(CallbackShortcuts))
        .bindings;

    testWidgets('typing in the video name, "S" is the letter s', (tester) async {
      await withOneBlockAndCursorInside(tester);
      expect(shortcuts(tester), isNotEmpty);

      final inputField = find.widgetWithText(TextField, 'My montage');
      await tester.tap(inputField);
      await settle(tester);

      expect(shortcuts(tester), isEmpty, reason: 'the key goes to the field');

      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.pump();
      expect(cutList(tester), hasLength(1), reason: 'nothing was split');
    });

    testWidgets('tapping the ruler gives back the shortcuts', (tester) async {
      // without this, tapping the field once killed the shortcuts for good: nothing
      // takes the focus away from a `TextField`, and "S" never split anything again
      await withOneBlockAndCursorInside(tester);
      await tester.tap(find.widgetWithText(TextField, 'My montage'));
      await settle(tester);
      expect(shortcuts(tester), isEmpty);

      await cursorAt(tester, 0.6);
      await settle(tester);

      expect(shortcuts(tester), isNotEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.pump();
      expect(cutList(tester), hasLength(2), reason: '"S" splits again');
    });

    testWidgets('typing in the video name, delete does not eat a block', (
      tester,
    ) async {
      await withOneBlockAndCursorInside(tester);
      final inputField = find.widgetWithText(TextField, 'My montage');
      await tester.tap(inputField);
      await settle(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();

      expect(cutList(tester), hasLength(1));
    });

    testWidgets('not even Ctrl+Z undoes the montage while typing', (
      tester,
    ) async {
      // the field has its own undo, and that is the one the person wants there
      await withOneBlockAndCursorInside(tester);
      final inputField = find.widgetWithText(TextField, 'My montage');
      await tester.tap(inputField);
      await settle(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(cutList(tester), hasLength(1), reason: 'the block is still there');
    });

    testWidgets('the rename dialog gets what is typed', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final job = Job.fromJson({
        ...jobJson(),
        'montages': [
          {
            'id': 'm1',
            'job_id': 'j1',
            'name': 'short vertical',
            'n_clips': 1,
            'duration_s': 2.0,
            'has_music': false,
            'n_versions': 0,
            'created_at': DateTime.now().toIso8601String(),
            'updated_at': DateTime.now().toIso8601String(),
            'data': {
              'layers': [
                {
                  'clips': [
                    {'at_s': 0.0, 'duration_s': 2.0, 'start_s': 30.0},
                  ],
                },
              ],
            },
          },
        ],
      });
      await tester.pumpWidget(MaterialApp(home: TimelineScreen(job: job)));
      await tester.pump();

      await tester.tap(find.byKey(const Key('screen-menu')));
      await settle(tester);
      await tester.tap(find.text('Rename'));
      await settle(tester);

      final inDialog = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      expect(inDialog, findsOneWidget);

      await tester.enterText(inDialog, 'shorts');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();

      // delete deletes a letter of the name — and not a block off the ruler, which is what
      // happened when the screen shortcuts reached whoever was typing
      expect(tester.widget<TextField>(inDialog).controller?.text, 'short');
      expect(cutList(tester), hasLength(1));
    });
  });

  // ── aligning the play ─────────────────────────────────────────────────────
  //
  // The block is a span; the play is an instant inside it, marked on the ruler.
  // Aligning by the edge would leave the impact half a second after the beat.

  group('aligning the play to the cursor', () {
    testWidgets('the button brings the play under the playhead', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(moment(30.0));
      await tester.pump();
      final beforeState = cutList(tester).single;
      expect(momentInVideo(beforeState), isNotNull);

      // stop the playhead on the beat, select the block, align
      await cursorAt(tester, 4);
      await tester.tap(block(tester, 0));
      await tester.pump();
      await tester.tap(find.byKey(const Key('align-moment')));
      await settle(tester);

      final afterState = cutList(tester).single;
      expect(momentInVideo(afterState), closeTo(4.0, 0.2));
      expect(afterState.durationS, beforeState.durationS, reason: 'neither stretches nor trims');
    });

    testWidgets('without a selection, the block under the playhead counts', (
      tester,
    ) async {
      // with nothing selected, M acts on the block under the playhead —
      // selecting it first would be the same gesture twice
      await open(tester);
      await tester.tap(moment(30.0));
      await tester.pump();
      await cursorAt(tester, 0.9); // inside the block, which starts at 0
      // the time strip keeps the selection (keyframing needs it); Esc clears it
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(
        find.byKey(const Key('align-moment')),
        findsNothing,
        reason: 'without a selection there is no panel',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await tester.pump();

      expect(momentInVideo(cutList(tester).single), closeTo(0.9, 0.2));
    });

    testWidgets('without a selection, the block under the playhead counts', (
      tester,
    ) async {
      // with nothing selected, M acts on the block under the playhead —
      // selecting it first would be the same gesture twice
      await open(tester);
      await tester.tap(moment(30.0));
      await tester.pump();
      await cursorAt(tester, 0.9); // inside the block, which starts at 0
      // the time strip keeps the selection (keyframing needs it); Esc clears it
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(
        find.byKey(const Key('align-moment')),
        findsNothing,
        reason: 'without a selection there is no panel',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await tester.pump();

      expect(momentInVideo(cutList(tester).single), closeTo(0.9, 0.2));
    });

    testWidgets('the M shortcut does the same', (tester) async {
      await open(tester);
      await tester.tap(moment(30.0));
      await tester.pump();
      await cursorAt(tester, 5);
      await tester.tap(block(tester, 0));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await tester.pump();

      expect(momentInVideo(cutList(tester).single), closeTo(5.0, 0.2));
    });

    testWidgets('with the neighbour back to back, the span slides and the screen says so', (
      tester,
    ) async {
      // in a montage of back-to-back blocks the block has nowhere to go — and
      // silence here would make it look like the command did not work
      await open(tester);
      await tester.tap(moment(30.0));
      await tester.pump();
      await tester.tap(moment(75.0));
      await tester.pump();
      final beforeState = cutList(tester).first;

      await cursorAt(tester, 0.4);
      await tester.tap(block(tester, 0));
      await tester.pump();
      await tester.tap(find.byKey(const Key('align-moment')));
      await settle(tester);

      final afterState = cutList(tester).first;
      expect(momentInVideo(afterState), closeTo(0.4, 0.2));
      expect(afterState.atS, beforeState.atS, reason: 'the block stayed where it was');
      expect(afterState.startS, isNot(beforeState.startS), reason: 'the span moved');
      expect(cutList(tester)[1].atS, 1.2, reason: 'the neighbour did not move');
      expect(find.textContaining('slid'), findsOneWidget);
    });

    testWidgets('a music block has no play to align', (tester) async {
      await open(tester, withMusic: true);
      await tab(tester, 'Library');
      await tester.tap(find.byKey(const ValueKey('media-m1')));
      await settle(tester);
      await tab(tester, 'Moments');

      // the music block stays selected after being placed
      expect(find.byKey(const Key('align-moment')), findsNothing);
    });

    testWidgets('the mark lights up when the play is under the cursor', (
      tester,
    ) async {
      // it is the visual confirmation of the fit: without it, aligning is an act of faith
      await open(tester);
      await tester.tap(moment(30.0));
      await tester.pump();
      await cursorAt(tester, 4);

      bool markLit() {
        final blocks = tester.widgetList<MusicTimeline>(
          find.byType(MusicTimeline),
        );
        return blocks.first.layers.any(
          (l) => l.clips.any(
            (c) =>
                momentInVideo(c) != null &&
                (momentInVideo(c)! - blocks.first.playheadS).abs() < 0.017,
          ),
        );
      }

      expect(markLit(), isFalse);
      await tester.tap(block(tester, 0));
      await tester.pump();
      await tester.tap(find.byKey(const Key('align-moment')));
      await settle(tester);
      expect(markLit(), isTrue);
    });
  });

  group('transitions', () {
    testWidgets('the tab sits in the sidebar, with moments and library', (
      tester,
    ) async {
      await open(tester);

      expect(find.widgetWithText(Tab, 'Moments'), findsOneWidget);
      expect(find.widgetWithText(Tab, 'Library'), findsOneWidget);
      expect(find.widgetWithText(Tab, 'Transitions'), findsOneWidget);
    });

    testWidgets('with no clip selected, there is nothing to apply', (
      tester,
    ) async {
      await open(tester);
      await tab(tester, 'Transitions');

      expect(find.textContaining('Pick a clip'), findsOneWidget);
      final tile = tester.widget<ListTile>(
        find.byKey(const ValueKey('transition-dissolve')),
      );
      expect(tile.enabled, isFalse);
    });

    testWidgets('tapping a transition sets the selected clip\'s entrance', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(moment(30.0));
      await tester.pump();
      final id = firstCut(tester).id;
      await tab(tester, 'Transitions');

      await tester.tap(find.byKey(const ValueKey('transition-fade_black')));
      await tester.pump();

      expect(firstCut(tester).transition?.kind, 'fade_black');
      expect(firstCut(tester).transition?.durationS, 0.5);
      expect(
        find.byKey(ValueKey('transition-on-clip-$id')),
        findsOneWidget,
        reason: 'the ruler shows the clip has an entrance',
      );

      // and the hard cut clears it
      await tester.tap(find.byKey(const Key('no-transition')));
      await tester.pump();
      expect(firstCut(tester).transition, isNull);
      expect(find.byKey(ValueKey('transition-on-clip-$id')), findsNothing);
    });

    testWidgets('setting a transition can be undone', (tester) async {
      await open(tester);
      await tester.tap(moment(30.0));
      await tester.pump();
      await tab(tester, 'Transitions');
      await tester.tap(find.byKey(const ValueKey('transition-dissolve')));
      await tester.pump();
      expect(firstCut(tester).transition, isNotNull);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(firstCut(tester).transition, isNull);
    });

    testWidgets('the monitor marks the transition while it happens', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(moment(30.0));
      await tester.pump();
      await tab(tester, 'Transitions');
      await tester.tap(find.byKey(const ValueKey('transition-fade_white')));
      await tester.pump();
      final c = firstCut(tester);

      await cursorAt(tester, c.atS + 0.1);
      expect(find.byKey(const Key('transition-badge')), findsOneWidget);
      expect(find.byKey(const Key('transition-veil')), findsOneWidget);

      await cursorAt(tester, c.atS + 2);
      expect(find.byKey(const Key('transition-badge')), findsNothing);
    });
  });

  group('composited monitor', () {
    Finder piece(String id) => find.byKey(ValueKey('monitor-piece-$id'));

    testWidgets('under a dissolve both clips are on the monitor', (
      tester,
    ) async {
      // the old monitor had one video: a dissolve was the new clip coming out
      // of black, with the clip before already gone
      await open(tester);
      await tester.tap(moment(30.0));
      await tester.pump();
      await cursorAt(tester, 0);
      await tester.tap(moment(30.0));
      await tester.pump();
      final [a, b] = cutList(tester);
      await tester.tap(block(tester, 1));
      await tester.pump();
      await tab(tester, 'Transitions');
      await tester.tap(find.byKey(const ValueKey('transition-dissolve')));
      await tester.pump();

      await cursorAt(tester, b.atS + 0.1);
      expect(piece(a.id), findsOneWidget);
      expect(piece(b.id), findsOneWidget);

      await cursorAt(tester, b.atS + b.durationS - 0.1);
      expect(piece(a.id), findsNothing);
      expect(piece(b.id), findsOneWidget);
    });

    testWidgets('an upper layer adds to the picture instead of replacing it', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(moment(30.0));
      await tester.pump();
      await tester.tap(find.byTooltip('New layer'));
      await settle(tester);
      await cursorAt(tester, 0);
      await tester.tap(moment(30.0));
      await tester.pump();
      final ids = [for (final c in cutList(tester)) c.id];

      await cursorAt(tester, 0.3);
      for (final id in ids) {
        expect(piece(id), findsOneWidget);
      }
    });
  });

  group('exact preview', () {
    testWidgets('needs something to render', (tester) async {
      await open(tester);
      final button = tester.widget<IconButton>(
        find.byKey(const Key('exact-preview-button')),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('a refused request says so on the monitor', (tester) async {
      // in tests every request answers 400: the failure path is the one
      // that can be walked here
      await open(tester);
      await tester.tap(moment(30.0));
      await tester.pump();

      await tester.tap(find.byKey(const Key('exact-preview-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.textContaining('Exact preview failed'), findsOneWidget);
      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pump();
      expect(find.byKey(const Key('exact-preview-status')), findsNothing);
    });
  });

  group('motion and keyframes', () {
    Future<void> openMotion(WidgetTester tester) async {
      await open(tester);
      await tester.tap(moment(30.0));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('motion-panel')));
      await tester.tap(find.text('Motion'));
      await settle(tester);
    }

    Slider slider(WidgetTester tester, String prop) => tester.widget<Slider>(
      find.byKey(ValueKey('motion-$prop-slider')),
    );

    testWidgets('a static value applies to the whole clip', (tester) async {
      await openMotion(tester);
      slider(tester, 'scale').onChanged!(0.5);
      await tester.pump();
      expect(firstCut(tester).transform.scale, 0.5);
      expect(firstCut(tester).keys, isEmpty);
    });

    testWidgets('animating and adjusting at two instants draws a move', (
      tester,
    ) async {
      await openMotion(tester);
      final c = firstCut(tester);
      await cursorAt(tester, c.atS + 0.1);
      await tester.ensureVisible(
        find.byKey(const ValueKey('motion-opacity-animate')),
      );
      await tester.tap(find.byKey(const ValueKey('motion-opacity-animate')));
      await tester.pump();
      expect(firstCut(tester).keysFor(KeyProp.opacity), hasLength(1));

      await cursorAt(tester, c.atS + c.durationS - 0.1);
      slider(tester, 'opacity').onChanged!(0.2);
      await tester.pump();

      final keys = firstCut(tester).keysFor(KeyProp.opacity);
      expect(keys.map((k) => k.value), [1, 0.2]);
      // the chosen block shows where its motion changes
      expect(
        find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey &&
              '${(w.key as ValueKey).value}'.startsWith('keyframe-'),
        ),
        findsNWidgets(2),
      );
    });

    testWidgets('the time strip moves the playhead and keeps the selection', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(moment(30.0));
      await tester.pump();
      final selection = tester
          .widget<MusicTimeline>(find.byType(MusicTimeline))
          .selectionIds;
      expect(selection, isNotEmpty);

      await cursorAt(tester, 0.5); // the beats band
      expect(
        tester.widget<MusicTimeline>(find.byType(MusicTimeline)).selectionIds,
        selection,
      );

      // an empty spot on a track still clears it
      final ruler = tester.getTopLeft(find.byType(MusicTimeline));
      await tester.tapAt(
        ruler +
            const Offset(
              MusicTimeline.headerWidth + 400,
              MusicTimeline.waveHeight + MusicTimeline.blockHeight / 2,
            ),
      );
      await tester.pump();
      expect(
        tester.widget<MusicTimeline>(find.byType(MusicTimeline)).selectionIds,
        isEmpty,
      );
    });

    testWidgets('a text clip has no Motion panel', (tester) async {
      await open(tester);
      await tester.tap(find.byTooltip('Write on screen'));
      await settle(tester);
      await tester.tap(find.text('Free text'));
      await settle(tester);
      expect(find.byKey(const Key('motion-panel')), findsNothing);
    });
  });

  group('speed ramps', () {
    testWidgets('one button ramps the clip around its play', (tester) async {
      await open(tester);
      await tester.tap(moment(30.0));
      await tester.pump();
      final before = firstCut(tester).durationS;

      await tester.ensureVisible(find.text('Effects'));
      await tester.tap(find.text('Effects'));
      await settle(tester);
      await tester.ensureVisible(find.byKey(const Key('ramp-into-play')));
      await tester.tap(find.byKey(const Key('ramp-into-play')));
      await tester.pump();

      final c = firstCut(tester);
      expect(c.isRamped, isTrue);
      expect(c.durationS, greaterThan(before), reason: 'slow motion is longer');
      // the single speed slider gives way to the ramp, edited in Motion
      expect(find.byKey(const Key('speed-ramped')), findsOneWidget);
      await tester.ensureVisible(find.text('Motion'));
      await tester.tap(find.text('Motion'));
      await settle(tester);
      expect(find.byKey(const ValueKey('motion-speed')), findsOneWidget);
      expect(find.text('1 animated'), findsOneWidget);
    });
  });

  group('cutting, selecting and closing gaps', () {
    List<Layer> layersOf(WidgetTester tester) =>
        tester.widget<MusicTimeline>(find.byType(MusicTimeline)).layers;

    /// A clip on the bottom layer and one on a new top layer, both at 0.
    Future<void> twoLayers(WidgetTester tester) async {
      await open(tester);
      await tester.tap(moment(30.0));
      await tester.pump();
      await tester.tap(find.byTooltip('New layer'));
      await settle(tester);
      await cursorAt(tester, 0);
      await tester.tap(moment(30.0));
      await tester.pump();
    }

    testWidgets('S cuts the clip on the active layer, not the bottom one', (
      tester,
    ) async {
      // the bug: the cut always went to the first clip found, on the bottom
      await twoLayers(tester);
      await cursorAt(tester, 0.6);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.pump();

      final layers = layersOf(tester);
      expect(layers[1].clips, hasLength(2), reason: 'the top, active layer');
      expect(layers[0].clips, hasLength(1));
    });

    testWidgets('Shift+S cuts every layer', (tester) async {
      await twoLayers(tester);
      await cursorAt(tester, 0.6);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();

      final layers = layersOf(tester);
      expect(layers[0].clips, hasLength(2));
      expect(layers[1].clips, hasLength(2));
    });

    testWidgets('dragging the mouse on empty tracks selects with a rectangle', (
      tester,
    ) async {
      await twoLayers(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      final ruler = tester.getTopLeft(find.byType(MusicTimeline));
      final mouse = await tester.startGesture(
        ruler +
            const Offset(
              MusicTimeline.headerWidth + 300,
              MusicTimeline.waveHeight + 4,
            ),
        kind: PointerDeviceKind.mouse,
      );
      // up and to the left, over both clips
      for (var i = 0; i < 20; i++) {
        await mouse.moveBy(const Offset(-14, 7));
        await tester.pump();
      }
      expect(find.byKey(const Key('selection-band')), findsOneWidget);
      await mouse.up();
      await tester.pump();

      final selected = tester
          .widget<MusicTimeline>(find.byType(MusicTimeline))
          .selectionIds;
      expect(selected, hasLength(2));
      expect(find.byKey(const Key('selection-band')), findsNothing);
    });

    testWidgets('Shift+Delete removes and closes the gap', (tester) async {
      await open(tester);
      await tester.tap(moment(30.0));
      await tester.pump();
      await tester.tap(moment(30.0));
      await tester.pump();
      final [a, b] = cutList(tester);
      await tester.tap(block(tester, 0));
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();

      expect(cutList(tester).single.id, b.id);
      expect(cutList(tester).single.atS, closeTo(a.atS, 1e-9));
    });

    testWidgets('in insert mode a new clip pushes the others right', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(moment(30.0));
      await tester.pump();
      final first = firstCut(tester);

      await tester.tap(find.byKey(const Key('insert-mode')));
      await tester.pump();
      await cursorAt(tester, 0);
      await tester.tap(moment(30.0));
      await tester.pump();

      final pushed = cutList(tester).firstWhere((c) => c.id == first.id);
      expect(pushed.atS, greaterThan(0));
      expect(cutList(tester).where((c) => c.atS == 0), hasLength(1));
    });
  });

  group('moment hover preview', () {
    Future<TestGesture> mouse(WidgetTester tester) async {
      final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await g.addPointer(location: Offset.zero);
      addTearDown(g.removePointer);
      return g;
    }

    testWidgets('resting the mouse on a moment opens the preview', (
      tester,
    ) async {
      await open(tester);
      final g = await mouse(tester);
      await g.moveTo(tester.getCenter(moment(75.0)));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const Key('moment-preview')), findsOneWidget);
    });

    testWidgets('sweeping past a moment does not open a player', (tester) async {
      // one player per card the mouse crosses would choke the browser
      await open(tester);
      final g = await mouse(tester);
      await g.moveTo(tester.getCenter(moment(75.0)));
      await tester.pump(const Duration(milliseconds: 100));
      await g.moveTo(Offset.zero);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const Key('moment-preview')), findsNothing);
    });

    testWidgets('leaving the moment closes the preview', (tester) async {
      await open(tester);
      final g = await mouse(tester);
      await g.moveTo(tester.getCenter(moment(75.0)));
      await tester.pump(const Duration(milliseconds: 500));
      await g.moveTo(Offset.zero);
      await tester.pump();
      expect(find.byKey(const Key('moment-preview')), findsNothing);
    });
  });
}
