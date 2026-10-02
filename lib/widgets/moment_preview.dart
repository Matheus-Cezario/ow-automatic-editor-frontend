import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../montage.dart';

/// Plays a few seconds of a moment while the mouse rests on [child].
///
/// The thumbnail says *what* happened; three seconds of video say whether the
/// play is worth a cut. It opens after a short pause on the card, so sweeping
/// the mouse down the shelf does not start a player per card, and there is
/// only ever one: leaving the card disposes it.
///
/// The preview floats next to the card instead of replacing the thumbnail —
/// at the shelf's width the thumbnail is too small to read a play in.
class MomentHoverPreview extends StatefulWidget {
  const MomentHoverPreview({
    super.key,
    required this.videoUrl,
    required this.t,
    required this.recordingS,
    required this.child,
  });

  /// What to play from: the match proxy, like the monitor.
  final String videoUrl;

  /// The moment's instant in the recording.
  final double t;
  final double recordingS;
  final Widget child;

  /// How long the mouse has to rest before the player opens.
  static const hoverDelay = Duration(milliseconds: 350);
  static const width = 320.0;

  @override
  State<MomentHoverPreview> createState() => _MomentHoverPreviewState();
}

class _MomentHoverPreviewState extends State<MomentHoverPreview> {
  final _portal = OverlayPortalController();
  final _link = LayerLink();
  Timer? _wait;

  /// Whether the card has room on its right; otherwise the preview covers it.
  bool _toTheRight = true;

  @override
  void dispose() {
    _wait?.cancel();
    super.dispose();
  }

  void _enter(PointerEnterEvent _) {
    _wait?.cancel();
    _wait = Timer(MomentHoverPreview.hoverDelay, _show);
  }

  void _exit(PointerExitEvent _) {
    _wait?.cancel();
    _wait = null;
    if (_portal.isShowing) _portal.hide();
  }

  void _show() {
    _wait = null;
    if (!mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) {
      final right = box.localToGlobal(Offset(box.size.width, 0)).dx;
      final screen = MediaQuery.sizeOf(context).width;
      _toTheRight = screen - right >= MomentHoverPreview.width + 16;
    }
    _portal.show();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: _enter,
      onExit: _exit,
      child: CompositedTransformTarget(
        link: _link,
        child: OverlayPortal(
          controller: _portal,
          overlayChildBuilder: (_) => CompositedTransformFollower(
            link: _link,
            targetAnchor: _toTheRight ? Alignment.topRight : Alignment.topLeft,
            followerAnchor: Alignment.topLeft,
            offset: _toTheRight ? const Offset(8, 0) : Offset.zero,
            child: Align(
              alignment: Alignment.topLeft,
              // the preview is only to look at: the mouse that reaches it is
              // still on the card underneath, and must not close it
              child: IgnorePointer(
                child: _PreviewWindow(
                  key: const Key('moment-preview'),
                  videoUrl: widget.videoUrl,
                  window: momentPreview(widget.t, recordingS: widget.recordingS),
                ),
              ),
            ),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// The floating player: muted, looping over [window].
class _PreviewWindow extends StatefulWidget {
  const _PreviewWindow({super.key, required this.videoUrl, required this.window});

  final String videoUrl;
  final ({double startS, double endS}) window;

  @override
  State<_PreviewWindow> createState() => _PreviewWindowState();
}

class _PreviewWindowState extends State<_PreviewWindow> {
  VideoPlayerController? _c;
  bool _failed = false;

  Duration get _start =>
      Duration(milliseconds: (widget.window.startS * 1000).round());
  Duration get _end =>
      Duration(milliseconds: (widget.window.endS * 1000).round());

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void dispose() {
    _c?.removeListener(_loop);
    _c?.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    final c = VideoPlayerController.networkUrl(Uri.parse(widget.videoUrl));
    try {
      await c.initialize();
      // muted: the browser only autoplays silent video, and a sound out of
      // nowhere on hover would be worse than none
      await c.setVolume(0);
      await c.seekTo(_start);
      await c.play();
    } catch (_) {
      await c.dispose();
      if (mounted) setState(() => _failed = true);
      return;
    }
    if (!mounted) {
      await c.dispose();
      return;
    }
    c.addListener(_loop);
    setState(() => _c = c);
  }

  /// Back to the start at the end of the window — or of the recording.
  void _loop() {
    final c = _c;
    if (c == null) return;
    final v = c.value;
    if (v.position >= _end || (v.isCompleted && !v.isBuffering)) {
      unawaited(c.seekTo(_start).then((_) => c.play()));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = _c;
    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      color: Colors.black,
      child: SizedBox(
        width: MomentHoverPreview.width,
        height: MomentHoverPreview.width * 9 / 16,
        child: c != null
            ? FittedBox(
                fit: BoxFit.cover,
                clipBehavior: Clip.hardEdge,
                child: SizedBox(
                  width: c.value.size.width,
                  height: c.value.size.height,
                  child: VideoPlayer(c),
                ),
              )
            : Center(
                child: _failed
                    ? Text(
                        'preview unavailable',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.white70,
                        ),
                      )
                    : const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
              ),
      ),
    );
  }
}
