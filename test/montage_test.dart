import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart';
import 'package:ow_editor/montage.dart';

/// As contas da montagem manual.
///
/// O que se verifica aqui é a promessa da tela: o bloco vai parar onde o
/// usuário mandou, com a duração que ele pediu, e nunca por cima de outro.
void main() {
  TimelineCut corte(double at, double dur, {double t = 10, String kind = 'kill'}) =>
      TimelineCut(
        atS: at,
        durationS: dur,
        startS: t - dur * kMomentAnchor,
        sourceT: t,
        kind: kind,
      );

  group('ímã', () {
    const batidas = [0.0, 0.5, 1.0, 1.5, 2.0];

    test('gruda na batida perto', () {
      expect(snapToBeat(0.53, batidas), 0.5);
      expect(snapToBeat(0.96, batidas), 1.0);
    });

    test('deixa em paz o que está longe de qualquer batida', () {
      // no meio de duas batidas o usuário quis mesmo aquele ponto
      expect(snapToBeat(0.75, batidas), 0.75);
    });

    test('sem batidas não faz nada', () {
      expect(snapToBeat(1.234, const []), 1.234);
    });

    test('o intervalo entre batidas sai da mediana', () {
      // uma batida perdida no começo esticaria a média e faria todo bloco
      // sugerido nascer com o tamanho errado
      expect(beatIntervalS(const [0.0, 3.0, 3.5, 4.0, 4.5]), 0.5);
    });
  });

  group('enquadramento', () {
    test('o instante cai a 70% do corte', () {
      final c = cutForMoment(
        DetectionEvent(kind: 'kill', t: 100, confidence: 1),
        atS: 0,
        beats: const [0.0, 0.5, 1.0, 1.5],
        beatsPerCut: 2,
      );

      expect(c.durationS, closeTo(1.0, 1e-9));
      // 1s de corte com a kill aos 100s => começa aos 99.3
      expect(c.startS, closeTo(99.3, 1e-9));
      expect(c.sourceT, 100);
    });

    test('a duração nasce em batidas inteiras quando há música', () {
      final c = cutForMoment(
        DetectionEvent(kind: 'sleep', t: 30, confidence: 1),
        atS: 0,
        beats: const [0.0, 0.6, 1.2, 1.8],
        beatsPerCut: 4,
      );
      expect(c.durationS, closeTo(2.4, 1e-9));
    });

    test('um corte não começa antes do início da gravação', () {
      expect(sourceStartFor(0.3, 2.0), 0);
    });

    test('nem passa do fim dela', () {
      // 2s de corte numa gravação de 60s só cabe se começar aos 58
      expect(sourceStartFor(59.9, 2.0, sourceDurationS: 60), closeTo(58, 1e-9));
    });
  });

  group('posicionar sem atropelar', () {
    test('bloco não entra por cima de outro', () {
      final cuts = [corte(0, 2), corte(5, 1)];

      expect(cabe(cuts, 2.0, 1.0), isTrue);
      expect(cabe(cuts, 1.5, 1.0), isFalse);
      expect(cabe(cuts, 4.5, 1.0), isFalse);
      expect(cabe(cuts, -0.1, 1.0), isFalse);
    });

    test('arrastando, o bloco não colide consigo mesmo', () {
      final cuts = [corte(0, 2), corte(5, 1)];
      expect(cabe(cuts, 0.5, 2.0, ignore: 0), isTrue);
    });

    test('mover para lugar ocupado deixa o bloco onde estava', () {
      // empurrar o vizinho moveria um corte que o usuário já tinha encaixado
      final cuts = [corte(0, 2), corte(5, 1)];
      final movido = mover(cuts, 1, 1.0, beats: const [], snap: false);
      expect(movido.atS, 5);
    });

    test('mover com ímã gruda na batida', () {
      final cuts = [corte(0, 1)];
      final movido =
          mover(cuts, 0, 2.05, beats: const [0.0, 1.0, 2.0, 3.0], snap: true);
      expect(movido.atS, 2.0);
    });

    test('quando é o fim que está perto da batida, é ele que manda', () {
      // numa montagem o que se ouve é a troca de cena, e ela acontece no fim
      final cuts = [corte(0, 1.0)];
      final movido = mover(
        cuts,
        0,
        1.9, // fim em 2.9; o começo está a 0.1 da batida 2.0, o fim a 0.1 da 3.0
        beats: const [0.0, 1.0, 2.0, 3.0],
        snap: true,
      );
      expect(movido.untilS, closeTo(3.0, 1e-9));
    });

    test('a próxima vaga é depois do último bloco', () {
      final cuts = [corte(0, 2), corte(2, 1)];
      expect(proximaVaga(cuts, 0.5, 1.0), 3.0);
      expect(proximaVaga(cuts, 4.0, 1.0), 4.0);
    });
  });

  group('duração do bloco', () {
    test('esticar puxa o começo do corte junto', () {
      // pedir "mais tempo" é pedir mais embalo antes da jogada, não a jogada
      // saindo de quadro
      final cuts = [corte(0, 1, t: 10)];
      final maior = redimensionar(cuts, 0, 2.0, beats: const [], snap: false);

      expect(maior.durationS, 2.0);
      expect(maior.startS, closeTo(10 - 2.0 * kMomentAnchor, 1e-9));
      expect(maior.endS, greaterThan(10)); // a jogada continua dentro
    });

    test('esticar até o vizinho encosta nele em vez de recusar', () {
      final cuts = [corte(0, 1), corte(3, 1)];
      final maior = redimensionar(cuts, 0, 5.0, beats: const [], snap: false);
      expect(maior.durationS, closeTo(3.0, 1e-9));
    });

    test('não encolhe abaixo do mínimo visível', () {
      final cuts = [corte(0, 1)];
      final menor = redimensionar(cuts, 0, 0.01, beats: const [], snap: false);
      expect(menor.durationS, kMinCutS);
    });

    test('com ímã, a borda direita gruda na batida', () {
      final cuts = [corte(0, 1)];
      final ajustado = redimensionar(
        cuts,
        0,
        1.45,
        beats: const [0.0, 0.5, 1.0, 1.5],
        snap: true,
      );
      expect(ajustado.durationS, closeTo(1.5, 1e-9));
    });
  });

  group('o que o vídeo vai ter', () {
    test('o buraco entra na duração — ele vira tela preta, não encurtamento', () {
      final cuts = [corte(0, 2), corte(5, 1)];

      expect(duracaoDoVideo(cuts), 6.0);
      expect(duracaoEmPreto(cuts), closeTo(3.0, 1e-9));
    });

    test('blocos encostados não têm preto nenhum', () {
      final cuts = [corte(0, 2), corte(2, 1)];
      expect(duracaoEmPreto(cuts), 0);
    });

    test('montagem vazia não tem duração', () {
      expect(duracaoDoVideo(const []), 0);
    });
  });

  group('o que vai para o servidor', () {
    test('a montagem leva os blocos e a música já enviada', () {
      final json = Montage(
        title: 'Minha montagem',
        trackId: 'abc123',
        musicStartS: 42.5,
        cuts: [corte(0, 1.5, t: 90)],
      ).toJson();

      expect(json['title'], 'Minha montagem');
      expect(json['track_id'], 'abc123');
      expect(json['music_start_s'], 42.5);
      final cuts = json['cuts'] as List;
      expect(cuts, hasLength(1));
      expect((cuts.first as Map)['at_s'], 0);
      expect((cuts.first as Map)['duration_s'], 1.5);
      expect((cuts.first as Map)['source_t'], 90);
      expect((cuts.first as Map)['kind'], 'kill');
    });

    test('sem música o campo nem vai — o vídeo sai com o áudio da partida', () {
      final json = const Montage(cuts: []).toJson();
      expect(json.containsKey('track_id'), isFalse);
    });
  });

  group('Track', () {
    test('lê a análise que o servidor devolveu', () {
      final t = Track.fromJson(const {
        'id': 'm1',
        'status': 'ready',
        'name': 'musica.mp3',
        'duration_s': 180.5,
        'bpm': 128.0,
        'beats': [0.0, 0.47, 0.94],
        'peaks': [0.1, 0.9, 0.5],
        'audio_url': '/api/tracks/m1/audio',
      });

      expect(t.isReady, isTrue);
      expect(t.beats, hasLength(3));
      expect(t.peaks, hasLength(3));
      expect(Uri.parse(t.audioUrl).hasScheme, isTrue);
    });

    test('música que o servidor não conseguiu ouvir se anuncia', () {
      final t = Track.fromJson(const {
        'id': 'm2',
        'status': 'failed',
        'name': 'quebrada.mp3',
        'error': 'ffmpeg nao decodificou a musica',
        'audio_url': '/api/tracks/m2/audio',
      });

      expect(t.isFailed, isTrue);
      expect(t.error, isNotNull);
      expect(t.beats, isEmpty);
    });
  });
}
