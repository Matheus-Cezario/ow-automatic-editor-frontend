import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart';
import 'package:ow_editor/levels.dart';
import 'package:ow_editor/monitor/frame.dart';
import 'package:ow_editor/montage.dart';
import 'package:ow_editor/montage_state.dart';
import 'package:ow_editor/screens/timeline_screen.dart';
import 'package:ow_editor/widgets/music_timeline.dart';
import 'package:ow_editor/widgets/preview_player.dart';

import 'timeline_screen_test.dart' show jobJson;

/// Several matches in one montage: a moment brought from another match is a
/// recording block carrying that match's id.
void main() {
  final kill = DetectionEvent(kind: 'kill', t: 30, confidence: 1);

  group('the block', () {
    test('remembers its match, and says it to the server', () {
      final clip = cutForMoment(
        kill.inMatch('j2'),
        atS: 0,
        beats: const [],
        sourceDurationS: 40,
      );
      expect(clip.jobId, 'j2');
      expect(clip.toJson()['job_id'], 'j2');
      expect(TimelineClip.fromJson(clip.toJson()).jobId, 'j2');
      // this match's own blocks say nothing
      final own = cutForMoment(kill, atS: 0, beats: const []);
      expect(own.jobId, isNull);
      expect(own.toJson().containsKey('job_id'), isFalse);
    });

    test('the same play in two matches is two moments', () {
      expect(
        momentKey('kill', 30, jobId: 'j2'),
        isNot(momentKey('kill', 30)),
      );
    });
  });

  group('the monitor and the meter', () {
    final layers = [
      Layer(
        clips: [
          const TimelineClip(id: 'a', atS: 0, durationS: 2, startS: 10),
          const TimelineClip(
            id: 'b',
            atS: 2,
            durationS: 2,
            startS: 20,
            jobId: 'j2',
          ),
        ],
      ),
    ];

    test('a brought moment plays the other match', () {
      String? urlAt(double t, {Map<String, String> others = const {}}) =>
          frameAt(layers, t, matchUrl: 'own', otherMatches: others)
              .pieces
              .firstOrNull
              ?.url;
      expect(urlAt(1, others: {'j2': 'other'}), 'own');
      expect(urlAt(3, others: {'j2': 'other'}), 'other');
      // not loaded yet: dark, rather than this match pretending to be it
      expect(urlAt(3), isNull);
    });

    test('and is heard with the other match\'s sound', () {
      final s = MontageState.blank().copyWith(layers: layers);
      double at(double t) => mixLevelAt(
        s,
        t,
        tracks: const {},
        matchWave: [for (var i = 0; i < 100; i++) 0.2],
        matchDurationS: 100,
        otherMatches: {
          'j2': ([for (var i = 0; i < 100; i++) 0.8], 100.0),
        },
      );
      expect(at(1), closeTo(0.2, 1e-9));
      expect(at(3), closeTo(0.8, 1e-9));
    });
  });

  group('the screen', () {
    testWidgets('picks another match and brings its moment in', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _FakeApi();
      await tester.pumpWidget(
        MaterialApp(
          home: TimelineScreen(job: Job.fromJson(jobJson()), api: api),
        ),
      );
      await tester.pump();
      await tester.pump();

      // only the other match that finished its analysis is offered
      await tester.tap(find.byKey(const Key('moments-match')));
      await tester.pumpAndSettle();
      expect(find.text('still.mp4'), findsNothing);
      await tester.tap(find.text('sigma.mp4').last);
      await tester.pump();
      await tester.pump();

      final other = find.byKey(
        ValueKey('moment-${momentKey('kill', 12, jobId: 'j2')}'),
      );
      expect(other, findsOneWidget);
      expect(find.byKey(ValueKey('moment-${momentKey('kill', 30)}')),
          findsNothing, reason: 'the shelf shows the chosen match only');

      await tester.tap(other);
      await tester.pump();

      final clips = [
        for (final l
            in tester.widget<MusicTimeline>(find.byType(MusicTimeline)).layers)
          ...l.clips,
      ];
      final brought = clips.single;
      expect(brought.jobId, 'j2');
      expect(brought.sourceT, 12);
      // cut from inside the other recording, which is only 20 s long
      expect(brought.startS + brought.durationS, lessThanOrEqualTo(20));
      // the monitor plays it from the other match's proxy
      final monitor = tester.widget<PreviewPlayer>(find.byType(PreviewPlayer));
      expect(monitor.otherMatches.keys, ['j2']);
      expect(monitor.otherMatches['j2'], endsWith('/api/jobs/j2/proxy'));
    });
  });
}

Map<String, dynamic> _other(String id, String name, String status) => {
  ...jobJson(),
  'id': id,
  'video_name': name,
  'status': status,
  'duration_s': 20.0,
  'proxy_url': '/api/jobs/$id/proxy',
  'events': [
    {'kind': 'kill', 't': 12.0, 'confidence': 1.0},
  ],
};

class _FakeApi extends ApiClient {
  @override
  Future<List<Job>> listJobs() async => [
    Job.fromJson(jobJson()),
    Job.fromJson(_other('j2', 'sigma.mp4', 'ready')),
    Job.fromJson(_other('j3', 'still.mp4', 'analyzing')),
  ];

  @override
  Future<Job> getJob(String id) async =>
      Job.fromJson(_other(id, 'sigma.mp4', 'ready'));

  @override
  Future<void> requestFrames(String jobId) async {}
}
