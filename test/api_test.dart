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

  group('ClipOptions', () {
    // A janela de música é por vídeo, não por partida: é assim que dois
    // vídeos da mesma gravação saem com trilhas e durações diferentes.
    test('janela de música só vai no JSON quando o fim é escolhido', () {
      expect(const ClipOptions().toJson().containsKey('music_end_s'), isFalse);
      final comFim = const ClipOptions().copyWith(
        musicEndS: 40,
        musicStartS: 10,
      );
      final json = comFim.toJson();
      expect(json['music_end_s'], 40);
      expect(json['music_start_s'], 10);
    });

    test('dá para limpar o fim escolhido', () {
      final o = const ClipOptions().copyWith(musicEndS: 40);
      expect(o.copyWith(clearMusicEnd: true).musicEndS, isNull);
    });

    test('fim antes do início é apontado como inválido', () {
      expect(const ClipOptions().janelaValida, isTrue);
      final ruim = const ClipOptions().copyWith(musicStartS: 30, musicEndS: 10);
      expect(ruim.janelaValida, isFalse);
    });
  });

  group('JobParams', () {
    test('só carrega os parâmetros da análise', () {
      final json = const JobParams().toJson();
      expect(json.containsKey('music_start_s'), isFalse);
      expect(json.containsKey('montage_loop'), isFalse);
      expect(json['multikill_min'], 3);
    });
  });

  group('Selection', () {
    test('o JSON leva a proposta e as opções, e a música vai à parte', () {
      const sel = Selection(
        proposalId: 'p1',
        options: ClipOptions(montageClipBeats: 4),
      );
      final json = sel.toJson();
      expect(json['proposal_id'], 'p1');
      expect((json['options'] as Map)['montage_clip_beats'], 4);
      // o arquivo em si sobe como campo multipart separado
      expect(json.containsKey('music'), isFalse);
    });
  });

  group('Job', () {
    Map<String, dynamic> base(Map<String, dynamic> extra) => {
      'id': 'j1',
      'status': 'ready',
      'created_at': '2024-01-01T00:00:00',
      ...extra,
    };

    test('ready significa pronto para escolher, não terminado', () {
      final job = Job.fromJson(base({'n_proposals': 3}));
      expect(job.isReady, isTrue);
      expect(job.isAnalyzing, isFalse);
      expect(job.isActive, isFalse);
      expect(job.nProposals, 3);
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
        'kind': 'beat_montage',
        'start_s': 0,
        'end_s': 5,
        'score': 1,
        'meta': {'original_audio': true},
      });
      expect(c.keepsOriginalAudio, isTrue);
      expect(c.musicName, isNull);
    });
  });
}
