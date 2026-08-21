import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api.dart';
import 'highlight_style.dart';

/// A régua da música com os blocos por cima — o coração da montagem manual.
///
/// Tudo é desenhado na escala da música: a forma de onda para achar o refrão a
/// olho, as batidas para saber onde a percussão cai, e os blocos exatamente
/// onde o usuário os pôs. Arrastar um bloco move o corte; arrastar a borda
/// direita muda a duração dele.
///
/// A faixa rola na horizontal. Arrastar o fundo rola a régua; arrastar um
/// bloco move o bloco — o gesto do filho ganha do gesto do scroll, que é
/// justamente o que se espera ao pegar num bloco.
class MusicTimeline extends StatelessWidget {
  const MusicTimeline({
    super.key,
    required this.track,
    required this.cuts,
    required this.selected,
    required this.pxPerSecond,
    required this.videoStartS,
    required this.playheadS,
    required this.scroll,
    required this.onSeek,
    required this.onSelect,
    required this.onMove,
    required this.onResize,
    this.fallbackDurationS = 60,
  });

  final Track? track;
  final List<TimelineCut> cuts;
  final int? selected;

  /// Zoom: quantos pixels vale um segundo de música.
  final double pxPerSecond;

  /// Onde, na música, o vídeo começa. Os blocos são posicionados em tempo de
  /// **vídeo**, então é este valor que os desloca na régua da música.
  final double videoStartS;
  final double playheadS;
  final ScrollController scroll;

  final ValueChanged<double> onSeek;
  final ValueChanged<int?> onSelect;

  /// (índice, nova posição em tempo de vídeo)
  final void Function(int index, double atS) onMove;

  /// (índice, nova duração)
  final void Function(int index, double durationS) onResize;

  /// Régua a desenhar quando ainda não há música escolhida.
  final double fallbackDurationS;

  static const double waveHeight = 76;
  static const double blockHeight = 58;
  static const double rulerHeight = 20;
  static const double totalHeight = waveHeight + blockHeight + rulerHeight;

  double get _durationS {
    final musica = track?.durationS ?? 0;
    var fim = videoStartS;
    for (final c in cuts) {
      fim = math.max(fim, videoStartS + c.untilS);
    }
    // uma folga no fim para dar onde soltar o último bloco
    return math.max(math.max(musica, fim + 4), fallbackDurationS);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final largura = _durationS * pxPerSecond;

    return SizedBox(
      height: totalHeight,
      child: SingleChildScrollView(
        controller: scroll,
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: largura,
          height: totalHeight,
          child: Stack(
            children: [
              // fundo: onda, batidas, régua e marcador de início
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) =>
                      onSeek(d.localPosition.dx / pxPerSecond),
                  child: CustomPaint(
                    painter: _RulerPainter(
                      peaks: track?.peaks ?? const [],
                      beats: track?.beats ?? const [],
                      durationS: _durationS,
                      musicDurationS: track?.durationS ?? 0,
                      pxPerSecond: pxPerSecond,
                      videoStartS: videoStartS,
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

              // os blocos
              for (var i = 0; i < cuts.length; i++)
                _Block(
                  cut: cuts[i],
                  index: i,
                  selected: selected == i,
                  pxPerSecond: pxPerSecond,
                  left: (videoStartS + cuts[i].atS) * pxPerSecond,
                  top: waveHeight,
                  height: blockHeight,
                  onSelect: () => onSelect(i),
                  onMove: (delta) => onMove(
                    i,
                    cuts[i].atS + delta / pxPerSecond,
                  ),
                  onResize: (delta) => onResize(
                    i,
                    cuts[i].durationS + delta / pxPerSecond,
                  ),
                ),

              // a cabeça de leitura, por último para ficar por cima de tudo
              Positioned(
                left: playheadS * pxPerSecond - 1,
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
    );
  }
}

class _Block extends StatelessWidget {
  const _Block({
    required this.cut,
    required this.index,
    required this.selected,
    required this.pxPerSecond,
    required this.left,
    required this.top,
    required this.height,
    required this.onSelect,
    required this.onMove,
    required this.onResize,
  });

  final TimelineCut cut;
  final int index;
  final bool selected;
  final double pxPerSecond;
  final double left;
  final double top;
  final double height;
  final VoidCallback onSelect;
  final ValueChanged<double> onMove;
  final ValueChanged<double> onResize;

  /// Área da borda direita que arrasta a duração em vez da posição. Larga o
  /// bastante para o dedo acertar num celular.
  static const double handle = 22;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = EventStyle.of(cut.kind);
    final largura = math.max(8.0, cut.durationS * pxPerSecond);

    return Positioned(
      left: left,
      top: top,
      width: largura,
      height: height,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onSelect,
        onHorizontalDragStart: (_) => onSelect(),
        onHorizontalDragUpdate: (d) => onMove(d.delta.dx),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
            color: style.color.withValues(alpha: selected ? 0.45 : 0.25),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: selected ? theme.colorScheme.onSurface : style.color,
              width: selected ? 2 : 1,
            ),
          ),
          child: Stack(
            children: [
              if (largura > 44)
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 4, handle, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        style.label,
                        maxLines: 1,
                        overflow: TextOverflow.clip,
                        softWrap: false,
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: style.color),
                      ),
                      Text(
                        '${cut.durationS.toStringAsFixed(1)}s',
                        maxLines: 1,
                        softWrap: false,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.hintColor),
                      ),
                    ],
                  ),
                ),
              // pega da borda direita: muda a duração
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                width: handle,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragStart: (_) => onSelect(),
                  onHorizontalDragUpdate: (d) => onResize(d.delta.dx),
                  child: Center(
                    child: Container(
                      width: 3,
                      height: 20,
                      decoration: BoxDecoration(
                        color: style.color,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RulerPainter extends CustomPainter {
  _RulerPainter({
    required this.peaks,
    required this.beats,
    required this.durationS,
    required this.musicDurationS,
    required this.pxPerSecond,
    required this.videoStartS,
    required this.onColor,
    required this.waveColor,
    required this.beatColor,
    required this.textColor,
  });

  final List<double> peaks;
  final List<double> beats;
  final double durationS;
  final double musicDurationS;
  final double pxPerSecond;
  final double videoStartS;
  final Color onColor;
  final Color waveColor;
  final Color beatColor;
  final Color textColor;

  @override
  void paint(Canvas canvas, Size size) {
    final alturaOnda = MusicTimeline.waveHeight;
    final meio = alturaOnda / 2;

    // ── forma de onda ──────────────────────────────────────────────────────
    // Um traço por pixel, e não um por pico: com a música afastada há mais
    // picos que pixels, e desenhar todos só empilharia traços no mesmo lugar.
    if (peaks.isNotEmpty && musicDurationS > 0) {
      final pincel = Paint()
        ..color = waveColor
        ..strokeWidth = 1;
      final largura = math.min(size.width, musicDurationS * pxPerSecond);
      for (var x = 0.0; x < largura; x += 1) {
        final s = x / pxPerSecond;
        final i = (s / musicDurationS * peaks.length).floor();
        if (i < 0 || i >= peaks.length) continue;
        final h = peaks[i] * (meio - 4);
        canvas.drawLine(Offset(x, meio - h), Offset(x, meio + h), pincel);
      }
    }

    // ── batidas ────────────────────────────────────────────────────────────
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
        canvas.drawLine(Offset(x, 0), Offset(x, alturaOnda), pincel);
      }
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

    // ── onde o vídeo começa ────────────────────────────────────────────────
    // Antes desta linha a música existe mas o vídeo ainda não começou: é o
    // ponto da faixa que vai virar o primeiro quadro.
    final x = videoStartS * pxPerSecond;
    canvas.drawLine(
      Offset(x, 0),
      Offset(x, size.height),
      Paint()
        ..color = onColor
        ..strokeWidth = 2,
    );
    canvas.drawPath(
      Path()
        ..moveTo(x, 0)
        ..lineTo(x + 12, 0)
        ..lineTo(x, 10)
        ..close(),
      Paint()..color = onColor,
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
      old.peaks != peaks ||
      old.beats != beats ||
      old.pxPerSecond != pxPerSecond ||
      old.durationS != durationS ||
      old.videoStartS != videoStartS;
}
