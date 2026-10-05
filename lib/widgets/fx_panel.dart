import 'package:flutter/material.dart';

import '../api.dart';

/// The clip's look and visual effects: a colour grade in one click, blur,
/// sharpen, vignette, a handheld shake, and the impact — a flash and a burst
/// of shake right at the play.
class FxPanel extends StatelessWidget {
  const FxPanel({
    super.key,
    required this.fx,
    required this.onChanged,
    this.hasPlay = false,
    this.onGestureStart,
    this.onGestureEnd,
  });

  final ClipFx fx;
  final ValueChanged<ClipFx> onChanged;

  /// Does the clip have a play? The impact hits there; otherwise at its start.
  final bool hasPlay;

  /// A slider drag is one undo step, not one per frame.
  final VoidCallback? onGestureStart;
  final VoidCallback? onGestureEnd;

  int get _active =>
      (fx.look == Look.none ? 0 : 1) +
      [fx.blur, fx.sharpen, fx.vignette, fx.shake, fx.impact]
          .where((v) => v > 0)
          .length;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Widget amount(
      String label,
      String key,
      double value,
      ClipFx Function(double) set, {
      String? hint,
    }) => Row(
      children: [
        SizedBox(
          width: 76,
          child: Tooltip(
            message: hint ?? '',
            child: Text(label, style: theme.textTheme.bodyMedium),
          ),
        ),
        Expanded(
          child: Slider(
            key: ValueKey('fx-$key'),
            value: value.clamp(0.0, 1.0),
            onChangeStart: (_) => onGestureStart?.call(),
            onChangeEnd: (_) => onGestureEnd?.call(),
            onChanged: (v) => onChanged(set((v * 100).round() / 100)),
          ),
        ),
        SizedBox(
          width: 40,
          child: Text(
            value == 0 ? 'off' : '${(value * 100).round()}%',
            textAlign: TextAlign.right,
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );

    return ExpansionTile(
      key: const Key('fx-panel'),
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 8),
      title: Row(
        children: [
          const Icon(Icons.blur_on, size: 16),
          const SizedBox(width: 8),
          Text('Look & FX', style: theme.textTheme.labelLarge),
          if (_active > 0) ...[
            const SizedBox(width: 8),
            Text(
              '$_active in use',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ],
        ],
      ),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Text('Look', style: theme.textTheme.bodyMedium),
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final l in Look.values)
              ChoiceChip(
                key: ValueKey('look-${l.name}'),
                label: Text(l.label),
                selected: fx.look == l,
                onSelected: (_) => onChanged(fx.copyWith(look: l)),
              ),
          ],
        ),
        const SizedBox(height: 8),
        amount('Blur', 'blur', fx.blur, (v) => fx.copyWith(blur: v)),
        amount(
          'Sharpen',
          'sharpen',
          fx.sharpen,
          (v) => fx.copyWith(sharpen: v),
          hint: 'shows in the exact preview and the render, not live',
        ),
        amount(
          'Vignette',
          'vignette',
          fx.vignette,
          (v) => fx.copyWith(vignette: v),
        ),
        amount(
          'Shake',
          'shake',
          fx.shake,
          (v) => fx.copyWith(shake: v),
          hint: 'a handheld camera, the whole clip',
        ),
        amount(
          'Impact',
          'impact',
          fx.impact,
          (v) => fx.copyWith(impact: v),
          hint: hasPlay
              ? 'a flash and a burst of shake at the play'
              : 'a flash and a burst of shake at the start of the clip',
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            key: const Key('fx-reset'),
            onPressed: fx.isNeutral ? null : () => onChanged(const ClipFx()),
            child: const Text('Reset'),
          ),
        ),
      ],
    );
  }
}
