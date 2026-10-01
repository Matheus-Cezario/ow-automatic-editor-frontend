import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart';

void main() {
  group('absoluteUrl', () {
    test('URL já absoluta passa intacta', () {
      const url = 'http://servidor:8000/api/clips/abc/cortes.zip';
      expect(absoluteUrl(url), url);
      expect(absoluteUrl('https://x.exemplo/y'), 'https://x.exemplo/y');
    });

    test('caminho relativo ganha esquema', () {
      // Foi exatamente isto que quebrou o download: compilado com API_BASE
      // vazio, a URL vinha como "/api/..." — sem esquema, e o url_launcher
      // recusa. `fetch` e a tag <video> resolvem sozinhos, o launcher não.
      final resolvida = absoluteUrl('/api/jobs/abc/cortes.zip');
      expect(Uri.parse(resolvida).hasScheme, isTrue);
      expect(resolvida, endsWith('/api/jobs/abc/cortes.zip'));
    });

    test('relativo sem barra inicial também resolve', () {
      expect(Uri.parse(absoluteUrl('api/health')).hasScheme, isTrue);
    });
  });

  group('JobParams', () {
    test('só carrega os parâmetros da análise', () {
      final json = const JobParams().toJson();
      // nada de música: ela entra pela biblioteca, no editor
      expect(json.containsKey('music_start_s'), isFalse);
      expect(json.containsKey('montage_loop'), isFalse);
      // e nada de agrupar momentos: isso deixou de ser trabalho da análise
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

    test('ready significa pronto para editar, não terminado', () {
      final job = Job.fromJson(base({'n_clips': 0}));
      expect(job.isReady, isTrue);
      expect(job.isAnalyzing, isFalse);
      expect(job.isActive, isFalse);
    });

    test('um pedido em andamento mantém o app consultando', () {
      final job = Job.fromJson(base({'has_active_render': true}));
      expect(job.isActive, isTrue);
    });

    test('durante a análise ainda não há o que escolher', () {
      final job = Job.fromJson(base({'status': 'detecting'}));
      expect(job.isAnalyzing, isTrue);
      expect(job.isReady, isFalse);
    });
  });

  group('Clip', () {
    test('sem trilha o clipe declara o áudio original', () {
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
      expect(back.simples, isFalse, reason: 'a transition needs the graph');
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
