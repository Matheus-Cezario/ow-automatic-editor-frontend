import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../monitor/frame.dart';
import '../monitor/monitor_picture.dart';
import '../montage.dart';
import 'highlight_style.dart';

/// The montage's monitor: shows what the video will be, before asking for it.
///
/// It renders nothing on the server. Every picture layer is stacked here the
/// way the server will stack it — each clip on its own `<video>` or `<img>`,
/// seeked to its point in the source, with its zoom, colour, scale, place,
/// opacity, fades and transitions (see [frameAt]). A dissolve really shows
/// both clips; a clip on an upper layer really covers only its own area.
///
/// Rendering for real on every adjustment would cost a full trip through
/// ffmpeg per drag. Seeking inside files that already exist is instant, and
/// it is what any editor does while you edit.
///
/// > What this preview does **not** guarantee is frame-exact sync during
/// > playback: each clip runs on its own media element, corrected when it
/// > drifts. The exact cut is the final file's, which the server assembles
/// > with ffmpeg.
class PreviewPlayer extends StatelessWidget {
  const PreviewPlayer({
    super.key,
    required this.videoUrl,
    required this.layers,
    required this.cuts,
    required this.atS,
    required this.playing,
    this.library = const {},
    this.export = const ExportSpec(),
    this.aspectRatio = 16 / 9,
    this.texts = const [],
    this.selectionIds = const {},
    this.onSelectText,
    this.onMoveText,
    this.onDragging,
    this.editingId,
    this.onEditing,
    this.onTextChanged,
    this.onGestureStart,
    this.onGestureEnd,
  });

  /// What a clip of the match shows: the proxy, or the recording itself.
  final String? videoUrl;

  /// Every layer, bottom to top — the monitor composes them all.
  final List<Layer> layers;

  /// The picture clips the screen considers visible: they decide the
  /// transition badge.
  final List<TimelineClip> cuts;

  /// Library items by id: what a media clip shows.
  final Map<String, Media> library;

  /// The fit, the watermark — what the export changes in the picture.
  final ExportSpec export;

  /// The frame's shape: the export's when one was asked for.
  final double aspectRatio;

  /// Where the playhead is, in **assembled video** time.
  final double atS;
  final bool playing;

  /// The montage's text clips. The monitor draws them over the picture, at the
  /// place and size the server will draw them — it is the only way to decide
  /// where a line goes without rendering the video to see.
  final List<TimelineClip> texts;

  /// Who is selected, so the chosen line stands out.
  final Set<String> selectionIds;

  final ValueChanged<String>? onSelectText;

  /// (id, x, y) — the new position, as a fraction of half the frame, as the
  /// server understands it.
  final void Function(String id, double x, double y)? onMoveText;

  /// The text being typed right there on the frame; `null` if none.
  final String? editingId;

  /// Asks to start (id) or stop (`null`) typing on the frame.
  final ValueChanged<String?>? onEditing;

  /// (id, text) — what is written now, on every keystroke.
  final void Function(String id, String text)? onTextChanged;

  /// Start and end of a drag of the text: everything in between is **one**
  /// undo step, not one per pointer movement.
  final VoidCallback? onGestureStart;
  final VoidCallback? onGestureEnd;

  /// Text for the screen to show while the finger drags the line; `null` on
  /// release. It serves the same purpose as the ruler's drag label.
  final ValueChanged<String?>? onDragging;

  /// How far ahead the next clips are loaded, so a cut does not wait for them.
  static const lookaheadS = 0.6;

  Frame _frame(double t) => frameAt(
    layers,
    t,
    matchUrl: videoUrl,
    library: library,
    export: export,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final frame = _frame(atS);

    return AspectRatio(
      aspectRatio: aspectRatio,
      child: ColoredBox(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            MonitorPicture(
              frame: frame,
              playing: playing,
              upcoming: _frame(atS + lookaheadS),
            ),
            if (transitionAt(cuts, atS) case final tr?)
              Positioned(
                left: 8,
                top: 8,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      child: Text(
                        TransitionType.of(tr.kind)?.name ?? tr.kind,
                        key: const Key('transition-badge'),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ),

            // The black-screen notice takes no taps: it sits in the middle of
            // the frame, which is exactly where text usually is, and a notice
            // stealing the line's drag would be the worst place possible.
            if (frame.isBlack)
              IgnorePointer(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.crop_din,
                        color: theme.hintColor.withValues(alpha: 0.6),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        cuts.isEmpty
                            ? 'no cuts yet'
                            : 'black screen — only the music here',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.hintColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // ── the text, over the picture ──────────────────────────────
            //
            // Drawn with the same computation as the server: the size is a
            // fraction of the frame's height and the position is an offset
            // from the centre by half of it. What is seen here is what will
            // come out.
            for (final t in texts)
              if (atS >= t.atS - 1e-6 && atS < t.untilS - 1e-6)
                _TextOnFrame(
                  key: ValueKey('text-on-frame-${t.id}'),
                  clip: t,
                  pickedOne: selectionIds.contains(t.id),
                  onChoose: () => onSelectText?.call(t.id),
                  onMove: onMoveText == null
                      ? null
                      : (x, y) => onMoveText!(t.id, x, y),
                  onDragging: onDragging,
                  editing: editingId == t.id,
                  onEditing: onEditing == null
                      ? null
                      : (on) => onEditing!(on ? t.id : null),
                  onTextChanged: onTextChanged == null
                      ? null
                      : (v) => onTextChanged!(t.id, v),
                  onGestureStart: onGestureStart,
                  onGestureEnd: onGestureEnd,
                ),
          ],
        ),
      ),
    );
  }
}

/// A line of text drawn over the monitor, and draggable.
///
/// Dragging here is the natural way to say where the text goes: the
/// alternative was typing two numbers and rendering the video to check.
///
/// It is also where text is typed: tapping the already selected text opens
/// editing on the frame itself, at the size and colour it will come out in.
class _TextOnFrame extends StatefulWidget {
  const _TextOnFrame({
    super.key,
    required this.clip,
    required this.pickedOne,
    required this.onChoose,
    required this.onMove,
    required this.onDragging,
    this.editing = false,
    this.onEditing,
    this.onTextChanged,
    this.onGestureStart,
    this.onGestureEnd,
  });

  final TimelineClip clip;
  final bool pickedOne;
  final VoidCallback onChoose;
  final void Function(double x, double y)? onMove;
  final ValueChanged<String?>? onDragging;
  final bool editing;
  final ValueChanged<bool>? onEditing;
  final ValueChanged<String>? onTextChanged;
  final VoidCallback? onGestureStart;
  final VoidCallback? onGestureEnd;

  @override
  State<_TextOnFrame> createState() => _TextOnFrameState();
}

class _TextOnFrameState extends State<_TextOnFrame> {
  /// How far the finger has moved in this gesture, and where the line started.
  ///
  /// The offset is accumulated here, not read from the pointer position: the
  /// first `onPanUpdate` arrives with the position of the instant the gesture
  /// was accepted — the same as `onPanStart` — so measuring "position minus
  /// origin" gave zero, and a single-jump drag (a test's, or a fast finger's)
  /// moved nothing.
  Offset _moved = Offset.zero;
  double _x0 = 0;
  double _y0 = 0;

  late final TextEditingController _controller = TextEditingController(
    text: widget.clip.text,
  );

  /// The field's focus, requested by hand.
  ///
  /// `autofocus` is not enough: it only applies when **nothing** on screen has
  /// focus, and the editor keeps focus on the shortcuts node almost all the
  /// time. The field opened with no keyboard, and keys went to the shortcuts —
  /// "s" split the clip.
  late final FocusNode _focusNode = FocusNode(debugLabel: 'text on frame')
    ..addListener(_onFocusChange);

  /// What was written when editing opened: clearing everything and leaving
  /// restores it, because empty text is not text the server draws.
  String _before = '';

  @override
  void initState() {
    super.initState();
    if (widget.editing) _opened();
  }

  @override
  void didUpdateWidget(_TextOnFrame old) {
    super.didUpdateWidget(old);
    if (widget.editing && !old.editing) _opened();
    // undo, or another screen, changed the text from outside: the field follows
    if (!widget.editing && _controller.text != widget.clip.text) {
      _controller.text = widget.clip.text;
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// Losing focus by any route closes editing: an open field with no keyboard
  /// is the worst of both worlds.
  void _onFocusChange() {
    if (!_focusNode.hasFocus && widget.editing) _finish();
  }

  void _opened() {
    _before = widget.clip.text;
    _controller.value = TextEditingValue(
      text: widget.clip.text,
      selection: TextSelection(
        baseOffset: 0,
        extentOffset: widget.clip.text.length,
      ),
    );
    // the field only exists after this frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.editing) _focusNode.requestFocus();
    });
  }

  void _finish() {
    if (!widget.editing) return;
    if (_controller.text.trim().isEmpty) widget.onTextChanged?.call(_before);
    widget.onEditing?.call(false);
  }

  @override
  Widget build(BuildContext context) {
    final styleSpec = widget.clip.textStyle;
    final t = widget.clip.transform;

    return LayoutBuilder(
      builder: (context, box) {
        final body = styleSpec.size * box.maxHeight;
        final outlineSize = styleSpec.outline * body;
        final fillColour = _colours[styleSpec.color] ?? Colors.white;
        final outlineColour = _colours[styleSpec.outlineColor] ?? Colors.black;

        return Align(
          // it is the same computation as `drawtext`: the line's centre lands
          // `x` half-frames from the centre of the screen
          alignment: Alignment(t.x, t.y),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // `down`, not `start`: with the default, the offset spent beating
            // the slop is discarded and a drag delivered all at once (a fast
            // finger, or a test) produces no update at all — the line did not
            // move
            dragStartBehavior: DragStartBehavior.down,
            onTap: widget.editing
                ? null
                : widget.pickedOne && widget.onEditing != null
                ? () => widget.onEditing!(true)
                : widget.onChoose,
            onPanStart: widget.onMove == null || widget.editing
                ? null
                : (_) {
                    widget.onChoose();
                    widget.onGestureStart?.call();
                    _moved = Offset.zero;
                    _x0 = t.x;
                    _y0 = t.y;
                  },
            onPanUpdate: widget.onMove == null || widget.editing
                ? null
                : (d) {
                    _moved += d.delta;
                    final x = (_x0 + _moved.dx / (box.maxWidth / 2)).clamp(
                      -1.0,
                      1.0,
                    );
                    final y = (_y0 + _moved.dy / (box.maxHeight / 2)).clamp(
                      -1.0,
                      1.0,
                    );
                    widget.onDragging?.call(
                      'text at ${(x * 100).round()}%, ${(y * 100).round()}% '
                      'from the centre',
                    );
                    widget.onMove!(x, y);
                  },
            onPanEnd: widget.onMove == null || widget.editing
                ? null
                : (_) {
                    _moved = Offset.zero;
                    widget.onDragging?.call(null);
                    widget.onGestureEnd?.call();
                  },
            child: Container(
              // the key is on the line, not on the frame's area: it is what is
              // tapped, and it is where the drag starts
              key: ValueKey('frame-text-${widget.clip.id}'),
              padding: const EdgeInsets.all(4),
              decoration: widget.pickedOne
                  ? BoxDecoration(
                      border: Border.all(
                        color: Theme.of(context).colorScheme.primary,
                        width: 1,
                      ),
                    )
                  : null,
              child: widget.editing
                  ? IntrinsicWidth(
                      child: TextField(
                        key: ValueKey('typing-${widget.clip.id}'),
                        controller: _controller,
                        focusNode: _focusNode,
                        textAlign: TextAlign.center,
                        cursorColor: fillColour,
                        onChanged: widget.onTextChanged,
                        onSubmitted: (_) => _finish(),
                        onTapOutside: (_) => _finish(),
                        decoration: const InputDecoration.collapsed(
                          hintText: '',
                        ),
                        style: TextStyle(
                          fontSize: body,
                          fontWeight: FontWeight.bold,
                          height: 1.1,
                          color: fillColour,
                          // the real outline is a second text underneath, and a
                          // field cannot draw two; the shadow imitates it well
                          // enough to read what is being typed
                          shadows: outlineSize > 0
                              ? [
                                  for (final d in const [
                                    Offset(1, 1),
                                    Offset(-1, 1),
                                    Offset(1, -1),
                                    Offset(-1, -1),
                                  ])
                                    Shadow(
                                      color: outlineColour,
                                      offset: d * (outlineSize / 2),
                                    ),
                                ]
                              : null,
                        ),
                      ),
                    )
                  : Stack(
                      children: [
                        // the outline is what makes white text survive a bright
                        // scene; without it the preview would lie about
                        // legibility
                        if (outlineSize > 0)
                          Text(
                            widget.clip.text,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: body,
                              fontWeight: FontWeight.bold,
                              height: 1.1,
                              foreground: Paint()
                                ..style = PaintingStyle.stroke
                                ..strokeWidth = outlineSize
                                ..color = outlineColour,
                            ),
                          ),
                        Text(
                          widget.clip.text,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: body,
                            fontWeight: FontWeight.bold,
                            height: 1.1,
                            color: fillColour,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        );
      },
    );
  }

  /// The same colours the server accepts, on the app's side.
  static const _colours = <String, Color>{
    'white': Colors.white,
    'yellow': Color(0xFFFFEB3B),
    'orange': Color(0xFFFF9800),
    'red': Color(0xFFF44336),
    'cyan': Color(0xFF00E5FF),
    'black': Colors.black,
  };
}
