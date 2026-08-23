import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart';
import 'package:ow_editor/montage_state.dart';
import 'package:ow_editor/receita.dart';

/// Uma predefinição não guarda cortes — guarda o **jeito** de cortar. É o que
/// faz a segunda partida custar um clique em vez de meia hora de encaixe.
void main() {
  DetectionEvent ev(String kind, double t) =>
      DetectionEvent(kind: kind, t: t, confidence: 1);

  final partida = [
    ev('kill', 30),
    ev('sleep', 50),
    ev('kill', 75),
    ev('low_hp', 90),
    ev('kill', 120),
  ];

  group('aplicar', () {
    test('só os eventos que a receita pede viram corte', () {
      final s = aplicarReceita(
        const Receita(kinds: ['kill']),
        eventos: partida,
        sourceDurationS: 600,
      );

      expect(s.clips, hasLength(3));
      expect(s.clips.every((c) => c.kind == 'kill'), isTrue);
    });

    test('os cortes saem em fila, na ordem em que aconteceram', () {
      final s = aplicarReceita(
        const Receita(kinds: ['kill'], durationS: 2),
        eventos: partida,
        sourceDurationS: 600,
      );

      expect(s.clips.map((c) => c.atS), [0.0, 2.0, 4.0]);
      expect(s.clips.map((c) => c.sourceT), [30.0, 75.0, 120.0]);
    });

    test('o espaço entre cortes vira tela preta com a música tocando', () {
      final s = aplicarReceita(
        const Receita(kinds: ['kill'], durationS: 2, gapS: 0.5),
        eventos: partida,
        sourceDurationS: 600,
      );

      expect(s.clips.map((c) => c.atS), [0.0, 2.5, 5.0]);
    });

    test('o corte começa antes do momento: ele precisa de embalo', () {
      // sem isso a eliminação aparece no primeiro quadro, antes de o
      // espectador entender o que está vendo
      final s = aplicarReceita(
        const Receita(kinds: ['kill'], leadS: 1.5),
        eventos: partida,
        sourceDurationS: 600,
      );

      expect(s.clips.first.startS, 28.5);
      expect(s.clips.first.sourceT, 30.0);
    });

    test('um momento perto do fim da gravação não pede o que não existe', () {
      final s = aplicarReceita(
        const Receita(kinds: ['kill'], durationS: 4, leadS: 1),
        eventos: [ev('kill', 119)],
        sourceDurationS: 120,
      );

      expect(s.clips.single.startS, 116.0, reason: '120 - 4 de corte');
    });

    test('o limite de cortes é respeitado', () {
      final s = aplicarReceita(
        const Receita(kinds: ['kill'], maxCuts: 2),
        eventos: partida,
        sourceDurationS: 600,
      );

      expect(s.clips, hasLength(2));
    });

    test('a velocidade come mais gravação por corte', () {
      final s = aplicarReceita(
        const Receita(kinds: ['kill'], durationS: 2, speed: 2, leadS: 0),
        eventos: [ev('kill', 3)],
        sourceDurationS: 4,
      );

      // 2s de vídeo a 2x comem 4s de gravação, e só há 4s
      expect(s.clips.single.startS, 0.0);
      expect(s.clips.single.speed, 2.0);
    });
  });

  group('encaixe na batida', () {
    // uma grade de 0,5 s, como uma música de 120 bpm
    final grade = [for (var i = 0; i < 40; i++) i * 0.5];

    test('cada corte vai de uma batida à outra', () {
      final s = aplicarReceita(
        const Receita(kinds: ['kill'], beatsPerCut: 2),
        eventos: partida,
        sourceDurationS: 600,
        batidas: grade,
      );

      expect(s.clips.map((c) => c.atS), [0.0, 1.0, 2.0]);
      expect(s.clips.every((c) => c.durationS == 1.0), isTrue);
    });

    test('a grade manda, e o tamanho pedido é ignorado', () {
      // é o ponto de encaixar no ritmo: o compasso decide, não o cronômetro
      final s = aplicarReceita(
        const Receita(kinds: ['kill'], beatsPerCut: 1, durationS: 7),
        eventos: partida,
        sourceDurationS: 600,
        batidas: grade,
      );

      expect(s.clips.first.durationS, 0.5);
    });

    test('sem batidas, a receita de ritmo cai no tamanho fixo', () {
      // escolher a predefinição antes de escolher a música não pode dar em
      // montagem nenhuma
      final s = aplicarReceita(
        const Receita(kinds: ['kill'], beatsPerCut: 2, durationS: 3),
        eventos: partida,
        sourceDurationS: 600,
      );

      expect(s.clips, hasLength(3));
      expect(s.clips.first.durationS, 3.0);
    });

    test('a música curta interrompe em vez de estourar a grade', () {
      final s = aplicarReceita(
        const Receita(kinds: ['kill'], beatsPerCut: 2),
        eventos: partida,
        sourceDurationS: 600,
        batidas: const [0, 0.5, 1.0, 1.5],
      );

      expect(s.clips, hasLength(1), reason: 'só coube um de duas batidas');
    });
  });

  group('efeitos e texto', () {
    test('o zoom entra como o punch de sempre', () {
      final s = aplicarReceita(
        const Receita(kinds: ['kill'], zoom: true),
        eventos: partida,
        sourceDurationS: 600,
      );

      expect(s.clips.first.zoom, isNotEmpty);
      expect(s.clips.first.zoom.first.scale, 1.0);
    });

    test('o contador vai numa camada própria, por cima dos cortes', () {
      final s = aplicarReceita(
        const Receita(kinds: ['kill'], counter: true),
        eventos: partida,
        sourceDurationS: 600,
      );

      expect(s.layers, hasLength(2));
      expect(s.layers[1].clips.map((c) => c.text), ['1', '2', '3']);
      expect(s.layers[0].clips.every((c) => !c.isText), isTrue);
    });

    test('sem texto pedido, não se cria camada à toa', () {
      final s = aplicarReceita(
        const Receita(kinds: ['kill']),
        eventos: partida,
        sourceDurationS: 600,
      );

      expect(s.layers, hasLength(1));
    });

    test('os rótulos de rajada olham os cortes, não os eventos', () {
      // três eliminações longe umas das outras na partida ficam coladas na
      // montagem — e é o que o espectador vê seguido que vale
      final s = aplicarReceita(
        const Receita(kinds: ['kill'], durationS: 1, streaks: true),
        eventos: partida,
        sourceDurationS: 600,
      );

      expect(s.layers[1].clips.map((c) => c.text), ['TRIPLE KILL']);
    });

    test('cada clipe sai com id próprio', () {
      final s = aplicarReceita(
        const Receita(kinds: ['kill'], counter: true),
        eventos: partida,
        sourceDurationS: 600,
      );

      final ids = s.clips.map((c) => c.id).toSet();
      expect(ids, hasLength(s.clips.length));
      expect(ids.contains(''), isFalse);
    });
  });

  group('mistura e saída', () {
    test('a receita traz a mistura e o formato junto', () {
      final s = aplicarReceita(
        const Receita(
          kinds: ['kill'],
          musicVolume: 0.7,
          gameVolume: 0.3,
          export: ExportSpec(width: 1080, height: 1920),
        ),
        eventos: partida,
        sourceDurationS: 600,
      );

      expect(s.musicVolume, 0.7);
      expect(s.gameVolume, 0.3);
      expect(s.export.width, 1080);
    });

    test('a música que já estava na régua não se perde', () {
      // aplicar uma predefinição troca os cortes, não a música que já foi posta
      final base = MontageState(
        layers: [
          const Layer(),
          Layer(
            kind: 'audio',
            clips: [
              TimelineClip(
                atS: 0,
                durationS: 30,
                startS: 12.5,
                source: 'media',
                mediaId: 't1',
              ),
            ],
          ),
        ],
        title: 'a minha',
      );
      final s = aplicarReceita(
        const Receita(kinds: ['kill']),
        eventos: partida,
        sourceDurationS: 600,
        base: base,
      );

      final som = s.layers.firstWhere((l) => l.isAudio);
      expect(som.clips.single.mediaId, 't1');
      expect(som.clips.single.startS, 12.5);
      expect(s.title, 'a minha');
    });
  });

  group('ler a receita de uma montagem', () {
    MontageState comCortes(List<TimelineClip> c) =>
        MontageState(layers: [Layer(clips: c)]);

    TimelineClip corte({
      required double dur,
      double t = 30,
      double lead = 1,
      String kind = 'kill',
    }) => TimelineClip(
      atS: 0,
      durationS: dur,
      startS: t - lead,
      sourceT: t,
      kind: kind,
    );

    test('o tamanho sai da mediana, e não da média', () {
      // um bloco esticado até o fim da música puxaria a média para longe do
      // que todos os outros são
      final r = receitaDaMontagem(
        comCortes([
          corte(dur: 2),
          corte(dur: 2),
          corte(dur: 2),
          corte(dur: 60),
        ]),
      );

      expect(r.durationS, 2.0);
    });

    test('o embalo é lido de onde o corte começa em relação ao momento', () {
      final r = receitaDaMontagem(
        comCortes([corte(dur: 2, t: 30, lead: 1.5)]),
      );

      expect(r.leadS, 1.5);
    });

    test('os tipos de momento vêm dos cortes que estão lá', () {
      final r = receitaDaMontagem(
        comCortes([
          corte(dur: 2, kind: 'kill'),
          corte(dur: 2, kind: 'sleep'),
          corte(dur: 2, kind: 'kill'),
        ]),
      );

      expect(r.kinds, ['kill', 'sleep']);
    });

    test('o zoom é lido se algum corte o tiver', () {
      final semZoom = receitaDaMontagem(comCortes([corte(dur: 2)]));
      expect(semZoom.zoom, isFalse);

      final comZoom = receitaDaMontagem(
        comCortes([corte(dur: 2), corte(dur: 2).copyWith(zoom: punch())]),
      );
      expect(comZoom.zoom, isTrue);
    });

    test('uma montagem vazia ainda dá uma receita utilizável', () {
      final r = receitaDaMontagem(
        MontageState(
          layers: const [],
          musicVolume: 0.5,
          export: const ExportSpec(width: 720, height: 1280),
        ),
      );

      expect(r.durationS, greaterThan(0));
      expect(r.musicVolume, 0.5);
      expect(r.export.width, 720);
    });

    test('ida e volta: a receita lida remonta o mesmo tipo de montagem', () {
      final original = aplicarReceita(
        const Receita(kinds: ['kill'], durationS: 1.8, leadS: 1.2, zoom: true),
        eventos: partida,
        sourceDurationS: 600,
      );

      final lida = receitaDaMontagem(original);
      final refeita = aplicarReceita(
        lida,
        eventos: partida,
        sourceDurationS: 600,
      );

      expect(refeita.clips.map((c) => c.durationS), [1.8, 1.8, 1.8]);
      expect(refeita.clips.map((c) => c.startS), original.clips.map((c) => c.startS));
      expect(refeita.clips.first.zoom, isNotEmpty);
    });
  });

  test('a receita viaja pelo JSON inteira', () {
    const r = Receita(
      kinds: ['kill', 'sleep'],
      beatsPerCut: 2,
      zoom: true,
      counter: true,
      export: ExportSpec(width: 1080, height: 1920, crf: 26),
    );
    final volta = Receita.fromJson(r.toJson());

    expect(volta.kinds, ['kill', 'sleep']);
    expect(volta.beatsPerCut, 2.0);
    expect(volta.zoom, isTrue);
    expect(volta.counter, isTrue);
    expect(volta.export.width, 1080);
    expect(volta.export.crf, 26);
  });
}
