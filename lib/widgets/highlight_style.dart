import 'package:flutter/material.dart';

/// Each kind of generated video gets an icon, a colour and a display name.
/// Kept here so the list, the detail and the player speak the same language.
class HighlightStyle {
  const HighlightStyle(this.label, this.icon, this.color);

  final String label;
  final IconData icon;
  final Color color;

  static const _map = <String, HighlightStyle>{
    // everything that comes out of the editor. The rule-based kinds (kill
    // streak, sleep darts…) belonged to videos the system assembled on its
    // own, which no longer exist.
    'custom': HighlightStyle('Montage', Icons.timeline, Color(0xFF7E57C2)),
  };

  static HighlightStyle of(String kind) =>
      _map[kind] ?? const HighlightStyle('Moment', Icons.movie, Colors.grey);
}

/// The same idea for the timeline's raw events.
class EventStyle {
  const EventStyle(this.label, this.color);

  final String label;
  final Color color;

  static const _map = <String, EventStyle>{
    'kill': EventStyle('Kill', Color(0xFFFFB300)),
    // the detector recognises health hitting zero or the HUD disappearing:
    // that covers death, kill cam, round change and hero selection. The label
    // promises no more than the signal delivers.
    'death': EventStyle('Interruption', Color(0xFF78909C)),
    'low_hp': EventStyle('Low health', Color(0xFFFF7043)),
    'escape': EventStyle('Survived', Color(0xFF4FC3F7)),
    // it can be the player's (read on the footer button) or someone else's
    // (read in the killfeed); `meta['side']` tells them apart
    'ult_used': EventStyle('Ultimate', Color(0xFF66BB6A)),
    'ult_negated': EventStyle('Negated ultimate', Color(0xFF26A69A)),
    'headshot': EventStyle('Headshot', Color(0xFFEF5350)),
    'ability_kill': EventStyle('Ability kill', Color(0xFF7E57C2)),
    'sleep': EventStyle('Sleep dart', Color(0xFF29B6F6)),
    'stun': EventStyle('Accretion stun', Color(0xFF8D6E63)),
    // a stretch the user marked by hand on the recording
    'custom': EventStyle('Cut', Color(0xFF90A4AE)),
  };

  static EventStyle of(String kind) =>
      _map[kind] ?? const EventStyle('Event', Colors.grey);

  static List<MapEntry<String, EventStyle>> get all => _map.entries.toList();
}

/// `orisa/energy_javelin` → `Orisa: Energy Javelin`.
///
/// The name comes from the icon's file, which came from Blizzard in English —
/// the same name the player sees on the hero screen and recognises.
String abilityName(String ability) {
  final bar = ability.indexOf('/');
  final hero = bar < 0 ? '' : ability.substring(0, bar);
  final displayName = bar < 0 ? ability : ability.substring(bar + 1);
  String pretty(String s) => [
    for (final word
        in s.replaceAll('-', ' ').replaceAll('_', ' ').split(' '))
      if (word.isNotEmpty)
        '${word[0].toUpperCase()}${word.substring(1)}',
  ].join(' ');
  final abilityPart = pretty(displayName);
  return hero.isEmpty ? abilityPart : '${pretty(hero)}: $abilityPart';
}

String formatDuration(double seconds) {
  final s = seconds.round();
  final m = s ~/ 60;
  final r = s % 60;
  return m > 0
      ? '$m:${r.toString().padLeft(2, '0')}'
      : '${seconds.toStringAsFixed(1)}s';
}

String formatClock(double seconds) {
  final s = seconds.round();
  return '${(s ~/ 60).toString().padLeft(2, '0')}:'
      '${(s % 60).toString().padLeft(2, '0')}';
}

/// What each transition is, for the screen.
class TransitionType {
  const TransitionType(this.kind, this.name, this.description, this.icon);

  final String kind;
  final String name;
  final String description;
  final IconData icon;

  static const all = [
    TransitionType(
      'dissolve',
      'Dissolve',
      'the new clip appears over the previous one',
      Icons.blur_on,
    ),
    TransitionType(
      'fade_black',
      'Dip to black',
      'goes dark and comes back on the new clip',
      Icons.brightness_3,
    ),
    TransitionType(
      'fade_white',
      'Dip to white',
      'a flash at the cut',
      Icons.flare,
    ),
    TransitionType(
      'slide_left',
      'Slide left',
      'comes in from the right',
      Icons.west,
    ),
    TransitionType(
      'slide_right',
      'Slide right',
      'comes in from the left',
      Icons.east,
    ),
    TransitionType('slide_up', 'Slide up', 'comes in from below', Icons.north),
    TransitionType(
      'slide_down',
      'Slide down',
      'comes in from above',
      Icons.south,
    ),
    TransitionType(
      'wipe_left',
      'Wipe left',
      'an edge sweeps right to left, uncovering it',
      Icons.keyboard_double_arrow_left,
    ),
    TransitionType(
      'wipe_right',
      'Wipe right',
      'an edge sweeps left to right, uncovering it',
      Icons.keyboard_double_arrow_right,
    ),
    TransitionType(
      'wipe_up',
      'Wipe up',
      'an edge sweeps upwards, uncovering it',
      Icons.keyboard_double_arrow_up,
    ),
    TransitionType(
      'wipe_down',
      'Wipe down',
      'an edge sweeps downwards, uncovering it',
      Icons.keyboard_double_arrow_down,
    ),
    TransitionType(
      'zoom',
      'Zoom',
      'arrives enlarged and settles as it appears',
      Icons.zoom_out_map,
    ),
    TransitionType(
      'spin',
      'Spin',
      'turns and grows into place',
      Icons.rotate_right,
    ),
    TransitionType(
      'glitch',
      'Glitch',
      'a torn hard cut — split colours, jumping bands',
      Icons.broken_image_outlined,
    ),
  ];

  static TransitionType? of(String kind) =>
      all.where((t) => t.kind == kind).firstOrNull;
}
