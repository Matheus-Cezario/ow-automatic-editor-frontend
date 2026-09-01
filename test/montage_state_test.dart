import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart';
import 'package:ow_editor/montage.dart';
import 'package:ow_editor/montage_state.dart';

/// O estado da montagem e o histórico que o desfaz.
///
/// A conta de *onde* um bloco pode cair está em `montage_test.dart`. Aqui o que
/// se verifica é o que a V1 não tinha: que uma operação devolve um estado novo
/// sem estragar o anterior, e que dá para voltar atrás.
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

  /// Um estado com clipes já identificados, como sai do rascunho.
  MontageState estadoCom(List<TimelineClip> clips) =>
      montagemDoRascunho(Montage(layers: [Layer(clips: clips)]));

  /// Um estado de duas camadas, para o que só camada faz.
  MontageState estadoEmCamadas(
    List<TimelineClip> baixo,
    List<TimelineClip> cima,
  ) => montagemDoRascunho(
    Montage(
      layers: [
        Layer(clips: baixo),
        Layer(name: 'cima', clips: cima),
      ],
    ),
  );

  group('imutabilidade', () {
    test('operar devolve um estado novo e não estraga o anterior', () {
      // é isto que a V1 não fazia: `_cuts` era alterada no lugar, e o "antes"
      // deixava de existir no instante em que o "depois" nascia
      final antes = estadoCom([corte(0, 1)]);
      final id = antes.clips.first.id;

      final depois = moverBloco(antes, id, 5, beats: const [], snap: false);

      expect(depois.clips.first.atS, 5);
      expect(antes.clips.first.atS, 0, reason: 'o estado anterior foi mexido');
      expect(identical(antes, depois), isFalse);
    });

    test('as listas não aceitam alteração por fora', () {
      final s = estadoCom([corte(0, 1)]);
      expect(
        () => s.layers.first.clips.add(corte(2, 1)),
        throwsUnsupportedError,
      );
      expect(() => s.layers.add(const Layer()), throwsUnsupportedError);
      expect(() => s.selecao.add('x'), throwsUnsupportedError);
    });

    test('cada bloco ganha uma identidade ao ser carregado', () {
      final s = estadoCom([corte(0, 1), corte(2, 1)]);
      expect(s.clips[0].id, isNotEmpty);
      expect(s.clips[0].id, isNot(s.clips[1].id));
    });

    test('a identidade não vai para o servidor', () {
      // para o servidor um bloco é um trecho com hora marcada, e mais nada
      final s = estadoCom([corte(0, 1)]);
      final clip = s.paraEnvio().toJson()['layers'][0]['clips'][0] as Map;
      expect(clip.containsKey('id'), isFalse);
    });
  });

  group('correções da grade de batidas', () {
    test('voltam do rascunho e vão de volta para o servidor', () {
      // consertar a grade duas vezes irrita mais do que consertá-la uma
      final s = montagemDoRascunho(
        const Montage(
          layers: [],
          beatOffsetS: 0.12,
          beatMultiplier: 2,
          beatBar: 4,
        ),
      );

      expect(s.beatOffsetS, 0.12);
      expect(s.beatMultiplier, 2);
      expect(s.beatBar, 4);

      final json = s.paraEnvio().toJson();
      expect(json['beat_offset_s'], 0.12);
      expect(json['beat_multiplier'], 2);
      expect(json['beat_bar'], 4);
    });

    test('mudá-las é edição, e edição se desfaz', () {
      // a grade errada faz todo corte grudar no lugar errado; voltar atrás
      // dela tem de ser tão possível quanto voltar atrás de um arrasto
      final h = MontageHistory(estadoCom([corte(0, 1)]));
      h.aplicar(h.atual.copyWith(beatOffsetS: 0.25));

      expect(h.atual.beatOffsetS, 0.25);
      expect(h.desfazer().beatOffsetS, 0);
    });
  });

  group('efeitos', () {
    test('a velocidade muda o que se come da gravação, não o que se vê', () {
      final s = estadoCom([corte(0, 2, t: 10)]);
      final id = s.clips.first.id;

      final lento = ajustarEfeito(s, id, speed: 0.5);

      expect(lento.clips.first.speed, 0.5);
      expect(lento.clips.first.fonteConsumidaS, closeTo(1.0, 1e-9));
      expect(lento.clips.first.durationS, 2.0, reason: 'o bloco não encolheu');
    });

    test('velocidade absurda é aparada em vez de recusada pelo servidor', () {
      final s = estadoCom([corte(0, 1)]);
      final id = s.clips.first.id;

      expect(ajustarEfeito(s, id, speed: 99).clips.first.speed, 10.0);
      expect(ajustarEfeito(s, id, speed: 0.001).clips.first.speed, 0.1);
    });

    test('fades maiores que o clipe são encolhidos, mantendo a proporção', () {
      // o servidor recusaria; descobrir isso só na hora de gerar seria pior
      final s = estadoCom([corte(0, 1)]);
      final id = s.clips.first.id;

      final c = ajustarEfeito(
        s,
        id,
        fade: const ClipFade(inS: 1.0, outS: 3.0),
      ).clips.first;

      expect(c.fade.inS + c.fade.outS, closeTo(1.0, 1e-9));
      expect(c.fade.outS / c.fade.inS, closeTo(3.0, 1e-6));
    });

    test('efeito é edição, e edição se desfaz', () {
      final h = MontageHistory(estadoCom([corte(0, 2)]));
      final id = h.atual.clips.first.id;

      h.aplicar(ajustarEfeito(h.atual, id, speed: 2));

      expect(h.atual.clips.first.speed, 2);
      expect(h.desfazer().clips.first.speed, 1);
    });

    test('o que vai para o servidor só leva o que não é neutro', () {
      final s = estadoCom([corte(0, 2)]);
      final id = s.clips.first.id;
      final limpo = s.paraEnvio().toJson()['layers'][0]['clips'][0] as Map;
      expect(limpo.containsKey('speed'), isFalse);
      expect(limpo.containsKey('fade'), isFalse);

      final comEfeito =
          ajustarEfeito(
                s,
                id,
                speed: 2,
              ).paraEnvio().toJson()['layers'][0]['clips'][0]
              as Map;
      expect(comEfeito['speed'], 2);
    });

    test('a mistura de áudio viaja com a montagem', () {
      final s = estadoCom([
        corte(0, 1),
      ]).copyWith(musicVolume: 0.8, gameVolume: 0.4);
      final json = s.paraEnvio().toJson();

      expect(json['music_volume'], 0.8);
      expect(json['game_volume'], 0.4);
    });
  });

  group('zoom, congelar e inverter', () {
    test('o punch fecha a lente e afrouxa até o fim', () {
      final k = punch(ate: 2.0);

      expect(k, hasLength(3));
      expect(k.first.t, 0);
      expect(k.first.scale, 1, reason: 'começa no tamanho cheio');
      expect(k[1].scale, 2.0, reason: 'o pico é o que se pediu');
      expect(k.last.t, 1);
      expect(k.last.scale, greaterThan(1));
      expect(k.last.scale, lessThan(k[1].scale), reason: 'afrouxa depois');
    });

    test('os pontos estão em ordem — o servidor recusaria fora dela', () {
      final ts = punch().map((k) => k.t).toList();
      expect(ts, orderedEquals([...ts]..sort()));
    });

    test('congelar desliga inverter, e vice-versa', () {
      // o servidor recusa os dois juntos; ligar o segundo quer dizer trocar
      var s = estadoCom([corte(0, 2)]);
      final id = s.clips.first.id;

      s = ajustarEfeito(s, id, freeze: true);
      expect(s.clips.first.freeze, isTrue);

      s = ajustarEfeito(s, id, reverse: true);
      expect(s.clips.first.reverse, isTrue);
      expect(s.clips.first.freeze, isFalse, reason: 'um desligou o outro');
    });

    test('um clipe congelado come um quadro só da gravação', () {
      var s = estadoCom([corte(0, 3, t: 10)]);
      final id = s.clips.first.id;
      s = ajustarEfeito(s, id, freeze: true);

      expect(s.clips.first.fonteConsumidaS, lessThan(0.2));
      expect(s.clips.first.untilS, 3.0, reason: 'mas ocupa o bloco inteiro');
    });

    test('o que vai para o servidor só leva o que está ligado', () {
      var s = estadoCom([corte(0, 2)]);
      final id = s.clips.first.id;
      s = ajustarEfeito(s, id, zoom: punch(), freeze: true);

      final clip = s.paraEnvio().toJson()['layers'][0]['clips'][0] as Map;
      expect((clip['zoom'] as List), hasLength(3));
      expect(clip['freeze'], isTrue);
      expect(clip.containsKey('reverse'), isFalse);
    });
  });

  group('camadas', () {
    test('colisão é por camada: dois clipes no mesmo instante convivem', () {
      // é justamente para isto que camada serve
      final s = estadoEmCamadas([corte(0, 2)], [corte(0, 2)]);

      expect(s.clips, hasLength(2));
      expect(s.layers[0].clips.first.atS, 0);
      expect(s.layers[1].clips.first.atS, 0);
    });

    test('o clipe novo entra na camada ativa', () {
      var s = estadoEmCamadas([corte(0, 1)], []);
      s = s.copyWith(camadaAtiva: 1);
      s = adicionar(s, corte(0, 1), beats: const [], snap: false);

      expect(s.layers[0].clips, hasLength(1));
      expect(s.layers[1].clips, hasLength(1));
      // e não foi empurrado: a camada de cima estava livre naquele instante
      expect(s.layers[1].clips.first.atS, 0);
    });

    test('trocar de camada mantém o instante', () {
      final s = estadoEmCamadas([corte(3, 1)], []);
      final id = s.layers[0].clips.first.id;

      final depois = moverParaCamada(s, id, 1);

      expect(depois.layers[0].clips, isEmpty);
      expect(depois.layers[1].clips.first.atS, 3.0);
      expect(depois.camadaAtiva, 1);
    });

    test('não troca de camada se o lugar estiver ocupado lá', () {
      // empurrar para outro instante seria mudar duas coisas quando se pediu
      // uma
      final s = estadoEmCamadas([corte(0, 2)], [corte(1, 2)]);
      final id = s.layers[0].clips.first.id;

      expect(moverParaCamada(s, id, 1).layers[0].clips, hasLength(1));
    });

    test('a última camada não sai', () {
      // sem camada nenhuma não haveria onde receber o próximo clipe
      final s = estadoCom([corte(0, 1)]);
      expect(removerCamada(s, 0).layers, hasLength(1));
    });

    test('tirar uma camada leva os clipes dela e reancora a ativa', () {
      var s = estadoEmCamadas([corte(0, 1)], [corte(0, 1)]);
      s = s.copyWith(camadaAtiva: 1);

      final depois = removerCamada(s, 1);

      expect(depois.layers, hasLength(1));
      expect(depois.clips, hasLength(1));
      expect(depois.camadaAtiva, 0);
    });

    test('esconder e emudecer não mexem nos clipes', () {
      var s = estadoEmCamadas([corte(0, 1)], [corte(0, 1)]);
      s = ajustarCamada(s, 1, hidden: true, muted: true);

      expect(s.layers[1].hidden, isTrue);
      expect(s.layers[1].muted, isTrue);
      expect(s.clips, hasLength(2), reason: 'os clipes continuam lá');
    });

    test('o monitor mostra a camada de cima onde as duas se cobrem', () {
      // o preview não compõe: ele mostra um quadro, e o que vale é o que o
      // servidor vai desenhar por último
      final s = estadoEmCamadas([corte(0, 4, t: 10)], [corte(1, 1, t: 50)]);

      final visiveis = s.clipesVisiveis;
      expect(visiveis, hasLength(1));
      expect(visiveis.first.sourceT, 50, reason: 'a de baixo foi coberta');
    });

    test('camada escondida não aparece no monitor', () {
      var s = estadoEmCamadas([corte(0, 1, t: 10)], [corte(0, 1, t: 50)]);
      s = ajustarCamada(s, 1, hidden: true);

      expect(s.clipesVisiveis.single.sourceT, 10);
    });

    test('a montagem vai para o servidor em camadas', () {
      final s = estadoEmCamadas([corte(0, 1)], [corte(2, 1)]);
      final camadas = s.paraEnvio().toJson()['layers'] as List;

      expect(camadas, hasLength(2));
      expect(((camadas[0] as Map)['clips'] as List), hasLength(1));
      expect(((camadas[1] as Map)['clips'] as List), hasLength(1));
    });
  });

  group('adicionar e apagar', () {
    test('o bloco novo entra selecionado', () {
      final s = adicionar(
        MontageState.vazio(),
        corte(0, 1),
        beats: const [],
        snap: false,
      );

      expect(s.clips, hasLength(1));
      expect(s.selecao, {s.clips.first.id});
    });

    test('um bloco novo em cima de outro vai para a primeira vaga', () {
      var s = estadoCom([corte(0, 2)]);
      s = adicionar(s, corte(0.5, 1), beats: const [], snap: false);

      expect(s.clips.last.atS, 2.0);
    });

    test('apagar tira só os escolhidos e limpa a seleção', () {
      final s = estadoCom([corte(0, 1), corte(2, 1), corte(4, 1)]);
      final depois = remover(s, {s.clips[1].id});

      expect(depois.clips.map((c) => c.atS), [0.0, 4.0]);
      expect(depois.selecao, isEmpty);
    });
  });

  group('dividir', () {
    test(
      'a emenda é invisível: a segunda metade continua de onde a primeira parou',
      () {
        final s = estadoCom([corte(0, 2, t: 10)]);
        final original = s.clips.first;

        final depois = dividir(s, original.id, 1.2);

        expect(depois.clips, hasLength(2));
        final a = depois.clips[0];
        final b = depois.clips[1];
        expect(a.durationS, closeTo(1.2, 1e-9));
        expect(b.atS, closeTo(1.2, 1e-9));
        expect(b.durationS, closeTo(0.8, 1e-9));
        // o quadro seguinte da gravação, sem salto nem repetição
        expect(b.startS, closeTo(a.endS, 1e-9));
        // e juntas continuam cobrindo exatamente o que o bloco cobria
        expect(b.untilS, closeTo(original.untilS, 1e-9));
      },
    );

    test('a metade nova fica selecionada, para seguir editando', () {
      final s = estadoCom([corte(0, 2)]);
      final depois = dividir(s, s.clips.first.id, 1);
      expect(depois.selecao, {depois.clips[1].id});
    });

    test('não divide se sobrasse um pedaço invisível', () {
      final s = estadoCom([corte(0, 1)]);
      expect(dividir(s, s.clips.first.id, 0.99).clips, hasLength(1));
      expect(dividir(s, s.clips.first.id, 0.01).clips, hasLength(1));
    });

    test('dividir fora do bloco não faz nada', () {
      final s = estadoCom([corte(0, 1)]);
      expect(dividir(s, s.clips.first.id, 5).clips, hasLength(1));
    });
  });

  group('seleção em lote', () {
    test('o grupo anda junto, mantendo a distância entre os blocos', () {
      var s = estadoCom([corte(0, 1), corte(2, 1), corte(10, 1)]);
      s = s.copyWith(selecao: {s.clips[0].id, s.clips[1].id});

      final depois = moverSelecao(s, 3, beats: const [], snap: false);

      expect(depois.clips[0].atS, 3.0);
      expect(depois.clips[1].atS, 5.0);
      expect(
        depois.clips[2].atS,
        10.0,
        reason: 'quem não estava na seleção ficou',
      );
    });

    test('anda junto ou não anda: colidir cancela o movimento inteiro', () {
      // mover metade de uma seleção desmancharia um arranjo já feito
      var s = estadoCom([corte(0, 1), corte(2, 1), corte(4, 1)]);
      s = s.copyWith(selecao: {s.clips[0].id, s.clips[1].id});

      final depois = moverSelecao(s, 2.5, beats: const [], snap: false);

      expect(depois.clips.map((c) => c.atS), [0.0, 2.0, 4.0]);
    });

    test('não empurra o grupo para antes do primeiro quadro', () {
      var s = estadoCom([corte(1, 1), corte(3, 1)]);
      s = s.copyWith(selecao: {for (final c in s.clips) c.id});

      expect(
        moverSelecao(s, -2, beats: const [], snap: false).clips[0].atS,
        1.0,
      );
    });

    test('com ímã, o grupo gruda pela borda do primeiro', () {
      var s = estadoCom([corte(0, 1), corte(2, 1)]);
      s = s.copyWith(selecao: {for (final c in s.clips) c.id});

      final depois = moverSelecao(
        s,
        1.04,
        beats: const [0, 1, 2, 3, 4],
        snap: true,
      );

      expect(depois.clips[0].atS, 1.0);
      expect(depois.clips[1].atS, 3.0, reason: 'a distância se manteve');
    });
  });

  group('duplicar e colar', () {
    test('as cópias vão para depois do fim, com identidade nova', () {
      var s = estadoCom([corte(0, 1), corte(2, 1)]);
      final ids = {for (final c in s.clips) c.id};

      s = duplicar(s, ids);

      expect(s.clips, hasLength(4));
      expect(s.clips[2].atS, 3.0);
      expect(s.clips[3].atS, 5.0, reason: 'o arranjo interno se manteve');
      expect(
        ids.intersection({for (final c in s.clips.skip(2)) c.id}),
        isEmpty,
      );
      expect(s.selecao, {s.clips[2].id, s.clips[3].id});
    });

    test('colar no cursor mantém o arranjo', () {
      final s = estadoCom([corte(0, 1)]);
      final area = [corte(10, 1), corte(12, 2)];

      final depois = colar(s, area, 4);

      expect(depois.clips[1].atS, 4.0);
      expect(depois.clips[2].atS, 6.0);
    });

    test('sem caber no cursor, o grupo inteiro vai para o fim', () {
      // espalhar as cópias pelos buracos seria menos previsível
      final s = estadoCom([corte(0, 5)]);
      final depois = colar(s, [corte(0, 1), corte(2, 1)], 1);

      expect(depois.clips[1].atS, 5.0);
      expect(depois.clips[2].atS, 7.0);
    });

    test('colar nada não muda nada', () {
      final s = estadoCom([corte(0, 1)]);
      expect(colar(s, const [], 3).clips, hasLength(1));
    });
  });

  group('histórico', () {
    test('desfazer volta ao estado anterior; refazer traz de volta', () {
      final h = MontageHistory(estadoCom([corte(0, 1)]));
      final id = h.atual.clips.first.id;

      h.aplicar(moverBloco(h.atual, id, 5, beats: const [], snap: false));
      expect(h.atual.clips.first.atS, 5);

      expect(h.desfazer().clips.first.atS, 0);
      expect(h.refazer().clips.first.atS, 5);
    });

    test('sem nada a desfazer, não estoura nem inventa', () {
      final h = MontageHistory(MontageState.vazio());
      expect(h.podeDesfazer, isFalse);
      expect(h.desfazer().clips, isEmpty);
      expect(h.refazer().clips, isEmpty);
    });

    test('um arrasto inteiro vale um passo só', () {
      // sem agrupar, desfazer andaria um pixel de cada vez
      final h = MontageHistory(estadoCom([corte(0, 1)]));
      final id = h.atual.clips.first.id;

      h.abrirGesto();
      for (final at in [1.0, 2.0, 3.0, 4.0]) {
        h.aplicar(moverBloco(h.atual, id, at, beats: const [], snap: false));
      }
      h.fecharGesto();

      expect(h.atual.clips.first.atS, 4);
      expect(h.desfazer().clips.first.atS, 0);
      expect(h.podeDesfazer, isFalse);
    });

    test('dois arrastos são dois passos', () {
      final h = MontageHistory(estadoCom([corte(0, 1)]));
      final id = h.atual.clips.first.id;

      for (final at in [2.0, 4.0]) {
        h.abrirGesto();
        h.aplicar(moverBloco(h.atual, id, at, beats: const [], snap: false));
        h.fecharGesto();
      }

      expect(h.desfazer().clips.first.atS, 2);
      expect(h.desfazer().clips.first.atS, 0);
    });

    test('editar depois de desfazer descarta o refazer', () {
      final h = MontageHistory(estadoCom([corte(0, 1)]));
      final id = h.atual.clips.first.id;

      h.aplicar(moverBloco(h.atual, id, 5, beats: const [], snap: false));
      h.desfazer();
      h.aplicar(moverBloco(h.atual, id, 9, beats: const [], snap: false));

      expect(h.podeRefazer, isFalse);
      expect(h.atual.clips.first.atS, 9);
    });

    test('selecionar não vira passo de desfazer', () {
      // desfazer tem de voltar uma *edição*, não uma mudança de foco
      final h = MontageHistory(estadoCom([corte(0, 1)]));
      h.substituir(h.atual.copyWith(selecao: {h.atual.clips.first.id}));

      expect(h.podeDesfazer, isFalse);
      expect(h.atual.selecao, hasLength(1));
    });

    test('aplicar o mesmo estado não cria passo', () {
      final h = MontageHistory(estadoCom([corte(0, 1)]));
      h.aplicar(h.atual);
      expect(h.podeDesfazer, isFalse);
    });

    test('o histórico tem teto', () {
      final h = MontageHistory(estadoCom([corte(0, 1)]));
      final id = h.atual.clips.first.id;
      for (var i = 0; i < MontageHistory.maxPassos + 40; i++) {
        h.aplicar(
          moverBloco(
            h.atual,
            id,
            i.toDouble() + 1,
            beats: const [],
            snap: false,
          ),
        );
      }
      var passos = 0;
      while (h.podeDesfazer) {
        h.desfazer();
        passos++;
      }
      expect(passos, MontageHistory.maxPassos);
    });
  });

  group('música na régua', () {
    Track musica({
      String id = 'm1',
      String nome = 'faixa.mp3',
      double duracao = 90,
      String status = 'ready',
    }) => Track(
      id: id,
      status: status,
      name: nome,
      durationS: duracao,
      bpm: 120,
      beats: const [],
      peaks: const [],
      audioUrl: '',
    );

    test('a camada de som não desenha nada', () {
      // é a diferença que justifica o tipo: um bloco de música na camada de
      // cima apagaria o vídeo se o empilhamento visual o considerasse
      final s = porMusica(
        adicionarCamadaDeMusica(estadoCom([corte(0, 2)])),
        musica(),
        atS: 0,
      );

      expect(s.layers.last.isAudio, isTrue);
      expect(s.layers.last.clips, hasLength(1));
      expect(s.clipesVisiveis, hasLength(1));
      expect(s.clipesVisiveis.single.source, isNot('media'));
    });

    test('abrir a camada de som leva o foco para ela', () {
      final s = adicionarCamadaDeMusica(estadoCom([corte(0, 2)]));
      expect(s.camadaAtiva, s.layers.length - 1);
      expect(s.selecao, isEmpty);
    });

    test('pôr música sem camada de som abre uma', () {
      // ninguém deveria ter de preparar o terreno antes de pedir a música
      final s = porMusica(estadoCom([corte(0, 2)]), musica(), atS: 0);

      expect(s.layers, hasLength(2));
      expect(s.layers.last.isAudio, isTrue);
      expect(s.layers.last.clips.single.mediaId, 'm1');
      expect(s.selecao, {s.layers.last.clips.single.id});
    });

    test('a segunda música vai para a mesma camada de som', () {
      var s = porMusica(estadoCom([corte(0, 2)]), musica(), atS: 0);
      s = porMusica(s, musica(id: 'm2'), atS: 200, durationS: 10);

      expect(s.layers, hasLength(2), reason: 'não abriu outra camada');
      expect(s.layers.last.clips, hasLength(2));
      expect(s.layers.last.clips.last.mediaId, 'm2');
    });

    test('sem duração pedida, entra o que sobra da faixa', () {
      final s = porMusica(
        estadoCom([corte(0, 2)]),
        musica(duracao: 90),
        atS: 0,
        startS: 20,
      );

      expect(s.layers.last.clips.single.durationS, 70);
      expect(s.layers.last.clips.single.startS, 20);
    });

    test('a duração pedida não passa do que a faixa tem', () {
      final s = porMusica(
        estadoCom([corte(0, 2)]),
        musica(duracao: 30),
        atS: 0,
        durationS: 500,
      );

      expect(s.layers.last.clips.single.durationS, 30);
    });

    test('onde já há música, a nova entra depois — não empurra ninguém', () {
      // empurrar desalinharia a que já estava encaixada na batida
      var s = porMusica(
        estadoCom([corte(0, 2)]),
        musica(),
        atS: 0,
        durationS: 10,
      );
      s = porMusica(s, musica(id: 'm2'), atS: 5, durationS: 10);

      final blocos = s.layers.last.clips;
      expect(blocos.map((c) => c.atS), [0, 10]);
      expect(blocos.last.mediaId, 'm2');
    });

    test('música que ainda não foi ouvida não entra', () {
      final s = estadoCom([corte(0, 2)]);
      expect(porMusica(s, musica(status: 'pending'), atS: 0), same(s));
    });

    test('a faixa contínua de uma montagem antiga vira bloco ao abrir', () {
      // houve dois jeitos de ter música e sobrou um. Quem converte o formato
      // velho é o código que lê -- e o servidor lê pela mesma regra
      final s = montagemDoRascunho(
        Montage(
          trackId: 'm1',
          musicStartS: 12,
          layers: [
            Layer(clips: [corte(0, 2), corte(2, 3)]),
          ],
        ),
      );

      expect(s.layers, hasLength(2));
      final bloco = s.layers.last.clips.single;
      expect(s.layers.last.isAudio, isTrue);
      expect(bloco.mediaId, 'm1');
      expect(bloco.atS, 0, reason: 'a música entrava com o vídeo');
      expect(bloco.durationS, 5, reason: 'e cobria o vídeo inteiro');
      expect(bloco.startS, 12, reason: 'do mesmo ponto da música');
    });

    test('sem cortes não há vídeo a cobrir, e a faixa antiga se perde', () {
      // um bloco de música sozinho não é montagem nenhuma: o que ele cobriria
      final s = montagemDoRascunho(
        const Montage(trackId: 'm1', musicStartS: 3),
      );
      expect(s.layers.any((l) => l.isAudio), isFalse);
    });

    test('a montagem convertida não manda a faixa de volta', () {
      // mandá-la seria criar uma segunda música: ela já virou bloco
      final s = montagemDoRascunho(
        Montage(
          trackId: 'm1',
          musicStartS: 4,
          layers: [
            Layer(clips: [corte(0, 2)]),
          ],
        ),
      );
      expect(s.paraEnvio().toJson().containsKey('track_id'), isFalse);
    });

    test('som não sobe para camada de imagem', () {
      // as duas coisas não se misturam: o servidor recusaria, e recusar aqui
      // explica melhor
      final s = porMusica(estadoCom([corte(0, 2)]), musica(), atS: 0);
      final bloco = s.layers.last.clips.single.id;
      final video = s.clips.first.id;

      expect(moverParaCamada(s, bloco, 0), same(s));
      expect(moverParaCamada(s, video, 1), same(s));
    });

    test('o bloco de música se move e se apara como qualquer outro', () {
      // é o ponto da fase: depois de posto, ele é um clipe comum
      final s = porMusica(
        estadoCom([corte(0, 20)]),
        musica(),
        atS: 0,
        durationS: 10,
      );
      final id = s.layers.last.clips.single.id;

      final movido = moverBloco(s, id, 4, beats: const [], snap: false);
      expect(movido.layers.last.clips.single.atS, 4);

      final aparado = apararBloco(movido, id, 9, beats: const [], snap: false);
      expect(aparado.layers.last.clips.single.durationS, 5);
    });

    test('desfazer tira a música da régua', () {
      final h = MontageHistory(estadoCom([corte(0, 2)]));
      h.aplicar(porMusica(h.atual, musica(), atS: 0));
      expect(h.atual.layers.last.clips, hasLength(1));

      h.desfazer();
      expect(h.atual.layers.any((l) => l.isAudio), isFalse);
    });
  });

  group('posição no quadro', () {
    test('mover o texto muda o transform, e nada mais', () {
      // é o que o arrasto no monitor faz: a mesma conta do servidor, em
      // fração da metade do quadro
      final s = estadoCom([corte(0, 2)]);
      final id = s.clips.first.id;

      final depois = posicionarNoQuadro(s, id, x: 0.5, y: -0.25);

      expect(depois.clips.first.transform.x, 0.5);
      expect(depois.clips.first.transform.y, -0.25);
      expect(depois.clips.first.transform.scale, 1.0);
      expect(depois.clips.first.atS, 0, reason: 'a posição na régua não muda');
      expect(s.clips.first.transform.x, 0, reason: 'o estado anterior ficou');
    });

    test('não deixa o conteúdo sair do quadro', () {
      // um clipe que não aparece é indistinguível de um que sumiu
      final s = estadoCom([corte(0, 2)]);
      final id = s.clips.first.id;

      final depois = posicionarNoQuadro(s, id, x: 9, y: -9);

      expect(depois.clips.first.transform.x, 1.0);
      expect(depois.clips.first.transform.y, -1.0);
    });

    test('mover um clipe que não existe mais não estoura', () {
      final s = estadoCom([corte(0, 2)]);
      expect(posicionarNoQuadro(s, 'fantasma', x: 0.5), same(s));
    });
  });

  group('ordem das camadas', () {
    test('reordenar troca quem fica por cima', () {
      // a ordem da lista é a ordem em que o servidor desenha: a última ganha
      final s = estadoEmCamadas([corte(0, 2)], [corte(0, 2)]);
      final debaixo = s.layers[0].clips.first.id;

      final depois = reordenarCamadas(s, 0, 1);

      expect(depois.layers[1].clips.first.id, debaixo);
      expect(depois.camadaAtiva, 1, reason: 'o foco segue a camada movida');
      expect(s.layers[0].clips.first.id, debaixo, reason: 'o anterior ficou');
    });

    test('o que o monitor mostra segue a ordem nova', () {
      // dois clipes no mesmo instante: quem aparece é o da camada de cima
      final s = estadoEmCamadas([corte(0, 2)], [corte(0, 2)]);
      final deCima = s.layers[1].clips.first.id;
      expect(s.clipesVisiveis.single.id, deCima);

      final depois = reordenarCamadas(s, 1, 0);
      expect(depois.clipesVisiveis.single.id, isNot(deCima));
    });

    test('índice fora da lista não faz nada', () {
      final s = estadoEmCamadas([corte(0, 2)], [corte(0, 2)]);
      expect(reordenarCamadas(s, 0, 5), same(s));
      expect(reordenarCamadas(s, -1, 0), same(s));
      expect(reordenarCamadas(s, 1, 1), same(s));
    });

    test('reordenar entra no desfazer', () {
      final h = MontageHistory(estadoEmCamadas([corte(0, 2)], [corte(4, 2)]));
      final debaixo = h.atual.layers[0].clips.first.id;

      h.aplicar(reordenarCamadas(h.atual, 0, 1));
      expect(h.atual.layers[1].clips.first.id, debaixo);

      h.desfazer();
      expect(h.atual.layers[0].clips.first.id, debaixo);
    });
  });

  group('alinhar a jogada', () {
    /// Alinha e devolve o estado — a gravação é longa, e cabe deslizar.
    MontageState alinhar(MontageState s, String id, double alvo) =>
        alinharMomento(s, id, alvo, sourceDurationS: 600)!.estado;

    test('o bloco anda para pôr a jogada no ponto pedido', () {
      // é a razão de existir: o corte começa antes da jogada, e mover pela
      // borda deixaria o impacto meio segundo depois da batida
      final s = estadoCom([corte(0, 2, t: 90)]); // jogada a 1,4s do começo
      final id = s.clips.first.id;

      final depois = alinhar(s, id, 5);

      expect(momentoNoVideo(depois.clips.first), closeTo(5, 1e-9));
      expect(depois.clips.first.atS, closeTo(3.6, 1e-9));
      expect(depois.clips.first.durationS, 2, reason: 'não estica nem apara');
      expect(s.clips.first.atS, 0, reason: 'o estado anterior ficou');
    });

    test('encostado no primeiro quadro, o trecho é que desliza', () {
      // pedir a jogada em 0,5s levaria o começo do bloco para -0,9; em vez de
      // parar na borda e não alinhar nada, o trecho anda dentro do bloco
      final s = estadoCom([corte(0, 2, t: 90)]);
      final feito = alinharMomento(
        s,
        s.clips.first.id,
        0.5,
        sourceDurationS: 600,
      )!;

      expect(feito.deslizou, isTrue);
      expect(feito.estado.clips.first.atS, 0);
      expect(momentoNoVideo(feito.estado.clips.first), closeTo(0.5, 1e-9));
    });

    test('com o vizinho no caminho, o trecho desliza dentro do bloco', () {
      // numa montagem de blocos colados o bloco não tem para onde andar; o que
      // sobra é trocar *qual* pedaço da gravação aparece ali, e a jogada vem
      // até o cursor sem tocar em vizinho nenhum
      final s = estadoCom([corte(0, 2, t: 90), corte(2, 2, t: 200)]);
      final id = s.clips.first.id;

      final feito = alinharMomento(s, id, 0.5, sourceDurationS: 600)!;

      expect(feito.deslizou, isTrue);
      expect(feito.estado.clips.first.atS, 0, reason: 'o bloco ficou');
      expect(momentoNoVideo(feito.estado.clips.first), closeTo(0.5, 1e-9));
      expect(feito.estado.clips.first.startS, closeTo(89.5, 1e-9));
      expect(feito.estado.clips[1].atS, 2, reason: 'o vizinho não se mexeu');
    });

    test('andar com o bloco é o caminho preferido', () {
      // ele mantém o embalo: o mesmo trecho da gravação, noutro instante
      final s = estadoCom([corte(0, 2, t: 90)]);
      final feito = alinharMomento(
        s,
        s.clips.first.id,
        5,
        sourceDurationS: 600,
      )!;

      expect(feito.deslizou, isFalse);
      expect(feito.estado.clips.first.startS, s.clips.first.startS);
    });

    test('sem gravação para deslizar, não há alinhamento a fazer', () {
      // a jogada está a 1,4s do começo do bloco e a gravação acaba logo ali
      final s = estadoCom([corte(0, 2, t: 1.4), corte(2, 2, t: 200)]);
      expect(
        alinharMomento(s, s.clips.first.id, 1.9, sourceDurationS: 2.0),
        isNull,
      );
    });

    test('bloco sem jogada não se alinha', () {
      final s = porMusica(
        estadoCom([corte(0, 2)]),
        Track(
          id: 'm1',
          status: 'ready',
          name: 'faixa.mp3',
          durationS: 60,
          bpm: 120,
          beats: const [],
          peaks: const [],
          audioUrl: '',
        ),
        atS: 0,
      );
      final bloco = s.layers.last.clips.single.id;
      expect(alinharMomento(s, bloco, 3, sourceDurationS: 600), isNull);
    });

    test('alinhar entra no desfazer', () {
      final h = MontageHistory(estadoCom([corte(0, 2, t: 90)]));
      final id = h.atual.clips.first.id;

      h.aplicar(alinhar(h.atual, id, 5));
      expect(h.atual.clips.first.atS, closeTo(3.6, 1e-9));

      h.desfazer();
      expect(h.atual.clips.first.atS, 0);
    });
  });
}
