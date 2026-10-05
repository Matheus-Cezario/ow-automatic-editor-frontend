import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../stage_text.dart';

/// Where a render request is: its bar, how long it still needs or how many
/// are ahead of it, and the way to stop it.
class RenderProgressLine extends StatelessWidget {
  const RenderProgressLine({super.key, required this.render, this.onCancel});

  final Render render;

  /// `null` hides the button — the request is not running.
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = render;
    final waiting = r.status == 'pending';
    final note = waiting
        ? switch (r.queuePosition) {
            null || 0 => 'next in the queue',
            1 => 'waiting · 1 ahead',
            final n => 'waiting · $n ahead',
          }
        : [
            '${(r.progress * 100).round()}%',
            if (r.remainingText case final left?) '$left left',
          ].join(' · ');
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: !waiting && r.progress > 0 ? r.progress : null,
                  minHeight: 6,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                note,
                key: ValueKey('render-note-${r.id}'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.hintColor,
                ),
              ),
            ],
          ),
        ),
        if (onCancel != null && r.isActive) ...[
          const SizedBox(width: 8),
          TextButton(
            key: ValueKey('cancel-render-${r.id}'),
            onPressed: onCancel,
            child: const Text('Cancel'),
          ),
        ],
      ],
    );
  }
}

/// The app bar's way into the render queue: a badge with how many requests
/// are waiting or rendering, across every match.
///
/// It asks the server every few seconds while something is running, and
/// rarely when nothing is.
class RenderQueueButton extends StatefulWidget {
  const RenderQueueButton({
    super.key,
    required this.load,
    required this.cancel,
    this.onOpenJob,
  });

  final Future<List<Render>> Function() load;
  final Future<void> Function(String renderId) cancel;

  /// Opens a request's match, to watch or download its videos.
  final ValueChanged<String>? onOpenJob;

  @override
  State<RenderQueueButton> createState() => _RenderQueueButtonState();
}

class _RenderQueueButtonState extends State<RenderQueueButton> {
  List<Render> _renders = const [];
  Timer? _timer;

  int get _active => _renders.where((r) => r.isActive).length;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    _timer?.cancel();
    try {
      final list = await widget.load();
      if (!mounted) return;
      setState(() => _renders = list);
    } catch (_) {
      // the queue is a convenience: a failed poll waits for the next one
    }
    if (!mounted) return;
    _timer = Timer(
      Duration(seconds: _active > 0 ? 3 : 20),
      _refresh,
    );
  }

  Future<void> _open() async {
    await showDialog<void>(
      context: context,
      builder: (_) => RenderQueueDialog(
        load: widget.load,
        cancel: widget.cancel,
        initial: _renders,
        onOpenJob: widget.onOpenJob,
      ),
    );
    _refresh();
  }

  @override
  Widget build(BuildContext context) => IconButton(
    key: const Key('render-queue'),
    tooltip: _active == 0
        ? 'Render queue'
        : 'Render queue · $_active running or waiting',
    onPressed: _open,
    icon: Badge(
      isLabelVisible: _active > 0,
      label: Text('$_active'),
      child: const Icon(Icons.queue_play_next),
    ),
  );
}

/// Every request waiting, rendering or just finished, across matches,
/// oldest first — the order they are worked through.
class RenderQueueDialog extends StatefulWidget {
  const RenderQueueDialog({
    super.key,
    required this.load,
    required this.cancel,
    this.initial = const [],
    this.onOpenJob,
  });

  final Future<List<Render>> Function() load;
  final Future<void> Function(String renderId) cancel;
  final List<Render> initial;
  final ValueChanged<String>? onOpenJob;

  @override
  State<RenderQueueDialog> createState() => _RenderQueueDialogState();
}

class _RenderQueueDialogState extends State<RenderQueueDialog> {
  late List<Render> _renders = widget.initial;
  Timer? _timer;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final list = await widget.load();
      if (mounted) {
        setState(() {
          _renders = list;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _cancel(Render r) async {
    try {
      await widget.cancel(r.id);
    } catch (e) {
      if (mounted) setState(() => _error = 'could not cancel: $e');
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      key: const Key('render-queue-dialog'),
      title: const Text('Render queue'),
      content: SizedBox(
        width: 520,
        child: _renders.isEmpty
            ? Text(
                _error ?? 'Nothing rendering, and nothing finished lately.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.hintColor,
                ),
              )
            : ListView(
                shrinkWrap: true,
                children: [
                  for (final r in _renders)
                    Padding(
                      key: ValueKey('queue-item-${r.id}'),
                      padding: const EdgeInsets.only(bottom: 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  r.titles.where((t) => t.isNotEmpty).isEmpty
                                      ? '${r.titles.length} video(s)'
                                      : r.titles
                                            .where((t) => t.isNotEmpty)
                                            .join(', '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleSmall,
                                ),
                              ),
                              if (widget.onOpenJob != null && r.jobId.isNotEmpty)
                                TextButton(
                                  onPressed: () {
                                    Navigator.of(context).pop();
                                    widget.onOpenJob!(r.jobId);
                                  },
                                  child: const Text('Open'),
                                ),
                            ],
                          ),
                          Text(
                            [
                              if (r.jobName.isNotEmpty) r.jobName,
                              if (!r.isActive) renderStageText(r),
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: r.isFailed
                                  ? theme.colorScheme.error
                                  : theme.hintColor,
                            ),
                          ),
                          if (r.isActive) ...[
                            const SizedBox(height: 6),
                            RenderProgressLine(
                              render: r,
                              onCancel: () => _cancel(r),
                            ),
                          ],
                        ],
                      ),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
