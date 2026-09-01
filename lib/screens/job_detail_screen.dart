import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../main.dart' show PhoneWidth;
import '../widgets/download.dart';
import '../widgets/highlight_style.dart';
import '../widgets/timeline.dart';
import 'player_screen.dart';
import 'timeline_screen.dart';

class JobDetailScreen extends StatefulWidget {
  const JobDetailScreen({super.key, required this.jobId});

  final String jobId;

  @override
  State<JobDetailScreen> createState() => _JobDetailScreenState();
}

class _JobDetailScreenState extends State<JobDetailScreen> {
  final _api = ApiClient();
  Job? _job;
  String? _error;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _refresh();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_job?.isActive ?? true) _refresh();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final job = await _api.getJob(widget.jobId);
      if (mounted) {
        setState(() {
          _job = job;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _montar(Job job) async {
    final feito = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => TimelineScreen(job: job)));
    if (feito == true) await _refresh();
  }

  Future<void> _apagarPedido(Render r) async {
    try {
      await _api.deleteRender(r.id);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final job = _job;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(job?.videoName ?? 'Partida')),
      body: PhoneWidth(
        child: job == null
            ? Center(
                child: _error != null
                    ? Text(_error!)
                    : const CircularProgressIndicator(),
              )
            : RefreshIndicator(
                onRefresh: _refresh,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
                  children: [
                    _Progress(job: job),
                    if (job.isFailed && job.error != null) _Failure(job: job),
                    const SizedBox(height: 20),
                    if (job.events.isNotEmpty) ...[
                      Text('Linha do tempo', style: theme.textTheme.titleSmall),
                      const SizedBox(height: 10),
                      EventTimeline(
                        events: job.events,
                        durationS: job.durationS,
                      ),
                      const SizedBox(height: 20),
                    ],
                    if (job.detectors.isNotEmpty) ...[
                      _Detectors(job: job),
                      const SizedBox(height: 20),
                    ],

                    // ── o editor ──────────────────────────────────────────
                    // Não há mais lista de vídeos prontos para escolher: a
                    // análise entrega os momentos e o editor é o que se faz
                    // com eles.
                    if (job.isReady && job.events.isNotEmpty) ...[
                      FilledButton.icon(
                        onPressed: () => _montar(job),
                        icon: const Icon(Icons.timeline),
                        label: Text(
                          job.montages.isEmpty
                              ? 'Abrir o editor'
                              : 'Continuar editando',
                        ),
                      ),
                      const SizedBox(height: 24),
                    ] else if (job.isReady)
                      const _NothingFound(),

                    // ── o que já foi gerado ───────────────────────────────
                    if (job.renders.isNotEmpty) ...[
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Vídeos gerados',
                              style: theme.textTheme.titleSmall,
                            ),
                          ),
                          if (job.zipUrl != null)
                            BotaoBaixar(
                              url: job.zipUrl!,
                              icon: Icons.folder_zip_outlined,
                              label: job.hasCuts
                                  ? 'Baixar tudo: vídeos + cortes (.zip)'
                                  : 'Baixar os vídeos (.zip)',
                            ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      for (final r in job.renders)
                        _RenderCard(
                          render: r,
                          onDelete: () => _apagarPedido(r),
                          onOpen: (c) => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => PlayerScreen(clip: c),
                            ),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
      ),
    );
  }
}

class _RenderCard extends StatelessWidget {
  const _RenderCard({
    required this.render,
    required this.onOpen,
    required this.onDelete,
  });

  final Render render;
  final ValueChanged<Clip> onOpen;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        render.stage.isEmpty ? render.status : render.stage,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: render.isFailed
                              ? theme.colorScheme.error
                              : null,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [
                          _quando(render.createdAt),
                          if (render.musicNames.isNotEmpty)
                            render.musicNames.join(', ')
                          else
                            'áudio da partida',
                        ].join('  ·  '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.hintColor,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Apagar este pedido',
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            if (render.isActive) ...[
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: render.progress > 0 ? render.progress : null,
                  minHeight: 6,
                ),
              ),
            ],
            if (render.isFailed && render.error != null) ...[
              const SizedBox(height: 8),
              Text(
                render.error!,
                style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
              ),
            ],
            if (render.clips.isNotEmpty) const SizedBox(height: 10),
            for (final c in render.clips)
              _ClipCard(clip: c, onTap: () => onOpen(c)),
          ],
        ),
      ),
    );
  }

  static String _quando(DateTime t) {
    final d = t.toLocal();
    String dois(int n) => n.toString().padLeft(2, '0');
    return '${dois(d.day)}/${dois(d.month)} ${dois(d.hour)}:${dois(d.minute)}';
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.job});

  final Job job;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                job.stage.isEmpty ? job.status : job.stage,
                style: theme.textTheme.titleMedium,
              ),
            ),
            if (job.isAnalyzing) ...[
              if (formatRestante(job.restante) case final falta?) ...[
                Text(
                  'falta $falta',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.hintColor,
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Text(
                '${(job.progress * 100).toStringAsFixed(0)}%',
                style: theme.textTheme.titleMedium,
              ),
            ],
          ],
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: job.isAnalyzing
                ? (job.progress > 0 ? job.progress : null)
                : 1,
            minHeight: 7,
            color: job.isFailed ? theme.colorScheme.error : null,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 16,
          runSpacing: 6,
          children: [
            _Fact(icon: Icons.schedule, text: formatDuration(job.durationS)),
            _Fact(icon: Icons.flash_on, text: '${job.events.length} momentos'),
            if (job.montages.isNotEmpty)
              _Fact(
                icon: Icons.playlist_add_check,
                text: '${job.montages.length} montagem(ns)',
              ),
            if (job.renders.isNotEmpty)
              _Fact(
                icon: Icons.movie_creation_outlined,
                text: '${job.renders.length} pedido(s)',
              ),
          ],
        ),
      ],
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 15, color: Theme.of(context).hintColor),
      const SizedBox(width: 5),
      Text(text, style: Theme.of(context).textTheme.bodySmall),
    ],
  );
}

class _Failure extends StatelessWidget {
  const _Failure({required this.job});

  final Job job;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.error.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(job.error!, style: TextStyle(color: scheme.error)),
    );
  }
}

class _Detectors extends StatelessWidget {
  const _Detectors({required this.job});

  final Job job;

  static const _labels = {
    'kills': 'Eliminações',
    'survival': 'Vida e sobrevivência',
    'ults': 'Ultimates',
    'banner': 'Habilidades (rodapé)',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Detectores', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        for (final d in job.detectors)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                Icon(
                  d.ok ? Icons.check_circle : Icons.error,
                  size: 17,
                  color: d.ok
                      ? const Color(0xFF66BB6A)
                      : theme.colorScheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(_labels[d.detector] ?? d.detector)),
                Text(
                  d.ok ? '${d.nEvents}' : 'falhou',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.hintColor,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ClipCard extends StatelessWidget {
  const _ClipCard({required this.clip, required this.onTap});

  final Clip clip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final style = HighlightStyle.of(clip.kind);
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 8, right: 6),
      child: InkWell(
        onTap: onTap,
        child: Row(
          children: [
            SizedBox(
              width: 118,
              height: 78,
              child: clip.thumbUrl != null
                  ? Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.network(
                          clip.thumbUrl!,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) =>
                              Container(color: Colors.black26),
                        ),
                        Center(
                          child: Icon(
                            Icons.play_circle_fill,
                            size: 32,
                            color: Colors.white.withValues(alpha: 0.85),
                          ),
                        ),
                      ],
                    )
                  : Container(
                      color: style.color.withValues(alpha: 0.15),
                      child: Icon(style.icon, color: style.color),
                    ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Icon(style.icon, size: 14, color: style.color),
                        const SizedBox(width: 5),
                        Text(
                          style.label,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: style.color,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      clip.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      [
                        if (clip.onlyCuts)
                          'vídeo não gerado — cortes disponíveis'
                        else
                          formatDuration(clip.durationS),
                        if (clip.segments > 1) '${clip.segments} cortes',
                        if (clip.isBeatSynced && !clip.onlyCuts) 'no ritmo',
                        if (clip.isLooped && !clip.onlyCuts) 'sorteado',
                        if (clip.keepsOriginalAudio && !clip.onlyCuts)
                          'áudio da partida',
                      ].join('  ·  '),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: clip.onlyCuts
                            ? theme.colorScheme.error
                            : theme.hintColor,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NothingFound extends StatelessWidget {
  const _NothingFound();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: [
          Icon(Icons.search_off, size: 44, color: theme.hintColor),
          const SizedBox(height: 12),
          Text('Nenhum momento encontrado', style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          Text(
            'Se a partida claramente tinha bons momentos, a HUD provavelmente '
            'está em posição diferente da esperada — dá para ajustar isso no '
            'perfil de calibração.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ],
      ),
    );
  }
}
