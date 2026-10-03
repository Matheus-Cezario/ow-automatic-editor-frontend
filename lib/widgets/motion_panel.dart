import 'package:flutter/material.dart';

import '../api.dart';
import '../montage.dart';

/// Position, scale, opacity and volume of the selected clip — each one static
/// or keyframed.
///
/// The model is the one every editor uses. A property starts static: its
/// slider sets one value for the whole clip. The stopwatch turns it into an
/// animation, with a first keyframe at the playhead; from then on, moving the
/// slider sets the keyframe under the playhead, or creates one there. Drawing a
/// move is: playhead, value; playhead, value.
class MotionPanel extends StatelessWidget {
  const MotionPanel({
    super.key,
    required this.clip,
    required this.props,
    required this.localS,
    required this.onSet,
    required this.onAnimate,
    required this.onRemoveKey,
    required this.onEase,
    required this.onSeek,
    this.onGestureStart,
    this.onGestureEnd,
  });

  final TimelineClip clip;

  /// What this clip can animate: a song has only volume, an image no sound.
  final List<KeyProp> props;

  /// The playhead, in seconds from the clip's start — outside 0..duration
  /// when the playhead is off the clip.
  final double localS;

  final void Function(KeyProp prop, double value) onSet;
  final void Function(KeyProp prop, bool on) onAnimate;
  final ValueChanged<KeyProp> onRemoveKey;
  final void Function(KeyProp prop, Ease ease) onEase;

  /// Moves the playhead to this instant of the video.
  final ValueChanged<double> onSeek;

  /// A slider drag is one undo step, not one per frame.
  final VoidCallback? onGestureStart;
  final VoidCallback? onGestureEnd;

  bool get _onClip => localS >= -1e-6 && localS <= clip.durationS + 1e-6;

  int get _animated => props.where((p) => clip.keysFor(p).isNotEmpty).length;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ExpansionTile(
      key: const Key('motion-panel'),
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 8),
      title: Row(
        children: [
          const Icon(Icons.open_with, size: 16),
          const SizedBox(width: 8),
          Text('Motion', style: theme.textTheme.labelLarge),
          if (_animated > 0) ...[
            const SizedBox(width: 8),
            Text(
              '$_animated animated',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ],
        ],
      ),
      children: [
        if (!_onClip && _animated > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              'Put the playhead over the clip to set keyframes.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
              ),
            ),
          ),
        for (final p in props) _row(context, p),
      ],
    );
  }

  Widget _row(BuildContext context, KeyProp p) {
    final theme = Theme.of(context);
    final keys = clip.keysFor(p);
    final animated = keys.isNotEmpty;
    final at = localS.clamp(0.0, clip.durationS).toDouble();
    final value = valueAt(clip, p, at);
    final here = animated ? keyAt(clip, p, localS) : null;
    // an animated slider off the clip would set a keyframe nobody can see
    final editable = !animated || _onClip;

    double? neighbour(bool forward) {
      final times = [for (final k in keys) k.t * clip.durationS];
      final candidates = forward
          ? times.where((t) => t > localS + kKeyToleranceS)
          : times.where((t) => t < localS - kKeyToleranceS);
      if (candidates.isEmpty) return null;
      return forward
          ? candidates.reduce((a, b) => a < b ? a : b)
          : candidates.reduce((a, b) => a > b ? a : b);
    }

    final previous = neighbour(false);
    final next = neighbour(true);

    return Column(
      key: ValueKey('motion-${p.wire}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            IconButton(
              key: ValueKey('motion-${p.wire}-animate'),
              tooltip: animated
                  ? 'Stop animating (keeps the value at the playhead)'
                  : 'Animate: a keyframe at the playhead',
              visualDensity: VisualDensity.compact,
              onPressed: _onClip || animated
                  ? () => onAnimate(p, !animated)
                  : null,
              icon: Icon(
                animated ? Icons.timer : Icons.timer_outlined,
                size: 18,
                color: animated ? theme.colorScheme.primary : null,
              ),
            ),
            SizedBox(
              width: 76,
              child: Text(p.label, style: theme.textTheme.bodyMedium),
            ),
            Expanded(
              child: Slider(
                key: ValueKey('motion-${p.wire}-slider'),
                value: value.clamp(p.min, p.max).toDouble(),
                min: p.min,
                max: p.max,
                onChangeStart: (_) => onGestureStart?.call(),
                onChangeEnd: (_) => onGestureEnd?.call(),
                onChanged: editable ? (v) => onSet(p, v) : null,
              ),
            ),
            SizedBox(
              width: 40,
              child: Text(
                _format(p, value),
                textAlign: TextAlign.right,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
        if (animated)
          Padding(
            padding: const EdgeInsets.only(left: 40, bottom: 4),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 2,
              children: [
                IconButton(
                  tooltip: 'Previous keyframe',
                  visualDensity: VisualDensity.compact,
                  onPressed: previous == null
                      ? null
                      : () => onSeek(clip.atS + previous),
                  icon: const Icon(Icons.chevron_left, size: 18),
                ),
                Icon(
                  here != null ? Icons.diamond : Icons.diamond_outlined,
                  size: 14,
                  color: here != null
                      ? theme.colorScheme.primary
                      : theme.hintColor,
                ),
                IconButton(
                  tooltip: 'Next keyframe',
                  visualDensity: VisualDensity.compact,
                  onPressed: next == null
                      ? null
                      : () => onSeek(clip.atS + next),
                  icon: const Icon(Icons.chevron_right, size: 18),
                ),
                Text(
                  '${keys.length} key${keys.length == 1 ? '' : 's'}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.hintColor,
                  ),
                ),
                if (here != null) ...[
                  const SizedBox(width: 8),
                  PopupMenuButton<Ease>(
                    key: ValueKey('motion-${p.wire}-ease'),
                    tooltip: 'How it travels to the next keyframe',
                    initialValue: here.ease,
                    onSelected: (e) => onEase(p, e),
                    itemBuilder: (_) => [
                      for (final e in Ease.values)
                        PopupMenuItem(value: e, child: Text(e.label)),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            here.ease.label,
                            style: theme.textTheme.bodySmall,
                          ),
                          const Icon(Icons.arrow_drop_down, size: 16),
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    key: ValueKey('motion-${p.wire}-remove-key'),
                    tooltip: 'Delete this keyframe',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => onRemoveKey(p),
                    icon: const Icon(Icons.delete_outline, size: 16),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  static String _format(KeyProp p, double v) => switch (p) {
    KeyProp.opacity || KeyProp.volume => '${(v * 100).round()}%',
    KeyProp.scale || KeyProp.speed => '${v.toStringAsFixed(2)}×',
    KeyProp.x || KeyProp.y => v.toStringAsFixed(2),
  };
}

/// Which properties a clip can animate.
///
/// A music block has only its volume; an image has no sound; a text clip is
/// positioned by its own style on the server, so it stays out for now.
List<KeyProp> motionPropsFor(
  TimelineClip clip, {
  required bool onSoundLayer,
  Media? media,
}) {
  if (onSoundLayer) return const [KeyProp.volume];
  if (clip.isText) return const [];
  if (media?.isImage ?? false) {
    return const [KeyProp.x, KeyProp.y, KeyProp.scale, KeyProp.opacity];
  }
  // a frozen or reversed clip cannot ramp: the server refuses both together
  if (clip.freeze || clip.reverse) {
    return [
      for (final p in KeyProp.values)
        if (p != KeyProp.speed) p,
    ];
  }
  return KeyProp.values;
}
