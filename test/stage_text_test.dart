import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart';
import 'package:ow_editor/stage_text.dart';

/// The server stores a code and the numbers apart; the sentence is the app's.
void main() {
  Job job(Map<String, dynamic> extra) => Job.fromJson({
    'id': 'j1',
    'status': 'ready',
    'created_at': '2024-01-01T00:00:00',
    ...extra,
  });

  Render render(
    Map<String, dynamic> extra, {
    List<Map<String, dynamic>> clips = const [],
  }) => Render.fromJson({
    'id': 'r1',
    'status': 'done',
    'created_at': '2024-01-01T00:00:00',
    'clips': clips,
    ...extra,
  });

  Map<String, dynamic> clip(String id, {bool video = true}) => {
    'id': id,
    'kind': 'custom',
    'start_s': 0,
    'end_s': 5,
    'score': 1,
    if (video) 'video_url': '/api/clips/$id/video',
    if (!video) 'segments_zip_url': '/api/clips/$id/cuts.zip',
  };

  group('match', () {
    test('a finished analysis says how many moments, from the number', () {
      expect(
        jobStageText(job({'stage': 'ready', 'n_moments': 68})),
        '68 moment(s) found — open the editor',
      );
    });

    test('no moments is said plainly', () {
      expect(
        jobStageText(job({'stage': 'ready', 'n_moments': 0})),
        'no moments found',
      );
    });

    test('an old sentence in stage is never shown for a ready match', () {
      // matches analysed before the codes kept prose there, in Portuguese too
      final j = job({'stage': '68 momento(s) encontrados', 'n_moments': 68});
      expect(jobStageText(j), '68 moment(s) found — open the editor');
    });

    test('while analysing, the code becomes a sentence', () {
      final j = job({'status': 'preprocessing', 'stage': 'cropping'});
      expect(jobStageText(j), 'cropping the HUD regions');
    });

    test('a failure says so, whatever the stage', () {
      expect(
        jobStageText(job({'status': 'failed', 'stage': 'error'})),
        'analysis failed',
      );
    });
  });

  group('request', () {
    test('done counts videos and cuts-only from the clips', () {
      final r = render(
        {'stage': 'done'},
        clips: [clip('a'), clip('b'), clip('c', video: false)],
      );
      expect(renderStageText(r), '2 video(s) ready + 1 with cuts only');
    });

    test('rendering shows the progress, which is a number of its own', () {
      final r = render({
        'status': 'rendering',
        'stage': 'rendering',
        'progress': 0.42,
      });
      expect(renderStageText(r), 'rendering (42%)');
    });
  });
}
