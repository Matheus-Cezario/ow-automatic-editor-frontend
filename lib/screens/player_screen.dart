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
    if (url == null) return; // the montage failed: only the cuts exist
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
              tooltip: 'Copy video link',
              icon: const Icon(Icons.link),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: widget.clip.videoUrl!));
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('Link copied')));
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
                    ? _NoVideo(clip: widget.clip)
                    : _error != null
                    ? Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'Could not open the video.\n$_error',
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
                      'span ${formatClock(widget.clip.startS)}'
                          '–${formatClock(widget.clip.endS)} of the match',
                      formatDuration(widget.clip.durationS),
                      if (widget.clip.segments > 1)
                        '${widget.clip.segments} cuts',
                      if (widget.clip.isBeatSynced)
                        'cut to the beat'
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
                          tooltip: 'From the start',
                        ),
                        const Spacer(),
                        DownloadButton(
                          url: widget.clip.videoUrl!,
                          label: 'Download the video',
                          compact: true,
                        ),
                      ],
                    ),
                  ],
                  if (widget.clip.segmentsZipUrl != null) ...[
                    const SizedBox(height: 14),
                    DownloadButton(
                      url: widget.clip.segmentsZipUrl!,
                      icon: Icons.folder_zip_outlined,
                      label: 'Download this montage\'s cuts (.zip)',
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Each cut comes in its own file, named after the instant it '
                      'came from in the recording — to re-edit your own way.',
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

/// Shown when the montage failed but the cuts survived.
class _NoVideo extends StatelessWidget {
  const _NoVideo({required this.clip});

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
            'The final video was not generated',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'Joining the pieces failed, but the ${clip.segments} cuts were '
            'made and are available below.',
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
