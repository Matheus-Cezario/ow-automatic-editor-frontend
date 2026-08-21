import 'dart:math' as math;

import 'api.dart';

/// As contas da montagem manual, longe de qualquer widget.
///
/// A tela desenha e arrasta; quem decide onde um bloco pode cair, quanto ele
/// dura e onde o corte começa na gravação é este arquivo. Separado porque é a
/// parte que tem resposta certa — e é a única que dá para testar sem pintar
/// pixel nenhum.

/// Onde o instante detectado cai dentro do corte.
///
/// 0.7 põe a eliminação a 70% do bloco: sobra embalo antes e o impacto cai
/// perto do fim, que é onde ele funciona numa montagem. O usuário reposiciona
/// depois se quiser — isto é só o palpite inicial.
const double kMomentAnchor = 0.7;

/// Duração inicial de um bloco recém-posto, quando não há batida para sugerir
/// outra coisa.
const double kDefaultCutS = 1.2;

/// Menor bloco que faz sentido. Abaixo disso o corte pisca e não se vê nada.
const double kMinCutS = 0.2;

/// O ímã só age quando a batida está perto: mais longe que isto, o usuário
/// quis mesmo aquele ponto, e grudar seria desobedecer.
const double kSnapToleranceS = 0.12;

/// Gruda um instante na batida mais próxima, se houver uma ao alcance.
double snapToBeat(
  double value,
  List<double> beats, {
  double tolerance = kSnapToleranceS,
}) {
  if (beats.isEmpty) return value;
  var melhor = beats.first;
  for (final b in beats) {
    if ((b - value).abs() < (melhor - value).abs()) melhor = b;
  }
  return (melhor - value).abs() <= tolerance ? melhor : value;
}

/// Quanto dura o intervalo entre duas batidas — a unidade natural de corte.
///
/// Vem da mediana, e não da média: uma batida perdida no começo da música
/// esticaria a média e faria todo bloco sugerido nascer com o tamanho errado.
double beatIntervalS(List<double> beats) {
  if (beats.length < 2) return kDefaultCutS;
  final gaps = <double>[
    for (var i = 1; i < beats.length; i++) beats[i] - beats[i - 1],
  ]..sort();
  return gaps[gaps.length ~/ 2];
}

/// O bloco que nasce quando o usuário joga um momento na linha do tempo.
///
/// A duração sai de um número inteiro de batidas quando há batidas: assim o
/// bloco já nasce no ritmo, e o ímã tem onde grudar as bordas.
TimelineCut cutForMoment(
  DetectionEvent event, {
  required double atS,
  required List<double> beats,
  int beatsPerCut = 2,
  double? sourceDurationS,
}) {
  final duracao = beats.length >= 2
      ? beatIntervalS(beats) * beatsPerCut
      : kDefaultCutS;
  return TimelineCut(
    sourceT: event.t,
    kind: event.kind,
    atS: math.max(0, atS),
    durationS: duracao,
    startS: sourceStartFor(event.t, duracao, sourceDurationS: sourceDurationS),
  );
}

/// Onde o corte começa na gravação para que o instante caia em [kMomentAnchor].
double sourceStartFor(
  double momentT,
  double durationS, {
  double? sourceDurationS,
}) {
  var inicio = momentT - durationS * kMomentAnchor;
  if (sourceDurationS != null && inicio + durationS > sourceDurationS) {
    inicio = sourceDurationS - durationS;
  }
  return math.max(0, inicio);
}

/// Um bloco cabe em [atS] sem encostar nos vizinhos?
///
/// [ignore] é o índice do próprio bloco quando ele está sendo arrastado — sem
/// isso ele colidiria consigo mesmo e nunca sairia do lugar.
bool cabe(
  List<TimelineCut> cuts,
  double atS,
  double durationS, {
  int? ignore,
}) {
  if (atS < 0) return false;
  for (var i = 0; i < cuts.length; i++) {
    if (i == ignore) continue;
    final outro = cuts[i];
    if (atS < outro.untilS - 1e-6 && outro.atS < atS + durationS - 1e-6) {
      return false;
    }
  }
  return true;
}

/// Onde pôr o próximo bloco: logo depois do último, ou no ponto pedido se ele
/// estiver livre.
///
/// Serve ao caso comum de encher a montagem em sequência sem ter de mirar o
/// cursor em cada encaixe.
double proximaVaga(List<TimelineCut> cuts, double desejado, double duracao) {
  if (cabe(cuts, desejado, duracao)) return desejado;
  var t = 0.0;
  for (final c in [...cuts]..sort((a, b) => a.atS.compareTo(b.atS))) {
    t = math.max(t, c.untilS);
  }
  return t;
}

/// Move um bloco para [atS], grudando na batida e recusando sobreposição.
///
/// Devolve o bloco parado no lugar antigo quando o destino está ocupado: é
/// menos surpreendente do que empurrar o vizinho, que moveria um corte que o
/// usuário já tinha encaixado.
TimelineCut mover(
  List<TimelineCut> cuts,
  int index,
  double atS, {
  required List<double> beats,
  required bool snap,
}) {
  final atual = cuts[index];
  var destino = math.max(0.0, atS);
  if (snap) {
    // gruda pelo começo, mas se o fim é que está perto de uma batida, é ele
    // que manda: numa montagem o que se ouve é a troca de cena
    final porInicio = snapToBeat(destino, beats);
    final porFim = snapToBeat(destino + atual.durationS, beats) -
        atual.durationS;
    destino = (porInicio - destino).abs() <= (porFim - destino).abs()
        ? porInicio
        : porFim;
    destino = math.max(0, destino);
  }
  if (!cabe(cuts, destino, atual.durationS, ignore: index)) return atual;
  return atual.copyWith(atS: destino);
}

/// Muda a duração de um bloco mantendo o instante ancorado.
///
/// Esticar o bloco puxa o começo do corte junto: o que o usuário quer ao pedir
/// "mais tempo" é mais embalo antes da jogada, não a jogada saindo de quadro.
TimelineCut redimensionar(
  List<TimelineCut> cuts,
  int index,
  double duracao, {
  required List<double> beats,
  required bool snap,
  double? sourceDurationS,
}) {
  final atual = cuts[index];
  var nova = math.max(kMinCutS, duracao);
  if (snap) {
    final fim = snapToBeat(atual.atS + nova, beats);
    if (fim - atual.atS >= kMinCutS) nova = fim - atual.atS;
  }
  if (!cabe(cuts, atual.atS, nova, ignore: index)) {
    // encosta no vizinho em vez de recusar: parar exatamente no limite é o
    // que o usuário está tentando fazer quando estica até lá
    final vizinho = cuts
        .asMap()
        .entries
        .where((e) => e.key != index && e.value.atS >= atual.untilS - 1e-6)
        .map((e) => e.value.atS)
        .fold<double?>(null, (a, b) => a == null ? b : math.min(a, b));
    if (vizinho == null) return atual;
    nova = vizinho - atual.atS;
    if (nova < kMinCutS) return atual;
  }
  return atual.copyWith(
    durationS: nova,
    startS: sourceStartFor(atual.sourceT, nova, sourceDurationS: sourceDurationS),
  );
}

/// Duração do vídeo que vai sair — buracos incluídos.
///
/// É o número que a tela mostra, e tem de bater com o que o servidor vai
/// produzir: espaço vazio vira preto com a música tocando, não encurtamento.
double duracaoDoVideo(List<TimelineCut> cuts) {
  var fim = 0.0;
  for (final c in cuts) {
    fim = math.max(fim, c.untilS);
  }
  return fim;
}

/// Quanto do vídeo é preto — o que o usuário deixou vazio entre os blocos.
double duracaoEmPreto(List<TimelineCut> cuts) {
  final total = duracaoDoVideo(cuts);
  var comImagem = 0.0;
  for (final c in cuts) {
    comImagem += c.durationS;
  }
  return math.max(0, total - comImagem);
}
