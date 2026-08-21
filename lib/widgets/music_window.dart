import 'package:flutter/material.dart';

import '../api.dart';

/// Escolha do trecho da música de **um** vídeo, e do que fazer quando os
/// momentos acabarem antes dela.
///
/// Opera sobre [ClipOptions], que é por vídeo: dois vídeos da mesma partida
/// podem ter músicas, trechos e durações diferentes.
class MusicWindow extends StatelessWidget {
  const MusicWindow({
    super.key,
    required this.options,
    required this.enabled,
    required this.onChanged,
    this.dense = false,
  });

  final ClipOptions options;
  final bool enabled;
  final ValueChanged<ClipOptions> onChanged;

  /// Versão compacta, para caber dentro do cartão de uma proposta.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final delimitado = options.musicEndS != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!dense) ...[
          Text('Trecho da música', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
        ],
        Text(
          enabled
              ? 'Onde a música entra e onde termina. O vídeo é montado para '
                  'caber nesse trecho.'
              : 'Escolha uma música para poder recortar um trecho.',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TimeField(
                label: 'Início',
                seconds: options.musicStartS,
                enabled: enabled,
                onChanged: (v) =>
                    onChanged(options.copyWith(musicStartS: v ?? 0)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TimeField(
                label: 'Fim',
                seconds: options.musicEndS,
                enabled: enabled,
                hint: 'até o fim',
                onChanged: (v) => onChanged(
                  v == null
                      ? options.copyWith(clearMusicEnd: true)
                      : options.copyWith(musicEndS: v),
                ),
              ),
            ),
          ],
        ),
        if (!options.janelaValida)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'O fim precisa vir depois do início.',
              style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
            ),
          ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: dense,
          value: options.montageLoop,
          onChanged: enabled && delimitado
              ? (v) => onChanged(options.copyWith(montageLoop: v))
              : null,
          title: const Text('Repetir trechos para preencher'),
          subtitle: Text(
            options.montageLoop
                ? 'o vídeo terá exatamente a duração do trecho; os momentos '
                    'entram em ordem sorteada, sem repetir nenhum antes de '
                    'todos terem aparecido'
                : 'o vídeo para quando os momentos acabarem, sem passar da '
                    'duração do trecho',
          ),
        ),
      ],
    );
  }
}

/// Campo de tempo em mm:ss (aceita também segundos puros).
class TimeField extends StatefulWidget {
  const TimeField({
    super.key,
    required this.label,
    required this.seconds,
    required this.enabled,
    required this.onChanged,
    this.hint,
  });

  final String label;
  final double? seconds;
  final bool enabled;
  final String? hint;
  final ValueChanged<double?> onChanged;

  @override
  State<TimeField> createState() => _TimeFieldState();
}

class _TimeFieldState extends State<TimeField> {
  late final TextEditingController _c =
      TextEditingController(text: _format(widget.seconds));

  static String _format(double? s) {
    if (s == null || s <= 0) return '';
    final total = s.round();
    return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
  }

  /// "1:30" → 90. "90" → 90. Vazio → null.
  static double? _parse(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    final parts = text.split(':');
    if (parts.length == 2) {
      final m = int.tryParse(parts[0]);
      final s = int.tryParse(parts[1]);
      if (m == null || s == null) return null;
      return (m * 60 + s).toDouble();
    }
    return double.tryParse(text);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
        controller: _c,
        enabled: widget.enabled,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: widget.label,
          hintText: widget.hint ?? '0:00',
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        onChanged: (v) => widget.onChanged(_parse(v)),
      );
}
