import 'package:flutter/material.dart';

import '../api.dart';

/// How the clip mixes with the layers under it, and a colour keyed out.
///
/// Both only show over something: on the bottom layer there is just the black
/// background to mix with — the hint says so.
class BlendPanel extends StatelessWidget {
  const BlendPanel({
    super.key,
    required this.blend,
    required this.chroma,
    required this.onChanged,
    this.overSomething = true,
    this.onGestureStart,
    this.onGestureEnd,
  });

  final ClipBlend blend;
  final ChromaKey? chroma;
  final void Function(ClipBlend blend, ChromaKey? chroma) onChanged;

  /// Is there a picture layer under this clip's?
  final bool overSomething;

  /// A slider drag is one undo step, not one per frame.
  final VoidCallback? onGestureStart;
  final VoidCallback? onGestureEnd;

  /// The usual screens, and black and white for a logo on a solid ground.
  static const keyColours = [
    ('Green', '#00ff00'),
    ('Blue', '#0000ff'),
    ('Black', '#000000'),
    ('White', '#ffffff'),
  ];

  static Color _colour(String hex) =>
      Color(int.parse('ff${hex.replaceFirst('#', '')}', radix: 16));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final key = chroma;
    final summary = [
      if (blend != ClipBlend.normal) blend.label,
      if (key != null) 'keyed',
    ].join(' · ');

    Widget amount(
      String label,
      String id,
      double value,
      double min,
      ChromaKey Function(double) set,
    ) => Row(
      children: [
        SizedBox(
          width: 76,
          child: Text(label, style: theme.textTheme.bodyMedium),
        ),
        Expanded(
          child: Slider(
            key: ValueKey('key-$id'),
            value: value.clamp(min, 1.0),
            min: min,
            onChangeStart: (_) => onGestureStart?.call(),
            onChangeEnd: (_) => onGestureEnd?.call(),
            onChanged: (v) => onChanged(blend, set((v * 100).round() / 100)),
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
      key: const Key('blend-panel'),
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 8),
      title: Row(
        children: [
          const Icon(Icons.layers_outlined, size: 16),
          const SizedBox(width: 8),
          Text('Blend & key', style: theme.textTheme.labelLarge),
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
        if (!overSomething)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              'Nothing under this clip yet: it mixes with the black background.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: Text('Blend mode', style: theme.textTheme.bodyMedium),
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final m in ClipBlend.values)
              ChoiceChip(
                key: ValueKey('blend-${m.name}'),
                label: Text(m.label),
                selected: blend == m,
                onSelected: (_) => onChanged(m, key),
              ),
          ],
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          key: const Key('chroma-switch'),
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: key != null,
          onChanged: (on) => onChanged(blend, on ? const ChromaKey() : null),
          title: const Text('Chroma key'),
          subtitle: const Text('make a colour transparent — a green screen'),
        ),
        if (key != null) ...[
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final (name, hex) in keyColours)
                ChoiceChip(
                  key: ValueKey('key-colour-${name.toLowerCase()}'),
                  avatar: CircleAvatar(backgroundColor: _colour(hex)),
                  label: Text(name),
                  selected: key.color.toLowerCase() == hex,
                  onSelected: (_) => onChanged(blend, key.copyWith(color: hex)),
                ),
              SizedBox(
                width: 110,
                child: TextFormField(
                  key: const Key('key-colour-hex'),
                  initialValue: key.color,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: 'Other #rrggbb',
                  ),
                  onFieldSubmitted: (v) {
                    final hex = v.trim().startsWith('#') ? v.trim() : '#${v.trim()}';
                    if (RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(hex)) {
                      onChanged(blend, key.copyWith(color: hex.toLowerCase()));
                    }
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          amount(
            'Similarity',
            'similarity',
            key.similarity,
            0.01,
            (v) => key.copyWith(similarity: v),
          ),
          amount(
            'Softness',
            'softness',
            key.softness,
            0,
            (v) => key.copyWith(softness: v),
          ),
          Text(
            'The live monitor approximates the key; the exact preview and '
            'the render are what it really looks like.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ],
      ],
    );
  }
}
