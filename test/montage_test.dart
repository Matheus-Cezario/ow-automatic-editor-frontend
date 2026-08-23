import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart';
import 'package:ow_editor/montage.dart';

/// As contas da montagem manual.
///
/// O que se verifica aqui é a promessa da tela: o bloco vai parar onde o
/// usuário mandou, com a duração que ele pediu, e nunca por cima de outro.
void main() {
  TimelineClip corte(
    double at,
    double dur, {
    double t = 10,
    String kind = 'kill',
  }) => TimelineClip(
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

    test('a borda que não gruda não ganha da que grudou', () {
      // efeito escondido de comparar as duas distâncias direto: a borda que não
      // grudou fica onde o dedo largou, distância zero, e ganhava sempre — o
      // ímã sumia para todo bloco cuja duração não fosse múltipla do compasso
      final cortes = [corte(0, 1.2, t: 10)];
      final movido = mover(cortes, 0, 1.55, beats: batidas, snap: true);

      expect(movido.atS, closeTo(1.5, 1e-9));
    });

    test('quando as duas bordas grudam, vale a mais perto', () {
      // um bloco de duração redonda tem as duas na mesma batida; o desempate só
      // aparece quando elas discordam
      final cortes = [corte(0, 1.0, t: 10)];
      final movido = mover(cortes, 0, 0.94, beats: batidas, snap: true);

      expect(movido.atS, closeTo(1.0, 1e-9));
    });

    test('o intervalo entre batidas sai da mediana', () {
      // uma batida perdida no começo esticaria a média e faria todo bloco
      // sugerido nascer com o tamanho errado
      expect(beatIntervalS(const [0.0, 3.0, 3.5, 4.0, 4.5]), 0.5);
    });
  });

  group('grade de batidas ajustável', () {
    const grade = [0.0, 0.5, 1.0, 1.5, 2.0];

    test('sem ajuste, é a grade que veio do servidor', () {
      expect(gradeAjustada(grade), grade);
    });

    test('dobrar a densidade põe uma batida entre cada par', () {
      // o detector às vezes conta metade das batidas de uma música rápida
      expect(gradeAjustada(grade, multiplicador: 2), [
        0.0,
        0.25,
        0.5,
        0.75,
        1.0,
        1.25,
        1.5,
        1.75,
        2.0,
      ]);
    });

    test('reduzir à metade fica de duas em duas', () {
      expect(gradeAjustada(grade, multiplicador: 0.5), [0.0, 1.0, 2.0]);
    });

    test('o deslocamento conserta o contratempo de uma vez', () {
      // meio tempo adiantada é o erro clássico, e não se conserta arrastando
      // bloco por bloco: quem está errada é a régua
      expect(gradeAjustada(grade, offsetS: 0.25), [
        0.25,
        0.75,
        1.25,
        1.75,
        2.25,
      ]);
    });

    test('deslocar para trás não inventa batida antes do começo', () {
      // 0.0 e 0.5 saem (virariam -0.7 e -0.2); 1.0 vira 0.3 e fica
      final atrasada = gradeAjustada(grade, offsetS: -0.7);
      expect(atrasada, hasLength(3));
      expect(atrasada.first, closeTo(0.3, 1e-9));
      expect(atrasada.every((b) => b >= 0), isTrue);
    });

    test('o compasso deixa só o tempo forte', () {
      expect(gradeAjustada(grade, compasso: 4), [0.0, 2.0]);
    });

    test('os ajustes se somam, na ordem que importa', () {
      // densidade primeiro, depois compasso, depois deslocamento: pedir o tempo
      // forte de uma grade dobrada tem de dar o mesmo lugar de antes
      expect(
        gradeAjustada(grade, multiplicador: 2, compasso: 2, offsetS: 0.1),
        [0.1, 0.6, 1.1, 1.6, 2.1],
      );
    });

    test('grade vazia continua vazia', () {
      expect(gradeAjustada(const [], multiplicador: 2), isEmpty);
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
      final movido = mover(
        cuts,
        0,
        2.05,
        beats: const [0.0, 1.0, 2.0, 3.0],
        snap: true,
      );
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

  group('esticar pela borda direita', () {
    test('cresce o rabo: o começo do corte não se move', () {
      // se o conteúdo se reenquadrasse a cada pixel, a imagem escorregaria
      // debaixo do dedo — o reenquadramento é outro controle
      final cuts = [corte(0, 1, t: 10)];
      final maior = esticar(cuts, 0, 2.0, beats: const [], snap: false);

      expect(maior.durationS, 2.0);
      expect(maior.startS, cuts[0].startS);
      expect(maior.atS, 0);
    });

    test('encosta no vizinho em vez de recusar', () {
      final cuts = [corte(0, 1), corte(3, 1)];
      final maior = esticar(cuts, 0, 5.0, beats: const [], snap: false);
      expect(maior.durationS, closeTo(3.0, 1e-9));
    });

    test('não encolhe abaixo do mínimo visível', () {
      final cuts = [corte(0, 1)];
      final menor = esticar(cuts, 0, 0.01, beats: const [], snap: false);
      expect(menor.durationS, kMinCutS);
    });

    test('não estica além do que foi gravado', () {
      // o corte começa aos 9.3s de uma gravação de 10s: sobram 0.7s
      final cuts = [corte(0, 1, t: 10)];
      final maior = esticar(
        cuts,
        0,
        5.0,
        beats: const [],
        snap: false,
        sourceDurationS: 10,
      );
      expect(maior.endS, lessThanOrEqualTo(10.0 + 1e-9));
    });

    test('com ímã, a borda direita gruda na batida', () {
      final cuts = [corte(0, 1)];
      final ajustado = esticar(
        cuts,
        0,
        1.45,
        beats: const [0.0, 0.5, 1.0, 1.5],
        snap: true,
      );
      expect(ajustado.durationS, closeTo(1.5, 1e-9));
    });
  });

  group('aparar pela borda esquerda', () {
    test('come o começo sem mover o que já está enquadrado', () {
      // a borda anda, o conteúdo fica: por isso o início na gravação anda
      // junto, na mesma medida. É o que distingue aparar de mover.
      final cuts = [corte(0, 2, t: 10)];
      final aparado = aparar(cuts, 0, 0.5, beats: const [], snap: false);

      expect(aparado.atS, 0.5);
      expect(aparado.durationS, closeTo(1.5, 1e-9));
      expect(aparado.startS, closeTo(cuts[0].startS + 0.5, 1e-9));
      // o fim, nas duas escalas, não se mexeu
      expect(aparado.untilS, closeTo(2.0, 1e-9));
      expect(aparado.endS, closeTo(cuts[0].endS, 1e-9));
    });

    test('não invade o bloco de trás', () {
      final cuts = [corte(0, 2), corte(2, 2)];
      final aparado = aparar(cuts, 1, 0.5, beats: const [], snap: false);
      expect(aparado.atS, 2.0, reason: 'parou encostado no vizinho');
    });

    test('não puxa o corte para antes do começo da gravação', () {
      // um bloco que começa aos 0.3s da gravação só pode ser aparado 0.3s
      final cuts = [
        TimelineClip(atS: 5, durationS: 2, startS: 0.3, sourceT: 1),
      ];
      final aparado = aparar(cuts, 0, 3.0, beats: const [], snap: false);
      expect(aparado.startS, greaterThanOrEqualTo(0));
      expect(aparado.atS, closeTo(4.7, 1e-9));
    });

    test('sobrar menos que o mínimo não apara nada', () {
      final cuts = [corte(0, 1)];
      final aparado = aparar(cuts, 0, 0.95, beats: const [], snap: false);
      expect(aparado.durationS, 1.0);
    });
  });

  group('a marca do momento dentro do bloco', () {
    test('sai onde a jogada acontece', () {
      // o bloco começa aos 99.3s e a kill é aos 100s: 70% de 1s de corte
      final c = corte(0, 1, t: 100);
      expect(marcaDoMomento(c), closeTo(kMomentAnchor, 1e-9));
    });

    test('anda quando o bloco é aparado pela esquerda', () {
      // Aparar come material *antes* da jogada, então ela fica proporcional-
      // mente mais perto do começo do bloco. O corte de 8,6→10,6 com a kill aos
      // 10s a tem a 70%; aparado um segundo, ele vai de 9,6→10,6 e ela cai a
      // 40%. É por isso que a marca precisa ser desenhada, e não deduzida.
      final cuts = [corte(0, 2, t: 10)];
      final aparado = aparar(cuts, 0, 1.0, beats: const [], snap: false);

      expect(marcaDoMomento(cuts[0]), closeTo(0.7, 1e-9));
      expect(marcaDoMomento(aparado), closeTo(0.4, 1e-9));
    });

    test('some quando o momento fica fora do corte', () {
      // um bloco que não contém o instante não tem o que marcar
      final c = TimelineClip(atS: 0, durationS: 1, startS: 50, sourceT: 10);
      expect(marcaDoMomento(c), isNull);
    });
  });

  group('clipes de mídia', () {
    Media midia({String kind = 'video', double dur = 10}) =>
        Media(id: 'm1', kind: kind, status: 'ready', name: 'x', durationS: dur);

    test('um vídeo longo entra por um pedaço, não inteiro', () {
      final c = clipeDeMidia(midia(dur: 300), atS: 0, beats: const []);
      expect(c.durationS, lessThanOrEqualTo(3.0));
      expect(c.source, 'media');
      expect(c.startS, 0, reason: 'o arquivo começa onde começa');
    });

    test('um item curto manda na duração', () {
      final c = clipeDeMidia(midia(dur: 1.2), atS: 0, beats: const []);
      expect(c.durationS, closeTo(1.2, 1e-9));
    });

    test('com música, a duração cai num número inteiro de batidas', () {
      final c = clipeDeMidia(
        midia(dur: 300),
        atS: 0,
        beats: const [0, 0.5, 1.0, 1.5],
        beatsPerCut: 4,
      );
      expect(c.durationS, closeTo(2.0, 1e-9));
    });

    test('imagem não tem duração própria: a montagem escolhe', () {
      final c = clipeDeMidia(
        midia(kind: 'image', dur: 0),
        atS: 0,
        beats: const [],
      );
      expect(c.durationS, greaterThan(0));
      expect(c.kind, 'image');
    });

    test('copyWith não perde a fonte nem a transformação', () {
      // o copyWith é usado em toda operação de estado; perder a fonte aqui
      // transformaria um clipe de mídia num trecho da gravação, em silêncio
      const c = TimelineClip(
        atS: 0,
        durationS: 1,
        startS: 0,
        source: 'media',
        mediaId: 'm1',
        transform: ClipTransform(scale: 0.5),
      );

      final movido = c.copyWith(atS: 5);

      expect(movido.source, 'media');
      expect(movido.mediaId, 'm1');
      expect(movido.transform.scale, 0.5);
    });

    test('o que vai para o servidor traz o id da mídia', () {
      const c = TimelineClip(
        atS: 0,
        durationS: 1,
        startS: 0,
        source: 'media',
        mediaId: 'm1',
      );
      expect(c.toJson()['media_id'], 'm1');
      // e um clipe da gravação não manda o campo à toa
      expect(
        const TimelineClip(
          atS: 0,
          durationS: 1,
          startS: 0,
        ).toJson().containsKey('media_id'),
        isFalse,
      );
    });
  });

  group('o que o monitor mostra', () {
    test('sobre um bloco, o instante correspondente da gravação', () {
      // bloco que entra aos 2s do vídeo e sai dos 100s da gravação: meio
      // segundo depois de entrar, o monitor tem de estar em 100.5
      final cuts = [
        TimelineClip(atS: 2, durationS: 1.5, startS: 100, sourceT: 100.7),
      ];

      expect(blocoEm(cuts, 2.5), 0);
      expect(origemEm(cuts, 2.5), closeTo(100.5, 1e-9));
    });

    test('no buraco, tela preta', () {
      final cuts = [corte(0, 1), corte(3, 1)];

      expect(blocoEm(cuts, 2.0), isNull);
      expect(origemEm(cuts, 2.0), isNull);
    });

    test('depois do último bloco também é preto', () {
      expect(origemEm([corte(0, 1)], 5.0), isNull);
    });

    test('a borda do bloco pertence a ele; a do fim, não', () {
      final cuts = [corte(0, 1)];
      expect(blocoEm(cuts, 0.0), 0);
      expect(blocoEm(cuts, 1.0), isNull);
    });
  });

  group('o que o vídeo vai ter', () {
    test(
      'o buraco entra na duração — ele vira tela preta, não encurtamento',
      () {
        final cuts = [corte(0, 2), corte(5, 1)];

        expect(duracaoDoVideo(cuts), 6.0);
        expect(duracaoEmPreto(cuts), closeTo(3.0, 1e-9));
      },
    );

    test('blocos encostados não têm preto nenhum', () {
      final cuts = [corte(0, 2), corte(2, 1)];
      expect(duracaoEmPreto(cuts), 0);
    });

    test('montagem vazia não tem duração', () {
      expect(duracaoDoVideo(const []), 0);
    });
  });

  group('o que vai para o servidor', () {
    test('a montagem leva os blocos', () {
      final json = Montage(
        title: 'Minha montagem',
        layers: [
          Layer(clips: [corte(0, 1.5, t: 90)]),
        ],
      ).toJson();

      expect(json['title'], 'Minha montagem');
      final camadas = json['layers'] as List;
      expect(camadas, hasLength(1));
      final clips = (camadas.first as Map)['clips'] as List;
      expect(clips, hasLength(1));
      expect((clips.first as Map)['at_s'], 0);
      expect((clips.first as Map)['duration_s'], 1.5);
      expect((clips.first as Map)['source_t'], 90);
      expect((clips.first as Map)['kind'], 'kill');
      expect((clips.first as Map)['source'], 'recording');
      // transformação e som neutros não vão: o servidor os assume
      expect((clips.first as Map).containsKey('transform'), isFalse);
    });

    test('a faixa contínua nunca mais é escrita', () {
      // ela ainda é lida -- vira bloco ao abrir --, e reenviá-la criaria uma
      // segunda música tocando por baixo da que já virou bloco
      final json = const Montage(trackId: 'abc123', musicStartS: 42.5).toJson();
      expect(json.containsKey('track_id'), isFalse);
      expect(json.containsKey('music_start_s'), isFalse);
    });

    test('a camada de som vai marcada, e volta marcada', () {
      // é o que diz ao servidor para não desenhar o bloco: sem a marca, uma
      // música na régua viraria imagem por cima do vídeo
      final json = Montage(
        layers: [
          Layer(clips: [corte(0, 1.5)]),
          Layer(
            kind: 'audio',
            name: 'Música',
            clips: [
              TimelineClip(
                atS: 0,
                durationS: 30,
                startS: 12,
                source: 'media',
                mediaId: 'm1',
              ),
            ],
          ),
        ],
      ).toJson();

      final camadas = json['layers'] as List;
      expect((camadas.first as Map)['kind'], 'video');
      expect((camadas.last as Map)['kind'], 'audio');

      final volta = Montage.fromJson(json);
      expect(volta.layers.last.isAudio, isTrue);
      expect(volta.layers.last.clips.single.mediaId, 'm1');
      expect(volta.layers.last.clips.single.startS, 12);
    });

    test('lê o formato de uma camada só que o app mandava antes', () {
      // um rascunho salvo antes das camadas existirem tem de abrir
      final m = Montage.fromJson(const {
        'title': 'de ontem',
        'music_start_s': 3.0,
        'cuts': [
          {'start_s': 10.0, 'duration_s': 2.0, 'at_s': 0.0, 'kind': 'kill'},
        ],
      });

      expect(m.layers, hasLength(1));
      expect(m.clips, hasLength(1));
      expect(m.clips.first.kind, 'kill');
      expect(m.clips.first.source, 'recording');
      expect(m.musicStartS, 3.0);
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
