import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../api.dart';
import '../montage.dart';
import '../widgets/highlight_style.dart';
import '../widgets/music_timeline.dart';

/// Montar o vídeo à mão: ouvir a música e pôr cada momento onde se quiser.
///
/// É a outra metade do sistema. A análise diz *quando* cada coisa aconteceu —
/// eliminação, dardo, pedrada — e para por aí; aqui é o usuário que decide
/// quais entram, em que ponto da música cada um cai e quanto tempo dura.
///
/// A música sobe antes de existir vídeo nenhum, justamente porque não dá para
/// decidir nada disso sem ouvi-la. O que a tela desenha — onda, batidas,
/// duração — vem do servidor junto com ela.
class TimelineScreen extends StatefulWidget {
  const TimelineScreen({super.key, required this.job});

  final Job job;

  @override
  State<TimelineScreen> createState() => _TimelineScreenState();
}

/// Eventos que valem um bloco. `death` e `low_hp` ficam de fora: são o contexto
/// que faz uma jogada valer, não a jogada.
const _momentosUteis = {'kill', 'sleep', 'stun', 'ult_negated', 'escape'};

class _TimelineScreenState extends State<TimelineScreen> {
  final _api = ApiClient();
  final _scroll = ScrollController();
  final _titulo = TextEditingController(text: 'Minha montagem');

  Track? _track;
  VideoPlayerController? _audio;
  bool _carregandoMusica = false;
  String? _erroMusica;

  final List<TimelineCut> _cuts = [];
  int? _sel;

  /// Zoom da régua. 60 px/s mostra uns 10 segundos num celular — perto o
  /// bastante para encaixar na batida sem precisar de precisão de cirurgião.
  double _px = 60;
  bool _ima = true;

  /// Onde, na música, o vídeo começa.
  double _videoStart = 0;
  double _cursor = 0;

  bool _enviando = false;
  String? _erro;

  @override
  void initState() {
    super.initState();
    final prontas = widget.job.tracks.where((t) => t.isReady).toList();
    if (prontas.isNotEmpty) _usarMusica(prontas.last);
  }

  @override
  void dispose() {
    _audio?.dispose();
    _scroll.dispose();
    _titulo.dispose();
    super.dispose();
  }

  // ── música ────────────────────────────────────────────────────────────────

  List<DetectionEvent> get _momentos => widget.job.events
      .where((e) => _momentosUteis.contains(e.kind))
      .toList();

  /// As batidas em tempo de **vídeo**: é nelas que os blocos grudam, porque a
  /// posição de um bloco é medida a partir do início do vídeo, não da música.
  List<double> get _batidas {
    final t = _track;
    if (t == null) return const [];
    return [
      for (final b in t.beats)
        if (b >= _videoStart) b - _videoStart,
    ];
  }

  Future<void> _usarMusica(Track track) async {
    setState(() {
      _track = track;
      _erroMusica = null;
    });
    final antigo = _audio;
    _audio = null;
    await antigo?.dispose();

    final controller = VideoPlayerController.networkUrl(
      Uri.parse(track.audioUrl),
    );
    try {
      await controller.initialize();
    } catch (e) {
      // sem player a montagem continua possível: a onda e as batidas já estão
      // desenhadas, e é por elas que se encaixa o corte
      await controller.dispose();
      if (mounted) {
        setState(() => _erroMusica = 'não consegui tocar a música aqui ($e)');
      }
      return;
    }
    controller.addListener(_acompanharAudio);
    if (!mounted) {
      await controller.dispose();
      return;
    }
    setState(() => _audio = controller);
  }

  void _acompanharAudio() {
    final c = _audio;
    if (c == null || !c.value.isInitialized) return;
    final t = c.value.position.inMilliseconds / 1000.0;
    if ((t - _cursor).abs() < 0.02) return;
    setState(() => _cursor = t);
    if (c.value.isPlaying) _seguirCursor(t);
  }

  /// Mantém a cabeça de leitura na tela enquanto a música toca.
  void _seguirCursor(double t) {
    if (!_scroll.hasClients) return;
    final x = t * _px;
    final janela = _scroll.position.viewportDimension;
    final inicio = _scroll.offset;
    if (x < inicio + 40 || x > inicio + janela - 80) {
      _scroll.jumpTo(
        (x - janela / 3).clamp(0.0, _scroll.position.maxScrollExtent),
      );
    }
  }

  Future<void> _escolherMusica() async {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['mp3', 'wav', 'm4a', 'aac', 'ogg', 'flac'],
    );
    if (picked == null) return;
    setState(() {
      _carregandoMusica = true;
      _erroMusica = null;
    });
    try {
      final enviada = await _api.uploadTrack(
        jobId: widget.job.id,
        audio: picked,
      );
      final pronta = await _api.waitForTrack(enviada.id);
      if (!mounted) return;
      if (pronta.isFailed) {
        setState(() => _erroMusica = pronta.error ?? 'não consegui ouvir essa música');
      } else {
        await _usarMusica(pronta);
      }
    } catch (e) {
      if (mounted) setState(() => _erroMusica = '$e');
    } finally {
      if (mounted) setState(() => _carregandoMusica = false);
    }
  }

  void _tocarOuPausar() {
    final c = _audio;
    if (c == null) return;
    setState(() => c.value.isPlaying ? c.pause() : c.play());
  }

  Future<void> _irPara(double s) async {
    final limite = _track?.durationS ?? double.infinity;
    final t = s.clamp(0.0, limite);
    setState(() => _cursor = t);
    await _audio?.seekTo(Duration(milliseconds: (t * 1000).round()));
  }

  // ── blocos ────────────────────────────────────────────────────────────────

  void _adicionar(DetectionEvent e) {
    setState(() {
      // o primeiro bloco define onde o vídeo começa: sem isso, encaixar o
      // primeiro corte no refrão daria minutos de tela preta antes dele
      if (_cuts.isEmpty) _videoStart = _cursor;

      final at = math.max(0.0, _cursor - _videoStart);
      final novo = cutForMoment(
        e,
        atS: at,
        beats: _batidas,
        sourceDurationS: widget.job.durationS,
      );
      final vaga = proximaVaga(_cuts, novo.atS, novo.durationS);
      _cuts.add(novo.copyWith(atS: _ima ? snapToBeat(vaga, _batidas) : vaga));
      _cuts.sort((a, b) => a.atS.compareTo(b.atS));
      _sel = _cuts.indexWhere((c) => c.sourceT == e.t && c.atS >= vaga - 1e-6);
    });
  }

  void _mover(int i, double atS) {
    setState(() {
      _cuts[i] = mover(_cuts, i, atS, beats: _batidas, snap: _ima);
    });
  }

  void _redimensionar(int i, double duracao) {
    setState(() {
      _cuts[i] = redimensionar(
        _cuts,
        i,
        duracao,
        beats: _batidas,
        snap: _ima,
        sourceDurationS: widget.job.durationS,
      );
    });
  }

  void _apagar(int i) {
    setState(() {
      _cuts.removeAt(i);
      _sel = null;
    });
  }

  /// Move o conteúdo dentro do bloco sem mexer no bloco.
  ///
  /// É o ajuste fino do enquadramento: o mesmo 1,5 s de vídeo, começando um
  /// tiquinho antes ou depois na gravação.
  void _deslocar(int i, double delta) {
    setState(() {
      final c = _cuts[i];
      final limite = math.max(0.0, widget.job.durationS - c.durationS);
      _cuts[i] = c.copyWith(
        startS: (c.startS + delta).clamp(0.0, limite),
      );
    });
  }

  Future<void> _gerar() async {
    setState(() {
      _enviando = true;
      _erro = null;
    });
    try {
      await _api.createRender(
        jobId: widget.job.id,
        montages: [
          Montage(
            title: _titulo.text.trim(),
            trackId: _track?.id,
            musicStartS: _videoStart,
            cuts: _cuts,
          ),
        ],
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _erro = '$e';
          _enviando = false;
        });
      }
    }
  }

  // ── tela ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final duracao = duracaoDoVideo(_cuts);
    final preto = duracaoEmPreto(_cuts);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Montar vídeo'),
        actions: [
          IconButton(
            tooltip: _ima ? 'ímã ligado: gruda na batida' : 'ímã desligado',
            onPressed: () => setState(() => _ima = !_ima),
            icon: Icon(_ima ? Icons.grid_on : Icons.grid_off),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 32),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _Musica(
              track: _track,
              tracks: widget.job.tracks.where((t) => t.isReady).toList(),
              carregando: _carregandoMusica,
              erro: _erroMusica,
              enabled: !_enviando,
              onEscolher: _escolherMusica,
              onTrocar: _usarMusica,
            ),
          ),
          const SizedBox(height: 14),

          // ── transporte ────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                IconButton.filledTonal(
                  onPressed: _audio == null ? null : _tocarOuPausar,
                  icon: Icon(
                    (_audio?.value.isPlaying ?? false)
                        ? Icons.pause
                        : Icons.play_arrow,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  formatClock(_cursor),
                  style: theme.textTheme.titleMedium,
                ),
                const Spacer(),
                const Icon(Icons.zoom_out, size: 18),
                SizedBox(
                  width: 120,
                  child: Slider(
                    value: _px,
                    min: 20,
                    max: 220,
                    onChanged: (v) => setState(() => _px = v),
                  ),
                ),
                const Icon(Icons.zoom_in, size: 18),
              ],
            ),
          ),

          // ── a régua da música com os blocos ───────────────────────────────
          MusicTimeline(
            track: _track,
            cuts: _cuts,
            selected: _sel,
            pxPerSecond: _px,
            videoStartS: _videoStart,
            playheadS: _cursor,
            scroll: _scroll,
            onSeek: _irPara,
            onSelect: (i) => setState(() => _sel = i),
            onMove: _mover,
            onResize: _redimensionar,
          ),

          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'O vídeo começa em ${formatClock(_videoStart)} da música.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.hintColor),
                  ),
                ),
                TextButton(
                  onPressed: _cuts.isEmpty && _audio == null
                      ? null
                      : () => setState(() => _videoStart = _cursor),
                  child: const Text('Começar aqui'),
                ),
              ],
            ),
          ),

          if (_sel != null) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _BlocoSelecionado(
                cut: _cuts[_sel!],
                onDuracao: (d) => _redimensionar(_sel!, d),
                onDeslocar: (d) => _deslocar(_sel!, d),
                onParaOCursor: () =>
                    _mover(_sel!, math.max(0, _cursor - _videoStart)),
                onApagar: () => _apagar(_sel!),
              ),
            ),
          ],

          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _Momentos(
              momentos: _momentos,
              usados: {for (final c in _cuts) c.sourceT},
              enabled: !_enviando,
              onAdicionar: _adicionar,
            ),
          ),

          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _titulo,
                  enabled: !_enviando,
                  decoration: const InputDecoration(
                    labelText: 'Nome do vídeo',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  _cuts.isEmpty
                      ? 'Toque num momento abaixo para pôr o primeiro corte '
                          'onde a música estiver.'
                      : '${_cuts.length} corte(s)  ·  vídeo de '
                          '${formatDuration(duracao)}'
                          '${preto > 0.05 ? '  ·  ${formatDuration(preto)} '
                              'de tela preta' : ''}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.hintColor),
                ),
                if (preto > 0.05)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'Os espaços vazios entre os blocos ficam pretos, com a '
                      'música tocando.',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.hintColor),
                    ),
                  ),
                if (_erro != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.error.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      _erro!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                if (_enviando)
                  const Center(child: CircularProgressIndicator())
                else
                  FilledButton.icon(
                    onPressed: _cuts.isEmpty ? null : _gerar,
                    icon: const Icon(Icons.movie_creation_outlined),
                    label: Text(
                      _cuts.isEmpty
                          ? 'Ponha ao menos um corte'
                          : 'Gerar este vídeo',
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Musica extends StatelessWidget {
  const _Musica({
    required this.track,
    required this.tracks,
    required this.carregando,
    required this.erro,
    required this.enabled,
    required this.onEscolher,
    required this.onTrocar,
  });

  final Track? track;
  final List<Track> tracks;
  final bool carregando;
  final String? erro;
  final bool enabled;
  final VoidCallback onEscolher;
  final ValueChanged<Track> onTrocar;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = track;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.music_note, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    t?.name ?? 'Sem música',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                if (carregando)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  TextButton(
                    onPressed: enabled ? onEscolher : null,
                    child: Text(t == null ? 'Enviar' : 'Trocar'),
                  ),
              ],
            ),
            Text(
              carregando
                  ? 'enviando e ouvindo a música…'
                  : t == null
                      ? 'sem música o vídeo sai com o áudio da partida'
                      : '${t.bpm.round()} BPM  ·  '
                          '${formatDuration(t.durationS)}  ·  '
                          '${t.beats.length} batidas',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.hintColor),
            ),
            if (tracks.length > 1) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                children: [
                  for (final outra in tracks)
                    ChoiceChip(
                      label: Text(
                        outra.name,
                        overflow: TextOverflow.ellipsis,
                      ),
                      selected: outra.id == t?.id,
                      onSelected:
                          enabled ? (_) => onTrocar(outra) : null,
                    ),
                ],
              ),
            ],
            if (erro != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  erro!,
                  style: TextStyle(
                    color: theme.colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _BlocoSelecionado extends StatelessWidget {
  const _BlocoSelecionado({
    required this.cut,
    required this.onDuracao,
    required this.onDeslocar,
    required this.onParaOCursor,
    required this.onApagar,
  });

  final TimelineCut cut;
  final ValueChanged<double> onDuracao;
  final ValueChanged<double> onDeslocar;
  final VoidCallback onParaOCursor;
  final VoidCallback onApagar;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = EventStyle.of(cut.kind);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.crop_free, size: 16, color: style.color),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${style.label} de ${formatClock(cut.sourceT)}',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                IconButton(
                  tooltip: 'tirar da montagem',
                  visualDensity: VisualDensity.compact,
                  onPressed: onApagar,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            Text(
              'entra em ${formatClock(cut.atS)} do vídeo  ·  '
              '${cut.durationS.toStringAsFixed(2)}s',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.hintColor),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                const Expanded(child: Text('Duração')),
                _Passo(
                  onMenos: () => onDuracao(cut.durationS - 0.1),
                  onMais: () => onDuracao(cut.durationS + 0.1),
                ),
              ],
            ),
            Row(
              children: [
                const Expanded(child: Text('Enquadramento')),
                _Passo(
                  onMenos: () => onDeslocar(-0.2),
                  onMais: () => onDeslocar(0.2),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onParaOCursor,
                icon: const Icon(Icons.vertical_align_center, size: 18),
                label: const Text('Mover para o cursor'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Passo extends StatelessWidget {
  const _Passo({required this.onMenos, required this.onMais});

  final VoidCallback onMenos;
  final VoidCallback onMais;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: onMenos,
            icon: const Icon(Icons.remove_circle_outline),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: onMais,
            icon: const Icon(Icons.add_circle_outline),
          ),
        ],
      );
}

class _Momentos extends StatelessWidget {
  const _Momentos({
    required this.momentos,
    required this.usados,
    required this.enabled,
    required this.onAdicionar,
  });

  final List<DetectionEvent> momentos;
  final Set<double> usados;
  final bool enabled;
  final ValueChanged<DetectionEvent> onAdicionar;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (momentos.isEmpty) {
      return Text(
        'A análise não achou nenhum momento nesta partida.',
        style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Momentos da partida', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          'Toque para pôr o corte onde a música estiver. Um momento pode '
          'entrar mais de uma vez.',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final e in momentos)
              ActionChip(
                avatar: Icon(
                  usados.contains(e.t)
                      ? Icons.check_circle
                      : Icons.add_circle_outline,
                  size: 16,
                  color: EventStyle.of(e.kind).color,
                ),
                label: Text(
                  '${EventStyle.of(e.kind).label} ${formatClock(e.t)}',
                  style: theme.textTheme.labelSmall,
                ),
                onPressed: enabled ? () => onAdicionar(e) : null,
              ),
          ],
        ),
      ],
    );
  }
}
