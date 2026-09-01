import 'api.dart';
import 'montage.dart';

/// Texto que o próprio sistema escreve, a partir do que aconteceu na partida.
///
/// É o diferencial deste editor, e ele não está no ffmpeg: está em o editor
/// **saber o que aconteceu no vídeo**. Um contador de eliminações que sobe
/// sozinho não é um efeito difícil de renderizar — é um efeito que qualquer
/// outro editor não tem como oferecer, porque para ele o vídeo é um retângulo
/// de pixels sem história.
///
/// Tudo aqui devolve clipes de texto comuns. Depois de criados, eles se movem,
/// somem e se editam como qualquer outro — o gerador é um atalho, não uma
/// entidade nova.

/// Quanto tempo cada rótulo fica na tela, quando nada manda o contrário.
const double kDuracaoDoRotulo = 1.6;

/// Um rótulo pronto, no ponto pedido da montagem.
TimelineClip rotulo(
  String texto, {
  required double atS,
  double durationS = kDuracaoDoRotulo,
  double size = 0.1,
  String color = 'white',
  double y = -0.55,
}) => TimelineClip(
  atS: atS,
  durationS: durationS,
  startS: 0,
  source: 'text',
  text: texto,
  textStyle: ClipTextStyle(size: size, color: color),
  transform: ClipTransform(y: y),
  fade: const ClipFade(inS: 0.15, outS: 0.25),
);

/// Os tipos de corte que o contador e as rajadas contam como uma eliminação.
///
/// `ability_kill` entra: uma lança da Orisa que mata é uma eliminação como
/// outra qualquer — o detector só a lê num lugar diferente da tela (o killfeed,
/// e não a mira). Deixá-la de fora dava um contador que pulava números na cara
/// de quem tinha acabado de ver a morte acontecer.
///
/// `headshot` **não** entra: o marcador vermelho na mira é acerto crítico, não
/// morte. Contá-lo inflaria o número com tiros que só machucaram.
const _eliminacoes = {'kill', 'ability_kill'};

/// O contador de eliminações, subindo a cada corte que veio de uma.
///
/// Um rótulo por eliminação, cada um começando onde o corte dela começa e
/// durando até o próximo — assim o número na tela é sempre o de agora. O
/// último fica até o fim do vídeo.
List<TimelineClip> contadorDeEliminacoes(
  List<TimelineClip> clips, {
  double? fimS,
  String sufixo = '',
}) {
  final kills = [
    for (final c in clips)
      if (_eliminacoes.contains(c.kind)) c,
  ]..sort((a, b) => a.atS.compareTo(b.atS));
  if (kills.isEmpty) return const [];

  final fim = fimS ?? duracaoDoVideo(clips);
  final rotulos = <TimelineClip>[];
  for (var i = 0; i < kills.length; i++) {
    final comeca = kills[i].atS;
    final acaba = i + 1 < kills.length ? kills[i + 1].atS : fim;
    if (acaba - comeca < kMinCutS) continue;
    rotulos.add(
      rotulo(
        '${i + 1}$sufixo',
        atS: comeca,
        durationS: acaba - comeca,
        size: 0.12,
        y: -0.72,
      ),
    );
  }
  return rotulos;
}

/// Como se chama uma sequência de N eliminações seguidas.
///
/// Os nomes são os do próprio jogo — quem monta vídeo de Overwatch os reconhece
/// de imediato, e um rótulo que diz "3 KILLS" onde caberia "TRIPLE KILL" soa a
/// planilha.
String? nomeDaRajada(int quantas) => switch (quantas) {
  2 => 'DOUBLE KILL',
  3 => 'TRIPLE KILL',
  4 => 'QUAD KILL',
  >= 5 => 'TEAM KILL',
  _ => null,
};

/// Rótulos para as rajadas: eliminações próximas umas das outras.
///
/// A janela é a mesma ideia que o `planner` usa no servidor para propor uma
/// rajada — mas aqui ela olha os cortes que **estão na montagem**, e não os
/// eventos da partida: o que vale é o que o espectador vai ver seguido.
List<TimelineClip> rotulosDeRajada(
  List<TimelineClip> clips, {
  double janelaS = 2.5,
}) {
  final kills = [
    for (final c in clips)
      if (_eliminacoes.contains(c.kind)) c,
  ]..sort((a, b) => a.atS.compareTo(b.atS));
  if (kills.length < 2) return const [];

  final rotulos = <TimelineClip>[];
  var inicio = 0;
  for (var i = 1; i <= kills.length; i++) {
    final quebrou =
        i == kills.length || kills[i].atS - kills[i - 1].untilS > janelaS;
    if (!quebrou) continue;

    final nome = nomeDaRajada(i - inicio);
    if (nome != null) {
      // o rótulo entra na última eliminação da rajada: é ali que ela se fecha
      rotulos.add(
        rotulo(
          nome,
          atS: kills[i - 1].atS,
          durationS: kDuracaoDoRotulo,
          size: 0.11,
          color: 'yellow',
        ),
      );
    }
    inicio = i;
  }
  return rotulos;
}
