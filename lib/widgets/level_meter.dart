import 'package:flutter/material.dart';

import '../levels.dart';

/// A thin bar of how close the mix comes to full scale at the playhead:
/// green, amber near the top, red past it — the sources adding up beyond
/// what the file can hold.
class LevelMeter extends StatelessWidget {
  const LevelMeter({super.key, required this.level, this.width = 72});

  /// 1.0 is full scale.
  final double level;
  final double width;

  /// The bar's right end, past full scale, so going over shows.
  static const _span = 1.25;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colour = level >= 1
        ? theme.colorScheme.error
        : level >= 0.7
        ? Colors.amber
        : Colors.green;
    return Tooltip(
      message: level >= 1
          ? 'Mix level ${dbfs(level)} — over full scale: lower a volume, or '
                'let the export loudness bring it down'
          : 'Mix level ${dbfs(level)}',
      child: SizedBox(
        key: const Key('level-meter'),
        width: width,
        height: 6,
        child: CustomPaint(
          painter: _MeterPainter(
            fill: (level / _span).clamp(0.0, 1.0),
            colour: colour,
            track: theme.colorScheme.onSurface.withValues(alpha: 0.12),
            mark: theme.colorScheme.onSurface.withValues(alpha: 0.5),
          ),
        ),
      ),
    );
  }
}

class _MeterPainter extends CustomPainter {
  _MeterPainter({
    required this.fill,
    required this.colour,
    required this.track,
    required this.mark,
  });

  final double fill;
  final Color colour, track, mark;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Radius.circular(size.height / 2);
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, r),
        Paint()..color = track);
    if (fill > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0, 0, size.width * fill, size.height),
          r,
        ),
        Paint()..color = colour,
      );
    }
    // where full scale is
    final x = size.width / LevelMeter._span;
    canvas.drawLine(Offset(x, 0), Offset(x, size.height),
        Paint()..color = mark..strokeWidth = 1);
  }

  @override
  bool shouldRepaint(_MeterPainter old) =>
      old.fill != fill || old.colour != colour;
}
