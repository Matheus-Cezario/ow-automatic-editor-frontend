import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../montage.dart';
import 'highlight_style.dart';

/// O que está sendo arrastado para a régua.
///
/// São duas origens e um só alvo: um momento da partida, da prateleira da
/// esquerda, ou um item da biblioteca — vídeo, imagem ou música. A régua não
/// precisa saber o que fazer com cada um; ela diz **onde** caiu e a tela
/// resolve o resto.
class ArrastoParaARegua {
  const ArrastoParaARegua.momento(DetectionEvent this.evento) : media = null;
  const ArrastoParaARegua.midia(Media this.media) : evento = null;

  final DetectionEvent? evento;
  final Media? media;

  /// Quanto o bloco vai durar — é o que o fantasma do arrasto desenha, para o
  /// tamanho no dedo ser o tamanho na régua.
  double get duracaoS => media?.duracaoSugerida ?? kDefaultCutS;

  String get rotulo => media?.name ?? EventStyle.of(evento!.kind).label;

  bool get eSom => media?.isAudio ?? false;
}

/// A régua do vídeo com as camadas por cima — o coração da montagem manual.
///
/// Tudo é desenhado na escala do **vídeo que vai sair**: o instante zero é o
/// primeiro quadro dele. A música mora dentro dessa escala, em blocos, e cada
/// bloco desenha a própria onda — foi assim que ela deixou de ser um fundo
/// contínuo e virou material como qualquer outro.
///
/// As camadas são pistas empilhadas, da de baixo para a de cima — a mesma
/// ordem em que o servidor as desenha. O cabeçalho de cada uma fica **fora** da
/// rolagem: ele tem de continuar visível quando a régua anda.
///
/// Quatro gestos: arrastar o corpo do clipe **move**, a borda esquerda
/// **apara**, a direita **estica**, e arrastar para cima ou para baixo **troca
/// de camada**.
class MusicTimeline extends StatefulWidget {
  const MusicTimeline({
    super.key,
    required this.layers,
    required this.camadaAtiva,
    required this.selecao,
    required this.pxPerSecond,
    required this.playheadS,
    required this.scroll,
    required this.onSeek,
    required this.onSelect,
    required this.onMove,
    required this.onTrim,
    required this.onStretch,
    required this.onGestoInicio,
    required this.onGestoFim,
    required this.onTrocarDeCamada,
    required this.onCamadaAtiva,
    required this.onAjustarCamada,
    required this.onReordenarCamadas,
    this.onDragLabel,
    this.onSoltar,
    this.batidas = const [],
    this.ondaDaPartida = const [],
    this.duracaoDaPartida = 0,
    this.musicas = const {},
    this.fallbackDurationS = 60,
  });

  final List<Layer> layers;
  final int camadaAtiva;

  /// Quem está selecionado, por id do clipe. Índice não serve: apagar um clipe
  /// desloca os seguintes, e a seleção passaria a apontar para o vizinho.
  final Set<String> selecao;

  /// Zoom: quantos pixels vale um segundo de vídeo.
  final double pxPerSecond;

  final double playheadS;
  final ScrollController scroll;

  final ValueChanged<double> onSeek;

  /// Escolher um clipe. `alternar` é o shift-clique, que soma à seleção em vez
  /// de trocá-la; `null` limpa.
  final void Function(String? id, {bool alternar}) onSelect;

  /// (id, nova posição em tempo de vídeo) — valores **absolutos**, já que o
  /// arrasto é medido desde o início do gesto.
  final void Function(String id, double atS) onMove;
  final void Function(String id, double atS) onTrim;
  final void Function(String id, double durationS) onStretch;

  /// (id, camada de destino) — o arrasto vertical.
  final void Function(String id, int camada) onTrocarDeCamada;

  final ValueChanged<int> onCamadaAtiva;

  /// (de, para) — arrastar um cabeçalho por cima do outro troca a ordem em que
  /// as camadas são desenhadas.
  final void Function(int de, int para) onReordenarCamadas;
  final void Function(int camada, {bool? muted, bool? hidden, bool? locked})
  onAjustarCamada;

  /// Abre e fecha o gesto no histórico: um arrasto inteiro vira um único passo
  /// de desfazer, em vez de um por quadro.
  final VoidCallback onGestoInicio;
  final VoidCallback onGestoFim;

  /// Texto para a tela mostrar enquanto o dedo está no clipe; `null` ao soltar.
  final ValueChanged<String?>? onDragLabel;

  /// O que fazer quando algo é solto na régua: um momento da partida ou um item
  /// da biblioteca, com o instante e a camada em que caiu.
  ///
  /// É o caminho curto de quem já sabe onde quer a coisa — clicar põe na cabeça
  /// de leitura, arrastar põe onde o dedo largou.
  final void Function(ArrastoParaARegua o, double atS, int camada)? onSoltar;

  /// A grade de batidas em tempo de vídeo — a mesma que o ímã usa. Desenhá-la
  /// e grudar nela têm de ser a mesma coisa, senão a linha mente.
  final List<double> batidas;

  /// A forma de onda do áudio da partida inteira, e quanto tempo ela cobre.
  final List<double> ondaDaPartida;
  final double duracaoDaPartida;

  /// As músicas da biblioteca, por id. É delas que sai a onda desenhada dentro
  /// de um bloco de música — cada uma tem a sua, e não a da partida.
  final Map<String, Track> musicas;

  /// Régua a desenhar enquanto a montagem ainda está vazia.
  final double fallbackDurationS;

  /// A faixa de cima, onde ficam as batidas e a cabeça de leitura. Era a onda
  /// da faixa contínua; hoje cada bloco desenha a sua, e o que sobra aqui é a
  /// grade.
  static const double waveHeight = 26;
  static const double blockHeight = 72;
  static const double rulerHeight = 20;
  static const double larguraDosCabecalhos = 148;

  static double alturaPara(int camadas) =>
      waveHeight + blockHeight * camadas + rulerHeight;

  /// Que camada é desenhada na pista [linha], contada de cima para baixo.
  ///
  /// A lista de camadas vai da de baixo para a de cima — a ordem em que o
  /// servidor as desenha —, e a régua mostra o contrário: **a pista de cima é
  /// a camada de cima**, como em qualquer editor. Sem esta inversão, arrastar
  /// uma camada para o topo a mandava para trás de todas as outras.
  static int camadaDaLinha(int linha, int quantas) => quantas - 1 - linha;

  /// A conta inversa: em que pista uma camada aparece.
  static int linhaDaCamada(int camada, int quantas) => quantas - 1 - camada;

  @override
  State<MusicTimeline> createState() => _MusicTimelineState();
}

class _MusicTimelineState extends State<MusicTimeline> {
  /// Rolagem automática quando o dedo chega perto da borda da janela.
  Timer? _autoScroll;
  double _direcao = 0;

  /// Onde o arrasto de fora vai cair: (instante, camada). É o que desenha o
  /// retângulo antes de soltar — largar às cegas é o que faz arrastar parecer
  /// pior do que clicar.
  (double, int)? _mira;
  double _larguraDaMira = kDefaultCutS;

  @override
  void dispose() {
    _autoScroll?.cancel();
    super.dispose();
  }

  double get _durationS {
    var fim = 0.0;
    for (final l in widget.layers) {
      for (final c in l.clips) {
        fim = math.max(fim, c.untilS);
      }
    }
    // uma folga no fim para dar onde soltar o último clipe
    return math.max(fim + 4, widget.fallbackDurationS);
  }

  /// A jogada deste bloco cai exatamente sob a cabeça de leitura?
  ///
  /// Meio quadro de tolerância: alinhar é uma decisão de montagem, não uma
  /// medida de precisão infinita.
  bool _jogadaNoCursor(TimelineClip clip) {
    final marca = momentoNoVideo(clip);
    return marca != null && (marca - widget.playheadS).abs() < 0.017;
  }

  /// Em que camada cai um ponto da régua — a conta inversa do empilhamento.
  int _camadaEm(double dy) {
    final linha = ((dy - MusicTimeline.waveHeight) / MusicTimeline.blockHeight)
        .floor();
    return MusicTimeline.camadaDaLinha(
      linha.clamp(0, math.max(0, widget.layers.length - 1)),
      widget.layers.length,
    );
  }

  /// Liga/desliga a rolagem conforme a posição global do dedo.
  void _talvezRolar(Offset global) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !widget.scroll.hasClients) return;
    final x = box.globalToLocal(global).dx;
    const margem = 48.0;

    final direcao = x < MusicTimeline.larguraDosCabecalhos + margem
        ? -1.0
        : x > box.size.width - margem
        ? 1.0
        : 0.0;
    if (direcao == _direcao) return;
    _direcao = direcao;
    _autoScroll?.cancel();
    if (direcao == 0) return;

    _autoScroll = Timer.periodic(const Duration(milliseconds: 16), (_) {
      final pos = widget.scroll.position;
      final alvo = (widget.scroll.offset + direcao * 8).clamp(
        0.0,
        pos.maxScrollExtent,
      );
      if (alvo == widget.scroll.offset) return;
      widget.scroll.jumpTo(alvo);
    });
  }

  /// Converte a posição global do dedo em (instante, camada) da régua.
  (double, int)? _ondeCai(Offset global) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return null;
    final local = box.globalToLocal(global);
    final x =
        local.dx - MusicTimeline.larguraDosCabecalhos + widget.scroll.offset;
    if (x < 0) return null;
    return (math.max(0.0, x / widget.pxPerSecond), _camadaEm(local.dy));
  }

  void _pararDeRolar() {
    _autoScroll?.cancel();
    _autoScroll = null;
    _direcao = 0;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final px = widget.pxPerSecond;
    final largura = _durationS * px;
    final altura = MusicTimeline.alturaPara(widget.layers.length);

    return SizedBox(
      height: altura,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: MusicTimeline.larguraDosCabecalhos,
            child: _Cabecalhos(
              layers: widget.layers,
              ativa: widget.camadaAtiva,
              onAtiva: widget.onCamadaAtiva,
              onAjustar: widget.onAjustarCamada,
              onReordenar: widget.onReordenarCamadas,
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: SingleChildScrollView(
              controller: widget.scroll,
              scrollDirection: Axis.horizontal,
              child: DragTarget<ArrastoParaARegua>(
                onWillAcceptWithDetails: (d) {
                  final onde = _ondeCai(d.offset);
                  if (onde == null) return false;
                  setState(() {
                    _mira = onde;
                    _larguraDaMira = d.data.duracaoS;
                  });
                  return true;
                },
                onLeave: (_) => setState(() => _mira = null),
                onAcceptWithDetails: (d) {
                  final onde = _ondeCai(d.offset) ?? _mira;
                  setState(() => _mira = null);
                  if (onde == null) return;
                  widget.onSoltar?.call(d.data, onde.$1, onde.$2);
                },
                builder: (context, _, _) => SizedBox(
                  width: largura,
                  height: altura,
                  child: Stack(
                    children: [
                      // fundo: onda, batidas, régua, marcador de início e as
                      // linhas que separam as pistas
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapDown: (d) {
                            widget.onSeek(d.localPosition.dx / px);
                            widget.onSelect(null);
                          },
                          child: CustomPaint(
                            painter: _RulerPainter(
                              beats: widget.batidas,
                              durationS: _durationS,
                              pxPerSecond: px,
                              camadas: widget.layers.length,
                              onColor: theme.colorScheme.primary,
                              waveColor: theme.colorScheme.primary.withValues(
                                alpha: 0.35,
                              ),
                              beatColor: theme.colorScheme.onSurface.withValues(
                                alpha: 0.18,
                              ),
                              textColor: theme.hintColor,
                            ),
                          ),
                        ),
                      ),

                      for (
                        var camada = 0;
                        camada < widget.layers.length;
                        camada++
                      )
                        if (!widget.layers[camada].hidden)
                          for (final clip in widget.layers[camada].clips)
                            _Block(
                              key: ValueKey('bloco-${clip.id}'),
                              cut: clip,
                              musica: widget.musicas[clip.mediaId],
                              selected: widget.selecao.contains(clip.id),
                              travada: widget.layers[camada].locked,
                              marcaNoCursor: _jogadaNoCursor(clip),
                              pxPerSecond: px,
                              left: clip.atS * px,
                              top:
                                  MusicTimeline.waveHeight +
                                  MusicTimeline.linhaDaCamada(
                                        camada,
                                        widget.layers.length,
                                      ) *
                                      MusicTimeline.blockHeight,
                              height: MusicTimeline.blockHeight,
                              onSelect: ({bool alternar = false}) =>
                                  widget.onSelect(clip.id, alternar: alternar),
                              onMove: (at) => widget.onMove(clip.id, at),
                              onTrim: (at) => widget.onTrim(clip.id, at),
                              onStretch: (d) => widget.onStretch(clip.id, d),
                              onDragLabel: widget.onDragLabel,
                              onda: widget.ondaDaPartida,
                              duracaoDaPartida: widget.duracaoDaPartida,
                              onDragInicio: widget.onGestoInicio,
                              onDragMove: _talvezRolar,
                              onDragEnd: () {
                                _pararDeRolar();
                                widget.onGestoFim();
                              },
                              // para cima na tela é para cima na pilha: os
                              // passos vêm em pistas, e pista cresce para
                              // baixo
                              onTrocarDeCamada: (passos) => widget
                                  .onTrocarDeCamada(clip.id, camada - passos),
                            ),

                      // onde o que está sendo arrastado vai cair
                      if (_mira != null)
                        Positioned(
                          left: _mira!.$1 * px,
                          top:
                              MusicTimeline.waveHeight +
                              _mira!.$2 * MusicTimeline.blockHeight,
                          height: MusicTimeline.blockHeight,
                          width: math.max(2, _larguraDaMira * px),
                          child: IgnorePointer(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primary.withValues(
                                  alpha: 0.25,
                                ),
                                border: Border.all(
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                            ),
                          ),
                        ),

                      // a cabeça de leitura, por último para ficar por cima
                      Positioned(
                        left: widget.playheadS * px - 1,
                        top: 0,
                        bottom: 0,
                        width: 2,
                        child: IgnorePointer(
                          child: ColoredBox(color: theme.colorScheme.error),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A coluna de cabeçalhos, fora da rolagem.
///
/// Fica fora porque ela é a referência: quando a régua anda, saber de que
/// camada é cada pista continua valendo.
class _Cabecalhos extends StatefulWidget {
  const _Cabecalhos({
    required this.layers,
    required this.ativa,
    required this.onAtiva,
    required this.onAjustar,
    required this.onReordenar,
  });

  final List<Layer> layers;
  final int ativa;
  final ValueChanged<int> onAtiva;
  final void Function(int camada, {bool? muted, bool? hidden, bool? locked})
  onAjustar;

  /// (de, para) — a ordem nova das camadas.
  final void Function(int de, int para) onReordenar;

  @override
  State<_Cabecalhos> createState() => _CabecalhosState();
}

class _CabecalhosState extends State<_Cabecalhos> {
  /// Sobre qual cabeçalho o arrasto está agora, para a linha de destino
  /// aparecer antes de soltar.
  int? _alvo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final layers = widget.layers;
    return Column(
      children: [
        // a faixa da grade, que não pertence a camada nenhuma
        SizedBox(
          height: MusicTimeline.waveHeight,
          child: Center(
            child: Text(
              'batidas',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.hintColor,
              ),
            ),
          ),
        ),
        // As pistas, **de cima para baixo**: a primeira linha é a camada de
        // cima, como em qualquer editor. Cada cabeçalho é pegável — arrastar um
        // por cima do outro troca a ordem em que o servidor desenha as camadas,
        // que é o que decide quem cobre quem.
        for (var linha = 0; linha < layers.length; linha++)
          Builder(
            builder: (context) {
              final i = MusicTimeline.camadaDaLinha(linha, layers.length);
              return DragTarget<int>(
                onWillAcceptWithDetails: (d) {
                  if (d.data == i) return false;
                  setState(() => _alvo = i);
                  return true;
                },
                onLeave: (_) => setState(() => _alvo = null),
                onAcceptWithDetails: (d) {
                  setState(() => _alvo = null);
                  widget.onReordenar(d.data, i);
                },
                builder: (context, _, _) => _Reordenavel(
                  indice: i,
                  feedback: Material(
                    color: Colors.transparent,
                    child: SizedBox(
                      width: MusicTimeline.larguraDosCabecalhos,
                      height: MusicTimeline.blockHeight,
                      child: Opacity(
                        opacity: 0.9,
                        child: _CabecalhoDeCamada(
                          layer: layers[i],
                          indice: i,
                          ativa: true,
                          onAtiva: () {},
                          onAjustar:
                              ({bool? muted, bool? hidden, bool? locked}) {},
                        ),
                      ),
                    ),
                  ),
                  childWhenDragging: SizedBox(
                    height: MusicTimeline.blockHeight,
                    child: ColoredBox(
                      color: theme.colorScheme.primary.withValues(alpha: 0.08),
                    ),
                  ),
                  builder: (alca) => Container(
                    key: ValueKey('cabecalho-$i'),
                    height: MusicTimeline.blockHeight,
                    decoration: _alvo == i
                        ? BoxDecoration(
                            border: Border.all(
                              color: theme.colorScheme.primary,
                            ),
                          )
                        : null,
                    child: _CabecalhoDeCamada(
                      layer: layers[i],
                      indice: i,
                      ativa: i == widget.ativa,
                      alca: alca,
                      onAtiva: () => widget.onAtiva(i),
                      onAjustar: ({bool? muted, bool? hidden, bool? locked}) =>
                          widget.onAjustar(
                            i,
                            muted: muted,
                            hidden: hidden,
                            locked: locked,
                          ),
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}

/// Um cabeçalho que se arrasta — mas só pela alça.
///
/// O punho é um `Draggable` de verdade (arrasto imediato, como qualquer editor
/// de desktop), e o resto do cabeçalho continua clicável: os botões de
/// esconder, emudecer e travar estão ali.
class _Reordenavel extends StatelessWidget {
  const _Reordenavel({
    required this.indice,
    required this.feedback,
    required this.childWhenDragging,
    required this.builder,
  });

  final int indice;
  final Widget feedback;
  final Widget childWhenDragging;
  final Widget Function(Widget alca) builder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final alca = Draggable<int>(
      data: indice,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: feedback,
      childWhenDragging: const SizedBox(width: 20, height: 20),
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: Tooltip(
          message: 'Arraste para mudar a ordem das camadas',
          child: Icon(Icons.drag_indicator, size: 16, color: theme.hintColor),
        ),
      ),
    );
    // O cabeçalho inteiro também sai no toque longo: num celular não há
    // ponteiro para mirar uma alça de 16px. Um arrasto que comece na alça é
    // reclamado pelo `Draggable` de dentro, que é mais fundo na árvore.
    return LongPressDraggable<int>(
      data: indice,
      delay: const Duration(milliseconds: 300),
      feedback: feedback,
      childWhenDragging: childWhenDragging,
      child: builder(alca),
    );
  }
}

class _CabecalhoDeCamada extends StatelessWidget {
  const _CabecalhoDeCamada({
    required this.layer,
    required this.indice,
    required this.ativa,
    required this.onAtiva,
    required this.onAjustar,
    this.alca,
  });

  final Layer layer;
  final int indice;
  final bool ativa;
  final VoidCallback onAtiva;
  final void Function({bool? muted, bool? hidden, bool? locked}) onAjustar;

  /// O punho por onde a camada é arrastada para outra posição da pilha.
  ///
  /// Uma alça, e não o cabeçalho inteiro: ele tem botões dentro, e um arrasto
  /// que começasse em qualquer lugar dele brigaria com cada um deles.
  final Widget? alca;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onAtiva,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: ativa
              ? theme.colorScheme.primary.withValues(alpha: 0.10)
              : null,
          border: Border(
            top: BorderSide(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.12),
            ),
            left: BorderSide(
              width: 3,
              color: ativa ? theme.colorScheme.primary : Colors.transparent,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              children: [
                Icon(
                  layer.isAudio ? Icons.music_note : Icons.layers,
                  size: 13,
                  color: theme.hintColor,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    layer.name.isEmpty ? 'Camada ${indice + 1}' : layer.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium,
                  ),
                ),
                ?alca,
              ],
            ),
            Row(
              children: [
                // esconder uma camada que não desenha nada não quer dizer nada;
                // o que se quer dela é o mudo
                if (!layer.isAudio)
                  _Chavinha(
                    ligado: !layer.hidden,
                    ligada: Icons.visibility,
                    desligada: Icons.visibility_off,
                    dica: layer.hidden ? 'mostrar' : 'esconder',
                    onTap: () => onAjustar(hidden: !layer.hidden),
                  ),
                _Chavinha(
                  ligado: !layer.muted,
                  ligada: Icons.volume_up,
                  desligada: Icons.volume_off,
                  dica: layer.muted ? 'com som' : 'sem som',
                  onTap: () => onAjustar(muted: !layer.muted),
                ),
                _Chavinha(
                  ligado: !layer.locked,
                  ligada: Icons.lock_open,
                  desligada: Icons.lock,
                  dica: layer.locked ? 'destravar' : 'travar',
                  onTap: () => onAjustar(locked: !layer.locked),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Chavinha extends StatelessWidget {
  const _Chavinha({
    required this.ligado,
    required this.ligada,
    required this.desligada,
    required this.dica,
    required this.onTap,
  });

  final bool ligado;
  final IconData ligada;
  final IconData desligada;
  final String dica;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return IconButton(
      tooltip: dica,
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 26, minHeight: 24),
      iconSize: 15,
      icon: Icon(
        ligado ? ligada : desligada,
        color: ligado ? theme.hintColor : theme.colorScheme.error,
      ),
    );
  }
}

/// Um bloco na régua, com os quatro gestos.
///
/// É `Stateful` por causa de uma armadilha que fazia o arrasto simplesmente
/// **não funcionar**: aplicando `delta.dx` quadro a quadro, cada passo de 3px
/// virava 0,05 s e o ímã grudava de volta na mesma batida — o bloco só saía do
/// lugar num piparote forte o bastante para vencer a tolerância num único
/// quadro. Agora o gesto guarda de onde partiu e acumula o deslocamento
/// inteiro, então o ímã decide sobre a intenção do arrasto, não sobre um pixel.
class _Block extends StatefulWidget {
  const _Block({
    super.key,
    required this.cut,
    required this.musica,
    required this.selected,
    required this.travada,
    required this.marcaNoCursor,
    required this.pxPerSecond,
    required this.left,
    required this.top,
    required this.height,
    required this.onSelect,
    required this.onMove,
    required this.onTrim,
    required this.onStretch,
    required this.onDragLabel,
    required this.onda,
    required this.duracaoDaPartida,
    required this.onDragInicio,
    required this.onDragMove,
    required this.onDragEnd,
    required this.onTrocarDeCamada,
  });

  final TimelineClip cut;

  /// A música deste bloco, quando ele é um bloco de música. É dela que sai a
  /// onda desenhada e o nome escrito.
  final Track? musica;

  final bool selected;

  /// Camada travada: o clipe ainda se escolhe, mas não se arrasta.
  final bool travada;

  /// A jogada deste bloco está debaixo da cabeça de leitura?
  final bool marcaNoCursor;

  final double pxPerSecond;
  final double left;
  final double top;
  final double height;
  final void Function({bool alternar}) onSelect;
  final ValueChanged<double> onMove;
  final ValueChanged<double> onTrim;
  final ValueChanged<double> onStretch;
  final ValueChanged<String?>? onDragLabel;
  final List<double> onda;
  final double duracaoDaPartida;
  final VoidCallback onDragInicio;
  final ValueChanged<Offset> onDragMove;
  final VoidCallback onDragEnd;

  /// Quantas pistas para cima (negativo) ou para baixo (positivo).
  final ValueChanged<int> onTrocarDeCamada;

  /// Alça de redimensionar. 26px porque o alvo é um dedo, não um mouse — abaixo
  /// disso a pessoa erra e move o bloco quando queria esticá-lo.
  static const double handle = 26;

  @override
  State<_Block> createState() => _BlockState();
}

enum _Gesto { mover, aparar, esticar }

class _BlockState extends State<_Block> {
  /// Valor no início do gesto e deslocamento acumulado desde então.
  double _partiuDe = 0;
  double _andou = 0;

  /// Quanto o dedo subiu ou desceu, para saber em que pista soltar.
  double _subiu = 0;

  void _comecar(_Gesto gesto) {
    // arrastar um bloco que já está numa seleção múltipla não deve desmanchá-la
    if (!widget.selected) widget.onSelect();
    widget.onDragInicio();
    _andou = 0;
    _partiuDe = switch (gesto) {
      _Gesto.mover => widget.cut.atS,
      _Gesto.aparar => widget.cut.atS,
      _Gesto.esticar => widget.cut.durationS,
    };
  }

  void _andar(_Gesto gesto, DragUpdateDetails d) {
    _andou += d.delta.dx / widget.pxPerSecond;
    final alvo = _partiuDe + _andou;
    switch (gesto) {
      case _Gesto.mover:
        widget.onMove(alvo);
      case _Gesto.aparar:
        widget.onTrim(alvo);
      case _Gesto.esticar:
        widget.onStretch(alvo);
    }
    widget.onDragMove(d.globalPosition);
    widget.onDragLabel?.call(_rotulo(gesto));
  }

  String _rotulo(_Gesto gesto) => switch (gesto) {
    _Gesto.mover => 'entra em ${formatClock(widget.cut.atS)} do vídeo',
    _ => '${widget.cut.durationS.toStringAsFixed(2)}s',
  };

  void _soltar() {
    widget.onDragLabel?.call(null);
    widget.onDragEnd();
  }

  /// Shift-clique soma à seleção; clique simples troca.
  void _tocar() =>
      widget.onSelect(alternar: HardwareKeyboard.instance.isShiftPressed);

  /// As alças só aparecem no bloco escolhido: num bloco de 1 s a 60 px/s, duas
  /// alças de 26 px não deixariam onde pegar para mover.
  Widget _alca(_Gesto gesto, Color cor, {required bool esquerda}) => Positioned(
    left: esquerda ? 0 : null,
    right: esquerda ? null : 0,
    top: 0,
    bottom: 0,
    width: _Block.handle,
    child: MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) => _comecar(gesto),
        onHorizontalDragUpdate: (d) => _andar(gesto, d),
        onHorizontalDragEnd: (_) => _soltar(),
        onHorizontalDragCancel: _soltar,
        child: Center(
          child: Container(
            width: 4,
            height: 26,
            decoration: BoxDecoration(
              color: cor,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    ),
  );

  double? get _marca => marcaDoMomento(widget.cut);

  /// (a onda a desenhar, quanto tempo ela cobre).
  ///
  /// Um bloco de música mostra a onda **da música**; um corte, a do áudio da
  /// partida. Nos dois casos o desenho é um recorte da onda inteira, então
  /// aparar o bloco muda o que aparece sem recalcular nada.
  (List<double>, double) get _onda {
    final m = widget.musica;
    if (m != null) return (m.peaks, m.durationS);
    return (widget.onda, widget.duracaoDaPartida);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final musica = widget.musica;
    final style = EventStyle.of(widget.cut.kind);
    // um bloco de música não é um momento da partida: ele tem a cor da trilha,
    // que é a mesma da onda desenhada no alto da régua
    final cor = musica != null ? theme.colorScheme.primary : style.color;
    final rotulo = musica?.name ?? style.label;
    final largura = math.max(10.0, widget.cut.durationS * widget.pxPerSecond);
    final cabeTexto = largura > 56;

    return Positioned(
      left: widget.left,
      top: widget.top,
      width: largura,
      height: widget.height,
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _tocar,
          // arrastar para cima ou para baixo leva o clipe para outra pista. É
          // um gesto separado do horizontal, então os dois não disputam.
          onVerticalDragStart: widget.travada
              ? null
              : (_) {
                  _subiu = 0;
                  if (!widget.selected) widget.onSelect();
                },
          onVerticalDragUpdate: widget.travada
              ? null
              : (d) => _subiu += d.delta.dy,
          onVerticalDragEnd: widget.travada
              ? null
              : (_) {
                  final passos = (_subiu / widget.height).round();
                  if (passos != 0) widget.onTrocarDeCamada(passos);
                  widget.onDragLabel?.call(null);
                },
          onHorizontalDragStart: widget.travada
              ? null
              : (_) => _comecar(_Gesto.mover),
          onHorizontalDragUpdate: widget.travada
              ? null
              : (d) => _andar(_Gesto.mover, d),
          onHorizontalDragEnd: widget.travada ? null : (_) => _soltar(),
          onHorizontalDragCancel: widget.travada ? null : _soltar,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            decoration: BoxDecoration(
              color: cor.withValues(alpha: widget.selected ? 0.45 : 0.25),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: widget.selected ? theme.colorScheme.onSurface : cor,
                width: widget.selected ? 2 : 1,
              ),
            ),
            child: Stack(
              children: [
                // ── o som do jogo dentro deste corte ───────────────────────
                if (_onda.$1.isNotEmpty && _onda.$2 > 0)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: _OndaDoCorte(
                          onda: _onda.$1,
                          duracaoTotal: _onda.$2,
                          de: widget.cut.startS,
                          ate: widget.cut.endS,
                          cor: cor.withValues(alpha: 0.55),
                        ),
                      ),
                    ),
                  ),

                // ── onde a jogada acontece ─────────────────────────────────
                // O bloco é um trecho; o momento é um instante dentro dele. Sem
                // esta marca, encaixar a eliminação na batida seria adivinhar:
                // o que se alinha com a percussão é ela, não a borda do corte.
                if (_marca != null)
                  Positioned(
                    left: _marca! * largura - (widget.marcaNoCursor ? 1.5 : 1),
                    top: 0,
                    bottom: 0,
                    width: widget.marcaNoCursor ? 3 : 2,
                    child: IgnorePointer(
                      child: ColoredBox(
                        // acesa quando a jogada está exatamente sob a cabeça de
                        // leitura: é a confirmação de que o encaixe pegou
                        color: widget.marcaNoCursor
                            ? theme.colorScheme.error
                            : theme.colorScheme.onSurface.withValues(
                                alpha: 0.85,
                              ),
                      ),
                    ),
                  ),
                if (_marca != null)
                  Positioned(
                    left: _marca! * largura - 4,
                    top: 0,
                    child: IgnorePointer(
                      child: Icon(
                        Icons.arrow_drop_down,
                        size: widget.marcaNoCursor ? 14 : 12,
                        color: widget.marcaNoCursor
                            ? theme.colorScheme.error
                            : theme.colorScheme.onSurface,
                      ),
                    ),
                  ),
                if (cabeTexto)
                  Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: widget.selected ? _Block.handle : 6,
                      vertical: 4,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          rotulo,
                          maxLines: 1,
                          overflow: TextOverflow.clip,
                          softWrap: false,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: cor,
                          ),
                        ),
                        Text(
                          '${widget.cut.durationS.toStringAsFixed(1)}s',
                          maxLines: 1,
                          softWrap: false,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.hintColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (widget.selected && !widget.travada) ...[
                  _alca(_Gesto.aparar, cor, esquerda: true),
                  _alca(_Gesto.esticar, cor, esquerda: false),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A onda do áudio da partida no pedaço que este bloco mostra.
///
/// Recorta a onda da partida inteira em vez de guardar uma por bloco: aparar ou
/// esticar o corte muda o pedaço desenhado sozinho, sem recalcular nada.
class _OndaDoCorte extends CustomPainter {
  _OndaDoCorte({
    required this.onda,
    required this.duracaoTotal,
    required this.de,
    required this.ate,
    required this.cor,
  });

  final List<double> onda;
  final double duracaoTotal;
  final double de;
  final double ate;
  final Color cor;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 2 || ate <= de) return;
    final meio = size.height / 2;
    final pincel = Paint()
      ..color = cor
      ..strokeWidth = 1;

    for (var x = 0.0; x < size.width; x += 1) {
      final t = de + (ate - de) * (x / size.width);
      final i = (t / duracaoTotal * onda.length).floor();
      if (i < 0 || i >= onda.length) continue;
      final h = onda[i] * (meio - 3);
      canvas.drawLine(Offset(x, meio - h), Offset(x, meio + h), pincel);
    }
  }

  @override
  bool shouldRepaint(_OndaDoCorte old) =>
      old.de != de || old.ate != ate || old.onda != onda;
}

class _RulerPainter extends CustomPainter {
  _RulerPainter({
    required this.beats,
    required this.durationS,
    required this.pxPerSecond,
    required this.camadas,
    required this.onColor,
    required this.waveColor,
    required this.beatColor,
    required this.textColor,
  });

  /// A grade em tempo de vídeo — a mesma que o ímã usa.
  final List<double> beats;
  final double durationS;
  final double pxPerSecond;
  final int camadas;
  final Color onColor;
  final Color waveColor;
  final Color beatColor;
  final Color textColor;

  @override
  void paint(Canvas canvas, Size size) {
    // ── batidas ────────────────────────────────────────────────────────────
    // Atravessam a altura inteira: é por elas que se alinha um bloco de
    // qualquer camada, e uma linha que morre na faixa de cima não ajuda quem
    // está encaixando o corte três pistas abaixo.
    //
    // Com a música muito afastada as batidas ficam a 2px uma da outra e viram
    // um borrão cinza; aí desenha-se uma a cada N para continuarem legíveis.
    if (beats.length >= 2) {
      final espaco = (beats[1] - beats[0]) * pxPerSecond;
      final passo = espaco < 6 ? (6 / math.max(espaco, 0.5)).ceil() : 1;
      final pincel = Paint()
        ..color = beatColor
        ..strokeWidth = 1;
      for (var i = 0; i < beats.length; i += passo) {
        final x = beats[i] * pxPerSecond;
        if (x > size.width) break;
        canvas.drawLine(
          Offset(x, 0),
          Offset(x, size.height - MusicTimeline.rulerHeight),
          pincel,
        );
      }
    }

    // ── divisórias entre as pistas ─────────────────────────────────────────
    final linha = Paint()
      ..color = beatColor
      ..strokeWidth = 1;
    for (var i = 0; i <= camadas; i++) {
      final y = MusicTimeline.waveHeight + i * MusicTimeline.blockHeight;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), linha);
    }

    // ── régua de tempo ─────────────────────────────────────────────────────
    final passoS = _passoDaRegua();
    final pincelRegua = Paint()
      ..color = beatColor
      ..strokeWidth = 1;
    final topoRegua = size.height - MusicTimeline.rulerHeight;
    for (var s = 0.0; s <= durationS; s += passoS) {
      final x = s * pxPerSecond;
      canvas.drawLine(
        Offset(x, topoRegua),
        Offset(x, topoRegua + 5),
        pincelRegua,
      );
      final texto = TextPainter(
        text: TextSpan(
          text: _relogio(s),
          style: TextStyle(color: textColor, fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      texto.paint(canvas, Offset(x + 3, topoRegua + 5));
    }

    // ── o primeiro quadro ──────────────────────────────────────────────────
    // A régua começa no começo do vídeo, e a marca diz isso sem depender de o
    // usuário lembrar que zero é zero.
    canvas.drawLine(
      Offset(0, 0),
      Offset(0, size.height),
      Paint()
        ..color = onColor
        ..strokeWidth = 2,
    );
  }

  /// De quanto em quanto tempo a régua ganha um número, para os rótulos não se
  /// atropelarem em nenhum zoom.
  double _passoDaRegua() {
    for (final passo in const [1.0, 2.0, 5.0, 10.0, 15.0, 30.0, 60.0]) {
      if (passo * pxPerSecond >= 56) return passo;
    }
    return 120;
  }

  static String _relogio(double s) {
    final t = s.round();
    return '${t ~/ 60}:${(t % 60).toString().padLeft(2, '0')}';
  }

  @override
  bool shouldRepaint(_RulerPainter old) =>
      old.beats != beats ||
      old.pxPerSecond != pxPerSecond ||
      old.durationS != durationS ||
      old.camadas != camadas;
}
