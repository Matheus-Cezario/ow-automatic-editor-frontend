import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart';
import 'package:ow_editor/montage_state.dart';
import 'package:ow_editor/screens/timeline_screen.dart';
import 'package:ow_editor/subtitles.dart';
import 'package:ow_editor/widgets/music_timeline.dart';

import 'timeline_screen_test.dart' show jobJson;

/// Subtitles: the files they come in and go out as, and the layer they live
/// on in the montage.
void main() {
  group('reading', () {
    test('an .srt, with what Windows and players put in it', () {
      const srt =
          '﻿1\r\n'
          '00:00:01,500 --> 00:00:03,000\r\n'
          '<i>Nice</i> shot!\r\n'
          '\r\n'
          '2\r\n'
          '00:00:04,000 --> 00:00:06,250\r\n'
          '{\\an8}Two lines,\r\n'
          'one cue\r\n'
          '\r\n'
          '3\r\n'
          '01:02:03,004 --> 01:02:04,000\r\n'
          'An hour in\r\n';
      final cues = parseSubtitles(srt);
      expect(cues, hasLength(3));
      expect((cues[0].startS, cues[0].endS, cues[0].text), (1.5, 3.0, 'Nice shot!'));
      expect(cues[1].text, 'Two lines,\none cue');
      expect(cues[1].endS, 6.25);
      expect(cues[2].startS, closeTo(3723.004, 1e-9));
    });

    test('a .vtt, with its header, notes, ids and cue settings', () {
      const vtt =
          'WEBVTT - made by hand\n'
          '\n'
          'NOTE this is not a cue\n'
          '\n'
          'intro\n'
          '00:01.000 --> 00:02.500 align:start line:90%\n'
          '<c.yellow>Here</c> we go &amp; go\n'
          '\n'
          '00:03.000 --> 00:04.000\n'
          '<00:03.500>Karaoke\n';
      final cues = parseSubtitles(vtt);
      expect([for (final c in cues) c.text], ['Here we go & go', 'Karaoke']);
      expect((cues[0].startS, cues[0].endS), (1.0, 2.5));
    });

    test('broken blocks are left out, not the whole file', () {
      const srt =
          '1\n00:00:01,000 --> 00:00:02,000\nfine\n\n'
          '2\nno timing here\n\n'
          '3\n00:00:05,000 --> 00:00:04,000\nends before it starts\n\n'
          '4\n00:00:06,000 --> 00:00:07,000\n\n\n'
          '5\n00:00:03,000 --> 00:00:03,500\nout of order\n';
      final cues = parseSubtitles(srt);
      expect([for (final c in cues) c.text], ['fine', 'out of order']);
    });
  });

  group('writing', () {
    test('an .srt in time order that reads back the same', () {
      final clips = [
        subtitleClip('second', atS: 5, durationS: 1.25),
        subtitleClip('first\nof two lines', atS: 3723.004, durationS: 1),
        subtitleClip('zero', atS: 0, durationS: 2),
      ];
      final srt = writeSrt(clips);
      expect(
        srt.split('\n').take(4).toList(),
        ['1', '00:00:00,000 --> 00:00:02,000', 'zero', ''],
      );
      expect(srt, contains('3\n01:02:03,004 --> 01:02:04,004\nfirst\nof two lines\n'));
      final back = parseSubtitles(srt);
      expect([for (final c in back) c.text], ['zero', 'second', 'first\nof two lines']);
      expect(back[1].endS, 6.25);
    });
  });

  group('the montage', () {
    final cues = [
      const SubtitleCue(1, 3, 'one'),
      // overlaps the next one: cut where it starts
      const SubtitleCue(4, 7, 'two'),
      const SubtitleCue(6, 8, 'three'),
      // left shorter than a block: dropped
      const SubtitleCue(8, 8.1, 'blink'),
    ];

    test('a file goes onto a subtitles layer on top, in its own look', () {
      final base = MontageState.blank();
      final s = putSubtitles(base, cues);
      expect(s.layers, hasLength(base.layers.length + 1));
      final layer = s.layers.last;
      expect(layer.name, kSubtitlesLayerName);
      expect(
        [for (final c in layer.clips) (c.text, c.atS, c.untilS)],
        [('one', 1.0, 3.0), ('two', 4.0, 6.0), ('three', 6.0, 8.0)],
      );
      final c = layer.clips.first;
      expect(c.isText, isTrue);
      expect(c.kind, kSubtitleKind);
      expect(c.textStyle.box, 'black');
      expect(c.textStyle.width, kSubtitleStyle.width);
      expect(c.transform.y, kSubtitleY);
      final json = c.toJson();
      expect(json['kind'], 'subtitle');
      expect((json['text_style'] as Map)['box'], 'black');
    });

    test('importing again replaces the subtitles, on the same layer', () {
      var s = putSubtitles(MontageState.blank(), cues);
      final layers = s.layers.length;
      s = putSubtitles(s, [const SubtitleCue(0, 1, 'fixed')]);
      expect(s.layers, hasLength(layers));
      expect([for (final c in subtitlesOf(s)) c.text], ['fixed']);
    });

    test('an offset moves every cue, and nothing goes before the start', () {
      final s = putSubtitles(MontageState.blank(), [
        const SubtitleCue(0.5, 2, 'early'),
        const SubtitleCue(3, 4, 'later'),
      ], offsetS: -1);
      expect(
        [for (final c in subtitlesOf(s)) (c.atS, c.untilS)],
        [(0.0, 1.0), (2.0, 3.0)],
      );
    });

    test('a subtitle at the playhead takes the next free stretch', () {
      var s = putSubtitles(MontageState.blank(), [const SubtitleCue(1, 3, 'x')]);
      s = addSubtitle(s, 2);
      final added = s.clipItem(s.selectionIds.single)!;
      expect(added.atS, 3);
      expect(added.durationS, kSubtitleDuration);
      expect(added.kind, kSubtitleKind);
      expect(s.layers.where((l) => l.name == kSubtitlesLayerName), hasLength(1));
    });

    test('a subtitle moved to another layer is still a subtitle', () {
      var s = putSubtitles(MontageState.blank(), [const SubtitleCue(1, 3, 'x')]);
      final id = s.layers.last.clips.single.id;
      s = moveToLayer(s, id, 0);
      expect(s.layers.first.clips.map((c) => c.id), [id]);
      expect([for (final c in subtitlesOf(s)) c.text], ['x']);
    });
  });

  group('the screen', () {
    testWidgets('the text menu writes a subtitle on a subtitles layer', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1000, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: TimelineScreen(job: Job.fromJson(jobJson()), api: _FakeApi()),
        ),
      );
      await tester.pump();

      List<Layer> layers() =>
          tester.widget<MusicTimeline>(find.byType(MusicTimeline)).layers;
      final before = layers().length;

      await tester.tap(find.byTooltip('Write on screen'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('menu-subtitle')));
      await tester.pumpAndSettle();

      final after = layers();
      expect(after, hasLength(before + 1));
      expect(after.last.name, kSubtitlesLayerName);
      final clip = after.last.clips.single;
      expect(clip.kind, kSubtitleKind);
      expect(clip.atS, 0, reason: 'at the playhead, which has not moved');
    });

    testWidgets('downloading with no subtitles says so', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: TimelineScreen(job: Job.fromJson(jobJson()), api: _FakeApi()),
        ),
      );
      await tester.pump();
      await tester.tap(find.byTooltip('Write on screen'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('menu-download-subtitles')));
      await tester.pump();
      expect(
        find.text('There are no subtitles in this montage yet.'),
        findsOneWidget,
      );
    });
  });
}

class _FakeApi extends ApiClient {
  @override
  Future<void> requestFrames(String jobId) async {}
}
