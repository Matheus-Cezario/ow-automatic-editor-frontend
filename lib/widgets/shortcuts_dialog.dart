import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../keymap.dart';

/// The shortcut list, where each command's keys can be changed.
///
/// "+" on a row waits for the next key pressed and gives it to that command;
/// a key that ran something else is taken from it, and the list says so.
/// Every change reaches [onChanged] at once — there is no "save".
class ShortcutsDialog extends StatefulWidget {
  const ShortcutsDialog({
    super.key,
    required this.keymap,
    required this.onChanged,
  });

  final Keymap keymap;
  final ValueChanged<Keymap> onChanged;

  @override
  State<ShortcutsDialog> createState() => _ShortcutsDialogState();
}

class _ShortcutsDialogState extends State<ShortcutsDialog> {
  late Keymap _keymap = widget.keymap;

  /// The command waiting for a key, if any.
  String? _listening;

  /// What the last change did, when it took a key from another command.
  String? _note;

  final _capture = FocusNode(debugLabel: 'shortcut capture');

  @override
  void dispose() {
    _capture.dispose();
    super.dispose();
  }

  void _change(Keymap next, {String? note}) {
    setState(() {
      _keymap = next;
      _note = note;
    });
    widget.onChanged(next);
  }

  void _listen(String id) {
    setState(() {
      _listening = id;
      _note = null;
    });
    _capture.requestFocus();
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    final id = _listening;
    if (id == null || event is! KeyDownEvent) return KeyEventResult.ignored;
    final combo = KeyCombo.fromEvent(event);
    if (combo == null) return KeyEventResult.handled; // a modifier alone
    if (kFixedKeys.contains(combo)) {
      // Esc cancels: it is not a key to give away
      setState(() => _listening = null);
      return KeyEventResult.handled;
    }
    final before = _keymap.commandFor(combo);
    final taken = before != null && before != id
        ? kEditorCommands.firstWhere((c) => c.id == before).label
        : null;
    _listening = null;
    _change(
      _keymap.bind(id, combo),
      note: taken == null ? null : '${combo.label} no longer does "$taken".',
    );
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Shortcuts'),
      content: Focus(
        focusNode: _capture,
        onKeyEvent: _onKey,
        child: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Press + on a row, then the key. Ctrl also means Cmd on a Mac.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.hintColor,
                ),
              ),
              if (_note case final note?)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    note,
                    key: const Key('shortcut-note'),
                    style: TextStyle(color: theme.colorScheme.tertiary),
                  ),
                ),
              const SizedBox(height: 8),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final c in kEditorCommands) _row(theme, c),
                      const Divider(height: 24),
                      const _Fixed(
                        'Esc',
                        'clear the selection / leave full screen',
                      ),
                      const _Fixed('Ctrl + scroll', 'zoom around the mouse'),
                      const _Fixed('Shift + click', 'add to the selection'),
                      const _Fixed(
                        'drag on an empty track',
                        'select with a rectangle',
                      ),
                      const _Fixed('drag ↑ ↓', 'move the cut to another layer'),
                      const _Fixed(
                        'right-click',
                        'a cut, a layer, a library item or a moment: its menu',
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('shortcuts-reset-all'),
          onPressed: _keymap.isDefault ? null : () => _change(Keymap.defaults),
          child: const Text('Back to the defaults'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Widget _row(ThemeData theme, EditorCommand c) {
    final keys = _keymap.keysOf(c.id);
    final listening = _listening == c.id;
    final changed = _keymap.changed.containsKey(c.id);
    return Padding(
      key: Key('shortcut-${c.id}'),
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(c.label, style: TextStyle(color: theme.hintColor)),
          ),
          Expanded(
            flex: 2,
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 4,
              runSpacing: 2,
              children: [
                for (final k in keys)
                  InputChip(
                    label: Text(k.label),
                    visualDensity: VisualDensity.compact,
                    onDeleted: () => _change(_keymap.unbind(c.id, k)),
                    deleteButtonTooltipMessage: 'Remove this key',
                  ),
                if (listening)
                  const Chip(
                    key: Key('shortcut-listening'),
                    label: Text('press a key…'),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ),
          IconButton(
            key: Key('shortcut-add-${c.id}'),
            tooltip: 'Add a key',
            visualDensity: VisualDensity.compact,
            onPressed: () => _listen(c.id),
            icon: const Icon(Icons.add, size: 18),
          ),
          SizedBox(
            width: 36,
            child: changed
                ? IconButton(
                    key: Key('shortcut-reset-${c.id}'),
                    tooltip: 'Back to the default',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _change(_keymap.reset(c.id)),
                    icon: const Icon(Icons.undo, size: 18),
                  )
                : null,
          ),
        ],
      ),
    );
  }
}

/// A gesture in the list: shown, not changed.
class _Fixed extends StatelessWidget {
  const _Fixed(this.keyName, this.whatItDoes);

  final String keyName;
  final String whatItDoes;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        SizedBox(width: 170, child: Text(keyName)),
        Expanded(
          child: Text(
            whatItDoes,
            style: TextStyle(color: Theme.of(context).hintColor),
          ),
        ),
      ],
    ),
  );
}
