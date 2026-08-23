import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../api.dart';
import '../montage.dart';

/// O monitor da montagem: mostra o que o vídeo vai ser, antes de pedi-lo.
///
/// Não renderiza nada. Abre a **gravação original** e busca dentro dela o
/// instante que corresponde à cabeça de leitura — se ela está sobre um bloco
/// que começa aos 3 min da partida, é aos 3 min que a gravação é posicionada.
/// Onde não há bloco, tela preta: o mesmo que o servidor vai gerar ali.
///
/// Renderizar de verdade a cada ajuste custaria uma volta inteira pelo ffmpeg
/// por arrasto. Buscar dentro do arquivo que já existe é instantâneo, e é o que
/// qualquer editor faz enquanto você edita.
///
/// > O que este preview **não** garante é sincronia de quadro com a música
/// > durante a reprodução: são dois elementos de mídia independentes, e a
/// > emenda entre blocos é feita por busca. Dentro de um bloco a imagem corre
/// > sozinha, e um blocozinho de 1 s pode terminar alguns quadros adiantado. O
/// > corte exato é o do arquivo final, que o servidor monta com ffmpeg.
class PreviewPlayer extends StatefulWidget {
  const PreviewPlayer({
    super.key,
    required this.videoUrl,
    required this.cuts,
    required this.atS,
    required this.playing,
    this.textos = const [],
    this.selecao = const {},
    this.onSelecionarTexto,
    this.onMoverTexto,
    this.onArrastando,
  });

  final String videoUrl;
  final List<TimelineClip> cuts;

  /// Onde a cabeça de leitura está, em tempo de **vídeo montado**.
  final double atS;
  final bool playing;

  /// Os clipes de texto da montagem. O monitor os desenha por cima da imagem,
  /// no lugar e no tamanho em que o servidor vai desenhá-los — é a única forma
  /// de decidir onde uma frase fica sem gerar o vídeo para ver.
  final List<TimelineClip> textos;

  /// Quem está selecionado, para a frase escolhida se destacar.
  final Set<String> selecao;

  final ValueChanged<String>? onSelecionarTexto;

  /// (id, x, y) — a posição nova, em fração da metade do quadro, como o
  /// servidor a entende.
  final void Function(String id, double x, double y)? onMoverTexto;

  /// Texto para a tela mostrar enquanto o dedo arrasta a frase; `null` ao
  /// soltar. Serve ao mesmo propósito do rótulo de arrasto da régua.
  final ValueChanged<String?>? onArrastando;

  @override
  State<PreviewPlayer> createState() => _PreviewPlayerState();
}

class _PreviewPlayerState extends State<PreviewPlayer> {
  VideoPlayerController? _c;
  String? _erro;
  bool _reabrindo = false;

  /// Quantas vezes o player já morreu e foi trazido de volta sozinho.
  ///
  /// Uma gravação de meio giga entregue por `Range`, com dezenas de buscas por
  /// segundo enquanto se arrasta, às vezes derruba o elemento de vídeo do
  /// navegador. Antes disto ele ficava preto até a página ser recarregada — e
  /// recarregar custava a montagem inteira.
  int _quedas = 0;
  static const _maxQuedas = 4;

  /// Uma busca por vez. `didUpdateWidget` dispara a cada quadro do arrasto, e
  /// buscas sobrepostas são justamente o que faz o elemento engasgar.
  bool _ocupado = false;

  DateTime _ultimaBusca = DateTime.fromMillisecondsSinceEpoch(0);
  int? _blocoAtual;

  @override
  void initState() {
    super.initState();
    _abrir();
  }

  @override
  void dispose() {
    _c?.removeListener(_vigiar);
    _c?.dispose();
    super.dispose();
  }

  Future<void> _abrir({Duration? retomarEm}) async {
    final c = VideoPlayerController.networkUrl(Uri.parse(widget.videoUrl));
    try {
      await c.initialize();
      await c.setVolume(0); // quem manda no som é a música da montagem
      if (retomarEm != null) await c.seekTo(retomarEm);
    } catch (e) {
      await c.dispose();
      if (mounted) setState(() => _erro = '$e');
      return;
    }
    if (!mounted) {
      await c.dispose();
      return;
    }
    c.addListener(_vigiar);
    setState(() {
      _c = c;
      _erro = null;
      _reabrindo = false;
    });
    _acompanhar(forcar: true);
  }

  /// Percebe o player morrer e o traz de volta no mesmo ponto.
  void _vigiar() {
    final c = _c;
    if (c == null || _reabrindo || !c.value.hasError) return;
    _reabrindo = true;
    final onde = c.value.position;
    _quedas++;
    if (_quedas > _maxQuedas) {
      setState(() {
        _erro = 'o player parou de responder; toque para tentar de novo';
        _reabrindo = false;
      });
      return;
    }
    unawaited(_ressuscitar(onde));
  }

  Future<void> _ressuscitar(Duration onde) async {
    final morto = _c;
    setState(() => _c = null);
    morto?.removeListener(_vigiar);
    await morto?.dispose();
    if (!mounted) return;
    await _abrir(retomarEm: onde);
  }

  Future<void> _tentarDeNovo() async {
    _quedas = 0;
    setState(() {
      _erro = null;
      _reabrindo = true;
    });
    await _ressuscitar(Duration.zero);
  }

  @override
  void didUpdateWidget(PreviewPlayer old) {
    super.didUpdateWidget(old);
    if (old.videoUrl != widget.videoUrl) {
      _quedas = 0;
      unawaited(_ressuscitar(Duration.zero));
      return;
    }
    _acompanhar(forcar: widget.playing != old.playing);
  }

  /// Põe a gravação no instante que a cabeça de leitura pede.
  Future<void> _acompanhar({bool forcar = false}) async {
    final c = _c;
    if (c == null || !c.value.isInitialized || c.value.hasError) return;
    if (_ocupado) return;

    final origem = origemEm(widget.cuts, widget.atS);
    final bloco = blocoEm(widget.cuts, widget.atS);

    // buraco (ou depois do fim): nada a mostrar, e nada a tocar
    if (origem == null) {
      _blocoAtual = null;
      if (c.value.isPlaying) {
        _ocupado = true;
        try {
          await c.pause();
        } finally {
          _ocupado = false;
        }
      }
      if (mounted) setState(() {});
      return;
    }

    // pedir um instante além do fim do arquivo é o tipo de coisa que derruba o
    // elemento de vídeo, e um corte pode ter sido esticado até lá
    final limite = c.value.duration.inMilliseconds / 1000.0;
    final alvo = limite > 0 ? origem.clamp(0.0, limite - 0.05) : origem;

    final trocouDeBloco = bloco != _blocoAtual;
    _blocoAtual = bloco;

    // Tocando, a imagem corre sozinha dentro do bloco; só se busca ao entrar
    // num bloco novo ou quando ela se afasta demais do que devia mostrar.
    final agora = c.value.position.inMilliseconds / 1000.0;
    final desviou = (agora - alvo).abs() > 0.34;
    final recente =
        DateTime.now().difference(_ultimaBusca) <
        const Duration(milliseconds: 120);

    _ocupado = true;
    try {
      if (forcar || trocouDeBloco || desviou) {
        if (!(recente && !forcar && !trocouDeBloco)) {
          _ultimaBusca = DateTime.now();
          await c.seekTo(Duration(milliseconds: (alvo * 1000).round()));
        }
      }
      if (widget.playing && !c.value.isPlaying) {
        await c.play();
      } else if (!widget.playing && c.value.isPlaying) {
        await c.pause();
      }
    } catch (_) {
      // uma busca que falha não pode derrubar a tela: o vigia cuida de
      // reabrir o player se ele tiver morrido de verdade
    } finally {
      _ocupado = false;
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = _c;
    final naTelaPreta = origemEm(widget.cuts, widget.atS) == null;
    final vivo = c != null && c.value.isInitialized && !c.value.hasError;

    return AspectRatio(
      aspectRatio: vivo ? c.value.aspectRatio : 16 / 9,
      child: ColoredBox(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // No buraco o quadro anterior não pode ficar à mostra: ali o vídeo
            // vai ser preto de verdade, e mostrar a imagem velha mentiria sobre
            // o que vai sair.
            if (vivo && !naTelaPreta) VideoPlayer(c),

            // O aviso de tela preta não pega toque: ele fica no meio do
            // quadro, que é justamente onde o texto costuma estar, e um aviso
            // roubando o arrasto da frase seria o pior lugar possível.
            if (naTelaPreta && _erro == null)
              IgnorePointer(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.crop_din,
                        color: theme.hintColor.withValues(alpha: 0.6),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        widget.cuts.isEmpty
                            ? 'sem cortes ainda'
                            : 'tela preta — só a música aqui',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.hintColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // ── o texto, por cima da imagem ──────────────────────────────
            //
            // Desenhado com a mesma conta do servidor: o corpo é fração da
            // altura do quadro e a posição é deslocamento do centro pela
            // metade dele. O que se vê aqui é o que vai sair.
            for (final t in widget.textos)
              if (widget.atS >= t.atS - 1e-6 && widget.atS < t.untilS - 1e-6)
                _TextoNoQuadro(
                  key: ValueKey('texto-no-quadro-${t.id}'),
                  clip: t,
                  escolhido: widget.selecao.contains(t.id),
                  onEscolher: () => widget.onSelecionarTexto?.call(t.id),
                  onMover: widget.onMoverTexto == null
                      ? null
                      : (x, y) => widget.onMoverTexto!(t.id, x, y),
                  onArrastando: widget.onArrastando,
                ),

            if (_erro != null)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _erro!,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                      const SizedBox(height: 8),
                      // a montagem não se perde por causa do player: dá para
                      // continuar editando pela onda e pelas batidas
                      TextButton.icon(
                        onPressed: _tentarDeNovo,
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('Tentar de novo'),
                      ),
                    ],
                  ),
                ),
              )
            else if (c == null || _reabrindo)
              // idem: enquanto o vídeo abre, o texto continua arrastável
              const IgnorePointer(
                child: Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Uma frase desenhada sobre o monitor, e arrastável.
///
/// Arrastar aqui é o jeito natural de dizer onde o texto fica: a alternativa
/// era digitar dois números e gerar o vídeo para conferir.
class _TextoNoQuadro extends StatefulWidget {
  const _TextoNoQuadro({
    super.key,
    required this.clip,
    required this.escolhido,
    required this.onEscolher,
    required this.onMover,
    required this.onArrastando,
  });

  final TimelineClip clip;
  final bool escolhido;
  final VoidCallback onEscolher;
  final void Function(double x, double y)? onMover;
  final ValueChanged<String?>? onArrastando;

  @override
  State<_TextoNoQuadro> createState() => _TextoNoQuadroState();
}

class _TextoNoQuadroState extends State<_TextoNoQuadro> {
  /// Quanto o dedo já andou neste gesto, e de onde a frase partiu.
  ///
  /// O deslocamento é somado aqui, e não lido da posição do ponteiro: o
  /// primeiro `onPanUpdate` chega com a posição do instante em que o gesto foi
  /// aceito — a mesma do `onPanStart` —, então medir "posição menos origem"
  /// dava zero, e um arrasto de um salto só (o de um teste, ou o de um dedo
  /// rápido) não movia nada.
  Offset _andou = Offset.zero;
  double _x0 = 0;
  double _y0 = 0;

  @override
  Widget build(BuildContext context) {
    final estilo = widget.clip.textStyle;
    final t = widget.clip.transform;

    return LayoutBuilder(
      builder: (context, caixa) {
        final corpo = estilo.size * caixa.maxHeight;
        final contorno = estilo.outline * corpo;
        final cor = _cores[estilo.color] ?? Colors.white;
        final corDoContorno = _cores[estilo.outlineColor] ?? Colors.black;

        return Align(
          // é a mesma conta do `drawtext`: o centro da frase cai a `x` metades
          // de quadro do centro da tela
          alignment: Alignment(t.x, t.y),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // `down`, e não `start`: com o padrão, o deslocamento gasto para
            // vencer o slop é descartado e um arrasto entregue de uma vez só
            // (dedo rápido, ou um teste) não produz update nenhum — a frase
            // não saía do lugar
            dragStartBehavior: DragStartBehavior.down,
            onTap: widget.onEscolher,
            onPanStart: widget.onMover == null
                ? null
                : (_) {
                    widget.onEscolher();
                    _andou = Offset.zero;
                    _x0 = t.x;
                    _y0 = t.y;
                  },
            onPanUpdate: widget.onMover == null
                ? null
                : (d) {
                    _andou += d.delta;
                    final x = (_x0 + _andou.dx / (caixa.maxWidth / 2)).clamp(
                      -1.0,
                      1.0,
                    );
                    final y = (_y0 + _andou.dy / (caixa.maxHeight / 2)).clamp(
                      -1.0,
                      1.0,
                    );
                    widget.onArrastando?.call(
                      'texto em ${(x * 100).round()}%, ${(y * 100).round()}% '
                      'do centro',
                    );
                    widget.onMover!(x, y);
                  },
            onPanEnd: (_) {
              _andou = Offset.zero;
              widget.onArrastando?.call(null);
            },
            child: Container(
              // a chave fica na frase, e não na área do quadro: é nela que se
              // toca, e é dela que o arrasto parte
              key: ValueKey('frase-${widget.clip.id}'),
              padding: const EdgeInsets.all(4),
              decoration: widget.escolhido
                  ? BoxDecoration(
                      border: Border.all(
                        color: Theme.of(context).colorScheme.primary,
                        width: 1,
                      ),
                    )
                  : null,
              child: Stack(
                children: [
                  // o contorno é o que faz texto branco sobreviver a cena
                  // clara; sem ele o preview mentiria sobre a legibilidade
                  if (contorno > 0)
                    Text(
                      widget.clip.text,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: corpo,
                        fontWeight: FontWeight.bold,
                        height: 1.1,
                        foreground: Paint()
                          ..style = PaintingStyle.stroke
                          ..strokeWidth = contorno
                          ..color = corDoContorno,
                      ),
                    ),
                  Text(
                    widget.clip.text,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: corpo,
                      fontWeight: FontWeight.bold,
                      height: 1.1,
                      color: cor,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// As mesmas cores que o servidor aceita, do lado do app.
  static const _cores = <String, Color>{
    'white': Colors.white,
    'yellow': Color(0xFFFFEB3B),
    'orange': Color(0xFFFF9800),
    'red': Color(0xFFF44336),
    'cyan': Color(0xFF00E5FF),
    'black': Colors.black,
  };
}
