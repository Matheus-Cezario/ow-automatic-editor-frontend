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

/// A grade de batidas depois dos ajustes do usuário.
///
/// O detector de ritmo acerta o andamento quase sempre e erra de duas maneiras
/// previsíveis: pega o contratempo (a grade fica meio tempo adiantada) ou conta
/// o dobro/metade das batidas. Nenhuma das duas dá para consertar arrastando
/// blocos — é a régua que está errada, e corrigi-la conserta todos de uma vez.
///
/// [multiplicador] dobra (2) ou reduz à metade (0.5) a densidade;
/// [offsetS] desloca a grade inteira; [compasso] maior que 1 deixa só o tempo
/// forte de cada N batidas, que é onde a troca de cena costuma cair melhor.
List<double> gradeAjustada(
  List<double> beats, {
  double offsetS = 0,
  double multiplicador = 1,
  int compasso = 1,
}) {
  if (beats.isEmpty) return const [];

  var grade = [...beats]..sort();

  if (multiplicador >= 2) {
    // uma batida no meio de cada par: o dobro da densidade
    final densa = <double>[];
    for (var i = 0; i < grade.length; i++) {
      densa.add(grade[i]);
      if (i + 1 < grade.length) densa.add((grade[i] + grade[i + 1]) / 2);
    }
    grade = densa;
  } else if (multiplicador <= 0.5) {
    grade = [for (var i = 0; i < grade.length; i += 2) grade[i]];
  }

  if (compasso > 1) {
    grade = [for (var i = 0; i < grade.length; i += compasso) grade[i]];
  }

  if (offsetS != 0) {
    grade = [
      for (final b in grade)
        if (b + offsetS >= 0) b + offsetS,
    ];
  }
  return grade;
}

/// Como se identifica um momento da partida sem ambiguidade.
///
/// O instante sozinho não basta: uma eliminação na cabeça acende o detector de
/// eliminações e o de acertos críticos quase no mesmo quadro, e os dois eventos
/// podem cair no mesmo tempo arredondado. Com o tipo junto, cada cartão da
/// prateleira tem chave própria e sabe sozinho se já foi para a régua.
String chaveDoMomento(String kind, double t) => '$kind@${t.toStringAsFixed(3)}';

/// O bloco que nasce quando o usuário joga um momento na linha do tempo.
///
/// A duração sai de um número inteiro de batidas quando há batidas: assim o
/// bloco já nasce no ritmo, e o ímã tem onde grudar as bordas.
TimelineClip cutForMoment(
  DetectionEvent event, {
  required double atS,
  required List<double> beats,
  int beatsPerCut = 2,
  double? sourceDurationS,
}) {
  final duracao = beats.length >= 2
      ? beatIntervalS(beats) * beatsPerCut
      : kDefaultCutS;
  return TimelineClip(
    sourceT: event.t,
    kind: event.kind,
    atS: math.max(0, atS),
    durationS: duracao,
    startS: sourceStartFor(event.t, duracao, sourceDurationS: sourceDurationS),
  );
}

/// O clipe que nasce quando o usuário traz um item da biblioteca para a régua.
///
/// Diferente de um momento da partida, aqui não há instante a enquadrar: o
/// arquivo começa onde começa. O que se escolhe é quanto tempo ele fica.
TimelineClip clipeDeMidia(
  Media item, {
  required double atS,
  required List<double> beats,
  int beatsPerCut = 2,
}) {
  final naBatida = beats.length >= 2 ? beatIntervalS(beats) * beatsPerCut : 0.0;
  // um item curto manda na duração; senão, um número inteiro de batidas
  final duracao = naBatida > 0
      ? math.min(naBatida, item.duracaoSugerida)
      : item.duracaoSugerida;
  return TimelineClip(
    atS: math.max(0, atS),
    durationS: math.max(kMinCutS, duracao),
    startS: 0,
    source: 'media',
    kind: item.kind,
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
  List<TimelineClip> cuts,
  double atS,
  double durationS, {
  int? ignore,
}) => cabeIgnorando(cuts, atS, durationS, ignore == null ? const {} : {ignore});

/// Como [cabe], mas ignorando vários blocos de uma vez.
///
/// É o que o movimento em lote precisa: os blocos que andam juntos não podem
/// colidir entre si — eles mantêm a distância —, só com os que ficaram parados.
bool cabeIgnorando(
  List<TimelineClip> cuts,
  double atS,
  double durationS,
  Set<int> ignorar,
) {
  if (atS < 0) return false;
  for (var i = 0; i < cuts.length; i++) {
    if (ignorar.contains(i)) continue;
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
double proximaVaga(List<TimelineClip> cuts, double desejado, double duracao) {
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
TimelineClip mover(
  List<TimelineClip> cuts,
  int index,
  double atS, {
  required List<double> beats,
  required bool snap,
}) {
  final atual = cuts[index];
  var destino = math.max(0.0, atS);
  if (snap) {
    // Gruda pelo começo, mas se o fim é que está perto de uma batida, é ele que
    // manda: numa montagem o que se ouve é a troca de cena.
    //
    // Só entram na disputa as bordas que **grudaram** em alguma coisa. Comparar
    // as duas distâncias direto tinha um efeito escondido: a borda que não
    // grudou fica exatamente onde o dedo largou, distância zero, e ganhava
    // sempre — o ímã deixava de existir para qualquer bloco cuja duração não
    // fosse múltipla do compasso.
    // Três candidatos: as duas bordas e a **jogada**. A jogada é o que se
    // alinha com a percussão numa montagem — a borda pode estar meio segundo
    // antes dela —, e sem ela na disputa encaixar a eliminação na batida era
    // mirar de olho na marca desenhada dentro do bloco.
    final daMarca = atual.sourceT > 0
        ? atual.sourceT - atual.startS
        : null;
    final candidatos = <double>[
      snapToBeat(destino, beats),
      snapToBeat(destino + atual.durationS, beats) - atual.durationS,
      if (daMarca != null && daMarca >= 0 && daMarca <= atual.durationS)
        snapToBeat(destino + daMarca, beats) - daMarca,
    ];

    // só entram os que grudaram: quem não grudou fica exatamente onde o dedo
    // largou, distância zero, e ganharia sempre
    final grudaram = [
      for (final c in candidatos)
        if ((c - destino).abs() > 1e-9) c,
    ];
    if (grudaram.isNotEmpty) {
      destino = grudaram.reduce(
        (a, b) => (a - destino).abs() <= (b - destino).abs() ? a : b,
      );
    }
    destino = math.max(0, destino);
  }
  if (!cabe(cuts, destino, atual.durationS, ignore: index)) return atual;
  return atual.copyWith(atS: destino);
}

/// Estica ou encurta um bloco pela **borda direita**.
///
/// O começo do corte não se move: cresce o rabo. É o que qualquer editor faz
/// ao arrastar a borda, e é o que faz o gesto ser previsível — se o conteúdo
/// se reenquadrasse a cada pixel, a imagem escorregaria debaixo do dedo.
///
/// (Na *criação* do bloco o enquadramento é ancorado a 70% — veja
/// [cutForMoment]. Depois disso, quem reposiciona o conteúdo dentro do bloco é
/// o controle de enquadramento, não a duração.)
TimelineClip esticar(
  List<TimelineClip> cuts,
  int index,
  double duracao, {
  required List<double> beats,
  required bool snap,
  double? sourceDurationS,
}) {
  final atual = cuts[index];
  var nova = math.max(kMinCutS, duracao);

  // não dá para mostrar o que não foi gravado
  if (sourceDurationS != null) {
    nova = math.min(nova, math.max(kMinCutS, sourceDurationS - atual.startS));
  }
  if (snap) {
    final fim = snapToBeat(atual.atS + nova, beats);
    if (fim - atual.atS >= kMinCutS) nova = fim - atual.atS;
  }

  // encosta no vizinho em vez de recusar: parar exatamente no limite é o que o
  // usuário está tentando fazer quando estica até lá
  final vizinho = _proximoDepois(cuts, index, atual.atS);
  if (vizinho != null) nova = math.min(nova, vizinho - atual.atS);
  if (nova < kMinCutS) return atual;

  return atual.copyWith(durationS: nova);
}

/// Apara o bloco pela **borda esquerda**, sem mover o que já está enquadrado.
///
/// Arrastar a esquerda come o começo do corte: a borda anda, o conteúdo fica
/// no lugar. Por isso o início na gravação anda junto, na mesma medida — é
/// isso que distingue *aparar* de *mover*.
TimelineClip aparar(
  List<TimelineClip> cuts,
  int index,
  double novoAt, {
  required List<double> beats,
  required bool snap,
}) {
  final atual = cuts[index];
  var destino = math.max(0.0, novoAt);
  if (snap) destino = math.max(0, snapToBeat(destino, beats));

  // não pode invadir o vizinho de trás nem começar antes da gravação
  final anterior = _anteriorAntes(cuts, index, atual.atS);
  if (anterior != null) destino = math.max(destino, anterior);
  destino = math.max(destino, atual.atS - atual.startS);

  final nova = atual.untilS - destino;
  if (nova < kMinCutS) return atual;

  return atual.copyWith(
    atS: destino,
    durationS: nova,
    startS: atual.startS + (destino - atual.atS),
  );
}

/// Onde começa o bloco seguinte — o teto de quem estica para a direita.
double? _proximoDepois(List<TimelineClip> cuts, int index, double at) {
  double? menor;
  for (var i = 0; i < cuts.length; i++) {
    if (i == index) continue;
    final outro = cuts[i].atS;
    if (outro >= at - 1e-6 && (menor == null || outro < menor)) menor = outro;
  }
  return menor;
}

/// Onde termina o bloco anterior — o piso de quem apara pela esquerda.
double? _anteriorAntes(List<TimelineClip> cuts, int index, double at) {
  double? maior;
  for (var i = 0; i < cuts.length; i++) {
    if (i == index) continue;
    final fim = cuts[i].untilS;
    if (fim <= at + 1e-6 && (maior == null || fim > maior)) maior = fim;
  }
  return maior;
}

/// Onde, de 0 a 1 do bloco, cai o instante que o originou.
///
/// É a marca desenhada dentro do bloco. Sem ela, encaixar a eliminação na
/// batida seria adivinhar: o que se alinha com a percussão é a jogada, não a
/// borda do corte — e a borda pode estar meio segundo antes dela.
///
/// `null` quando o momento ficou fora do bloco: dá para aparar até ele sair, e
/// aí não há o que marcar.
double? marcaDoMomento(TimelineClip cut) {
  if (cut.durationS <= 0) return null;
  final f = (cut.sourceT - cut.startS) / cut.durationS;
  return f < 0 || f > 1 ? null : f;
}

/// Onde o momento que originou o bloco cai no **vídeo**, em segundos.
///
/// `null` quando o momento ficou fora do bloco — dá para aparar até ele sair —
/// ou quando o bloco não veio de momento nenhum (música, texto, mídia).
double? momentoNoVideo(TimelineClip cut) {
  if (cut.sourceT <= 0 || marcaDoMomento(cut) == null) return null;
  return cut.atS + (cut.sourceT - cut.startS);
}

/// O bloco que está sob a cabeça de leitura em [atS], ou `null` se ali é buraco.
int? blocoEm(List<TimelineClip> cuts, double atS) {
  for (var i = 0; i < cuts.length; i++) {
    if (atS >= cuts[i].atS - 1e-6 && atS < cuts[i].untilS - 1e-6) return i;
  }
  return null;
}

/// Que instante da **gravação** o preview deve mostrar em [atS] do vídeo.
///
/// `null` quer dizer tela preta — o mesmo que o servidor vai gerar ali. É esta
/// função que faz o preview e o arquivo final contarem a mesma história: ela é
/// a versão de leitura do `plan()` que o backend usa para cortar.
double? origemEm(List<TimelineClip> cuts, double atS) {
  final i = blocoEm(cuts, atS);
  if (i == null) return null;
  return cuts[i].startS + (atS - cuts[i].atS);
}

/// Duração do vídeo que vai sair — buracos incluídos.
///
/// É o número que a tela mostra, e tem de bater com o que o servidor vai
/// produzir: espaço vazio vira preto com a música tocando, não encurtamento.
double duracaoDoVideo(List<TimelineClip> cuts) {
  var fim = 0.0;
  for (final c in cuts) {
    fim = math.max(fim, c.untilS);
  }
  return fim;
}

/// Quanto do vídeo é preto — o que o usuário deixou vazio entre os blocos.
double duracaoEmPreto(List<TimelineClip> cuts) {
  final total = duracaoDoVideo(cuts);
  var comImagem = 0.0;
  for (final c in cuts) {
    comImagem += c.durationS;
  }
  return math.max(0, total - comImagem);
}
