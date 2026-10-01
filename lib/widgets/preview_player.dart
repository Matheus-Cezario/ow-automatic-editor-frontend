import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../api.dart';
import '../montage.dart';
import 'highlight_style.dart';

/// The montage's monitor: shows what the video will be, before asking for it.
///
/// It renders nothing. It opens the **original recording** and seeks inside it
/// to the instant that corresponds to the playhead — if it is over a block
/// that starts at minute 3 of the match, it is at minute 3 that the recording
/// is positioned. Where there is no block, a black screen: the same the server
/// will render there.
///
/// Really rendering on every adjustment would cost a full trip through ffmpeg
/// per drag. Seeking inside the file that already exists is instant, and it is
/// what any editor does while you edit.
///
/// > What this preview does **not** guarantee is frame sync with the music
/// > during playback: they are two independent media elements, and the splice
/// > between blocks is done by seeking. Within a block the picture runs on its
/// > own, and a 1 s block may end a few frames early. The exact cut is the
/// > final file's, which the server assembles with ffmpeg.
class PreviewPlayer extends StatefulWidget {
  const PreviewPlayer({
    super.key,
    required this.videoUrl,
    required this.cuts,
    required this.atS,
    required this.playing,
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

  final String videoUrl;
  final List<TimelineClip> cuts;

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

  @override
  State<PreviewPlayer> createState() => _PreviewPlayerState();
}

class _PreviewPlayerState extends State<PreviewPlayer> {
  VideoPlayerController? _c;
  String? _error;
  bool _reopening = false;

  /// How many times the player has died and been brought back by itself.
  ///
  /// A half-gigabyte recording delivered via `Range`, with dozens of seeks per
  /// second while dragging, sometimes brings the browser's video element down.
  /// Before this it stayed black until the page was reloaded — and reloading
  /// cost the whole montage.
  int _crashes = 0;
  static const _maxCrashes = 4;

  /// One seek at a time. `didUpdateWidget` fires on every frame of a drag, and
  /// overlapping seeks are exactly what makes the element choke.
  bool _busy = false;

  DateTime _lastSeek = DateTime.fromMillisecondsSinceEpoch(0);
  int? _currentBlock;

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void dispose() {
    _c?.removeListener(_watch);
    _c?.dispose();
    super.dispose();
  }

  Future<void> _open({Duration? resumeAt}) async {
    final c = VideoPlayerController.networkUrl(Uri.parse(widget.videoUrl));
    try {
      await c.initialize();
      await c.setVolume(0); // the montage's music rules the sound
      if (resumeAt != null) await c.seekTo(resumeAt);
    } catch (e) {
      await c.dispose();
      if (mounted) setState(() => _error = '$e');
      return;
    }
    if (!mounted) {
      await c.dispose();
      return;
    }
    c.addListener(_watch);
    setState(() {
      _c = c;
      _error = null;
      _reopening = false;
    });
    _follow(force: true);
  }

  /// Notices the player dying and brings it back at the same point.
  void _watch() {
    final c = _c;
    if (c == null || _reopening || !c.value.hasError) return;
    _reopening = true;
    final location = c.value.position;
    _crashes++;
    if (_crashes > _maxCrashes) {
      setState(() {
        _error = 'the player stopped responding; tap to try again';
        _reopening = false;
      });
      return;
    }
    unawaited(_revive(location));
  }

  Future<void> _revive(Duration location) async {
    final dead = _c;
    setState(() => _c = null);
    dead?.removeListener(_watch);
    await dead?.dispose();
    if (!mounted) return;
    await _open(resumeAt: location);
  }

  Future<void> _retry() async {
    _crashes = 0;
    setState(() {
      _error = null;
      _reopening = true;
    });
    await _revive(Duration.zero);
  }

  @override
  void didUpdateWidget(PreviewPlayer old) {
    super.didUpdateWidget(old);
    if (old.videoUrl != widget.videoUrl) {
      _crashes = 0;
      unawaited(_revive(Duration.zero));
      return;
    }
    _follow(force: widget.playing != old.playing);
  }

  /// Puts the recording at the instant the playhead asks for.
  Future<void> _follow({bool force = false}) async {
    final c = _c;
    if (c == null || !c.value.isInitialized || c.value.hasError) return;
    if (_busy) return;

    final origin = sourceAt(widget.cuts, widget.atS);
    final block = blockAt(widget.cuts, widget.atS);

    // a gap (or past the end): nothing to show, and nothing to play
    if (origin == null) {
      _currentBlock = null;
      if (c.value.isPlaying) {
        _busy = true;
        try {
          await c.pause();
        } finally {
          _busy = false;
        }
      }
      if (mounted) setState(() {});
      return;
    }

    // asking for an instant past the end of the file is the kind of thing that
    // brings the video element down, and a cut may have been stretched there
    final limit = c.value.duration.inMilliseconds / 1000.0;
    final target = limit > 0 ? origin.clamp(0.0, limit - 0.05) : origin;

    final changedBlock = block != _currentBlock;
    _currentBlock = block;

    // While playing, the picture runs by itself inside the block; it only seeks
    // when entering a new block or when it drifts too far from what it should
    // show.
    final nowS = c.value.position.inMilliseconds / 1000.0;
    final drifted = (nowS - target).abs() > 0.34;
    final recent =
        DateTime.now().difference(_lastSeek) <
        const Duration(milliseconds: 120);

    _busy = true;
    try {
      if (force || changedBlock || drifted) {
        if (!(recent && !force && !changedBlock)) {
          _lastSeek = DateTime.now();
          await c.seekTo(Duration(milliseconds: (target * 1000).round()));
        }
      }
      if (widget.playing && !c.value.isPlaying) {
        await c.play();
      } else if (!widget.playing && c.value.isPlaying) {
        await c.pause();
      }
    } catch (_) {
      // a failing seek must not bring the screen down: the watcher takes care
      // of reopening the player if it really died
    } finally {
      _busy = false;
    }
    if (mounted) setState(() {});
  }

  /// The incoming clip's picture, as the transition brings it in.
  ///
  /// The monitor has **one** video: it cannot show the previous clip under the
  /// new one. Dissolve becomes the new clip emerging from black, and slide the
  /// new clip arriving from the side — enough to see its timing and direction.
  /// The real mix is the one in the rendered video.
  Widget _withTransition(Widget picture) {
    final tr = transitionAt(widget.cuts, widget.atS);
    if (tr == null || tr.leaving) return picture;
    final remaining = 1 - tr.p;
    return switch (tr.kind) {
      'dissolve' => Opacity(opacity: tr.p, child: picture),
      'slide_left' => _slide(picture, Offset(remaining, 0)),
      'slide_right' => _slide(picture, Offset(-remaining, 0)),
      'slide_up' => _slide(picture, Offset(0, remaining)),
      'slide_down' => _slide(picture, Offset(0, -remaining)),
      _ => picture,
    };
  }

  Widget _slide(Widget picture, Offset fraction) => ClipRect(
    child: FractionalTranslation(translation: fraction, child: picture),
  );

  /// The colour over the picture during a dip, or `null` outside one.
  Color? _veil() {
    final tr = transitionAt(widget.cuts, widget.atS);
    if (tr == null) return null;
    final colour = switch (tr.kind) {
      'fade_black' => Colors.black,
      'fade_white' => Colors.white,
      _ => null,
    };
    if (colour == null) return null;
    // leaving, the colour rises over the last half; entering, it fades over
    // the first half
    final opacity = tr.leaving ? tr.p : math.max(0.0, 1 - tr.p * 2);
    if (opacity <= 0) return null;
    return colour.withValues(alpha: opacity);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = _c;
    final onBlack = sourceAt(widget.cuts, widget.atS) == null;
    final alive = c != null && c.value.isInitialized && !c.value.hasError;

    return AspectRatio(
      aspectRatio: alive ? c.value.aspectRatio : 16 / 9,
      child: ColoredBox(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // In a gap the previous frame must not stay on show: the video will
            // really be black there, and showing the old picture would lie
            // about what will come out.
            if (alive && !onBlack) _withTransition(VideoPlayer(c)),
            if (_veil() case final veil?)
              IgnorePointer(
                child: ColoredBox(
                  key: const Key('transition-veil'),
                  color: veil,
                ),
              ),
            if (transitionAt(widget.cuts, widget.atS) case final tr?)
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
            if (onBlack && _error == null)
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
                        widget.cuts.isEmpty
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
            for (final t in widget.texts)
              if (widget.atS >= t.atS - 1e-6 && widget.atS < t.untilS - 1e-6)
                _TextOnFrame(
                  key: ValueKey('text-on-frame-${t.id}'),
                  clip: t,
                  pickedOne: widget.selectionIds.contains(t.id),
                  onChoose: () => widget.onSelectText?.call(t.id),
                  onMove: widget.onMoveText == null
                      ? null
                      : (x, y) => widget.onMoveText!(t.id, x, y),
                  onDragging: widget.onDragging,
                  editing: widget.editingId == t.id,
                  onEditing: widget.onEditing == null
                      ? null
                      : (on) => widget.onEditing!(on ? t.id : null),
                  onTextChanged: widget.onTextChanged == null
                      ? null
                      : (v) => widget.onTextChanged!(t.id, v),
                  onGestureStart: widget.onGestureStart,
                  onGestureEnd: widget.onGestureEnd,
                ),

            if (_error != null)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                      const SizedBox(height: 8),
                      // the montage is not lost because of the player: editing
                      // can go on through the waveform and the beats
                      TextButton.icon(
                        onPressed: _retry,
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('Try again'),
                      ),
                    ],
                  ),
                ),
              )
            else if (c == null || _reopening)
              // likewise: while the video opens, the text is still draggable
              const IgnorePointer(
                child: Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
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
