import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'highlight_style.dart';

/// A whole montage of up to this length is previewed in one go.
const kExactWholeUpToS = 20.0;

/// Otherwise the preview covers this much, starting a little before the
/// playhead — the stretch being worked on, with some run-up to judge the cut.
const kExactSpanS = 10.0;
const kExactRunUpS = 2.0;

/// The stretch of the montage an exact preview renders, in video seconds.
({double from, double to}) exactPreviewWindow(
  double durationS,
  double cursorS,
) {
  if (durationS <= kExactWholeUpToS) return (from: 0, to: durationS);
  var from = math.max(0.0, cursorS - kExactRunUpS);
  // near the end, the window slides back instead of shrinking
  from = math.min(from, math.max(0.0, durationS - kExactSpanS));
  return (from: from, to: math.min(durationS, from + kExactSpanS));
}

/// The server's rendering of a stretch, played over the monitor.
///
/// It plays with sound — the music and the game audio are part of what is
/// being checked — and loops, so the cut can be watched again without
/// touching anything. Closing it gives the live monitor back.
class ExactPreviewOverlay extends StatefulWidget {
  const ExactPreviewOverlay({
    super.key,
    required this.url,
    required this.fromS,
    required this.toS,
    required this.onClose,
    this.outdated = false,
  });

  final String url;
  final double fromS;
  final double toS;
  final VoidCallback onClose;

  /// The montage changed after this preview was asked for.
  final bool outdated;

  @override
  State<ExactPreviewOverlay> createState() => _ExactPreviewOverlayState();
}

class _ExactPreviewOverlayState extends State<ExactPreviewOverlay> {
  late final VideoPlayerController _c = VideoPlayerController.networkUrl(
    Uri.parse(widget.url),
  );
  String? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      await _c.initialize();
      await _c.setLooping(true);
      await _c.play();
    } catch (e) {
      if (mounted) setState(() => _error = 'could not play the preview');
      return;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ready = _c.value.isInitialized;
    return ColoredBox(
      key: const Key('exact-preview'),
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (ready)
            Center(
              child: AspectRatio(
                aspectRatio: _c.value.aspectRatio,
                child: GestureDetector(
                  onTap: () => setState(
                    () => _c.value.isPlaying ? _c.pause() : _c.play(),
                  ),
                  child: VideoPlayer(_c),
                ),
              ),
            )
          else if (_error != null)
            Center(
              child: Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            )
          else
            const Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          Positioned(
            left: 8,
            top: 8,
            child: _Tag(
              text:
                  'Exact preview · ${formatClock(widget.fromS)}–${formatClock(widget.toS)}'
                  '${widget.outdated ? ' · outdated' : ''}',
              warning: widget.outdated,
            ),
          ),
          Positioned(
            right: 4,
            top: 4,
            child: IconButton(
              key: const Key('exact-preview-close'),
              tooltip: 'Back to the live monitor',
              onPressed: widget.onClose,
              icon: const Icon(Icons.close, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}

/// The preview on its way: progress, or why it failed.
class ExactPreviewStatus extends StatelessWidget {
  const ExactPreviewStatus({
    super.key,
    required this.progress,
    this.error,
    this.onDismiss,
  });

  final double progress;
  final String? error;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final failed = error != null;
    return Row(
      key: const Key('exact-preview-status'),
      mainAxisSize: MainAxisSize.min,
      children: [
        _Tag(
          text: failed
              ? 'Exact preview failed: $error'
              : 'Rendering exact preview… ${(progress * 100).round()}%',
          warning: failed,
        ),
        if (failed && onDismiss != null)
          IconButton(
            tooltip: 'Dismiss',
            visualDensity: VisualDensity.compact,
            onPressed: onDismiss,
            icon: const Icon(Icons.close, size: 16, color: Colors.white),
          ),
      ],
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, this.warning = false});

  final String text;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: warning
              ? theme.colorScheme.error.withValues(alpha: 0.85)
              : Colors.black54,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Text(
            text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(color: Colors.white),
          ),
        ),
      ),
    );
  }
}
