import 'dart:math' as math;

import 'api.dart';
import 'montage.dart';
import 'montage_state.dart';
import 'rotulos.dart';

/// Aplicar uma predefinição: o jeito de cortar virando cortes.
///
/// Uma predefinição não guarda cortes — guarda o **jeito** de cortar. "Dois
/// segundos por eliminação, encaixado na batida, com zoom" vale para qualquer
/// partida, e é o que faz a segunda partida custar um clique em vez de meia
/// hora de encaixe.
///
/// O que sai daqui é uma montagem comum: depois de aplicada, cada bloco se
/// move, se apara e se apaga como qualquer outro. A receita é um ponto de
/// partida, não um molde do qual não se sai.

/// Monta a partir dos momentos da partida.
///
/// [batidas] são as batidas **em tempo de vídeo** — as mesmas que o ímã da
/// régua usa. Com elas e `beatsPerCut` maior que zero, cada corte vai de uma
/// batida à outra: é o encaixe no ritmo, e aí o espaço entre cortes não se
/// aplica, porque a grade já diz onde cada um começa.
MontageState aplicarReceita(
  Receita r, {
  required List<DetectionEvent> eventos,
  required double sourceDurationS,
  List<double> batidas = const [],
  MontageState? base,
}) {
  final momentos = [
    for (final e in eventos)
      if (r.kinds.contains(e.kind)) e,
  ]..sort((a, b) => a.t.compareTo(b.t));

  final quantos = r.maxCuts > 0
      ? math.min(r.maxCuts, momentos.length)
      : momentos.length;

  final naGrade = r.beatsPerCut > 0 && batidas.length > 1;
  final passo = math.max(1, r.beatsPerCut.round());

  final clips = <TimelineClip>[];
  var posicao = 0.0;
  for (var i = 0; i < quantos; i++) {
    final momento = momentos[i];

    double comeca;
    double dura;
    if (naGrade) {
      final k = i * passo;
      if (k + passo >= batidas.length) break; // a música acabou antes
      comeca = batidas[k];
      dura = batidas[k + passo] - comeca;
    } else {
      comeca = posicao;
      dura = r.durationS;
      posicao += dura + r.gapS;
    }
    if (dura < kMinCutS) continue;

    // o momento precisa de embalo: sem ele a eliminação aparece no primeiro
    // quadro, antes de o espectador entender o que está vendo
    final consumido = dura * r.speed;
    final entrada = (momento.t - r.leadS).clamp(
      0.0,
      math.max(0.0, sourceDurationS - consumido),
    );

    clips.add(
      TimelineClip(
        id: novoIdDeCorte(),
        atS: comeca,
        durationS: dura,
        startS: entrada.toDouble(),
        sourceT: momento.t,
        kind: momento.kind,
        speed: r.speed,
        zoom: r.zoom ? punch() : const [],
        fade: r.fadeS > 0
            ? ClipFade(inS: r.fadeS, outS: r.fadeS)
            : const ClipFade(),
      ),
    );
  }

  final camadas = <Layer>[Layer(clips: clips)];

  // o texto vai numa camada própria: ele quase sempre fica por cima de imagem,
  // e misturá-lo com os cortes obrigaria a desviar de um para pôr o outro
  final textos = <TimelineClip>[
    if (r.counter) ...contadorDeEliminacoes(clips),
    if (r.streaks) ...rotulosDeRajada(clips),
  ];
  if (textos.isNotEmpty) {
    camadas.add(
      Layer(
        name: 'texto',
        clips: [for (final t in textos) t.copyWith(id: novoIdDeCorte())]
          ..sort((a, b) => a.atS.compareTo(b.atS)),
      ),
    );
  }

  final anterior = base ?? MontageState(layers: const []);
  // a música que já foi posta na régua fica: uma predefinição descreve o jeito
  // de cortar, e não que música tocar por cima
  final som = [
    for (final l in anterior.layers)
      if (l.isAudio && l.clips.isNotEmpty) l,
  ];
  return anterior.copyWith(
    layers: [...camadas, ...som],
    selecao: const {},
    camadaAtiva: 0,
    musicVolume: r.musicVolume,
    gameVolume: r.gameVolume,
    export: r.export,
  );
}

/// A receita que descreve uma montagem que já existe.
///
/// É o "salvar como predefinição": em vez de pedir que se descreva de novo o
/// que já está na tela, lê-se o que está lá. O tamanho e o embalo saem da
/// **mediana** dos cortes, e não da média — um único bloco esticado até o fim
/// da música puxaria a média para longe do que todos os outros são.
Receita receitaDaMontagem(MontageState s, {double? beatsPerCut}) {
  final daGravacao = [
    for (final c in s.clips)
      if (c.source == 'recording' && !c.isText) c,
  ];
  if (daGravacao.isEmpty) {
    return Receita(
      musicVolume: s.musicVolume,
      gameVolume: s.gameVolume,
      export: s.export,
    );
  }

  final kinds = {
    for (final c in daGravacao)
      if (c.kind.isNotEmpty) c.kind,
  };
  final embalos = [
    for (final c in daGravacao)
      if (c.sourceT > 0) (c.sourceT - c.startS).clamp(0.0, 10.0).toDouble(),
  ];

  return Receita(
    kinds: kinds.isEmpty ? const ['kill'] : (kinds.toList()..sort()),
    durationS: _mediana([for (final c in daGravacao) c.durationS]) ?? 2.0,
    leadS: _mediana(embalos) ?? 1.0,
    beatsPerCut: beatsPerCut ?? 0,
    speed: _mediana([for (final c in daGravacao) c.speed]) ?? 1.0,
    zoom: daGravacao.any((c) => c.zoom.isNotEmpty),
    fadeS:
        _mediana([
          for (final c in daGravacao)
            if (!c.fade.neutro) c.fade.inS,
        ]) ??
        0,
    counter: s.clips.any((c) => c.isText && int.tryParse(c.text) != null),
    streaks:
        s.clips.any((c) => c.isText && nomeDaRajada(2) == c.text) ||
        s.clips.any((c) => c.isText && c.text.endsWith(' KILL')),
    musicVolume: s.musicVolume,
    gameVolume: s.gameVolume,
    export: s.export,
  );
}

double? _mediana(List<double> v) {
  if (v.isEmpty) return null;
  final ordenados = [...v]..sort();
  final meio = ordenados.length ~/ 2;
  final m = ordenados.length.isOdd
      ? ordenados[meio]
      : (ordenados[meio - 1] + ordenados[meio]) / 2;
  return double.parse(m.toStringAsFixed(3));
}
