import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart';

void main() {
  group('absoluteUrl', () {
    test('an already absolute URL passes untouched', () {
      const url = 'http://server:8000/api/clips/abc/cuts.zip';
      expect(absoluteUrl(url), url);
      expect(absoluteUrl('https://x.example/y'), 'https://x.example/y');
    });

    test('a relative path gets a scheme', () {
      // This is exactly what broke the download: built with an empty
      // API_BASE, the URL came as "/api/..." — with no scheme, and url_launcher
      // refuses it. `fetch` and the <video> tag resolve it on their own, the
      // launcher does not.
      final resolved = absoluteUrl('/api/jobs/abc/cuts.zip');
      expect(Uri.parse(resolved).hasScheme, isTrue);
      expect(resolved, endsWith('/api/jobs/abc/cuts.zip'));
    });

    test('relative without a leading slash also resolves', () {
      expect(Uri.parse(absoluteUrl('api/health')).hasScheme, isTrue);
    });
  });

  group('JobParams', () {
    test('only carries the analysis parameters', () {
      final json = const JobParams().toJson();
      // no music: it comes in through the library, in the editor
      expect(json.containsKey('music_start_s'), isFalse);
      expect(json.containsKey('montage_loop'), isFalse);
      // and no grouping of moments: that is no longer the analysis' job
      expect(json.containsKey('multikill_min'), isFalse);
      expect(json['ult_negate_window_s'], 6);
    });
  });

  group('Job', () {
    Map<String, dynamic> base(Map<String, dynamic> extra) => {
      'id': 'j1',
      'status': 'ready',
      'created_at': '2024-01-01T00:00:00',
      ...extra,
    };

    test('ready means ready to edit, not finished', () {
      final job = Job.fromJson(base({'n_clips': 0}));
      expect(job.isReady, isTrue);
      expect(job.isAnalyzing, isFalse);
      expect(job.isActive, isFalse);
    });

    test('a request in progress keeps the app polling', () {
      final job = Job.fromJson(base({'has_active_render': true}));
      expect(job.isActive, isTrue);
    });

    test('during the analysis there is nothing to choose yet', () {
      final job = Job.fromJson(base({'status': 'detecting'}));
      expect(job.isAnalyzing, isTrue);
      expect(job.isReady, isFalse);
    });
  });

  group('Clip', () {
    test('without a track the clip declares the original audio', () {
      final c = Clip.fromJson({
        'id': 'c1',
        'kind': 'custom',
        'start_s': 0,
        'end_s': 5,
        'score': 1,
        'meta': {'original_audio': true},
      });
      expect(c.keepsOriginalAudio, isTrue);
      expect(c.musicName, isNull);
    });
  });

  group('ClipTransition', () {
    test('round-trips through the server format', () {
      const c = TimelineClip(
        atS: 0,
        durationS: 2,
        startS: 1,
        transition: ClipTransition(kind: 'dissolve', durationS: 0.8),
      );
      final back = TimelineClip.fromJson(c.toJson());

      expect(back.transition, c.transition);
      expect(back.simple, isFalse, reason: 'a transition needs the graph');
    });

    test('is never sent longer than the clip', () {
      // trimming the clip after setting the transition must not leave the
      // montage impossible to render: the server would refuse it
      const c = TimelineClip(
        atS: 0,
        durationS: 0.4,
        startS: 1,
        transition: ClipTransition(kind: 'fade_black', durationS: 1.5),
      );

      expect((c.toJson()['transition'] as Map)['duration_s'], 0.4);
    });

    test('without a transition, the field is not sent', () {
      const c = TimelineClip(atS: 0, durationS: 1, startS: 0);
      expect(c.toJson().containsKey('transition'), isFalse);
      expect(TimelineClip.fromJson(c.toJson()).transition, isNull);
    });
  });
}
