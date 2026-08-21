import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../main.dart' show PhoneWidth;
import '../widgets/file_tile.dart';

/// Primeira fase: só a gravação.
///
/// Nenhuma música entra aqui. O sistema analisa a partida, monta a lista de
/// vídeos que dá para gerar, e só então — na tela da partida — o usuário
/// escolhe quais quer e dá a trilha de cada um.
class NewJobScreen extends StatefulWidget {
  const NewJobScreen({super.key});

  @override
  State<NewJobScreen> createState() => _NewJobScreenState();
}

class _NewJobScreenState extends State<NewJobScreen> {
  final _api = ApiClient();

  PlatformFile? _video;
  int _videoBytes = 0;
  JobParams _params = const JobParams();
  bool _sending = false;
  double _sent = 0;
  String? _error;

  Future<void> _pick() async {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['mp4', 'mkv', 'mov', 'avi', 'webm', 'm4v'],
    );
    if (picked == null) return;
    final size = await picked.length();
    if (!mounted) return;
    setState(() {
      _video = picked;
      _videoBytes = size;
    });
  }

  Future<void> _submit() async {
    if (_video == null) return;
    setState(() { _sending = true; _sent = 0; _error = null; });
    try {
      await _api.createJob(
        video: _video!,
        params: _params,
        onProgress: (p) => setState(() => _sent = p),
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _sending = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Nova partida')),
      body: PhoneWidth(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            FileTile(
              icon: Icons.videocam,
              title: 'Gravação da partida',
              subtitle: _video == null
                  ? 'mp4, mkv, mov, avi, webm'
                  : '${_video!.name}  ·  ${_mb(_videoBytes)}',
              chosen: _video != null,
              onTap: _sending ? null : _pick,
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.music_note,
                      size: 18, color: theme.colorScheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'A música vem depois: primeiro o sistema separa os '
                      'momentos, aí você escolhe quais vídeos quer e dá uma '
                      'trilha para cada um. Sem trilha, o vídeo fica com o '
                      'áudio original da partida.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),
            Text('O que considerar um momento',
                style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'Os padrões costumam funcionar; mexa se sua partida rende '
              'muitos ou pouquíssimos vídeos.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
            const SizedBox(height: 8),

            _Stepper(
              label: 'Eliminações para virar rajada',
              value: _params.multikillMin,
              min: 2,
              max: 6,
              enabled: !_sending,
              onChanged: (v) =>
                  setState(() => _params = _params.copyWith(multikillMin: v)),
            ),
            _Stepper(
              label: 'Eliminações para "sozinho contra todos"',
              value: _params.soloWipeMin,
              min: 3,
              max: 8,
              enabled: !_sending,
              onChanged: (v) =>
                  setState(() => _params = _params.copyWith(soloWipeMin: v)),
            ),
            _SliderRow(
              label: 'Janela da rajada',
              value: _params.multikillWindowS,
              min: 4,
              max: 25,
              suffix: 's',
              enabled: !_sending,
              onChanged: (v) => setState(
                  () => _params = _params.copyWith(multikillWindowS: v)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _params.makeBeatMontage,
              onChanged: _sending
                  ? null
                  : (v) => setState(
                      () => _params = _params.copyWith(makeBeatMontage: v)),
              title: const Text('Propor montagens no ritmo'),
              subtitle: const Text(
                  'junta os momentos avulsos num vídeo cortado na batida'),
            ),

            if (_error != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.error.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(_error!,
                    style: TextStyle(color: theme.colorScheme.error)),
              ),
            ],

            const SizedBox(height: 24),
            if (_sending) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(value: _sent, minHeight: 8),
              ),
              const SizedBox(height: 8),
              Center(
                child: Text(
                  'enviando… ${(_sent * 100).toStringAsFixed(0)}%',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ] else
              FilledButton.icon(
                onPressed: _video == null ? null : _submit,
                icon: const Icon(Icons.auto_awesome),
                label: const Text('Analisar a partida'),
              ),
          ],
        ),
      ),
    );
  }

  static String _mb(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.enabled = true,
  });

  final String label;
  final int value;
  final int min;
  final int max;
  final bool enabled;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Expanded(child: Text(label)),
            IconButton(
              onPressed:
                  enabled && value > min ? () => onChanged(value - 1) : null,
              icon: const Icon(Icons.remove_circle_outline),
            ),
            SizedBox(
              width: 24,
              child: Text('$value',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            IconButton(
              onPressed:
                  enabled && value < max ? () => onChanged(value + 1) : null,
              icon: const Icon(Icons.add_circle_outline),
            ),
          ],
        ),
      );
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.suffix = '',
    this.enabled = true,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String suffix;
  final bool enabled;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(label)),
                Text('${value.toStringAsFixed(0)}$suffix',
                    style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            Slider(
              value: value,
              min: min,
              max: max,
              divisions: (max - min).round(),
              onChanged: enabled ? onChanged : null,
            ),
          ],
        ),
      );
}
