import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../api.dart';
import '../montage.dart';
import 'highlight_style.dart';
import 'music_timeline.dart';

/// The whole recording, to cut by hand what the analysis did not find.
///
/// The moments shelf only offers what the detectors saw. Here the person
/// scrubs the match, marks an in and an out point — and, if they like, the
/// play in between — and takes that stretch to the ruler: with a button, at
/// the playhead, or by dragging it where it should go.
///
/// The detected moments are drawn on the scrub bar as ticks: they are the
/// fastest way to the part of the match being looked for.
///
/// With the panel focused: Space plays, ← → move a second, , . a frame,
/// I / O / P mark in, out and play.
class SourceViewer extends StatefulWidget {
  const SourceViewer({
    super.key,
    required this.videoUrl,
    required this.durationS,
    required this.onAdd,
    this.fps = 30,
    this.events = const [],
    this.enabled = true,
  });

  /// The match's proxy (or the recording, for old matches).
  final String? videoUrl;
  final double durationS;
  final double fps;
  final List<DetectionEvent> events;
  final bool enabled;

  /// "Add to timeline": the stretch goes in at the playhead.
  final ValueChanged<SourceSpan> onAdd;

  @override
  State<SourceViewer> createState() => _SourceViewerState();
}

class _SourceViewerState extends State<SourceViewer> {
  VideoPlayerController? _c;
  final _focus = FocusNode(debugLabel: 'source-viewer');

  /// Where the viewer is, in recording seconds. It is the panel's own state:
  /// the player follows it, and while playing it follows the player.
  double _pos = 0;
  double? _in;
  double? _out;
  double? _play;
  bool _playing = false;
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    final url = widget.videoUrl;
    if (url == null) return;
    final c = VideoPlayerController.networkUrl(Uri.parse(url));
    try {
      await c.initialize();
      await c.setVolume(0); // the montage's sound is the editor's business
    } catch (_) {
      await c.dispose();
      return; // marking still works on the bar, without the picture
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
    super.dispose();
  }

  double get _frame => 1 / (widget.fps > 0 ? widget.fps : 30);

  void _seek(double s) {
    final to = s.clamp(0.0, widget.durationS).toDouble();
    setState(() => _pos = to);
    _c?.seekTo(Duration(milliseconds: (to * 1000).round()));
  }

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
      if (now >= widget.durationS) {
        _togglePlay();
        return;
      }
      if (mounted) setState(() => _pos = now);
    });
  }

  void _markIn() => setState(() {
    _in = _pos;
    // an out before the new in no longer makes a stretch
    if (_out != null && _out! <= _pos) _out = null;
    if (_play != null && _play! < _pos) _play = null;
  });

  void _markOut() => setState(() {
    _out = _pos;
    if (_in != null && _in! >= _pos) _in = null;
    if (_play != null && _play! > _pos) _play = null;
  });

  void _markPlay() => setState(() => _play = _pos);

  void _clear() => setState(() {
    _in = null;
    _out = null;
    _play = null;
  });

  SourceSpan? get _span {
    final a = _in, b = _out;
    if (a == null || b == null) return null;
    final span = SourceSpan(inS: a, outS: b, playS: _play);
    return span.isValid ? span : null;
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
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
    if (k == LogicalKeyboardKey.keyI) act = _markIn;
    if (k == LogicalKeyboardKey.keyO) act = _markOut;
    if (k == LogicalKeyboardKey.keyP) act = _markPlay;
    if (act == null) return KeyEventResult.ignored;
    act();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = _c;
    final span = _span;
    final duration = math.max(widget.durationS, 0.001);

    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      child: GestureDetector(
        // a tap anywhere on the panel gives it the keys
        onTap: _focus.requestFocus,
        behavior: HitTestBehavior.translucent,
        child: Column(
          key: const Key('source-viewer'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
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
            const SizedBox(height: 4),
            // the scrub bar, with the detected moments and the marked stretch
            SizedBox(
              height: 34,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: _SpanPainter(
                          duration: duration,
                          events: widget.events,
                          inS: _in,
                          outS: _out,
                          playS: _play,
                          range: theme.colorScheme.primary.withValues(alpha: 0.25),
                          mark: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                  ),
                  Slider(
                    key: const Key('source-scrub'),
                    value: _pos.clamp(0.0, duration).toDouble(),
                    max: duration,
                    onChanged: (v) => _seek(v),
                  ),
                ],
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${formatClock(_pos)} / ${formatClock(widget.durationS)}',
                    key: const Key('source-clock'),
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Back a frame (,)',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  padding: EdgeInsets.zero,
                  onPressed: () => _seek(_pos - _frame),
                  icon: const Icon(Icons.chevron_left, size: 18),
                ),
                IconButton(
                  key: const Key('source-play'),
                  tooltip: _playing ? 'Pause (Space)' : 'Play (Space)',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  padding: EdgeInsets.zero,
                  onPressed: _togglePlay,
                  icon: Icon(_playing ? Icons.pause : Icons.play_arrow, size: 20),
                ),
                IconButton(
                  tooltip: 'Forward a frame (.)',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  padding: EdgeInsets.zero,
                  onPressed: () => _seek(_pos + _frame),
                  icon: const Icon(Icons.chevron_right, size: 18),
                ),
              ],
            ),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                ActionChip(
                  key: const Key('mark-in'),
                  avatar: const Icon(Icons.first_page, size: 16),
                  label: Text(_in == null ? 'In (I)' : 'In ${formatClock(_in!)}'),
                  onPressed: _markIn,
                ),
                ActionChip(
                  key: const Key('mark-out'),
                  avatar: const Icon(Icons.last_page, size: 16),
                  label: Text(
                    _out == null ? 'Out (O)' : 'Out ${formatClock(_out!)}',
                  ),
                  onPressed: _markOut,
                ),
                ActionChip(
                  key: const Key('mark-play'),
                  avatar: const Icon(Icons.adjust, size: 16),
                  tooltip: 'The play: what ducking and the slow-motion ramp work around',
                  label: Text(
                    _play == null ? 'Play (P)' : 'Play ${formatClock(_play!)}',
                  ),
                  onPressed: _markPlay,
                ),
                if (_in != null || _out != null || _play != null)
                  ActionChip(
                    avatar: const Icon(Icons.close, size: 16),
                    label: const Text('clear'),
                    onPressed: _clear,
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              span == null
                  ? 'Mark where the cut starts and ends.'
                  : '${span.lengthS.toStringAsFixed(1)} s from the recording',
              key: const Key('source-span'),
              style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    key: const Key('add-span'),
                    onPressed: span == null || !widget.enabled
                        ? null
                        : () => widget.onAdd(span),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Add at the playhead'),
                  ),
                ),
                const SizedBox(width: 8),
                // the same stretch, dragged to where it should go
                Draggable<RulerDrop>(
                  maxSimultaneousDrags: span == null || !widget.enabled ? 0 : 1,
                  data: span == null ? null : RulerDrop.span(span),
                  dragAnchorStrategy: pointerDragAnchorStrategy,
                  feedback: Material(
                    color: Colors.transparent,
                    child: Chip(
                      avatar: const Icon(Icons.content_cut, size: 16),
                      label: Text(
                        span == null
                            ? 'Cut'
                            : 'Cut · ${span.lengthS.toStringAsFixed(1)} s',
                      ),
                    ),
                  ),
                  child: Tooltip(
                    message: 'Drag to the ruler',
                    child: Icon(
                      Icons.drag_indicator,
                      color: span == null ? theme.disabledColor : null,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The scrub bar's background: a tick per detected moment, the marked
/// stretch, and the play inside it.
class _SpanPainter extends CustomPainter {
  _SpanPainter({
    required this.duration,
    required this.events,
    required this.inS,
    required this.outS,
    required this.playS,
    required this.range,
    required this.mark,
  });

  final double duration;
  final List<DetectionEvent> events;
  final double? inS;
  final double? outS;
  final double? playS;
  final Color range;
  final Color mark;

  // the Slider's track has this much margin on each side
  static const _pad = 24.0;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width - 2 * _pad;
    double x(double s) => _pad + w * (s / duration).clamp(0.0, 1.0);
    final mid = size.height / 2;

    if (inS != null || outS != null) {
      final a = x(inS ?? 0), b = x(outS ?? duration);
      canvas.drawRect(
        Rect.fromLTRB(a, mid - 8, b, mid + 8),
        Paint()..color = range,
      );
    }
    for (final e in events) {
      canvas.drawRect(
        Rect.fromLTWH(x(e.t) - 1, 2, 2, 7),
        Paint()..color = EventStyle.of(e.kind).color,
      );
    }
    final edge = Paint()
      ..color = mark
      ..strokeWidth = 2;
    for (final s in [inS, outS]) {
      if (s != null) {
        canvas.drawLine(Offset(x(s), mid - 10), Offset(x(s), mid + 10), edge);
      }
    }
    if (playS != null) {
      canvas.drawCircle(Offset(x(playS!), mid), 4, Paint()..color = mark);
    }
  }

  @override
  bool shouldRepaint(_SpanPainter old) =>
      old.inS != inS ||
      old.outS != outS ||
      old.playS != playS ||
      old.duration != duration ||
      old.events != events;
}
