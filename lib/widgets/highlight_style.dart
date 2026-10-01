import 'package:flutter/material.dart';

/// Each kind of generated video gets an icon, a colour and a display name.
/// Concentrado aqui para a lista, o detalhe e o player falarem a mesma língua.
class HighlightStyle {
  const HighlightStyle(this.label, this.icon, this.color);

  final String label;
  final IconData icon;
  final Color color;

  static const _map = <String, HighlightStyle>{
    // everything that comes out of the editor. The rule-based kinds (kill
    // streak, sleep darts…) belonged to videos the system assembled on its
    // own, which no longer exist.
    'custom': HighlightStyle('Montagem', Icons.timeline, Color(0xFF7E57C2)),
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
    // pode ser a do jogador (lida no botão do rodapé) ou a de outra pessoa
    // (lida no killfeed); `meta['side']` separa as duas
    'ult_used': EventStyle('Ultimate', Color(0xFF66BB6A)),
    'ult_negated': EventStyle('Ultimate anulada', Color(0xFF26A69A)),
    'headshot': EventStyle('Na cabeça', Color(0xFFEF5350)),
    'ability_kill': EventStyle('Morte por habilidade', Color(0xFF7E57C2)),
    'sleep': EventStyle('Dardo no alvo', Color(0xFF29B6F6)),
    'stun': EventStyle('Pedrada certeira', Color(0xFF8D6E63)),
  };

  static EventStyle of(String kind) =>
      _map[kind] ?? const EventStyle('Evento', Colors.grey);

  static List<MapEntry<String, EventStyle>> get all => _map.entries.toList();
}

/// `orisa/energy_javelin` → `Orisa: Energy Javelin`.
///
/// O nome vem do arquivo do ícone, que veio da Blizzard em inglês. Traduzir
/// aqui exigiria uma tabela de 270 linhas para envelhecer a cada herói novo — e
/// o nome original é o que o jogador vê na tela de herói e reconhece.
String nomeDaHabilidade(String ability) {
  final barra = ability.indexOf('/');
  final heroi = barra < 0 ? '' : ability.substring(0, barra);
  final nome = barra < 0 ? ability : ability.substring(barra + 1);
  String bonito(String s) => [
    for (final palavra
        in s.replaceAll('-', ' ').replaceAll('_', ' ').split(' '))
      if (palavra.isNotEmpty)
        '${palavra[0].toUpperCase()}${palavra.substring(1)}',
  ].join(' ');
  final habilidade = bonito(nome);
  return heroi.isEmpty ? habilidade : '${bonito(heroi)}: $habilidade';
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
  ];

  static TransitionType? of(String kind) =>
      all.where((t) => t.kind == kind).firstOrNull;
}
