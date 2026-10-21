import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../stage_text.dart';
import '../widgets/download.dart';
import '../widgets/highlight_style.dart';
import '../widgets/render_queue.dart';
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
    // while a job is running it is worth reloading on our own; when idle, not
    _poll = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_jobs?.any((j) => j.isActive) ?? false) _refresh();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  /// How many reloads in a row may fail before the screen complains.
  ///
  /// The list reloads every 2s during an analysis that lasts minutes, and a
  /// call lost in the middle of that is not news — it is a connection that
  /// dropped and comes back on the next one. Swapping the whole list for an
  /// error message then makes it look like the analysis died, when it keeps
  /// running on the server.
  static const _toleratedFailures = 3;

  int _consecutiveFailures = 0;

  Future<void> _refresh() async {
    try {
      final jobs = await _api.listJobs();
      if (mounted) {
        setState(() {
          _jobs = jobs;
          _error = null;
          _consecutiveFailures = 0;
        });
      }
    } catch (e) {
      _consecutiveFailures++;
      if (mounted && _consecutiveFailures >= _toleratedFailures) {
        setState(() => _error = e.toString());
      }
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
        title: const Text('Matches'),
        actions: [
          FilledButton.icon(
            onPressed: _newJob,
            style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
            icon: const Icon(Icons.add),
            label: const Text('New match'),
          ),
          const SizedBox(width: 4),
          RenderQueueButton(
            load: _api.renderQueue,
            cancel: _api.cancelRender,
            onOpenJob: (id) => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => JobDetailScreen(jobId: id)),
            ),
          ),
          IconButton(
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _body(),
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
      child: GridView.builder(
        padding: const EdgeInsets.all(16),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 340,
          mainAxisSpacing: 14,
          crossAxisSpacing: 14,
          childAspectRatio: 1.15,
        ),
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
            final messenger = ScaffoldMessenger.of(context);
            try {
              await _api.deleteJob(_jobs![i].id);
            } on ApiException catch (e) {
              // another match's montage uses its moments: say whose
              messenger.showSnackBar(
                SnackBar(content: Text('Not deleted: ${e.message}')),
              );
            }
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
      child: InkWell(
        onTap: onOpen,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(
                    color: theme.colorScheme.surfaceContainerHighest,
                    child: job.isReady
                        ? Image.network(
                            frameUrl(job.id, job.durationS * 0.1),
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => _thumbFallback(theme),
                          )
                        : _thumbFallback(theme),
                  ),
                  Positioned(top: 8, left: 8, child: _StatusChip(job: job)),
                  Positioned(
                    top: 0,
                    right: 0,
                    child: PopupMenuButton<String>(
                      onSelected: (v) {
                        if (v == 'zip' && job.zipUrl != null) {
                          downloadFile(context, job.zipUrl!);
                        } else if (v == 'del') {
                          onDelete();
                        }
                      },
                      itemBuilder: (_) => [
                        if (job.zipUrl != null)
                          const PopupMenuItem(
                            value: 'zip',
                            child: Text('Download all (.zip)'),
                          ),
                        const PopupMenuItem(
                          value: 'del',
                          child: Text('Delete'),
                        ),
                      ],
                    ),
                  ),
                  if (job.isReady)
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          formatDuration(job.durationS),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    job.videoName,
                    style: theme.textTheme.titleSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    jobStageText(job),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.hintColor,
                    ),
                  ),
                  if (job.isAnalyzing) ...[
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: LinearProgressIndicator(
                        value: job.progress > 0 ? job.progress : null,
                        minHeight: 6,
                      ),
                    ),
                  ],
                  if (job.isFailed && job.error != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      job.error!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _thumbFallback(ThemeData theme) =>
      Center(child: Icon(Icons.movie, size: 40, color: theme.hintColor));
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.job});

  final Job job;

  static const _labels = {
    'pending': 'queued',
    'preprocessing': 'preparing',
    'detecting': 'analysing',
    'editing': 'assembling',
    'done': 'done',
    'failed': 'failed',
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
            Text('No matches yet', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Upload a match recording and the system finds the key moments — '
              'kills, sleeps, stuns — ready to edit to the beat of your music.',
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
            Text('Could not reach the API', style: theme.textTheme.titleMedium),
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
              kApiBase.isEmpty ? '(same origin)' : kApiBase,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(height: 18),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}
