import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../api.dart';
import 'music_timeline.dart';

/// The server's sound effects: browse, listen, put on the ruler.
///
/// It sits in the Library because it answers the same question — "what do I
/// put in now?" — with sounds nobody had to bring. Clicking an effect puts it
/// at the playhead, dragging puts it where the finger lets go; either way it
/// lands over the music, on an effects layer, instead of after it.
class SoundShelf extends StatefulWidget {
  const SoundShelf({
    super.key,
    required this.library,
    required this.error,
    required this.enabled,
    required this.onAdd,
    this.adding,
    this.onRetry,
    this.padding = EdgeInsets.zero,
  });

  /// `null` while it loads.
  final SoundLibrary? library;
  final String? error;
  final bool enabled;
  final ValueChanged<SoundEffect> onAdd;

  /// The effect on its way into the match, if any — its tile shows it.
  final String? adding;
  final VoidCallback? onRetry;
  final EdgeInsets padding;

  /// What each group is called on screen.
  static const categoryLabels = {
    'transition': 'Transitions',
    'impact': 'Impacts',
    'ui': 'UI',
    'meme': 'Memes',
  };

  @override
  State<SoundShelf> createState() => _SoundShelfState();
}

class _SoundShelfState extends State<SoundShelf> {
  /// The group on show; `null` is all of them.
  String? _category;

  /// One effect plays at a time: listening to the next stops the last.
  VideoPlayerController? _player;
  String? _playing;

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  Future<void> _preview(SoundEffect effect) async {
    final old = _player;
    final wasPlaying = _playing;
    setState(() {
      _player = null;
      _playing = null;
    });
    await old?.dispose();
    // the same button again is "stop"
    if (wasPlaying == effect.id) return;

    final controller = VideoPlayerController.networkUrl(
      Uri.parse(effect.audioUrl),
    );
    setState(() {
      _player = controller;
      _playing = effect.id;
    });
    try {
      await controller.initialize();
      if (!mounted || _player != controller) return;
      controller.addListener(() {
        // back to the play icon when the sound ends on its own
        final v = controller.value;
        if (v.isInitialized &&
            !v.isPlaying &&
            v.position >= v.duration &&
            _playing == effect.id &&
            mounted) {
          setState(() => _playing = null);
        }
      });
      await controller.play();
    } catch (_) {
      // listening is a convenience: without a player the effect can still be
      // added and heard in the video
      if (mounted && _player == controller) setState(() => _playing = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final library = widget.library;

    final header = Padding(
      padding: widget.padding.copyWith(top: 12, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Sound effects', style: theme.textTheme.titleSmall),
          Text(
            'Click to put one at the playhead, or drag it onto the timeline. '
            'It goes over the music, on an effects layer.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ],
      ),
    );

    if (widget.error != null) {
      return Column(
        key: const Key('sound-shelf'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          header,
          Padding(
            padding: widget.padding,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Could not load the sound effects.',
                    style: TextStyle(
                      color: theme.colorScheme.error,
                      fontSize: 12,
                    ),
                  ),
                ),
                if (widget.onRetry != null)
                  TextButton(
                    onPressed: widget.onRetry,
                    child: const Text('Try again'),
                  ),
              ],
            ),
          ),
        ],
      );
    }
    if (library == null) {
      return Column(
        key: const Key('sound-shelf'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          header,
          Padding(
            padding: widget.padding,
            child: const LinearProgressIndicator(minHeight: 2),
          ),
        ],
      );
    }

    final shown = [
      for (final e in library.effects)
        if (_category == null || e.category == _category) e,
    ];

    return Column(
      key: const Key('sound-shelf'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        header,
        Padding(
          padding: widget.padding.copyWith(bottom: 6),
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              ChoiceChip(
                key: const Key('sfx-category-all'),
                label: const Text('All'),
                visualDensity: VisualDensity.compact,
                selected: _category == null,
                onSelected: (_) => setState(() => _category = null),
              ),
              for (final c in library.categories)
                ChoiceChip(
                  key: Key('sfx-category-$c'),
                  label: Text(SoundShelf.categoryLabels[c] ?? c),
                  visualDensity: VisualDensity.compact,
                  selected: _category == c,
                  onSelected: (_) => setState(() => _category = c),
                ),
            ],
          ),
        ),
        for (final e in shown)
          Padding(
            padding: widget.padding,
            child: _EffectTile(
              key: ValueKey('sfx-${e.id}'),
              effect: e,
              enabled: widget.enabled && widget.adding == null,
              adding: widget.adding == e.id,
              playing: _playing == e.id,
              onAdd: () => widget.onAdd(e),
              onPreview: () => _preview(e),
            ),
          ),
      ],
    );
  }
}

class _EffectTile extends StatelessWidget {
  const _EffectTile({
    super.key,
    required this.effect,
    required this.enabled,
    required this.adding,
    required this.playing,
    required this.onAdd,
    required this.onPreview,
  });

  final SoundEffect effect;
  final bool enabled;
  final bool adding;
  final bool playing;
  final VoidCallback onAdd;
  final VoidCallback onPreview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colour = theme.colorScheme.tertiary;
    final card = Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        onTap: enabled ? onAdd : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Row(
            children: [
              IconButton(
                key: ValueKey('sfx-preview-${effect.id}'),
                tooltip: playing ? 'Stop' : 'Listen',
                visualDensity: VisualDensity.compact,
                onPressed: onPreview,
                icon: Icon(
                  playing
                      ? Icons.stop_circle_outlined
                      : Icons.play_circle_outline,
                  color: colour,
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      effect.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium,
                    ),
                    Text(
                      '${effect.durationS.toStringAsFixed(1)} s',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.hintColor,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 64,
                height: 22,
                child: CustomPaint(
                  painter: _PeaksPainter(
                    effect.peaks,
                    colour.withValues(alpha: 0.6),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              if (adding)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(Icons.add, size: 18, color: theme.hintColor),
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );

    return Draggable<RulerDrop>(
      data: RulerDrop.effect(effect),
      affinity: Axis.horizontal,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      maxSimultaneousDrags: enabled ? 1 : 0,
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          width: 120,
          height: 36,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: colour.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            effect.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: card),
      child: card,
    );
  }
}

/// The effect's shape, small: a hit and a riser look different at a glance.
class _PeaksPainter extends CustomPainter {
  _PeaksPainter(this.peaks, this.colour);

  final List<double> peaks;
  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    if (peaks.isEmpty) return;
    final paint = Paint()
      ..color = colour
      ..strokeWidth = 1;
    final mid = size.height / 2;
    final step = size.width / peaks.length;
    for (var i = 0; i < peaks.length; i++) {
      final h = peaks[i].clamp(0.0, 1.0) * mid;
      final x = i * step;
      canvas.drawLine(Offset(x, mid - h), Offset(x, mid + h), paint);
    }
  }

  @override
  bool shouldRepaint(_PeaksPainter old) =>
      old.peaks != peaks || old.colour != colour;
}
