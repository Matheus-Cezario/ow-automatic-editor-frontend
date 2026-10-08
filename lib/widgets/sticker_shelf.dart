import 'package:flutter/material.dart';

import '../api.dart';

/// The server's stickers: pick a colour, click one, it lands on the frame.
///
/// It sits in the Library next to the sound effects for the same reason they
/// do: it answers "what do I put in now?" with things nobody had to bring.
/// A sticker goes over the picture at the playhead, small and in the middle;
/// on the monitor it is then dragged to whatever it points at.
class StickerShelf extends StatefulWidget {
  const StickerShelf({
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
  final StickerLibrary? library;
  final String? error;
  final bool enabled;

  /// The sticker and the colour it was picked in.
  final void Function(Sticker sticker, String color) onAdd;

  /// The sticker on its way into the match, if any — its tile shows it.
  final String? adding;
  final VoidCallback? onRetry;
  final EdgeInsets padding;

  /// What each group is called on screen.
  static const categoryLabels = {
    'point': 'Point',
    'mark': 'Marks',
    'game': 'Game',
    'fun': 'Fun',
  };

  @override
  State<StickerShelf> createState() => _StickerShelfState();
}

class _StickerShelfState extends State<StickerShelf> {
  /// The group on show; `null` is all of them.
  String? _category;

  /// The colour the stickers are shown and added in; the first on offer
  /// until one is picked.
  String? _color;

  static Color _parse(String hex) =>
      Color(int.parse(hex.replaceFirst('#', ''), radix: 16) | 0xFF000000);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final library = widget.library;

    final header = Padding(
      padding: widget.padding.copyWith(top: 12, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Stickers', style: theme.textTheme.titleSmall),
          Text(
            'Click to put one over the picture at the playhead, then drag it '
            'on the monitor to what it points at.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ],
      ),
    );

    if (widget.error != null) {
      return Column(
        key: const Key('sticker-shelf'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          header,
          Padding(
            padding: widget.padding,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Could not load the stickers.',
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
        key: const Key('sticker-shelf'),
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

    final color =
        _color ?? (library.colors.isEmpty ? 'red' : library.colors.first.id);
    final shown = [
      for (final s in library.stickers)
        if (_category == null || s.category == _category) s,
    ];
    final enabled = widget.enabled && widget.adding == null;

    return Column(
      key: const Key('sticker-shelf'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        header,
        Padding(
          padding: widget.padding.copyWith(bottom: 6),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final c in library.colors)
                Tooltip(
                  message: c.id,
                  child: InkWell(
                    key: Key('sticker-colour-${c.id}'),
                    customBorder: const CircleBorder(),
                    onTap: () => setState(() => _color = c.id),
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        color: _parse(c.hex),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: c.id == color
                              ? theme.colorScheme.primary
                              : theme.dividerColor,
                          width: c.id == color ? 3 : 1,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: widget.padding.copyWith(bottom: 6),
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              ChoiceChip(
                key: const Key('sticker-category-all'),
                label: const Text('All'),
                visualDensity: VisualDensity.compact,
                selected: _category == null,
                onSelected: (_) => setState(() => _category = null),
              ),
              for (final c in library.categories)
                ChoiceChip(
                  key: Key('sticker-category-$c'),
                  label: Text(StickerShelf.categoryLabels[c] ?? c),
                  visualDensity: VisualDensity.compact,
                  selected: _category == c,
                  onSelected: (_) => setState(() => _category = c),
                ),
            ],
          ),
        ),
        Padding(
          padding: widget.padding,
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final s in shown)
                Tooltip(
                  message: s.name,
                  child: Card(
                    key: ValueKey('sticker-${s.id}'),
                    margin: EdgeInsets.zero,
                    child: InkWell(
                      onTap: enabled ? () => widget.onAdd(s, color) : null,
                      child: SizedBox(
                        width: 56,
                        height: 56,
                        child: widget.adding == s.id
                            ? const Center(
                                child: SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              )
                            : Padding(
                                padding: const EdgeInsets.all(6),
                                child: Image.network(
                                  s.previewIn(color),
                                  errorBuilder: (_, _, _) => Center(
                                    child: Text(
                                      s.name,
                                      textAlign: TextAlign.center,
                                      style: theme.textTheme.labelSmall,
                                    ),
                                  ),
                                ),
                              ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
