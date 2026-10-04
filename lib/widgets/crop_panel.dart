import 'package:flutter/material.dart';

import '../api.dart';

/// Crop, rotate and mirror the selected clip.
///
/// The crop cuts edges **away**: the picture keeps its size and place, and
/// what was cut becomes transparent — a cropped killfeed laid over another
/// clip is the use it is made for. Rotation turns the clip around the
/// frame's centre; the frame edge cuts the corners that turn out of it.
class CropPanel extends StatelessWidget {
  const CropPanel({
    super.key,
    required this.transform,
    required this.onChanged,
    this.onGestureStart,
    this.onGestureEnd,
  });

  final ClipTransform transform;
  final ValueChanged<ClipTransform> onChanged;

  /// A slider drag is one undo step, not one per frame.
  final VoidCallback? onGestureStart;
  final VoidCallback? onGestureEnd;

  /// How much one edge can lose: two opposite edges together still leave a
  /// tenth of the picture.
  static const maxCrop = 0.45;

  /// Into (-180, 180], so ±90 steps never run off the slider.
  static double normalise(double degrees) {
    final d = (degrees + 180) % 360;
    return d == 0 ? 180 : d - 180;
  }

  String get _summary {
    final t = transform;
    return [
      if (t.hasCrop) 'cropped',
      if (t.rotation % 360 != 0) '${t.rotation.round()}°',
      if (t.flipH) 'mirrored',
      if (t.flipV) 'upside down',
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = transform;
    final summary = _summary;

    Widget edge(String label, double value, ClipTransform Function(double) set) =>
        Row(
          children: [
            SizedBox(
              width: 64,
              child: Text(label, style: theme.textTheme.bodyMedium),
            ),
            Expanded(
              child: Slider(
                key: ValueKey('crop-${label.toLowerCase()}'),
                value: value.clamp(0.0, maxCrop),
                max: maxCrop,
                onChangeStart: (_) => onGestureStart?.call(),
                onChangeEnd: (_) => onGestureEnd?.call(),
                onChanged: (v) => onChanged(set(v)),
              ),
            ),
            SizedBox(
              width: 40,
              child: Text(
                '${(value * 100).round()}%',
                textAlign: TextAlign.right,
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        );

    return ExpansionTile(
      key: const Key('crop-panel'),
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 8),
      title: Row(
        children: [
          const Icon(Icons.crop_rotate, size: 16),
          const SizedBox(width: 8),
          Text('Crop & rotate', style: theme.textTheme.labelLarge),
          if (summary.isNotEmpty) ...[
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                summary,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          ],
        ],
      ),
      children: [
        edge('Left', t.cropLeft, (v) => t.copyWith(cropLeft: v)),
        edge('Right', t.cropRight, (v) => t.copyWith(cropRight: v)),
        edge('Top', t.cropTop, (v) => t.copyWith(cropTop: v)),
        edge('Bottom', t.cropBottom, (v) => t.copyWith(cropBottom: v)),
        Row(
          children: [
            SizedBox(
              width: 64,
              child: Text('Rotate', style: theme.textTheme.bodyMedium),
            ),
            Expanded(
              child: Slider(
                key: const Key('rotation-slider'),
                value: normalise(t.rotation).clamp(-180.0, 180.0),
                min: -180,
                max: 180,
                onChangeStart: (_) => onGestureStart?.call(),
                onChangeEnd: (_) => onGestureEnd?.call(),
                // whole degrees, and a pull towards the right angles
                onChanged: (v) {
                  var d = v.roundToDouble();
                  for (final snap in const [-180.0, -90.0, 0.0, 90.0, 180.0]) {
                    if ((d - snap).abs() <= 3) d = snap;
                  }
                  onChanged(t.copyWith(rotation: d));
                },
              ),
            ),
            SizedBox(
              width: 40,
              child: Text(
                '${normalise(t.rotation).round()}°',
                textAlign: TextAlign.right,
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            IconButton(
              key: const Key('rotate-left'),
              tooltip: 'Turn 90° left',
              onPressed: () =>
                  onChanged(t.copyWith(rotation: normalise(t.rotation - 90))),
              icon: const Icon(Icons.rotate_left),
            ),
            IconButton(
              key: const Key('rotate-right'),
              tooltip: 'Turn 90° right',
              onPressed: () =>
                  onChanged(t.copyWith(rotation: normalise(t.rotation + 90))),
              icon: const Icon(Icons.rotate_right),
            ),
            FilterChip(
              key: const Key('flip-h'),
              avatar: const Icon(Icons.flip, size: 16),
              label: const Text('Mirror'),
              selected: t.flipH,
              onSelected: (v) => onChanged(t.copyWith(flipH: v)),
            ),
            FilterChip(
              key: const Key('flip-v'),
              avatar: const RotatedBox(
                quarterTurns: 1,
                child: Icon(Icons.flip, size: 16),
              ),
              label: const Text('Upside down'),
              selected: t.flipV,
              onSelected: (v) => onChanged(t.copyWith(flipV: v)),
            ),
            TextButton(
              key: const Key('crop-reset'),
              onPressed: t.hasCrop || t.hasTurn
                  ? () => onChanged(t.withoutCropTurn)
                  : null,
              child: const Text('Reset'),
            ),
          ],
        ),
      ],
    );
  }
}
