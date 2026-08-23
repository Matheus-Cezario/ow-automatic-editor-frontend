import 'dart:math';

import 'api.dart';
import 'montage_state.dart';

/// As escolhas de exportação, do lado do app.
///
/// A montagem não muda: o que muda é a janela por onde se olha para ela. É por
/// isso que o mesmo trabalho vira um 16:9 para o YouTube e um 9:16 para os
/// Shorts sem que um clipe sequer se mexa — e por isso trocar o formato não
/// pede nenhum desfazer.

/// Um tamanho de saída com nome.
class FormatoDeSaida {
  const FormatoDeSaida(this.nome, this.width, this.height, {this.nota = ''});

  final String nome;

  /// `0` nos dois = o tamanho da gravação.
  final int width;
  final int height;
  final String nota;

  bool combina(ExportSpec e) => e.width == width && e.height == height;

  /// Quanto o quadro é mais largo que alto. `null` quando segue a gravação.
  double? get proporcao => height == 0 ? null : width / height;
}

/// Os formatos que se pede de verdade num editor de gameplay.
///
/// Deliberadamente curto. Uma lista com toda resolução que o H.264 aceita não
/// ajuda ninguém a decidir: quem quer 1440x1080 sabe digitar dois números.
const formatosDeSaida = [
  FormatoDeSaida('Original', 0, 0, nota: 'como foi gravado'),
  FormatoDeSaida('1080p', 1920, 1080, nota: 'YouTube, Twitch'),
  FormatoDeSaida('720p', 1280, 720, nota: 'mais leve'),
  FormatoDeSaida('Vertical', 1080, 1920, nota: 'Shorts, Reels, TikTok'),
  FormatoDeSaida('Quadrado', 1080, 1080, nota: 'feed'),
];

/// Qualidade, em três degraus.
///
/// O número é o CRF do H.264, onde menor é melhor e cada +6 corta o arquivo
/// mais ou menos pela metade. Ninguém quer escolher isso em unidades de CRF.
class Qualidade {
  const Qualidade(this.nome, this.crf, this.nota);

  final String nome;
  final int crf;
  final String nota;
}

const qualidades = [
  Qualidade('Alta', 18, 'arquivo maior'),
  Qualidade('Boa', 20, 'o padrão'),
  Qualidade('Leve', 26, 'para mandar por aí'),
];

Qualidade qualidadeDe(ExportSpec e) =>
    qualidades.firstWhere((q) => q.crf == e.crf, orElse: () => qualidades[1]);

/// As taxas de quadros que fazem sentido oferecer. `0` segue a gravação.
const fpsDeSaida = <double>[0, 24, 30, 60];

/// O trecho que vai sair, já resolvido contra a duração da montagem.
///
/// [ExportSpec.toS] em `null` quer dizer "até o fim", e o fim só se conhece
/// aqui — a especificação não sabe quanto dura a montagem. Um recorte que
/// deixou de fazer sentido — porque os clipes dele foram apagados depois —
/// volta a ser o vídeo inteiro, em vez de virar um pedido de zero segundo que
/// o servidor recusaria.
({double inicio, double fim}) trechoDe(ExportSpec e, double duracaoS) {
  final inicio = e.fromS.clamp(0.0, duracaoS).toDouble();
  final fim = (e.toS ?? duracaoS).clamp(0.0, duracaoS).toDouble();
  if (fim - inicio < 0.05) return (inicio: 0.0, fim: duracaoS);
  return (inicio: inicio, fim: fim);
}

/// Quanto tempo o vídeo exportado vai ter.
double duracaoExportada(ExportSpec e, double duracaoS) {
  final t = trechoDe(e, duracaoS);
  return t.fim - t.inicio;
}

/// Recorta a exportação no que está selecionado.
///
/// O atalho para "quero ver só esta parte": em vez de exportar cinco minutos
/// para conferir uma emenda de dois segundos, exporta os dois segundos. A
/// montagem fica intacta — dá para tirar o recorte depois e exportar tudo.
MontageState exportarSelecao(MontageState s) {
  final escolhidos = [
    for (final c in s.clips)
      if (s.selecao.contains(c.id)) c,
  ];
  if (escolhidos.isEmpty) return s;

  var inicio = double.infinity;
  var fim = 0.0;
  for (final c in escolhidos) {
    if (c.atS < inicio) inicio = c.atS;
    if (c.untilS > fim) fim = c.untilS;
  }
  return s.copyWith(
    export: s.export.copyWith(fromS: inicio, toS: fim),
  );
}

/// Desfaz o recorte de tempo: o vídeo inteiro volta a sair.
MontageState exportarTudo(MontageState s) =>
    s.copyWith(export: s.export.copyWith(fromS: 0, limparTo: true));

/// Um palpite do tamanho do arquivo, em MB.
///
/// É um palpite mesmo — o H.264 gasta bits onde a imagem se mexe, e uma
/// montagem de gameplay se mexe muito. Serve para responder "isso vai dar 8 MB
/// ou 800?", que é a pergunta que se faz antes de exportar, e não para
/// prometer um número.
double tamanhoEstimadoMB(
  ExportSpec e, {
  required double duracaoS,
  required int largura,
  required int altura,
}) {
  final w = e.width == 0 ? largura : e.width;
  final h = e.height == 0 ? altura : e.height;
  final fps = e.fps == 0 ? 30.0 : e.fps;
  // bits por pixel por quadro, calibrado no CRF: cada +6 de CRF mais ou menos
  // divide a taxa por dois
  final bpp = 0.09 * pow(0.5, (e.crf - 20) / 6.0);
  final bits = w * h * fps * bpp * duracaoExportada(e, duracaoS);
  return bits / 8 / 1024 / 1024;
}

String _relogio(double s) {
  final m = s ~/ 60;
  final seg = (s - m * 60).floor().toString().padLeft(2, '0');
  return '$m:$seg';
}

/// Um resumo em uma linha do que vai sair, para a barra de exportar.
String resumoDaExportacao(
  ExportSpec e, {
  required double duracaoS,
  required int largura,
  required int altura,
}) {
  final w = e.width == 0 ? largura : e.width;
  final h = e.height == 0 ? altura : e.height;
  final fps = e.fps == 0 ? '' : ' · ${e.fps.toStringAsFixed(0)}fps';
  final dur = _relogio(duracaoExportada(e, duracaoS));
  final mb = tamanhoEstimadoMB(
    e,
    duracaoS: duracaoS,
    largura: largura,
    altura: altura,
  );
  return '${w}x$h$fps · $dur · ~${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
}

/// Onde a marca d'água pode ficar.
///
/// Quatro cantos e nada de arrastar: a marca é a única coisa do vídeo que não
/// se quer ver de perto, e um canto escolhido em dois cliques resolve o caso
/// inteiro. As coordenadas são medidas do centro do quadro.
class CantoDaMarca {
  const CantoDaMarca(this.nome, this.x, this.y);

  final String nome;
  final double x;
  final double y;
}

const kCantosDaMarca = [
  CantoDaMarca('↖', -0.82, -0.82),
  CantoDaMarca('↗', 0.82, -0.82),
  CantoDaMarca('↙', -0.82, 0.82),
  CantoDaMarca('↘', 0.82, 0.82),
];
