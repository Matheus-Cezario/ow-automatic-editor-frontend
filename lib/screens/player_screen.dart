import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../api.dart';
import '../main.dart' show PhoneWidth;
import '../widgets/download.dart';
import '../widgets/highlight_style.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.clip});

  final Clip clip;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  VideoPlayerController? _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    final url = widget.clip.videoUrl;
    if (url == null) return; // montagem falhou: só há os cortes
    final c = VideoPlayerController.networkUrl(Uri.parse(url));
    try {
      await c.initialize();
      await c.setLooping(true);
      await c.play();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _controller = c);
    } catch (e) {
      await c.dispose();
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = HighlightStyle.of(widget.clip.kind);
    final theme = Theme.of(context);
    final c = _controller;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(style.label),
        actions: [
          if (widget.clip.videoUrl != null)
            IconButton(
              tooltip: 'Copiar link do vídeo',
              icon: const Icon(Icons.link),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: widget.clip.videoUrl!));
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('Link copiado')));
              },
            ),
        ],
      ),
      body: PhoneWidth(
        maxWidth: 900,
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: widget.clip.onlyCuts
                    ? _SemVideo(clip: widget.clip)
                    : _error != null
                    ? Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'Não consegui abrir o vídeo.\n$_error',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                      )
                    : c == null
                    ? const CircularProgressIndicator()
                    : AspectRatio(
                        aspectRatio: c.value.aspectRatio,
                        child: Stack(
                          alignment: Alignment.bottomCenter,
                          children: [
                            VideoPlayer(c),
                            VideoProgressIndicator(c, allowScrubbing: true),
                            GestureDetector(
                              onTap: () => setState(
                                () => c.value.isPlaying ? c.pause() : c.play(),
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
              color: const Color(0xFF101216),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.clip.title, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(
                    [
                      'trecho ${formatClock(widget.clip.startS)}'
                          '–${formatClock(widget.clip.endS)} da partida',
                      formatDuration(widget.clip.durationS),
                      if (widget.clip.segments > 1)
                        '${widget.clip.segments} cortes',
                      if (widget.clip.isBeatSynced)
                        'cortado na batida'
                            '${widget.clip.meta['bpm'] != null ? ' (${(widget.clip.meta['bpm'] as num).toStringAsFixed(0)} BPM)' : ''}',
                    ].join('  ·  '),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.hintColor,
                    ),
                  ),
                  if (c != null) ...[
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        IconButton.filled(
                          onPressed: () => setState(
                            () => c.value.isPlaying ? c.pause() : c.play(),
                          ),
                          icon: Icon(
                            c.value.isPlaying ? Icons.pause : Icons.play_arrow,
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          onPressed: () => c.seekTo(Duration.zero),
                          icon: const Icon(Icons.replay),
                          tooltip: 'Do começo',
                        ),
                        const Spacer(),
                        BotaoBaixar(
                          url: widget.clip.videoUrl!,
                          label: 'Baixar o vídeo',
                          compact: true,
                        ),
                      ],
                    ),
                  ],
                  if (widget.clip.segmentsZipUrl != null) ...[
                    const SizedBox(height: 14),
                    BotaoBaixar(
                      url: widget.clip.segmentsZipUrl!,
                      icon: Icons.folder_zip_outlined,
                      label: 'Baixar os cortes desta montagem (.zip)',
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Cada corte vem num arquivo, nomeado pelo instante de onde '
                      'saiu na gravação — para reeditar do seu jeito.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.hintColor,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Mostrado quando a montagem falhou mas os cortes sobreviveram.
class _SemVideo extends StatelessWidget {
  const _SemVideo({required this.clip});

  final Clip clip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.folder_zip_outlined, size: 56, color: theme.hintColor),
          const SizedBox(height: 16),
          Text(
            'O vídeo final não foi gerado',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'A junção dos trechos falhou, mas os ${clip.segments} cortes foram '
            'feitos e estão disponíveis abaixo.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
          if (clip.renderError != null) ...[
            const SizedBox(height: 12),
            Text(
              clip.renderError!,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
