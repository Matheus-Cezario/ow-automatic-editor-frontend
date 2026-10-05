import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../api.dart' hide Clip;
import '../montage.dart';

/// The clip's volume as a line over its block — the rubber band every editor
/// has.
///
/// Height is volume: the bottom is silence, the middle 100%, the top 200%.
/// With no points the line is flat and dragging it sets the whole clip's
/// volume; a click on it puts a point there, points drag in time and level,
/// and a double click or a right click takes one away. With points, dragging
/// the line moves the whole curve up or down.
///
/// The points are the clip's volume keyframes — the same ones the Motion
/// panel edits — so the render and the panel agree with what is drawn here.
class VolumeCurve extends StatefulWidget {
  const VolumeCurve({
    super.key,
    required this.clip,
    required this.colour,
    required this.onLevel,
    required this.onKeys,
    this.editable = true,
    this.onLabel,
    this.onStart,
    this.onEnd,
  });

  final TimelineClip clip;
  final Color colour;

  /// The whole clip's volume, when the line has no points.
  final ValueChanged<double> onLevel;

  /// The volume points, all of them, in time order.
  final ValueChanged<List<ClipKey>> onKeys;

  /// Drawn only, when the block is not selected.
  final bool editable;

  /// What the drag is doing, for the ruler's caption — `null` when it ends.
  final ValueChanged<String?>? onLabel;

  /// A drag is one undo step.
  final VoidCallback? onStart;
  final VoidCallback? onEnd;

  /// Volume runs 0 to this, bottom to top.
  static const top = 2.0;

  /// How close to 100% a drag snaps onto it.
  static const _snap = 0.04;

  static double _snapped(double v) {
    final c = v.clamp(0.0, top).toDouble();
    return (c - 1).abs() <= _snap ? 1 : c;
  }

  static String percent(double v) => 'Volume ${(v * 100).round()}%';

  @override
  State<VolumeCurve> createState() => _VolumeCurveState();
}

class _VolumeCurveState extends State<VolumeCurve> {
  /// Where a drag started: the level or the points as they were.
  double _fromLevel = 1;
  List<ClipKey> _fromKeys = const [];
  double _dy = 0;
  double _dx = 0;

  List<ClipKey> get _keys => widget.clip.keysFor(KeyProp.volume);

  double _valueAt(double t) =>
      valueAt(widget.clip, KeyProp.volume, t * widget.clip.durationS);

  double _y(double v, double h) => (1 - v / VolumeCurve.top) * h;

  void _addPoint(double t) {
    final v = _valueAt(t);
    final keys = [..._keys, ClipKey(prop: KeyProp.volume, t: t, value: v)]
      ..sort((a, b) => a.t.compareTo(b.t));
    // the first point keeps the level the rest of the line had
    widget.onKeys(keys);
  }

  void _removePoint(int i) => widget.onKeys([..._keys]..removeAt(i));

  void _lineStart() {
    _fromLevel = widget.clip.audio.volume;
    _fromKeys = _keys;
    _dy = 0;
    widget.onStart?.call();
  }

  void _lineMove(double dy, double h) {
    _dy += dy;
    final change = -_dy / h * VolumeCurve.top;
    if (_fromKeys.isEmpty) {
      final v = VolumeCurve._snapped(_fromLevel + change);
      widget.onLevel(v);
      widget.onLabel?.call(VolumeCurve.percent(v));
    } else {
      widget.onKeys([
        for (final k in _fromKeys)
          k.copyWith(value: (k.value + change).clamp(0.0, VolumeCurve.top)),
      ]);
      widget.onLabel?.call(
        'Volume ${change >= 0 ? '+' : ''}${(change * 100).round()}%',
      );
    }
  }

  void _end() {
    widget.onLabel?.call(null);
    widget.onEnd?.call();
  }

  void _pointStart(int i) {
    _fromKeys = _keys;
    _dx = 0;
    _dy = 0;
    widget.onStart?.call();
  }

  void _pointMove(int i, Offset delta, Size size) {
    _dx += delta.dx;
    _dy += delta.dy;
    final from = _fromKeys[i];
    // a point stays between its neighbours: the order is the curve
    final lo = i == 0 ? 0.0 : _fromKeys[i - 1].t + 0.001;
    final hi = i == _fromKeys.length - 1 ? 1.0 : _fromKeys[i + 1].t - 0.001;
    final t = (from.t + _dx / size.width).clamp(lo, hi).toDouble();
    final v = VolumeCurve._snapped(
      from.value - _dy / size.height * VolumeCurve.top,
    );
    final keys = [..._fromKeys];
    keys[i] = ClipKey(prop: KeyProp.volume, t: t, value: v, ease: from.ease);
    widget.onKeys(keys);
    widget.onLabel?.call(VolumeCurve.percent(v));
  }

  @override
  Widget build(BuildContext context) {
    final keys = _keys;
    return LayoutBuilder(
      builder: (context, box) {
        final size = box.biggest;
        final samples = [
          for (var i = 0; i <= 48; i++)
            Offset(size.width * i / 48, _y(_valueAt(i / 48), size.height)),
        ];
        final line = CustomPaint(
          key: ValueKey('volume-line-${widget.clip.id}'),
          painter: _CurvePainter(
            samples,
            widget.colour,
            hits: widget.editable,
          ),
        );
        if (!widget.editable) return IgnorePointer(child: line);
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeUpDown,
                child: GestureDetector(
                  behavior: HitTestBehavior.deferToChild,
                  // from the press, so the line follows the pointer exactly
                  dragStartBehavior: DragStartBehavior.down,
                  onTapUp: (d) => _addPoint(
                    (d.localPosition.dx / size.width).clamp(0.0, 1.0),
                  ),
                  onVerticalDragStart: (_) => _lineStart(),
                  onVerticalDragUpdate: (d) =>
                      _lineMove(d.delta.dy, size.height),
                  onVerticalDragEnd: (_) => _end(),
                  child: line,
                ),
              ),
            ),
            for (final (i, k) in keys.indexed)
              Positioned(
                left: k.t * size.width - 6,
                top: _y(k.value, size.height) - 6,
                width: 12,
                height: 12,
                child: Tooltip(
                  message:
                      '${VolumeCurve.percent(k.value)} — drag; double click '
                      'or right click to remove',
                  waitDuration: const Duration(milliseconds: 700),
                  child: GestureDetector(
                    key: ValueKey('volume-point-${widget.clip.id}-$i'),
                    behavior: HitTestBehavior.opaque,
                    dragStartBehavior: DragStartBehavior.down,
                    onPanStart: (_) => _pointStart(i),
                    onPanUpdate: (d) => _pointMove(i, d.delta, size),
                    onPanEnd: (_) => _end(),
                    onDoubleTap: () => _removePoint(i),
                    onSecondaryTapUp: (_) => _removePoint(i),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: widget.colour,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 1.5),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _CurvePainter extends CustomPainter {
  _CurvePainter(this.samples, this.colour, {required this.hits});

  final List<Offset> samples;
  final Color colour;

  /// Takes a pointer near the line — and only there, so the rest of the
  /// block still moves the clip.
  final bool hits;

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.isEmpty) return;
    final path = Path()..moveTo(samples.first.dx, samples.first.dy);
    for (final p in samples.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = colour
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool? hitTest(Offset position) {
    if (!hits) return false;
    for (var i = 1; i < samples.length; i++) {
      final a = samples[i - 1], b = samples[i];
      if (position.dx < a.dx - 1 || position.dx > b.dx + 1) continue;
      final f = b.dx == a.dx ? 0.0 : (position.dx - a.dx) / (b.dx - a.dx);
      final y = a.dy + (b.dy - a.dy) * f.clamp(0.0, 1.0);
      if ((position.dy - y).abs() <= 6) return true;
    }
    return false;
  }

  @override
  bool shouldRepaint(_CurvePainter old) =>
      old.colour != colour || old.hits != hits || old.samples != samples;
}
