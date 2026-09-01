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
    'headshot_montage': HighlightStyle(
      'Só na cabeça',
      Icons.gps_fixed,
      Color(0xFFEF5350),
    ),
    // o título desta vem com o nome da habilidade ("Orisa: Energy Javelin"),
    // então o rótulo genérico só aparece onde o título não cabe
    'ability_montage': HighlightStyle(
      'Eliminações com habilidade',
      Icons.auto_awesome,
      Color(0xFF7E57C2),
    ),
    // tudo o que sai do editor. Os tipos acima são de vídeos gerados por regra,
    // que o sistema não faz mais — ficam para os vídeos já gerados não
    // perderem o ícone que tinham.
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
    for (final palavra in s.replaceAll('-', ' ').replaceAll('_', ' ').split(' '))
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
