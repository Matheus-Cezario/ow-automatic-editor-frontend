import 'package:flutter/material.dart';

import 'frame.dart';

/// Stand-in for the web monitor: one box per piece, keyed by clip, with the
/// piece's opacity and a dip's veil — what a widget test can look at.
class MonitorPicture extends StatelessWidget {
  const MonitorPicture({
    super.key,
    required this.frame,
    required this.playing,
    this.upcoming,
  });

  final Frame frame;
  final bool playing;

  /// The frame a moment ahead, so its clips can be loaded before the cut.
  final Frame? upcoming;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      for (final p in frame.pieces)
        Opacity(
          key: ValueKey('monitor-piece-${p.clipId}'),
          opacity: p.opacity,
          child: Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: Color(0xFF2A2F38)),
              if (p.veil != null)
                ColoredBox(
                  key: const Key('transition-veil'),
                  color: Color(
                    p.veil == '#ffffff' ? 0xFFFFFFFF : 0xFF000000,
                  ).withValues(alpha: p.veilOpacity),
                ),
            ],
          ),
        ),
    ],
  );
}
