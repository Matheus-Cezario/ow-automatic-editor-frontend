import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../main.dart' show PhoneWidth;
import '../widgets/file_tile.dart';

/// First stage: just the recording.
///
/// No music and no settings come in here. The system watches the match and
/// notes what happened — kill, headshot, sleep dart, stun — and it is in the
/// editor, with the moments at hand, that you decide what becomes a video.
class NewJobScreen extends StatefulWidget {
  const NewJobScreen({super.key});

  @override
  State<NewJobScreen> createState() => _NewJobScreenState();
}

class _NewJobScreenState extends State<NewJobScreen> {
  final _api = ApiClient();

  PlatformFile? _video;
  int _videoBytes = 0;
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
    setState(() {
      _sending = true;
      _sent = 0;
      _error = null;
    });
    try {
      await _api.createJob(
        video: _video!,
        onProgress: (p) => setState(() => _sent = p),
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _sending = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('New match')),
      body: PhoneWidth(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            FileTile(
              icon: Icons.videocam,
              title: 'Match recording',
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
                  Icon(
                    Icons.music_note,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Music comes later: the system finds the moments of the '
                      'match and you build the video in the editor, fitting '
                      'each cut to the track you want. Without a track, the '
                      'video keeps the original match audio.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            if (_error != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.error.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
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
                  'uploading… ${(_sent * 100).toStringAsFixed(0)}%',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ] else
              FilledButton.icon(
                onPressed: _video == null ? null : _submit,
                icon: const Icon(Icons.auto_awesome),
                label: const Text('Analyse the match'),
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
