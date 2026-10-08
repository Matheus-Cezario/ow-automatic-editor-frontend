/// The editor's keyboard shortcuts, and the user's own choice of keys.
///
/// Each command has an id, a name the shortcut list shows and default keys.
/// What the user changes is kept as a map from command id to keys, so a new
/// command added later comes in with its default and an old choice is not
/// lost to it.
library;

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// A key with its modifiers. `command` is Ctrl on Windows and Linux and Cmd
/// on a Mac: the same combination is registered both ways.
@immutable
class KeyCombo {
  const KeyCombo(
    this.key, {
    this.command = false,
    this.shift = false,
    this.alt = false,
  });

  final LogicalKeyboardKey key;
  final bool command;
  final bool shift;
  final bool alt;

  /// What [CallbackShortcuts] listens to: two activators for a command key.
  List<ShortcutActivator> get activators => command
      ? [
          SingleActivator(key, control: true, shift: shift, alt: alt),
          SingleActivator(key, meta: true, shift: shift, alt: alt),
        ]
      : [SingleActivator(key, shift: shift, alt: alt)];

  /// How it reads in the shortcut list: `Ctrl + Shift + C`.
  String get label => [
    if (command) 'Ctrl',
    if (alt) 'Alt',
    if (shift) 'Shift',
    keyLabel(key),
  ].join(' + ');

  /// The combination a key press makes, or null for a modifier alone — the
  /// press that starts a combination, not one.
  static KeyCombo? fromEvent(KeyEvent event) {
    final key = event.logicalKey;
    if (_modifiers.contains(key)) return null;
    final keys = HardwareKeyboard.instance;
    return KeyCombo(
      key,
      command: keys.isControlPressed || keys.isMetaPressed,
      shift: keys.isShiftPressed,
      alt: keys.isAltPressed,
    );
  }

  String toJson() => [
    if (command) 'cmd',
    if (alt) 'alt',
    if (shift) 'shift',
    '${key.keyId}',
  ].join('+');

  static KeyCombo? fromJson(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    final parts = raw.split('+');
    final id = int.tryParse(parts.last);
    if (id == null) return null;
    final key = LogicalKeyboardKey.findKeyByKeyId(id) ?? LogicalKeyboardKey(id);
    return KeyCombo(
      key,
      command: parts.contains('cmd'),
      shift: parts.contains('shift'),
      alt: parts.contains('alt'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is KeyCombo &&
      other.key == key &&
      other.command == command &&
      other.shift == shift &&
      other.alt == alt;

  @override
  int get hashCode => Object.hash(key, command, shift, alt);

  @override
  String toString() => label;
}

final _modifiers = {
  LogicalKeyboardKey.shift,
  LogicalKeyboardKey.shiftLeft,
  LogicalKeyboardKey.shiftRight,
  LogicalKeyboardKey.control,
  LogicalKeyboardKey.controlLeft,
  LogicalKeyboardKey.controlRight,
  LogicalKeyboardKey.alt,
  LogicalKeyboardKey.altLeft,
  LogicalKeyboardKey.altRight,
  LogicalKeyboardKey.meta,
  LogicalKeyboardKey.metaLeft,
  LogicalKeyboardKey.metaRight,
  LogicalKeyboardKey.capsLock,
  LogicalKeyboardKey.fn,
};

/// A key's name as people write it.
String keyLabel(LogicalKeyboardKey key) => switch (key) {
  LogicalKeyboardKey.space => 'Space',
  LogicalKeyboardKey.arrowLeft => '←',
  LogicalKeyboardKey.arrowRight => '→',
  LogicalKeyboardKey.arrowUp => '↑',
  LogicalKeyboardKey.arrowDown => '↓',
  LogicalKeyboardKey.delete => 'Delete',
  LogicalKeyboardKey.backspace => 'Backspace',
  LogicalKeyboardKey.escape => 'Esc',
  LogicalKeyboardKey.enter => 'Enter',
  LogicalKeyboardKey.tab => 'Tab',
  _ =>
    key.keyLabel.isEmpty ? (key.debugName ?? '?') : key.keyLabel.toUpperCase(),
};

/// One thing the keyboard can do in the editor.
class EditorCommand {
  const EditorCommand(this.id, this.label, this.defaults);

  final String id;

  /// What the shortcut list says it does.
  final String label;
  final List<KeyCombo> defaults;
}

/// Every command, in the order the shortcut list shows them.
final List<EditorCommand> kEditorCommands = [
  const EditorCommand('play', 'play or pause', [
    KeyCombo(LogicalKeyboardKey.space),
    KeyCombo(LogicalKeyboardKey.keyK),
  ]),
  const EditorCommand('play-on', 'play', [KeyCombo(LogicalKeyboardKey.keyL)]),
  const EditorCommand('back', 'back 2 s', [KeyCombo(LogicalKeyboardKey.keyJ)]),
  const EditorCommand('left', 'playhead back 1 s', [
    KeyCombo(LogicalKeyboardKey.arrowLeft),
  ]),
  const EditorCommand('right', 'playhead forward 1 s', [
    KeyCombo(LogicalKeyboardKey.arrowRight),
  ]),
  const EditorCommand('frame-back', 'one frame back', [
    KeyCombo(LogicalKeyboardKey.comma),
  ]),
  const EditorCommand('frame-on', 'one frame forward', [
    KeyCombo(LogicalKeyboardKey.period),
  ]),
  const EditorCommand('prev-clip', 'select the previous cut', [
    KeyCombo(LogicalKeyboardKey.arrowLeft, alt: true),
  ]),
  const EditorCommand('next-clip', 'select the next cut', [
    KeyCombo(LogicalKeyboardKey.arrowRight, alt: true),
  ]),
  const EditorCommand('prev-edit', 'playhead to the previous cut edge', [
    KeyCombo(LogicalKeyboardKey.arrowUp),
  ]),
  const EditorCommand('next-edit', 'playhead to the next cut edge', [
    KeyCombo(LogicalKeyboardKey.arrowDown),
  ]),
  const EditorCommand(
    'describe',
    'say where the playhead is and what is selected',
    [KeyCombo(LogicalKeyboardKey.keyW, alt: true)],
  ),
  const EditorCommand('nudge-left', 'nudge the selected cuts left', [
    KeyCombo(LogicalKeyboardKey.arrowLeft, shift: true),
  ]),
  const EditorCommand('nudge-right', 'nudge the selected cuts right', [
    KeyCombo(LogicalKeyboardKey.arrowRight, shift: true),
  ]),
  const EditorCommand('layer-up', 'move the selected cuts a layer up', [
    KeyCombo(LogicalKeyboardKey.arrowUp, alt: true),
  ]),
  const EditorCommand('layer-down', 'move the selected cuts a layer down', [
    KeyCombo(LogicalKeyboardKey.arrowDown, alt: true),
  ]),
  const EditorCommand('split', 'split the cut under the cursor', [
    KeyCombo(LogicalKeyboardKey.keyS),
  ]),
  const EditorCommand('split-all', 'split every layer at the cursor', [
    KeyCombo(LogicalKeyboardKey.keyS, shift: true),
  ]),
  const EditorCommand('trim-start', 'trim the start to the cursor', [
    KeyCombo(LogicalKeyboardKey.bracketLeft),
  ]),
  const EditorCommand('trim-end', 'trim the end to the cursor', [
    KeyCombo(LogicalKeyboardKey.bracketRight),
  ]),
  const EditorCommand(
    'align',
    'align the selected block\'s play to the cursor',
    [KeyCombo(LogicalKeyboardKey.keyM)],
  ),
  const EditorCommand('zoom-in', 'zoom the ruler in', [
    KeyCombo(LogicalKeyboardKey.equal),
  ]),
  const EditorCommand('zoom-out', 'zoom the ruler out', [
    KeyCombo(LogicalKeyboardKey.minus),
  ]),
  const EditorCommand('zoom-fit', 'fit the whole montage', [
    KeyCombo(LogicalKeyboardKey.backslash),
  ]),
  const EditorCommand('marker', 'marker at the playhead', [
    KeyCombo(LogicalKeyboardKey.keyN),
  ]),
  const EditorCommand('next-marker', 'next marker', [
    KeyCombo(LogicalKeyboardKey.keyN, shift: true),
  ]),
  const EditorCommand('mark-in', 'in point at the playhead', [
    KeyCombo(LogicalKeyboardKey.keyI),
  ]),
  const EditorCommand('mark-out', 'out point at the playhead', [
    KeyCombo(LogicalKeyboardKey.keyO),
  ]),
  const EditorCommand('clear-range', 'clear the in and out points', [
    KeyCombo(LogicalKeyboardKey.keyX, alt: true),
  ]),
  const EditorCommand('loop', 'loop playback (the in/out range, or all)', [
    KeyCombo(LogicalKeyboardKey.keyL, shift: true),
  ]),
  const EditorCommand('volume', 'volume lines: drag, click to add a point', [
    KeyCombo(LogicalKeyboardKey.keyV),
  ]),
  const EditorCommand('fullscreen', 'monitor full screen', [
    KeyCombo(LogicalKeyboardKey.keyF),
  ]),
  const EditorCommand('delete', 'remove from the montage', [
    KeyCombo(LogicalKeyboardKey.delete),
    KeyCombo(LogicalKeyboardKey.backspace),
  ]),
  const EditorCommand('ripple-delete', 'delete and close the gap', [
    KeyCombo(LogicalKeyboardKey.delete, shift: true),
    KeyCombo(LogicalKeyboardKey.backspace, shift: true),
  ]),
  const EditorCommand('undo', 'undo', [
    KeyCombo(LogicalKeyboardKey.keyZ, command: true),
  ]),
  const EditorCommand('redo', 'redo', [
    KeyCombo(LogicalKeyboardKey.keyZ, command: true, shift: true),
    KeyCombo(LogicalKeyboardKey.keyY, command: true),
  ]),
  const EditorCommand('copy', 'copy', [
    KeyCombo(LogicalKeyboardKey.keyC, command: true),
  ]),
  const EditorCommand('paste', 'paste', [
    KeyCombo(LogicalKeyboardKey.keyV, command: true),
  ]),
  const EditorCommand('duplicate', 'duplicate', [
    KeyCombo(LogicalKeyboardKey.keyD, command: true),
  ]),
  const EditorCommand('select-all', 'select all', [
    KeyCombo(LogicalKeyboardKey.keyA, command: true),
  ]),
  const EditorCommand('copy-effects', 'copy effects', [
    KeyCombo(LogicalKeyboardKey.keyC, command: true, shift: true),
  ]),
  const EditorCommand('paste-effects', 'paste effects', [
    KeyCombo(LogicalKeyboardKey.keyV, command: true, shift: true),
  ]),
];

/// Esc is not offered for change: it is how full screen and a selection are
/// left, and taking it away would leave no way out.
final kFixedKeys = {const KeyCombo(LogicalKeyboardKey.escape)};

/// The keys each command answers to: the defaults, with the user's changes.
@immutable
class Keymap {
  const Keymap([this.changed = const {}]);

  /// Only what the user changed, by command id. An empty list is a command
  /// the user left without a key.
  final Map<String, List<KeyCombo>> changed;

  static const defaults = Keymap();

  List<KeyCombo> keysOf(String id) =>
      changed[id] ?? kEditorCommands.firstWhere((c) => c.id == id).defaults;

  /// The command a combination runs, if any.
  String? commandFor(KeyCombo combo) {
    for (final c in kEditorCommands) {
      if (keysOf(c.id).contains(combo)) return c.id;
    }
    return null;
  }

  /// [combo] now runs [id] — and only it: a key that ran something else is
  /// taken from it, or one key would do two things.
  Keymap bind(String id, KeyCombo combo) {
    if (kFixedKeys.contains(combo)) return this;
    final next = <String, List<KeyCombo>>{...changed};
    for (final c in kEditorCommands) {
      if (c.id == id) continue;
      final keys = keysOf(c.id);
      if (keys.contains(combo)) {
        next[c.id] = [
          for (final k in keys)
            if (k != combo) k,
        ];
      }
    }
    final own = keysOf(id);
    next[id] = [...own.where((k) => k != combo), combo];
    return Keymap(next)._tidy();
  }

  /// [id] without [combo].
  Keymap unbind(String id, KeyCombo combo) => Keymap({
    ...changed,
    id: [
      for (final k in keysOf(id))
        if (k != combo) k,
    ],
  })._tidy();

  /// [id] back to its default keys. A default key the user had given to
  /// another command stays there: resetting one row does not undo others.
  Keymap reset(String id) {
    final next = {...changed}..remove(id);
    return Keymap(next)._tidy();
  }

  /// A change equal to the default is not a change.
  Keymap _tidy() {
    final next = <String, List<KeyCombo>>{};
    for (final e in changed.entries) {
      final command = kEditorCommands.where((c) => c.id == e.key).firstOrNull;
      if (command == null) continue;
      final same =
          e.value.length == command.defaults.length &&
          e.value.toSet().containsAll(command.defaults);
      if (!same) next[e.key] = e.value;
    }
    return Keymap(next);
  }

  bool get isDefault => changed.isEmpty;

  String toJson() => jsonEncode({
    for (final e in changed.entries)
      e.key: [for (final k in e.value) k.toJson()],
  });

  /// What was kept, ignoring commands that no longer exist and anything
  /// unreadable: a broken saved keymap gives the defaults, not a dead editor.
  static Keymap fromJson(String? raw) {
    if (raw == null || raw.isEmpty) return defaults;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return defaults;
      final ids = {for (final c in kEditorCommands) c.id};
      return Keymap({
        for (final e in decoded.entries)
          if (ids.contains(e.key) && e.value is List)
            e.key as String: [
              for (final k in e.value as List) ?KeyCombo.fromJson(k),
            ],
      })._tidy();
    } catch (_) {
      return defaults;
    }
  }
}

/// Where the keymap is kept among the preferences.
const kKeymapPref = 'keymap';
