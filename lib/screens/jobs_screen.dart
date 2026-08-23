import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../main.dart' show PhoneWidth;
import '../widgets/download.dart';
import '../widgets/highlight_style.dart';
import 'job_detail_screen.dart';
import 'new_job_screen.dart';

class JobsScreen extends StatefulWidget {
  const JobsScreen({super.key});

  @override
  State<JobsScreen> createState() => _JobsScreenState();
}

class _JobsScreenState extends State<JobsScreen> {
  final _api = ApiClient();
  List<Job>? _jobs;
  String? _error;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _refresh();
    // enquanto houver job em andamento vale recarregar sozinho; parado, não
    _poll = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_jobs?.any((j) => j.isActive) ?? false) _refresh();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final jobs = await _api.listJobs();
      if (mounted) {
        setState(() {
          _jobs = jobs;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _newJob() async {
    final created = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => const NewJobScreen()));
    if (created == true) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Melhores momentos'),
        actions: [
          IconButton(
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
            tooltip: 'Atualizar',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _newJob,
        icon: const Icon(Icons.add),
        label: const Text('Nova partida'),
      ),
      body: PhoneWidth(child: _body()),
    );
  }

  Widget _body() {
    if (_error != null && _jobs == null) {
      return _ErrorState(message: _error!, onRetry: _refresh);
    }
    if (_jobs == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_jobs!.isEmpty) return const _EmptyState();

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
        itemCount: _jobs!.length,
        itemBuilder: (_, i) => _JobCard(
          job: _jobs![i],
          onOpen: () async {
            await Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => JobDetailScreen(jobId: _jobs![i].id),
              ),
            );
            _refresh();
          },
          onDelete: () async {
            await _api.deleteJob(_jobs![i].id);
            _refresh();
          },
        ),
      ),
    );
  }
}

class _JobCard extends StatelessWidget {
  const _JobCard({
    required this.job,
    required this.onOpen,
    required this.onDelete,
  });

  final Job job;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      job.videoName,
                      style: theme.textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  _StatusChip(job: job),
                  PopupMenuButton<String>(
                    onSelected: (v) {
                      if (v == 'zip' && job.zipUrl != null) {
                        baixar(context, job.zipUrl!);
                      } else if (v == 'del') {
                        onDelete();
                      }
                    },
                    itemBuilder: (_) => [
                      if (job.zipUrl != null)
                        const PopupMenuItem(
                          value: 'zip',
                          child: Text('Baixar tudo (.zip)'),
                        ),
                      const PopupMenuItem(value: 'del', child: Text('Excluir')),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                job.stage.isEmpty ? '—' : job.stage,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.hintColor,
                ),
              ),
              if (job.isAnalyzing) ...[
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: job.progress > 0 ? job.progress : null,
                    minHeight: 6,
                  ),
                ),
              ],
              if (job.isFailed && job.error != null) ...[
                const SizedBox(height: 8),
                Text(
                  job.error!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
              if (job.isReady) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Icon(Icons.movie_filter, size: 16, color: theme.hintColor),
                    const SizedBox(width: 6),
                    Text(
                      job.nClips > 0
                          ? '${job.nClips} vídeo(s) gerados'
                          : '${job.nProposals} para gerar',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(width: 14),
                    Icon(Icons.schedule, size: 16, color: theme.hintColor),
                    const SizedBox(width: 6),
                    Text(
                      formatDuration(job.durationS),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.job});

  final Job job;

  static const _labels = {
    'pending': 'na fila',
    'preprocessing': 'preparando',
    'detecting': 'analisando',
    'editing': 'montando',
    'done': 'pronto',
    'failed': 'falhou',
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (job.status) {
      'done' => const Color(0xFF66BB6A),
      'failed' => scheme.error,
      _ => scheme.primary,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        _labels[job.status] ?? job.status,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.videocam_off, size: 56, color: theme.hintColor),
            const SizedBox(height: 16),
            Text('Nenhuma partida ainda', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Envie a gravação de uma partida e o sistema separa as rajadas '
              'de eliminação, as fugas e monta o resto no ritmo da sua música.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 48, color: theme.colorScheme.error),
            const SizedBox(height: 14),
            Text(
              'Não consegui falar com a API',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              kApiBase.isEmpty ? '(mesma origem)' : kApiBase,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(height: 18),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Tentar de novo'),
            ),
          ],
        ),
      ),
    );
  }
}
