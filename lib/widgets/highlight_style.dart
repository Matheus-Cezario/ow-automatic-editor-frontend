import 'package:flutter/material.dart';

/// Cada tipo de highlight ganha um ícone, uma cor e um nome em português.
/// Concentrado aqui para a lista, o detalhe e o player falarem a mesma língua.
class HighlightStyle {
  const HighlightStyle(this.label, this.icon, this.color);

  final String label;
  final IconData icon;
  final Color color;

  static const _map = <String, HighlightStyle>{
    'solo_wipe': HighlightStyle(
      'Sozinho contra todos',
      Icons.local_fire_department,
      Color(0xFFFF5252),
    ),
    'multikill': HighlightStyle(
      'Rajada de eliminações',
      Icons.bolt,
      Color(0xFFFFB300),
    ),
    'escape': HighlightStyle(
      'Fuga por pouco',
      Icons.directions_run,
      Color(0xFF4FC3F7),
    ),
    'beat_montage': HighlightStyle(
      'Montagem no ritmo',
      Icons.graphic_eq,
      Color(0xFFAB47BC),
    ),
    'ult_montage': HighlightStyle(
      'Ultimates anuladas',
      Icons.shield_moon,
      Color(0xFF66BB6A),
    ),
    'sleep_montage': HighlightStyle(
      'Dardos no alvo',
      Icons.bedtime,
      Color(0xFF29B6F6),
    ),
    'stun_montage': HighlightStyle(
      'Pedradas certeiras',
      Icons.landslide,
      Color(0xFF8D6E63),
    ),
  };

  static HighlightStyle of(String kind) =>
      _map[kind] ?? const HighlightStyle('Momento', Icons.movie, Colors.grey);
}

/// Mesma ideia para os eventos brutos da linha do tempo.
class EventStyle {
  const EventStyle(this.label, this.color);

  final String label;
  final Color color;

  static const _map = <String, EventStyle>{
    'kill': EventStyle('Eliminação', Color(0xFFFFB300)),
    // o detector reconhece a vida zerar ou a HUD sumir: isso cobre morte,
    // killcam, troca de round e seleção de herói. O rótulo não promete mais
    // do que o sinal entrega.
    'death': EventStyle('Interrupção', Color(0xFF78909C)),
    'low_hp': EventStyle('Vida baixa', Color(0xFFFF7043)),
    'escape': EventStyle('Sobreviveu', Color(0xFF4FC3F7)),
    'ult_used': EventStyle('Ultimate inimiga', Color(0xFF66BB6A)),
    'ult_negated': EventStyle('Ultimate anulada', Color(0xFF26A69A)),
    'sleep': EventStyle('Dardo no alvo', Color(0xFF29B6F6)),
    'stun': EventStyle('Pedrada certeira', Color(0xFF8D6E63)),
  };

  static EventStyle of(String kind) =>
      _map[kind] ?? const EventStyle('Evento', Colors.grey);

  static List<MapEntry<String, EventStyle>> get all => _map.entries.toList();
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
