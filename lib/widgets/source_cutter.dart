import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../api.dart' hide Clip;
import '../montage.dart';
import 'highlight_style.dart';

/// Opens the whole recording in a large window to cut a stretch by hand.
Future<void> openSourceCutter(
  BuildContext context, {
  required String? videoUrl,
  required double durationS,
  required ValueChanged<SourceSpan> onAdd,
  double fps = 30,
  List<DetectionEvent> events = const [],
}) {
  final size = MediaQuery.sizeOf(context);
  return showDialog<void>(
    context: context,
    builder: (_) => Dialog(
      insetPadding: const EdgeInsets.all(20),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: math.min(size.width - 40, 1500),
        height: size.height - 40,
        child: SourceCutter(
          videoUrl: videoUrl,
          durationS: durationS,
          fps: fps,
          events: events,
          onAdd: onAdd,
        ),
      ),
    ),
  );
}

/// The cutting window: the recording large, a whole-match overview to
/// navigate, and a zoomed strip where the cut's start and end are two lines
/// dragged into place — the picture follows the line being dragged, so the
/// exact frame is chosen by eye. The cut can be named.
///
/// It stays open after adding: cutting several stretches in a row is the
/// common case.
class SourceCutter extends StatefulWidget {
  const SourceCutter({
    super.key,
    required this.videoUrl,
    required this.durationS,
    required this.onAdd,
    this.fps = 30,
    this.events = const [],
  });

  final String? videoUrl;
  final double durationS;
  final double fps;
  final List<DetectionEvent> events;
  final ValueChanged<SourceSpan> onAdd;

  @override
  State<SourceCutter> createState() => _SourceCutterState();
}

/// The shortest stretch the two lines can make.
const _minCut = 0.2;

class _SourceCutterState extends State<SourceCutter> {
  VideoPlayerController? _c;
  final _focus = FocusNode(debugLabel: 'source-cutter');
  final _nameFocus = FocusNode(debugLabel: 'cut-name');
  final _name = TextEditingController();

  double _pos = 0;
  late double _in = 0;
  late double _out = math.min(3, widget.durationS);
  double? _play;

  /// The detail strip's window onto the recording.
  double _winStart = 0;
  late double _winLen = math.min(30, math.max(widget.durationS, 1));

  bool _playing = false;
  Timer? _clock;
  String? _added;

  double get _duration => math.max(widget.durationS, 0.001);
  double get _frame => 1 / (widget.fps > 0 ? widget.fps : 30);

  @override
  void initState() {
    super.initState();
    _open();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  Future<void> _open() async {
    final url = widget.videoUrl;
    if (url == null) return;
    final c = VideoPlayerController.networkUrl(Uri.parse(url));
    try {
      await c.initialize();
      await c.setVolume(0);
    } catch (_) {
      await c.dispose();
      return; // the lines still work, without the picture
    }
    if (!mounted) {
      await c.dispose();
      return;
    }
    setState(() => _c = c);
  }

  @override
  void dispose() {
    _clock?.cancel();
    _c?.dispose();
    _focus.dispose();
    _nameFocus.dispose();
    _name.dispose();
    super.dispose();
  }

  // ── time ──

  void _seek(double s, {bool keepWindow = false}) {
    final to = s.clamp(0.0, _duration).toDouble();
    setState(() {
      _pos = to;
      if (!keepWindow) _reveal(to);
    });
    _c?.seekTo(Duration(milliseconds: (to * 1000).round()));
  }

  /// Slides the detail window so [t] is in view.
  void _reveal(double t) {
    if (t >= _winStart && t <= _winStart + _winLen) return;
    _winStart = (t - _winLen * 0.3).clamp(0.0, math.max(0.0, _duration - _winLen));
  }

  void _setWindow(double len) => setState(() {
    final centre = _winStart + _winLen / 2;
    _winLen = len.clamp(math.min(5.0, _duration), _duration).toDouble();
    _winStart = (centre - _winLen / 2).clamp(0.0, math.max(0.0, _duration - _winLen));
  });

  void _togglePlay() {
    if (_playing) {
      _clock?.cancel();
      _c?.pause();
      setState(() => _playing = false);
      return;
    }
    _c?.play();
    setState(() => _playing = true);
    _clock = Timer.periodic(const Duration(milliseconds: 50), (_) {
      final c = _c;
      final now = c != null && c.value.isInitialized
          ? c.value.position.inMilliseconds / 1000
          : _pos + 0.05;
      if (now >= _duration) {
        _togglePlay();
        return;
      }
      if (!mounted) return;
      setState(() {
        _pos = now;
        _reveal(now);
      });
    });
  }

  void _pause() {
    if (_playing) _togglePlay();
  }

  // ── the two lines ──

  void _setIn(double t) {
    _pause();
    final v = t.clamp(0.0, _out - _minCut).toDouble();
    setState(() {
      _in = v;
      if (_play != null && _play! < v) _play = null;
    });
    _seek(v, keepWindow: true);
  }

  void _setOut(double t) {
    _pause();
    final v = t.clamp(_in + _minCut, _duration).toDouble();
    setState(() {
      _out = v;
      if (_play != null && _play! > v) _play = null;
    });
    _seek(v, keepWindow: true);
  }

  /// I past the OUT line carries the cut along, keeping its length.
  void _markIn(double t) {
    if (t > _out - _minCut) {
      final len = _out - _in;
      setState(() => _out = math.min(_duration, t + len));
    }
    _setIn(t);
  }

  /// O before the IN line does the same, backwards.
  void _markOut(double t) {
    if (t < _in + _minCut) {
      final len = _out - _in;
      setState(() => _in = math.max(0, t - len));
    }
    _setOut(t);
  }

  SourceSpan get _span =>
      SourceSpan(inS: _in, outS: _out, playS: _play, name: _name.text);

  void _add() {
    final span = _span;
    if (!span.isValid) return;
    widget.onAdd(span);
    setState(() {
      _added = span.name.trim().isEmpty
          ? 'Added ${span.lengthS.toStringAsFixed(1)} s to the timeline.'
          : 'Added "${span.name.trim()}" to the timeline.';
      _name.clear();
    });
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    // typing the name is typing, not shortcuts
    if (_nameFocus.hasFocus) return KeyEventResult.ignored;
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final k = e.logicalKey;
    void Function()? act;
    if (k == LogicalKeyboardKey.space) act = _togglePlay;
    if (k == LogicalKeyboardKey.arrowLeft) act = () => _seek(_pos - 1);
    if (k == LogicalKeyboardKey.arrowRight) act = () => _seek(_pos + 1);
    if (k == LogicalKeyboardKey.comma) act = () => _seek(_pos - _frame);
    if (k == LogicalKeyboardKey.period) act = () => _seek(_pos + _frame);
    if (k == LogicalKeyboardKey.keyI) act = () => _markIn(_pos);
    if (k == LogicalKeyboardKey.keyO) act = () => _markOut(_pos);
    if (k == LogicalKeyboardKey.keyP) act = () => setState(() => _play = _pos);
    if (act == null) return KeyEventResult.ignored;
    act();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = _c;
    final span = _span;

    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      child: Padding(
        key: const Key('source-cutter'),
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text('Cut from the recording', style: theme.textTheme.titleMedium),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'drag IN and OUT · I / O / P · Space · ← → · , .',
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  key: const Key('close-source-cutter'),
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            Expanded(
              child: Center(
                child: AspectRatio(
                  aspectRatio: c != null && c.value.isInitialized
                      ? c.value.aspectRatio
                      : 16 / 9,
                  child: ColoredBox(
                    color: Colors.black,
                    child: c != null && c.value.isInitialized
                        ? VideoPlayer(c)
                        : const Center(
                            child: Icon(Icons.movie_outlined, color: Colors.white24),
                          ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                IconButton(
                  tooltip: 'Back a frame (,)',
                  onPressed: () => _seek(_pos - _frame),
                  icon: const Icon(Icons.chevron_left),
                ),
                IconButton.filledTonal(
                  key: const Key('cutter-play'),
                  tooltip: _playing ? 'Pause (Space)' : 'Play (Space)',
                  onPressed: _togglePlay,
                  icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
                ),
                IconButton(
                  tooltip: 'Forward a frame (.)',
                  onPressed: () => _seek(_pos + _frame),
                  icon: const Icon(Icons.chevron_right),
                ),
                const SizedBox(width: 8),
                Text(
                  '${_clockOf(_pos)} / ${_clockOf(widget.durationS)}',
                  key: const Key('cutter-clock'),
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const Spacer(),
                const Icon(Icons.zoom_out, size: 18),
                SizedBox(
                  width: 160,
                  child: Slider(
                    key: const Key('cutter-zoom'),
                    // the detail window, on a log scale: 5 s to the whole match
                    value: _zoomValue,
                    onChanged: (v) => _setWindow(_lenFor(v)),
                  ),
                ),
                const Icon(Icons.zoom_in, size: 18),
              ],
            ),
            _Overview(
              duration: _duration,
              events: widget.events,
              winStart: _winStart,
              winLen: _winLen,
              inS: _in,
              outS: _out,
              pos: _pos,
              onJump: (t) {
                setState(() {
                  _winStart = (t - _winLen / 2)
                      .clamp(0.0, math.max(0.0, _duration - _winLen))
                      .toDouble();
                });
                _seek(t, keepWindow: true);
              },
            ),
            const SizedBox(height: 6),
            _Strip(
              winStart: _winStart,
              winLen: _winLen,
              events: widget.events,
              inS: _in,
              outS: _out,
              playS: _play,
              pos: _pos,
              onSeek: (t) {
                _pause();
                _seek(t, keepWindow: true);
              },
              onIn: _setIn,
              onOut: _setOut,
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 280,
                  child: TextField(
                    key: const Key('cut-name'),
                    controller: _name,
                    focusNode: _nameFocus,
                    maxLength: 80,
                    decoration: const InputDecoration(
                      isDense: true,
                      counterText: '',
                      labelText: 'Name (optional)',
                      hintText: 'e.g. the flank on B',
                    ),
                    onSubmitted: (_) => _add(),
                    onTapOutside: (_) => _nameFocus.unfocus(),
                  ),
                ),
                ActionChip(
                  key: const Key('cutter-mark-play'),
                  avatar: const Icon(Icons.adjust, size: 16),
                  tooltip:
                      'The play: what ducking and the slow-motion ramp work around',
                  label: Text(
                    _play == null ? 'Mark the play (P)' : 'Play ${_clockOf(_play!)}',
                  ),
                  onPressed: () => setState(() {
                    _play = _pos.clamp(_in, _out).toDouble();
                  }),
                ),
                Text(
                  '${_clockOf(_in)} → ${_clockOf(_out)} · '
                  '${span.lengthS.toStringAsFixed(1)} s',
                  key: const Key('cutter-span'),
                  style: theme.textTheme.bodyMedium,
                ),
                FilledButton.icon(
                  key: const Key('cutter-add'),
                  onPressed: span.isValid ? _add : null,
                  icon: const Icon(Icons.add),
                  label: const Text('Add at the playhead'),
                ),
                if (_added != null)
                  Text(
                    _added!,
                    key: const Key('cutter-added'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  double get _zoomValue {
    final lo = math.log(math.min(5.0, _duration));
    final hi = math.log(_duration);
    if (hi - lo < 1e-9) return 0;
    // right is closer: 1 = the shortest window
    return (1 - (math.log(_winLen) - lo) / (hi - lo)).clamp(0.0, 1.0);
  }

  double _lenFor(double v) {
    final lo = math.log(math.min(5.0, _duration));
    final hi = math.log(_duration);
    return math.exp(hi - v * (hi - lo));
  }
}

/// mm:ss.d — a tenth of a second is what choosing a cut needs.
String _clockOf(double s) {
  final m = s ~/ 60;
  final rest = s - m * 60;
  return '${m.toString().padLeft(2, '0')}:${rest.toStringAsFixed(1).padLeft(4, '0')}';
}

/// The whole match: moments as ticks, the detail window and the cut.
class _Overview extends StatelessWidget {
  const _Overview({
    required this.duration,
    required this.events,
    required this.winStart,
    required this.winLen,
    required this.inS,
    required this.outS,
    required this.pos,
    required this.onJump,
  });

  final double duration;
  final List<DetectionEvent> events;
  final double winStart;
  final double winLen;
  final double inS;
  final double outS;
  final double pos;
  final ValueChanged<double> onJump;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        double at(double dx) => (dx / box.maxWidth * duration).clamp(0.0, duration);
        return GestureDetector(
          key: const Key('cutter-overview'),
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => onJump(at(d.localPosition.dx)),
          onHorizontalDragUpdate: (d) => onJump(at(d.localPosition.dx)),
          child: CustomPaint(
            size: Size(box.maxWidth, 26),
            painter: _OverviewPainter(
              duration: duration,
              events: events,
              winStart: winStart,
              winLen: winLen,
              inS: inS,
              outS: outS,
              pos: pos,
              line: theme.colorScheme.onSurface.withValues(alpha: 0.25),
              window: theme.colorScheme.primary,
              range: theme.colorScheme.tertiary,
              head: theme.colorScheme.error,
            ),
          ),
        );
      },
    );
  }
}

class _OverviewPainter extends CustomPainter {
  _OverviewPainter({
    required this.duration,
    required this.events,
    required this.winStart,
    required this.winLen,
    required this.inS,
    required this.outS,
    required this.pos,
    required this.line,
    required this.window,
    required this.range,
    required this.head,
  });

  final double duration, winStart, winLen, inS, outS, pos;
  final List<DetectionEvent> events;
  final Color line, window, range, head;

  @override
  void paint(Canvas canvas, Size size) {
    double x(double t) => t / duration * size.width;
    final mid = size.height / 2;
    canvas.drawLine(Offset(0, mid), Offset(size.width, mid), Paint()..color = line..strokeWidth = 2);
    for (final e in events) {
      canvas.drawRect(
        Rect.fromLTWH(x(e.t) - 1, 3, 2, size.height - 6),
        Paint()..color = EventStyle.of(e.kind).color,
      );
    }
    canvas.drawRect(
      Rect.fromLTRB(x(inS), mid - 4, math.max(x(outS), x(inS) + 2), mid + 4),
      Paint()..color = range,
    );
    canvas.drawRect(
      Rect.fromLTWH(x(winStart), 0, math.max(4, x(winStart + winLen) - x(winStart)), size.height),
      Paint()
        ..color = window
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    canvas.drawLine(Offset(x(pos), 0), Offset(x(pos), size.height), Paint()..color = head..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(_OverviewPainter o) =>
      o.winStart != winStart || o.winLen != winLen || o.inS != inS ||
      o.outS != outS || o.pos != pos || o.events != events;
}

/// The zoomed strip: second marks, the moments, the cut between the IN and
/// OUT lines, and the playhead. Dragging a line moves that end; dragging
/// anywhere else scrubs.
class _Strip extends StatelessWidget {
  const _Strip({
    required this.winStart,
    required this.winLen,
    required this.events,
    required this.inS,
    required this.outS,
    required this.playS,
    required this.pos,
    required this.onSeek,
    required this.onIn,
    required this.onOut,
  });

  final double winStart, winLen, inS, outS, pos;
  final double? playS;
  final List<DetectionEvent> events;
  final ValueChanged<double> onSeek;
  final ValueChanged<double> onIn;
  final ValueChanged<double> onOut;

  static const height = 86.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth;
        double x(double t) => (t - winStart) / winLen * w;
        double at(double dx) => winStart + dx / w * winLen;

        Widget handle(String label, double t, ValueChanged<double> onMove, Key key) {
          final left = x(t);
          if (left < -12 || left > w + 12) return const SizedBox.shrink();
          return Positioned(
            left: left - 12,
            top: 0,
            bottom: 0,
            width: 24,
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeLeftRight,
              child: _HandleDrag(
                key: key,
                t: t,
                secondsPerPixel: winLen / w,
                onMove: onMove,
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.tertiary,
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Text(
                        label,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onTertiary,
                          fontSize: 9,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Container(width: 3, color: theme.colorScheme.tertiary),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        return SizedBox(
          height: height,
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              Positioned.fill(
                child: GestureDetector(
                  key: const Key('cutter-strip'),
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) => onSeek(at(d.localPosition.dx)),
                  onHorizontalDragUpdate: (d) => onSeek(at(d.localPosition.dx)),
                  child: CustomPaint(
                    painter: _StripPainter(
                      winStart: winStart,
                      winLen: winLen,
                      events: events,
                      inS: inS,
                      outS: outS,
                      playS: playS,
                      background: theme.colorScheme.surfaceContainerHighest,
                      tick: theme.colorScheme.onSurface.withValues(alpha: 0.35),
                      text: theme.hintColor,
                      range: theme.colorScheme.tertiary.withValues(alpha: 0.25),
                      mark: theme.colorScheme.tertiary,
                    ),
                  ),
                ),
              ),
              Positioned(
                left: x(pos) - 1,
                top: 14,
                bottom: 0,
                width: 2,
                child: IgnorePointer(
                  child: ColoredBox(color: theme.colorScheme.error),
                ),
              ),
              handle('IN', inS, onIn, const Key('cutter-in')),
              handle('OUT', outS, onOut, const Key('cutter-out')),
            ],
          ),
        );
      },
    );
  }
}

/// A line's drag, from where it was grabbed: the gesture adds up the
/// finger's travel, so a slow drag moves it as far as a fast one.
class _HandleDrag extends StatefulWidget {
  const _HandleDrag({
    super.key,
    required this.t,
    required this.secondsPerPixel,
    required this.onMove,
    required this.child,
  });

  final double t;
  final double secondsPerPixel;
  final ValueChanged<double> onMove;
  final Widget child;

  @override
  State<_HandleDrag> createState() => _HandleDragState();
}

class _HandleDragState extends State<_HandleDrag> {
  double _from = 0;
  double _moved = 0;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    dragStartBehavior: DragStartBehavior.down,
    onHorizontalDragStart: (_) {
      _from = widget.t;
      _moved = 0;
    },
    onHorizontalDragUpdate: (d) {
      _moved += d.delta.dx;
      widget.onMove(_from + _moved * widget.secondsPerPixel);
    },
    child: widget.child,
  );
}

class _StripPainter extends CustomPainter {
  _StripPainter({
    required this.winStart,
    required this.winLen,
    required this.events,
    required this.inS,
    required this.outS,
    required this.playS,
    required this.background,
    required this.tick,
    required this.text,
    required this.range,
    required this.mark,
  });

  final double winStart, winLen, inS, outS;
  final double? playS;
  final List<DetectionEvent> events;
  final Color background, tick, text, range, mark;

  @override
  void paint(Canvas canvas, Size size) {
    double x(double t) => (t - winStart) / winLen * size.width;
    canvas.drawRect(Offset.zero & size, Paint()..color = background);
    canvas.drawRect(
      Rect.fromLTRB(x(inS), 14, x(outS), size.height),
      Paint()..color = range,
    );

    // second marks, thinned out to keep ~80 px between labels
    final pxPerS = size.width / winLen;
    final steps = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600];
    final step = steps.firstWhere((s) => s * pxPerS >= 80, orElse: () => 600).toDouble();
    final first = (winStart / step).ceil() * step;
    for (var t = first; t <= winStart + winLen; t += step) {
      final px = x(t);
      canvas.drawLine(Offset(px, 14), Offset(px, 24), Paint()..color = tick);
      final m = t ~/ 60;
      final label = '${m.toString().padLeft(2, '0')}:${(t - m * 60).toStringAsFixed(step < 1 ? 1 : 0).padLeft(2, '0')}';
      final tp = TextPainter(
        text: TextSpan(text: label, style: TextStyle(color: text, fontSize: 10)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(px + 2, 0));
    }
    for (final e in events) {
      if (e.t < winStart || e.t > winStart + winLen) continue;
      canvas.drawRect(
        Rect.fromLTWH(x(e.t) - 1.5, size.height - 18, 3, 14),
        Paint()..color = EventStyle.of(e.kind).color,
      );
    }
    if (playS != null) {
      canvas.drawCircle(Offset(x(playS!), size.height / 2 + 7), 5, Paint()..color = mark);
    }
  }

  @override
  bool shouldRepaint(_StripPainter o) =>
      o.winStart != winStart || o.winLen != winLen || o.inS != inS ||
      o.outS != outS || o.playS != playS || o.events != events;
}
