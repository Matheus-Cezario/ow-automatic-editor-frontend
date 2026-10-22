import 'package:flutter/material.dart';

import '../api.dart';
import 'crop_panel.dart';

/// The crop drawn on the monitor: a white frame over the picture, with
/// handles on its corners and sides, and the part that will be cut dimmed.
///
/// The fractions are the ones of [ClipTransform] — the crop works on the
/// canvas-sized picture, so the frame here is the crop one to one. Dragging
/// inside moves the whole window, keeping its size.
class CropOverlay extends StatelessWidget {
  const CropOverlay({
    super.key,
    required this.transform,
    required this.onChanged,
    this.onGestureStart,
    this.onGestureEnd,
  });

  final ClipTransform transform;
  final ValueChanged<ClipTransform> onChanged;
  final VoidCallback? onGestureStart;
  final VoidCallback? onGestureEnd;

  static const _handle = 14.0;

  /// A window never shrinks below this fraction of the frame, on either axis.
  static const minWindow = 1 - 2 * CropPanel.maxCrop;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth;
        final h = box.maxHeight;
        final t = transform;
        final rect = Rect.fromLTRB(
          t.cropLeft * w,
          t.cropTop * h,
          (1 - t.cropRight) * w,
          (1 - t.cropBottom) * h,
        );

        // Moving an edge by a pixel delta, clamped so that the window stays
        // inside the limits the panel's sliders already enforce.
        ClipTransform edges(
          ClipTransform base, {
          double l = 0,
          double tp = 0,
          double r = 0,
          double b = 0,
        }) {
          double c(double v) => v.clamp(0.0, CropPanel.maxCrop);
          var left = c(base.cropLeft + l);
          var top = c(base.cropTop + tp);
          var right = c(base.cropRight + r);
          var bottom = c(base.cropBottom + b);
          if (1 - left - right < minWindow) {
            // the edge being dragged stops where the window gets too small
            if (l != 0) left = 1 - right - minWindow;
            if (r != 0) right = 1 - left - minWindow;
          }
          if (1 - top - bottom < minWindow) {
            if (tp != 0) top = 1 - bottom - minWindow;
            if (b != 0) bottom = 1 - top - minWindow;
          }
          return base.copyWith(
            cropLeft: left,
            cropTop: top,
            cropRight: right,
            cropBottom: bottom,
          );
        }

        // The edges move with the pointer from where the drag began, so the
        // handle follows the finger and does not drift with the clamping.
        Widget drag({
          required Key key,
          required Rect area,
          required MouseCursor cursor,
          required ClipTransform Function(ClipTransform start, Offset d) apply,
        }) {
          return Positioned.fromRect(
            rect: area,
            child: _Drag(
              key: key,
              cursor: cursor,
              start: () => transform,
              onUpdate: (start, d) => onChanged(apply(start, d)),
              onStart: onGestureStart,
              onEnd: onGestureEnd,
              child: const SizedBox.expand(),
            ),
          );
        }

        // A handle on the frame's edge would be half outside it, where the
        // taps never arrive: its grab area is pulled in to stay inside.
        Rect around(Offset c) => Rect.fromCenter(
          center: Offset(
            c.dx.clamp(_handle, w - _handle),
            c.dy.clamp(_handle, h - _handle),
          ),
          width: _handle * 2,
          height: _handle * 2,
        );

        final corners = {
          'tl': (rect.topLeft, SystemMouseCursors.resizeUpLeftDownRight),
          'tr': (rect.topRight, SystemMouseCursors.resizeUpRightDownLeft),
          'bl': (rect.bottomLeft, SystemMouseCursors.resizeUpRightDownLeft),
          'br': (rect.bottomRight, SystemMouseCursors.resizeUpLeftDownRight),
        };
        final sides = {
          'l': (rect.centerLeft, SystemMouseCursors.resizeLeftRight),
          'r': (rect.centerRight, SystemMouseCursors.resizeLeftRight),
          't': (rect.topCenter, SystemMouseCursors.resizeUpDown),
          'b': (rect.bottomCenter, SystemMouseCursors.resizeUpDown),
        };

        ClipTransform resize(String id, ClipTransform s, Offset d) {
          final dx = d.dx / w;
          final dy = d.dy / h;
          return edges(
            s,
            l: id.contains('l') ? dx : 0,
            r: id.contains('r') ? -dx : 0,
            tp: id.contains('t') ? dy : 0,
            b: id.contains('b') ? -dy : 0,
          );
        }

        return Stack(
          key: const Key('crop-overlay'),
          fit: StackFit.expand,
          children: [
            IgnorePointer(child: CustomPaint(painter: _WindowPainter(rect))),
            // inside: moves the window, keeping its size
            drag(
              key: const Key('crop-move'),
              area: rect,
              cursor: SystemMouseCursors.move,
              apply: (s, d) {
                final dx = (d.dx / w)
                    .clamp(-s.cropLeft, CropPanel.maxCrop - s.cropLeft)
                    .clamp(s.cropRight - CropPanel.maxCrop, s.cropRight);
                final dy = (d.dy / h)
                    .clamp(-s.cropTop, CropPanel.maxCrop - s.cropTop)
                    .clamp(s.cropBottom - CropPanel.maxCrop, s.cropBottom);
                return s.copyWith(
                  cropLeft: s.cropLeft + dx,
                  cropRight: s.cropRight - dx,
                  cropTop: s.cropTop + dy,
                  cropBottom: s.cropBottom - dy,
                );
              },
            ),
            for (final e in sides.entries)
              drag(
                key: Key('crop-handle-${e.key}'),
                area: around(e.value.$1),
                cursor: e.value.$2,
                apply: (s, d) => resize(e.key, s, d),
              ),
            for (final e in corners.entries)
              drag(
                key: Key('crop-handle-${e.key}'),
                area: around(e.value.$1),
                cursor: e.value.$2,
                apply: (s, d) => resize(e.key, s, d),
              ),
          ],
        );
      },
    );
  }
}

/// A pan gesture that reports the distance from where it began, together with
/// the transform it began with.
class _Drag extends StatefulWidget {
  const _Drag({
    super.key,
    required this.cursor,
    required this.start,
    required this.onUpdate,
    required this.child,
    this.onStart,
    this.onEnd,
  });

  final MouseCursor cursor;
  final ClipTransform Function() start;
  final void Function(ClipTransform start, Offset delta) onUpdate;
  final VoidCallback? onStart;
  final VoidCallback? onEnd;
  final Widget child;

  @override
  State<_Drag> createState() => _DragState();
}

class _DragState extends State<_Drag> {
  ClipTransform? _from;
  Offset _total = Offset.zero;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: widget.cursor,
    child: GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) {
        _from = widget.start();
        _total = Offset.zero;
        widget.onStart?.call();
      },
      onPanUpdate: (d) {
        _total += d.delta;
        if (_from != null) widget.onUpdate(_from!, _total);
      },
      onPanEnd: (_) {
        _from = null;
        widget.onEnd?.call();
      },
      onPanCancel: () {
        _from = null;
        widget.onEnd?.call();
      },
      child: widget.child,
    ),
  );
}

/// Dims everything outside the window and draws its white border and the
/// handles.
class _WindowPainter extends CustomPainter {
  _WindowPainter(this.rect);

  final Rect rect;

  @override
  void paint(Canvas canvas, Size size) {
    final outside = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(rect);
    canvas.drawPath(outside, Paint()..color = Colors.black54);

    final line = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawRect(rect, line);

    final fill = Paint()..color = Colors.white;
    final edge = Paint()
      ..color = Colors.black54
      ..style = PaintingStyle.stroke;
    for (final p in [
      rect.topLeft,
      rect.topRight,
      rect.bottomLeft,
      rect.bottomRight,
      rect.centerLeft,
      rect.centerRight,
      rect.topCenter,
      rect.bottomCenter,
    ]) {
      final r = Rect.fromCenter(center: p, width: 10, height: 10);
      canvas.drawRect(r, fill);
      canvas.drawRect(r, edge);
    }
  }

  @override
  bool shouldRepaint(_WindowPainter old) => old.rect != rect;
}
