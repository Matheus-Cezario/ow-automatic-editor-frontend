import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../main.dart' show PhoneWidth;
import '../widgets/file_tile.dart';
import '../widgets/highlight_style.dart';
import '../widgets/music_window.dart';

/// Segunda fase: escolher quais vídeos gerar e dar a trilha de cada um.
///
/// Cada proposta selecionada carrega as suas próprias opções — é por isso que
/// dois vídeos da mesma partida podem sair com músicas diferentes. Quem não
/// recebe música fica com o áudio original da partida.
///
/// Pode ser feito quantas vezes se quiser: as propostas continuam disponíveis
/// depois de geradas, porque usar um momento num vídeo não o consome.
class GenerateScreen extends StatefulWidget {
  const GenerateScreen({super.key, required this.job});

  final Job job;

  @override
  State<GenerateScreen> createState() => _GenerateScreenState();
}

class _GenerateScreenState extends State<GenerateScreen> {
  final _api = ApiClient();

  /// As escolhas, por proposta. Estar no mapa é estar selecionado.
  final Map<String, Selection> _escolhas = {};
  final Map<String, int> _musicBytes = {};

  bool _sending = false;
  double _sent = 0;
  String? _error;

  List<Proposal> get _propostas => widget.job.proposals;

  bool _tudoValido() =>
      _escolhas.values.every((s) => s.options.janelaValida);

  void _alternar(Proposal p, bool marcado) {
    setState(() {
      if (marcado) {
        _escolhas[p.id] = Selection(proposalId: p.id);
      } else {
        _escolhas.remove(p.id);
        _musicBytes.remove(p.id);
      }
    });
  }

  Future<void> _escolherMusica(Proposal p) async {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['mp3', 'wav', 'm4a', 'aac', 'ogg', 'flac'],
    );
    if (picked == null) return;
    final size = await picked.length();
    if (!mounted) return;
    setState(() {
      _escolhas[p.id] = _escolhas[p.id]!.copyWith(music: picked);
      _musicBytes[p.id] = size;
    });
  }

  Future<void> _gerar() async {
    if (_escolhas.isEmpty) return;
    setState(() { _sending = true; _sent = 0; _error = null; });
    try {
      await _api.createRender(
        jobId: widget.job.id,
        selections: _escolhas.values.toList(),
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
    final n = _escolhas.length;

    return Scaffold(
      appBar: AppBar(title: const Text('O que gerar')),
      body: PhoneWidth(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            Text(
              'A análise encontrou ${_propostas.length} vídeo(s) possíveis. '
              'Marque os que quiser e dê uma música para cada um — quem ficar '
              'sem música sai com o áudio original da partida.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.hintColor),
            ),
            const SizedBox(height: 16),
            for (final p in _propostas)
              _ProposalCard(
                key: ValueKey(p.id),
                proposal: p,
                selection: _escolhas[p.id],
                musicBytes: _musicBytes[p.id],
                enabled: !_sending,
                onToggle: (v) => _alternar(p, v),
                onPickMusic: () => _escolherMusica(p),
                onClearMusic: () => setState(() {
                  _escolhas[p.id] =
                      _escolhas[p.id]!.copyWith(clearMusic: true);
                  _musicBytes.remove(p.id);
                }),
                onOptions: (o) => setState(() {
                  _escolhas[p.id] = _escolhas[p.id]!.copyWith(options: o);
                }),
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

            const SizedBox(height: 20),
            if (_sending) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(value: _sent, minHeight: 8),
              ),
              const SizedBox(height: 8),
              Center(
                child: Text('enviando as músicas…',
                    style: theme.textTheme.bodySmall),
              ),
            ] else
              FilledButton.icon(
                onPressed: n == 0 || !_tudoValido() ? null : _gerar,
                icon: const Icon(Icons.movie_creation_outlined),
                label: Text(n == 0
                    ? 'Escolha ao menos um vídeo'
                    : 'Gerar $n vídeo${n > 1 ? 's' : ''}'),
              ),
          ],
        ),
      ),
    );
  }
}

class _ProposalCard extends StatelessWidget {
  const _ProposalCard({
    super.key,
    required this.proposal,
    required this.selection,
    required this.musicBytes,
    required this.enabled,
    required this.onToggle,
    required this.onPickMusic,
    required this.onClearMusic,
    required this.onOptions,
  });

  final Proposal proposal;
  final Selection? selection;
  final int? musicBytes;
  final bool enabled;
  final ValueChanged<bool> onToggle;
  final VoidCallback onPickMusic;
  final VoidCallback onClearMusic;
  final ValueChanged<ClipOptions> onOptions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = HighlightStyle.of(proposal.kind);
    final sel = selection;
    final marcado = sel != null;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CheckboxListTile(
            value: marcado,
            onChanged: enabled ? (v) => onToggle(v ?? false) : null,
            controlAffinity: ListTileControlAffinity.leading,
            title: Row(
              children: [
                Icon(style.icon, size: 14, color: style.color),
                const SizedBox(width: 5),
                Text(style.label,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: style.color)),
              ],
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 2),
                Text(proposal.title, style: theme.textTheme.bodyMedium),
                const SizedBox(height: 3),
                Text(
                  [
                    'trecho ${formatClock(proposal.startS)}'
                        '–${formatClock(proposal.endS)}',
                    if (proposal.acceptsMusic)
                      '${proposal.nMoments} momentos'
                    else
                      formatDuration(proposal.durationS),
                    if (!proposal.acceptsMusic) 'áudio da partida',
                  ].join('  ·  '),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.hintColor),
                ),
              ],
            ),
          ),
          if (marcado && proposal.acceptsMusic)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FileTile(
                    dense: true,
                    icon: Icons.music_note,
                    title: sel.music == null
                        ? 'Música (opcional)'
                        : sel.music!.name,
                    subtitle: sel.music == null
                        ? 'sem música o vídeo fica com o áudio da partida'
                        : _mb(musicBytes ?? 0),
                    chosen: sel.music != null,
                    onTap: enabled ? onPickMusic : null,
                    onClear:
                        sel.music == null || !enabled ? null : onClearMusic,
                  ),
                  const SizedBox(height: 12),
                  _Beats(
                    value: sel.options.montageClipBeats,
                    enabled: enabled,
                    onChanged: (v) => onOptions(
                        sel.options.copyWith(montageClipBeats: v)),
                  ),
                  const SizedBox(height: 4),
                  MusicWindow(
                    dense: true,
                    options: sel.options,
                    enabled: enabled && sel.music != null,
                    onChanged: onOptions,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _mb(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

class _Beats extends StatelessWidget {
  const _Beats({
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final int value;
  final bool enabled;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          const Expanded(child: Text('Batidas por corte')),
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: enabled && value > 1 ? () => onChanged(value - 1) : null,
            icon: const Icon(Icons.remove_circle_outline),
          ),
          SizedBox(
            width: 22,
            child: Text('$value',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: enabled && value < 8 ? () => onChanged(value + 1) : null,
            icon: const Icon(Icons.add_circle_outline),
          ),
        ],
      );
}
