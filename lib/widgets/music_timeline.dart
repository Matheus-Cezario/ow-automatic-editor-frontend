import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../montage.dart';
import 'highlight_style.dart';

/// What is being dragged onto the ruler.
///
/// Two origins and a single target: a match moment, from the left shelf, or a
/// library item — video, image or music. The ruler does not need to know what
/// to do with each; it says **where** it landed and the screen sorts out the
/// rest.
class RulerDrop {
  const RulerDrop.moment(DetectionEvent this.event) : media = null;
  const RulerDrop.mediaItem(Media this.media) : event = null;

  final DetectionEvent? event;
  final Media? media;

  /// How long the block will last — it is what the drag ghost draws, so the
  /// size under the finger is the size on the ruler.
  double get durationSecs => media?.suggestedDuration ?? kDefaultCutS;

  String get blockLabel => media?.name ?? EventStyle.of(event!.kind).label;

  bool get isSound => media?.isAudio ?? false;
}

/// The video ruler with the layers on top — the heart of the manual montage.
///
/// Everything is drawn on the scale of the **video that will come out**:
/// instant zero is its first frame. The music lives within that scale, in
/// blocks, and each block draws its own waveform — that is how it stopped
/// being a continuous background and became material like any other.
///
/// The layers are stacked tracks, from the bottom one to the top one — the
/// same order the server draws them in. Each one's header stays **outside**
/// the scroll: it must stay visible when the ruler moves.
///
/// Four gestures: dragging the clip's body **moves** it, the left edge
/// **trims**, the right one **stretches**, and dragging up or down **changes
/// layer**.
class MusicTimeline extends StatefulWidget {
  const MusicTimeline({
    super.key,
    required this.layers,
    required this.activeLayer,
    required this.selectionIds,
    required this.pxPerSecond,
    required this.playheadS,
    required this.scroll,
    required this.onSeek,
    required this.onSelect,
    required this.onMove,
    required this.onTrim,
    required this.onStretch,
    required this.onGestureStart,
    required this.onGestureEnd,
    required this.onChangeLayer,
    required this.onDropClip,
    required this.onActiveLayer,
    required this.onAdjustLayer,
    required this.onReorderLayers,
    this.onRenameLayer,
    this.onRemoveLayer,
    this.onDuplicateClip,
    this.onDeleteClip,
    this.onDragLabel,
    this.onDrop,
    this.beatTimes = const [],
    this.matchWaveform = const [],
    this.matchDuration = 0,
    this.tracks = const {},
    this.fallbackDurationS = 60,
  });

  final List<Layer> layers;
  final int activeLayer;

  /// Who is selected, by clip id. An index will not do: deleting a clip shifts
  /// the following ones, and the selection would point at the neighbour.
  final Set<String> selectionIds;

  /// Zoom: how many pixels one second of video is worth.
  final double pxPerSecond;

  final double playheadS;
  final ScrollController scroll;

  final ValueChanged<double> onSeek;

  /// Picks a clip. `toggle` is the shift-click, which adds to the selection
  /// instead of replacing it; `null` clears it.
  final void Function(String? id, {bool toggle}) onSelect;

  /// (id, new position in video time) — **absolute** values, since the drag is
  /// measured from the start of the gesture.
  final void Function(String id, double atS) onMove;
  final void Function(String id, double atS) onTrim;
  final void Function(String id, double durationS) onStretch;

  /// (id, target layer) — the clip menu's "move to layer".
  final void Function(String id, int layerIndex) onChangeLayer;

  /// (id, where the drag started, where it was let go, target layer) — the
  /// end of a move, which may change layer or swap with another clip.
  final void Function(String id, double fromS, double atS, int layerIndex)
  onDropClip;

  /// The clip menu's own operations; without them, the entry is left out.
  final ValueChanged<String>? onDuplicateClip;
  final ValueChanged<String>? onDeleteClip;

  final ValueChanged<int> onActiveLayer;

  /// (from, to) — dragging one header over another swaps the order in which
  /// the layers are drawn.
  final void Function(int from, int to) onReorderLayers;
  final void Function(int layerIndex, {bool? muted, bool? hidden, bool? locked})
  onAdjustLayer;

  /// The right-click menu's own operations; without them, the entry is left
  /// out of the menu.
  final void Function(int layerIndex, String name)? onRenameLayer;
  final ValueChanged<int>? onRemoveLayer;

  /// Opens and closes the gesture in the history: a whole drag becomes a
  /// single undo step, instead of one per frame.
  final VoidCallback onGestureStart;
  final VoidCallback onGestureEnd;

  /// Text for the screen to show while the finger is on the clip; `null` on
  /// release.
  final ValueChanged<String?>? onDragLabel;

  /// What to do when something is dropped on the ruler: a match moment or a
  /// library item, with the instant and the layer where it landed.
  ///
  /// It is the short path for whoever already knows where they want the thing
  /// — clicking puts it at the playhead, dragging puts it where the finger let
  /// go.
  final void Function(RulerDrop o, double atS, int layerIndex)? onDrop;

  /// The beat grid in video time — the same the magnet uses. Drawing it and
  /// snapping to it must be the same thing, or the line lies.
  final List<double> beatTimes;

  /// The whole match audio's waveform, and how much time it covers.
  final List<double> matchWaveform;
  final double matchDuration;

  /// The library's music tracks, by id. They are where the waveform drawn
  /// inside a music block comes from — each has its own, not the match's.
  final Map<String, Track> tracks;

  /// Ruler to draw while the montage is still empty.
  final double fallbackDurationS;

  /// The top band, where the beats and the playhead are. It used to be the
  /// continuous track's waveform; today each block draws its own, and what is
  /// left here is the grid.
  static const double waveHeight = 26;
  static const double blockHeight = 72;
  static const double rulerHeight = 20;
  static const double headerWidth = 148;

  static double heightFor(int layerCount) =>
      waveHeight + blockHeight * layerCount + rulerHeight;

  /// Which layer is drawn on track [line], counted from the top down.
  ///
  /// The list of layers goes from the bottom one to the top one — the order
  /// the server draws them in — and the ruler shows the opposite: **the top
  /// track is the top layer**, as in any editor. Without this inversion,
  /// dragging a layer to the top sent it behind all the others.
  static int rowLayer(int line, int howMany) => howMany - 1 - line;

  /// The inverse computation: which track a layer shows on.
  static int layerRow(int layerIndex, int howMany) => howMany - 1 - layerIndex;

  @override
  State<MusicTimeline> createState() => _MusicTimelineState();
}

class _MusicTimelineState extends State<MusicTimeline> {
  /// Automatic scrolling when the finger gets close to the window's edge.
  Timer? _autoScroll;
  double _direction = 0;

  /// Where the outside drag will land: (instant, layer). It is what draws the
  /// rectangle before dropping — dropping blind is what makes dragging feel
  /// worse than clicking.
  (double, int)? _crosshair;
  double _crosshairWidth = kDefaultCutS;

  @override
  void dispose() {
    _autoScroll?.cancel();
    super.dispose();
  }

  double get _durationS {
    var endTime = 0.0;
    for (final l in widget.layers) {
      for (final c in l.clips) {
        endTime = math.max(endTime, c.untilS);
      }
    }
    // some slack at the end, so there is somewhere to drop the last clip
    return math.max(endTime + 4, widget.fallbackDurationS);
  }

  /// Does this block's play fall exactly under the playhead?
  ///
  /// Half a frame of tolerance: aligning is an editing decision, not a
  /// measurement of infinite precision.
  bool _playAtCursor(TimelineClip clip) {
    final mark = momentInVideo(clip);
    return mark != null && (mark - widget.playheadS).abs() < 0.017;
  }

  /// Which layer a point of the ruler falls on — the inverse of the stacking.
  int _layerAt(double dy) {
    final line = ((dy - MusicTimeline.waveHeight) / MusicTimeline.blockHeight)
        .floor();
    return MusicTimeline.rowLayer(
      line.clamp(0, math.max(0, widget.layers.length - 1)),
      widget.layers.length,
    );
  }

  /// Turns auto-scroll on/off according to the finger's global position.
  void _maybeScroll(Offset global) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !widget.scroll.hasClients) return;
    final x = box.globalToLocal(global).dx;
    const marginPx = 48.0;

    final direction = x < MusicTimeline.headerWidth + marginPx
        ? -1.0
        : x > box.size.width - marginPx
        ? 1.0
        : 0.0;
    if (direction == _direction) return;
    _direction = direction;
    _autoScroll?.cancel();
    if (direction == 0) return;

    _autoScroll = Timer.periodic(const Duration(milliseconds: 16), (_) {
      final pos = widget.scroll.position;
      final target = (widget.scroll.offset + direction * 8).clamp(
        0.0,
        pos.maxScrollExtent,
      );
      if (target == widget.scroll.offset) return;
      widget.scroll.jumpTo(target);
    });
  }

  /// Converts the finger's global position into the ruler's (instant, layer).
  (double, int)? _dropPoint(Offset global) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return null;
    final local = box.globalToLocal(global);
    final x =
        local.dx - MusicTimeline.headerWidth + widget.scroll.offset;
    if (x < 0) return null;
    return (math.max(0.0, x / widget.pxPerSecond), _layerAt(local.dy));
  }

  void _stopScrolling() {
    _autoScroll?.cancel();
    _autoScroll = null;
    _direction = 0;
  }

  /// Every visible clip with its layer, the selected ones last.
  List<(int, TimelineClip)> _drawOrder() {
    final rest = <(int, TimelineClip)>[];
    final chosen = <(int, TimelineClip)>[];
    for (var i = 0; i < widget.layers.length; i++) {
      if (widget.layers[i].hidden) continue;
      for (final c in widget.layers[i].clips) {
        (widget.selectionIds.contains(c.id) ? chosen : rest).add((i, c));
      }
    }
    return [...rest, ...chosen];
  }

  /// Where a right click opens a menu: right under the pointer.
  RelativeRect _at(Offset global) {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    return RelativeRect.fromRect(
      global & const Size(1, 1),
      Offset.zero & overlay.size,
    );
  }

  /// The right-click menu of a clip.
  Future<void> _clipMenu(String id, int layerIndex, Offset global) async {
    if (!widget.selectionIds.contains(id)) widget.onSelect(id);
    final layers = widget.layers;
    final locked = layers[layerIndex].locked;
    bool sameKind(int i) =>
        i >= 0 &&
        i < layers.length &&
        layers[i].isAudio == layers[layerIndex].isAudio;
    final choice = await showMenu<String>(
      context: context,
      position: _at(global),
      items: [
        PopupMenuItem(
          value: 'up',
          // a picture above the top layer opens a new one
          enabled:
              !locked &&
              (sameKind(layerIndex + 1) ||
                  (layerIndex + 1 == layers.length &&
                      !layers[layerIndex].isAudio)),
          child: const Text('Move to layer above'),
        ),
        PopupMenuItem(
          value: 'down',
          enabled: !locked && sameKind(layerIndex - 1),
          child: const Text('Move to layer below'),
        ),
        if (widget.onDuplicateClip != null || widget.onDeleteClip != null)
          const PopupMenuDivider(),
        if (widget.onDuplicateClip != null)
          const PopupMenuItem(value: 'duplicate', child: Text('Duplicate')),
        if (widget.onDeleteClip != null)
          PopupMenuItem(
            key: const Key('clip-menu-delete'),
            value: 'delete',
            enabled: !locked,
            child: const Text('Delete'),
          ),
      ],
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'up':
        widget.onChangeLayer(id, layerIndex + 1);
      case 'down':
        widget.onChangeLayer(id, layerIndex - 1);
      case 'duplicate':
        widget.onDuplicateClip!(id);
      case 'delete':
        widget.onDeleteClip!(id);
    }
  }

  /// The right-click menu of a layer — on its header or on its empty track.
  ///
  /// The header buttons stay: the menu is where the rest lives, and where
  /// whoever looks for "delete" with the right button finds it.
  Future<void> _layerMenu(int i, Offset global) async {
    if (i < 0 || i >= widget.layers.length) return;
    widget.onActiveLayer(i);
    final layer = widget.layers[i];
    final top = widget.layers.length - 1;
    final choice = await showMenu<String>(
      context: context,
      position: _at(global),
      items: [
        if (widget.onRenameLayer != null)
          const PopupMenuItem(value: 'rename', child: Text('Rename…')),
        PopupMenuItem(
          value: 'up',
          enabled: i < top,
          child: const Text('Move layer up'),
        ),
        PopupMenuItem(
          value: 'down',
          enabled: i > 0,
          child: const Text('Move layer down'),
        ),
        const PopupMenuDivider(),
        if (!layer.isAudio)
          PopupMenuItem(
            value: 'hide',
            child: Text(layer.hidden ? 'Show' : 'Hide'),
          ),
        PopupMenuItem(
          value: 'mute',
          child: Text(layer.muted ? 'Unmute' : 'Mute'),
        ),
        PopupMenuItem(
          value: 'lock',
          child: Text(layer.locked ? 'Unlock' : 'Lock'),
        ),
        if (widget.onRemoveLayer != null) ...[
          const PopupMenuDivider(),
          PopupMenuItem(
            key: const Key('layer-menu-delete'),
            value: 'delete',
            // the montage always keeps one layer to receive the next clip
            enabled: widget.layers.length > 1,
            child: const Text('Delete layer'),
          ),
        ],
      ],
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'rename':
        final name = await _askName(layer.name);
        if (name != null && name.isNotEmpty) widget.onRenameLayer!(i, name);
      case 'up':
        widget.onReorderLayers(i, i + 1);
      case 'down':
        widget.onReorderLayers(i, i - 1);
      case 'hide':
        widget.onAdjustLayer(i, hidden: !layer.hidden);
      case 'mute':
        widget.onAdjustLayer(i, muted: !layer.muted);
      case 'lock':
        widget.onAdjustLayer(i, locked: !layer.locked);
      case 'delete':
        widget.onRemoveLayer!(i);
    }
  }

  Future<String?> _askName(String current) => showDialog<String>(
    context: context,
    builder: (_) => _RenameDialog(current: current),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final px = widget.pxPerSecond;
    final widthPx = _durationS * px;
    final heightPx = MusicTimeline.heightFor(widget.layers.length);

    return SizedBox(
      height: heightPx,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: MusicTimeline.headerWidth,
            child: _Headers(
              layers: widget.layers,
              active: widget.activeLayer,
              onActive: widget.onActiveLayer,
              onAdjust: widget.onAdjustLayer,
              onReorder: widget.onReorderLayers,
              onMenu: _layerMenu,
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: SingleChildScrollView(
              controller: widget.scroll,
              scrollDirection: Axis.horizontal,
              child: DragTarget<RulerDrop>(
                onWillAcceptWithDetails: (d) {
                  final location = _dropPoint(d.offset);
                  if (location == null) return false;
                  setState(() {
                    _crosshair = location;
                    _crosshairWidth = d.data.durationSecs;
                  });
                  return true;
                },
                onLeave: (_) => setState(() => _crosshair = null),
                onAcceptWithDetails: (d) {
                  final location = _dropPoint(d.offset) ?? _crosshair;
                  setState(() => _crosshair = null);
                  if (location == null) return;
                  widget.onDrop?.call(d.data, location.$1, location.$2);
                },
                builder: (context, _, _) => SizedBox(
                  width: widthPx,
                  height: heightPx,
                  child: Stack(
                    children: [
                      // background: waveform, beats, ruler, start marker and
                      // the lines that separate the tracks
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapDown: (d) {
                            widget.onSeek(d.localPosition.dx / px);
                            widget.onSelect(null);
                          },
                          onSecondaryTapUp: (d) => _layerMenu(
                            _layerAt(d.localPosition.dy),
                            d.globalPosition,
                          ),
                          child: CustomPaint(
                            painter: _RulerPainter(
                              beats: widget.beatTimes,
                              durationS: _durationS,
                              pxPerSecond: px,
                              layerList: widget.layers.length,
                              onColor: theme.colorScheme.primary,
                              waveColor: theme.colorScheme.primary.withValues(
                                alpha: 0.35,
                              ),
                              beatColor: theme.colorScheme.onSurface.withValues(
                                alpha: 0.18,
                              ),
                              textColor: theme.hintColor,
                            ),
                          ),
                        ),
                      ),

                      // the chosen clips are drawn last: the one being
                      // dragged passes over its neighbours, not under them
                      for (final (layerIndex, clip) in _drawOrder())
                        _Block(
                          key: ValueKey('block-${clip.id}'),
                          cut: clip,
                          music: widget.tracks[clip.mediaId],
                          selected: widget.selectionIds.contains(clip.id),
                          isLocked: widget.layers[layerIndex].locked,
                          markAtCursor: _playAtCursor(clip),
                          pxPerSecond: px,
                          left: clip.atS * px,
                          top:
                              MusicTimeline.waveHeight +
                              MusicTimeline.layerRow(
                                    layerIndex,
                                    widget.layers.length,
                                  ) *
                                  MusicTimeline.blockHeight,
                          height: MusicTimeline.blockHeight,
                          onSelect: ({bool toggle = false}) =>
                              widget.onSelect(clip.id, toggle: toggle),
                          onMove: (at) => widget.onMove(clip.id, at),
                          onTrim: (at) => widget.onTrim(clip.id, at),
                          onStretch: (d) => widget.onStretch(clip.id, d),
                          onDragLabel: widget.onDragLabel,
                          wave: widget.matchWaveform,
                          matchDuration: widget.matchDuration,
                          onDragStart: widget.onGestureStart,
                          onDragMove: _maybeScroll,
                          onDragEnd: () {
                            _stopScrolling();
                            widget.onGestureEnd();
                          },
                          // up on screen is up in the stack: the steps
                          // come in tracks, and tracks grow downwards
                          onLetGo: (fromS, atS, steps) => widget
                              .onDropClip(
                                clip.id,
                                fromS,
                                atS,
                                layerIndex - steps,
                              ),
                          onMenu: (global) =>
                              _clipMenu(clip.id, layerIndex, global),
                        ),

                      // where what is being dragged will land
                      if (_crosshair != null)
                        Positioned(
                          left: _crosshair!.$1 * px,
                          top:
                              MusicTimeline.waveHeight +
                              MusicTimeline.layerRow(
                                    _crosshair!.$2,
                                    widget.layers.length,
                                  ) *
                                  MusicTimeline.blockHeight,
                          height: MusicTimeline.blockHeight,
                          width: math.max(2, _crosshairWidth * px),
                          child: IgnorePointer(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primary.withValues(
                                  alpha: 0.25,
                                ),
                                border: Border.all(
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                            ),
                          ),
                        ),

                      // the playhead, last so it stays on top
                      Positioned(
                        left: widget.playheadS * px - 1,
                        top: 0,
                        bottom: 0,
                        width: 2,
                        child: IgnorePointer(
                          child: ColoredBox(color: theme.colorScheme.error),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Asks for a layer's new name. Stateful so the field's controller lives as
/// long as the dialog does — including its closing animation.
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.current});

  final String current;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _field = TextEditingController(text: widget.current);

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _done() => Navigator.pop(context, _field.text.trim());

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Rename layer'),
    content: TextField(
      key: const Key('layer-name'),
      controller: _field,
      autofocus: true,
      onSubmitted: (_) => _done(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _done, child: const Text('Rename')),
    ],
  );
}

/// The column of headers, outside the scroll.
///
/// It stays outside because it is the reference: when the ruler moves,
/// knowing which layer each track is still holds.
class _Headers extends StatefulWidget {
  const _Headers({
    required this.layers,
    required this.active,
    required this.onActive,
    required this.onAdjust,
    required this.onReorder,
    required this.onMenu,
  });

  final List<Layer> layers;
  final int active;

  /// (layer, where the right click happened).
  final void Function(int layerIndex, Offset global) onMenu;
  final ValueChanged<int> onActive;
  final void Function(int layerIndex, {bool? muted, bool? hidden, bool? locked})
  onAdjust;

  /// (from, to) — the layers' new order.
  final void Function(int from, int to) onReorder;

  @override
  State<_Headers> createState() => _HeadersState();
}

class _HeadersState extends State<_Headers> {
  /// Which header the drag is over now, so the target line shows before
  /// dropping.
  int? _target;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final layers = widget.layers;
    return Column(
      children: [
        // the grid band, which belongs to no layer
        SizedBox(
          height: MusicTimeline.waveHeight,
          child: Center(
            child: Text(
              'beats',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.hintColor,
              ),
            ),
          ),
        ),
        // The tracks, **from top to bottom**: the first row is the top layer,
        // as in any editor. Each header can be grabbed — dragging one over
        // another swaps the order in which the server draws the layers, which
        // is what decides who covers whom.
        for (var line = 0; line < layers.length; line++)
          Builder(
            builder: (context) {
              final i = MusicTimeline.rowLayer(line, layers.length);
              return DragTarget<int>(
                onWillAcceptWithDetails: (d) {
                  if (d.data == i) return false;
                  setState(() => _target = i);
                  return true;
                },
                onLeave: (_) => setState(() => _target = null),
                onAcceptWithDetails: (d) {
                  setState(() => _target = null);
                  widget.onReorder(d.data, i);
                },
                builder: (context, _, _) => _Reorderable(
                  index: i,
                  feedback: Material(
                    color: Colors.transparent,
                    child: SizedBox(
                      width: MusicTimeline.headerWidth,
                      height: MusicTimeline.blockHeight,
                      child: Opacity(
                        opacity: 0.9,
                        child: _LayerHeader(
                          layer: layers[i],
                          index: i,
                          active: true,
                          onActive: () {},
                          onAdjust:
                              ({bool? muted, bool? hidden, bool? locked}) {},
                        ),
                      ),
                    ),
                  ),
                  childWhenDragging: SizedBox(
                    height: MusicTimeline.blockHeight,
                    child: ColoredBox(
                      color: theme.colorScheme.primary.withValues(alpha: 0.08),
                    ),
                  ),
                  builder: (handle) => GestureDetector(
                    onSecondaryTapUp: (d) =>
                        widget.onMenu(i, d.globalPosition),
                    child: Container(
                      key: ValueKey('header-$i'),
                      height: MusicTimeline.blockHeight,
                      decoration: _target == i
                          ? BoxDecoration(
                              border: Border.all(
                                color: theme.colorScheme.primary,
                              ),
                            )
                          : null,
                      child: _LayerHeader(
                        layer: layers[i],
                        index: i,
                        active: i == widget.active,
                        handle: handle,
                        onActive: () => widget.onActive(i),
                        onAdjust: ({bool? muted, bool? hidden, bool? locked}) =>
                            widget.onAdjust(
                              i,
                              muted: muted,
                              hidden: hidden,
                              locked: locked,
                            ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}

/// A header that can be dragged — but only by its handle.
///
/// The grip is a real `Draggable` (immediate drag, like any desktop editor),
/// and the rest of the header stays clickable: the hide, mute and lock
/// buttons are there.
class _Reorderable extends StatelessWidget {
  const _Reorderable({
    required this.index,
    required this.feedback,
    required this.childWhenDragging,
    required this.builder,
  });

  final int index;
  final Widget feedback;
  final Widget childWhenDragging;
  final Widget Function(Widget handle) builder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final handle = Draggable<int>(
      data: index,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: feedback,
      childWhenDragging: const SizedBox(width: 20, height: 20),
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: Tooltip(
          message: 'Drag to change the order of the layers',
          child: Icon(Icons.drag_indicator, size: 16, color: theme.hintColor),
        ),
      ),
    );
    // The whole header also comes out on long press: on a phone there is no
    // pointer to aim at a 16px handle. A drag starting on the handle is
    // claimed by the inner `Draggable`, which is deeper in the tree.
    return LongPressDraggable<int>(
      data: index,
      delay: const Duration(milliseconds: 300),
      feedback: feedback,
      childWhenDragging: childWhenDragging,
      child: builder(handle),
    );
  }
}

class _LayerHeader extends StatelessWidget {
  const _LayerHeader({
    required this.layer,
    required this.index,
    required this.active,
    required this.onActive,
    required this.onAdjust,
    this.handle,
  });

  final Layer layer;
  final int index;
  final bool active;
  final VoidCallback onActive;
  final void Function({bool? muted, bool? hidden, bool? locked}) onAdjust;

  /// The grip by which the layer is dragged to another position in the stack.
  ///
  /// A handle, and not the whole header: it has buttons inside, and a drag
  /// starting anywhere on it would fight each of them.
  final Widget? handle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onActive,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: active
              ? theme.colorScheme.primary.withValues(alpha: 0.10)
              : null,
          border: Border(
            top: BorderSide(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.12),
            ),
            left: BorderSide(
              width: 3,
              color: active ? theme.colorScheme.primary : Colors.transparent,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              children: [
                Icon(
                  layer.isAudio ? Icons.music_note : Icons.layers,
                  size: 13,
                  color: theme.hintColor,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    layer.name.isEmpty ? 'Layer ${index + 1}' : layer.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium,
                  ),
                ),
                ?handle,
              ],
            ),
            Row(
              children: [
                // hiding a layer that draws nothing means nothing; what is
                // wanted from it is mute
                if (!layer.isAudio)
                  _Toggle(
                    turnedOn: !layer.hidden,
                    isOn: Icons.visibility,
                    off: Icons.visibility_off,
                    hint: layer.hidden ? 'show' : 'hide',
                    onTap: () => onAdjust(hidden: !layer.hidden),
                  ),
                _Toggle(
                  turnedOn: !layer.muted,
                  isOn: Icons.volume_up,
                  off: Icons.volume_off,
                  hint: layer.muted ? 'unmute' : 'mute',
                  onTap: () => onAdjust(muted: !layer.muted),
                ),
                _Toggle(
                  turnedOn: !layer.locked,
                  isOn: Icons.lock_open,
                  off: Icons.lock,
                  hint: layer.locked ? 'unlock' : 'lock',
                  onTap: () => onAdjust(locked: !layer.locked),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.turnedOn,
    required this.isOn,
    required this.off,
    required this.hint,
    required this.onTap,
  });

  final bool turnedOn;
  final IconData isOn;
  final IconData off;
  final String hint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return IconButton(
      tooltip: hint,
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 26, minHeight: 24),
      iconSize: 15,
      icon: Icon(
        turnedOn ? isOn : off,
        color: turnedOn ? theme.hintColor : theme.colorScheme.error,
      ),
    );
  }
}

/// A block on the ruler, with the four gestures.
///
/// It is `Stateful` because of a trap that made dragging simply **not work**:
/// applying `delta.dx` frame by frame, each 3px step became 0.05 s and the
/// magnet snapped back to the same beat — the block only moved with a flick
/// strong enough to beat the tolerance in a single frame. Now the gesture
/// keeps where it started and accumulates the whole offset, so the magnet
/// decides on the drag's intent, not on one pixel.
class _Block extends StatefulWidget {
  const _Block({
    super.key,
    required this.cut,
    required this.music,
    required this.selected,
    required this.isLocked,
    required this.markAtCursor,
    required this.pxPerSecond,
    required this.left,
    required this.top,
    required this.height,
    required this.onSelect,
    required this.onMove,
    required this.onTrim,
    required this.onStretch,
    required this.onDragLabel,
    required this.wave,
    required this.matchDuration,
    required this.onDragStart,
    required this.onDragMove,
    required this.onDragEnd,
    required this.onLetGo,
    required this.onMenu,
  });

  final TimelineClip cut;

  /// The music of this block, when it is a music block. It is where the drawn
  /// waveform and the written name come from.
  final Track? music;

  final bool selected;

  /// Locked layer: the clip can still be chosen, but not dragged.
  final bool isLocked;

  /// Is this block's play under the playhead?
  final bool markAtCursor;

  final double pxPerSecond;
  final double left;
  final double top;
  final double height;
  final void Function({bool toggle}) onSelect;
  final ValueChanged<double> onMove;
  final ValueChanged<double> onTrim;
  final ValueChanged<double> onStretch;
  final ValueChanged<String?>? onDragLabel;
  final List<double> wave;
  final double matchDuration;
  final VoidCallback onDragStart;
  final ValueChanged<Offset> onDragMove;
  final VoidCallback onDragEnd;

  /// (where the drag started, where it was let go, how many tracks up —
  /// negative — or down).
  final void Function(double fromS, double atS, int steps) onLetGo;

  /// A right click, with where it happened.
  final ValueChanged<Offset> onMenu;

  /// Resize handle. 26px because the target is a finger, not a mouse — below
  /// that the person misses and moves the block when they meant to stretch it.
  static const double handle = 26;

  @override
  State<_Block> createState() => _BlockState();
}

enum _Gesture { move, trimLeft, stretchRight }

class _BlockState extends State<_Block> {
  /// Value at the start of the gesture and the offset accumulated since.
  double _startedAt = 0;
  double _moved = 0;

  /// How far the finger went up or down, to know which track to drop on.
  double _rose = 0;

  void _begin(_Gesture gesture) {
    // dragging a block that is already in a multiple selection must not break
    // it up
    if (!widget.selected) widget.onSelect();
    widget.onDragStart();
    _moved = 0;
    _startedAt = switch (gesture) {
      _Gesture.move => widget.cut.atS,
      _Gesture.trimLeft => widget.cut.atS,
      _Gesture.stretchRight => widget.cut.durationS,
    };
  }

  void _advance(_Gesture gesture, DragUpdateDetails d) {
    _moved += d.delta.dx / widget.pxPerSecond;
    final target = _startedAt + _moved;
    switch (gesture) {
      case _Gesture.move:
        widget.onMove(target);
      case _Gesture.trimLeft:
        widget.onTrim(target);
      case _Gesture.stretchRight:
        widget.onStretch(target);
    }
    widget.onDragMove(d.globalPosition);
    widget.onDragLabel?.call(_label(gesture));
  }

  String _label(_Gesture gesture) => switch (gesture) {
    _Gesture.move => [
      'starts at ${formatClock(widget.cut.atS)} of the video',
      if (_steps < 0) '${-_steps} layer(s) up',
      if (_steps > 0) '$_steps layer(s) down',
    ].join(' · '),
    _ => '${widget.cut.durationS.toStringAsFixed(2)}s',
  };

  /// Where the finger was when the move was accepted.
  Offset _anchor = Offset.zero;

  /// Is a move under way? While it is, the clip is drawn where the finger is
  /// even when the montage could not follow — that is how it passes over a
  /// neighbour to swap with it.
  bool _moving = false;

  void _grab(DragStartDetails d) {
    _anchor = d.globalPosition;
    _rose = 0;
    _moving = true;
    _begin(_Gesture.move);
  }

  /// Both axes from the anchor — the recogniser's own delta only carries the
  /// axis it was built for.
  void _follow(DragUpdateDetails d) {
    final offset = d.globalPosition - _anchor;
    setState(() => _rose = offset.dy);
    _moved = offset.dx / widget.pxPerSecond;
    widget.onMove(_startedAt + _moved);
    widget.onDragMove(d.globalPosition);
    widget.onDragLabel?.call(_label(_Gesture.move));
  }

  /// How many tracks the finger is away from the clip's own — negative is up.
  int get _steps => (_rose / widget.height).round();

  /// Lets go of a move. Where it lands — another track, a swap — is decided
  /// **inside** the same gesture, so one undo takes back the whole drag.
  void _drop() {
    if (_moving) {
      final steps = _steps;
      setState(() {
        _rose = 0;
        _moving = false;
      });
      widget.onLetGo(_startedAt, _startedAt + _moved, steps);
    }
    _release();
  }

  /// Where to draw the clip: the montage's position, unless a move is under
  /// way and the montage could not follow the finger — then, the finger's.
  /// The magnet's pull stays visible: a snap is within its tolerance.
  double get _left {
    if (!_moving) return widget.left;
    final wanted = math.max(0.0, _startedAt + _moved);
    return (widget.cut.atS - wanted).abs() <= kSnapToleranceS + 1e-6
        ? widget.left
        : wanted * widget.pxPerSecond;
  }

  void _release() {
    widget.onDragLabel?.call(null);
    widget.onDragEnd();
  }

  /// Shift-click adds to the selection; a plain click replaces it.
  void _play() =>
      widget.onSelect(toggle: HardwareKeyboard.instance.isShiftPressed);

  /// The handles only show on the chosen block: on a 1 s block at 60 px/s, two
  /// 26 px handles would leave nowhere to grab to move it.
  Widget _handle(_Gesture gesture, Color fillColour, {required bool leftEdge}) => Positioned(
    left: leftEdge ? 0 : null,
    right: leftEdge ? null : 0,
    top: 0,
    bottom: 0,
    width: _Block.handle,
    child: MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) => _begin(gesture),
        onHorizontalDragUpdate: (d) => _advance(gesture, d),
        onHorizontalDragEnd: (_) => _release(),
        onHorizontalDragCancel: _release,
        child: Center(
          child: Container(
            width: 4,
            height: 26,
            decoration: BoxDecoration(
              color: fillColour,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    ),
  );

  double? get _mark => momentMark(widget.cut);

  /// (the waveform to draw, how much time it covers).
  ///
  /// A music block shows the **music's** waveform; a cut, the match audio's.
  /// In both cases the drawing is a slice of the whole waveform, so trimming
  /// the block changes what shows without recomputing anything.
  (List<double>, double) get _waveform {
    final m = widget.music;
    if (m != null) return (m.peaks, m.durationS);
    return (widget.wave, widget.matchDuration);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final music = widget.music;
    final style = EventStyle.of(widget.cut.kind);
    // a music block is not a match moment: it has the track's colour, which
    // is the same as the waveform drawn at the top of the ruler
    final fillColour = music != null ? theme.colorScheme.primary : style.color;
    final blockLabel = music?.name ?? style.label;
    final widthPx = math.max(10.0, widget.cut.durationS * widget.pxPerSecond);
    final textFits = widthPx > 56;

    return Positioned(
      left: _left,
      // the clip follows the finger between tracks, so where it will land is
      // visible before letting go
      top: widget.top + _rose,
      width: widthPx,
      height: widget.height,
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _play,
          onSecondaryTapUp: (d) => widget.onMenu(d.globalPosition),
          // Whichever axis the drag starts on, it follows the finger on both:
          // sideways moves the clip in time, up or down takes it to another
          // track. Following only the starting axis meant a drag that began
          // sideways could never change layer. Two recognisers and not one pan
          // because the ruler scrolls sideways too, and on touch a pan loses
          // that race.
          onHorizontalDragStart: widget.isLocked ? null : _grab,
          onHorizontalDragUpdate: widget.isLocked ? null : _follow,
          onHorizontalDragEnd: widget.isLocked ? null : (_) => _drop(),
          onHorizontalDragCancel: widget.isLocked ? null : _drop,
          onVerticalDragStart: widget.isLocked ? null : _grab,
          onVerticalDragUpdate: widget.isLocked ? null : _follow,
          onVerticalDragEnd: widget.isLocked ? null : (_) => _drop(),
          onVerticalDragCancel: widget.isLocked ? null : _drop,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            decoration: BoxDecoration(
              color: fillColour.withValues(alpha: widget.selected ? 0.45 : 0.25),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: widget.selected ? theme.colorScheme.onSurface : fillColour,
                width: widget.selected ? 2 : 1,
              ),
            ),
            child: Stack(
              children: [
                // ── the game sound inside this cut ──────────────────────────
                if (_waveform.$1.isNotEmpty && _waveform.$2 > 0)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: _CutWaveform(
                          wave: _waveform.$1,
                          totalDuration: _waveform.$2,
                          from: widget.cut.startS,
                          until: widget.cut.endS,
                          fillColour: fillColour.withValues(alpha: 0.55),
                        ),
                      ),
                    ),
                  ),

                // ── the entrance, when it is not a hard cut ────────────────
                // As long as it lasts: it is the part of the clip where the
                // previous one still shows, and fitting it to the beat means
                // seeing it.
                if (widget.cut.transition case final tr?)
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: math.min(widthPx, tr.durationS * widget.pxPerSecond),
                    child: IgnorePointer(
                      child: Container(
                        key: ValueKey('transition-on-clip-${widget.cut.id}'),
                        alignment: Alignment.topLeft,
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          borderRadius: const BorderRadius.horizontal(
                            left: Radius.circular(6),
                          ),
                          gradient: LinearGradient(
                            colors: [
                              theme.colorScheme.onSurface.withValues(
                                alpha: 0.45,
                              ),
                              theme.colorScheme.onSurface.withValues(alpha: 0),
                            ],
                          ),
                        ),
                        child: Icon(
                          TransitionType.of(tr.kind)?.icon ??
                              Icons.compare_arrows,
                          size: 12,
                          color: theme.colorScheme.surface,
                        ),
                      ),
                    ),
                  ),

                // ── where the play happens ──────────────────────────────────
                // The block is a stretch; the moment is an instant inside it.
                // Without this mark, fitting the kill to the beat would be
                // guessing: what lines up with the percussion is the play, not
                // the cut's edge.
                if (_mark != null)
                  Positioned(
                    left: _mark! * widthPx - (widget.markAtCursor ? 1.5 : 1),
                    top: 0,
                    bottom: 0,
                    width: widget.markAtCursor ? 3 : 2,
                    child: IgnorePointer(
                      child: ColoredBox(
                        // lit when the play is exactly under the playhead: it
                        // is the confirmation that the fit took
                        color: widget.markAtCursor
                            ? theme.colorScheme.error
                            : theme.colorScheme.onSurface.withValues(
                                alpha: 0.85,
                              ),
                      ),
                    ),
                  ),
                if (_mark != null)
                  Positioned(
                    left: _mark! * widthPx - 4,
                    top: 0,
                    child: IgnorePointer(
                      child: Icon(
                        Icons.arrow_drop_down,
                        size: widget.markAtCursor ? 14 : 12,
                        color: widget.markAtCursor
                            ? theme.colorScheme.error
                            : theme.colorScheme.onSurface,
                      ),
                    ),
                  ),
                if (textFits)
                  Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: widget.selected ? _Block.handle : 6,
                      vertical: 4,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          blockLabel,
                          maxLines: 1,
                          overflow: TextOverflow.clip,
                          softWrap: false,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: fillColour,
                          ),
                        ),
                        Text(
                          '${widget.cut.durationS.toStringAsFixed(1)}s',
                          maxLines: 1,
                          softWrap: false,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.hintColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (widget.selected && !widget.isLocked) ...[
                  _handle(_Gesture.trimLeft, fillColour, leftEdge: true),
                  _handle(_Gesture.stretchRight, fillColour, leftEdge: false),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The match audio's waveform over the piece this block shows.
///
/// It slices the whole match's waveform instead of storing one per block:
/// trimming or stretching the cut changes the drawn piece by itself, without
/// recomputing anything.
class _CutWaveform extends CustomPainter {
  _CutWaveform({
    required this.wave,
    required this.totalDuration,
    required this.from,
    required this.until,
    required this.fillColour,
  });

  final List<double> wave;
  final double totalDuration;
  final double from;
  final double until;
  final Color fillColour;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 2 || until <= from) return;
    final middle = size.height / 2;
    final brush = Paint()
      ..color = fillColour
      ..strokeWidth = 1;

    for (var x = 0.0; x < size.width; x += 1) {
      final t = from + (until - from) * (x / size.width);
      final i = (t / totalDuration * wave.length).floor();
      if (i < 0 || i >= wave.length) continue;
      final h = wave[i] * (middle - 3);
      canvas.drawLine(Offset(x, middle - h), Offset(x, middle + h), brush);
    }
  }

  @override
  bool shouldRepaint(_CutWaveform old) =>
      old.from != from || old.until != until || old.wave != wave;
}

class _RulerPainter extends CustomPainter {
  _RulerPainter({
    required this.beats,
    required this.durationS,
    required this.pxPerSecond,
    required this.layerList,
    required this.onColor,
    required this.waveColor,
    required this.beatColor,
    required this.textColor,
  });

  /// The grid in video time — the same the magnet uses.
  final List<double> beats;
  final double durationS;
  final double pxPerSecond;
  final int layerList;
  final Color onColor;
  final Color waveColor;
  final Color beatColor;
  final Color textColor;

  @override
  void paint(Canvas canvas, Size size) {
    // ── beats ──────────────────────────────────────────────────────────────
    // They cross the whole height: they are what blocks on any layer are
    // aligned by, and a line that dies at the top band does not help whoever
    // is fitting the cut three tracks below.
    //
    // With the music zoomed far out the beats end up 2px apart and become a
    // grey smear; then one every N is drawn so they stay readable.
    if (beats.length >= 2) {
      final gap = (beats[1] - beats[0]) * pxPerSecond;
      final step = gap < 6 ? (6 / math.max(gap, 0.5)).ceil() : 1;
      final brush = Paint()
        ..color = beatColor
        ..strokeWidth = 1;
      for (var i = 0; i < beats.length; i += step) {
        final x = beats[i] * pxPerSecond;
        if (x > size.width) break;
        canvas.drawLine(
          Offset(x, 0),
          Offset(x, size.height - MusicTimeline.rulerHeight),
          brush,
        );
      }
    }

    // ── dividers between the tracks ─────────────────────────────────────────
    final line = Paint()
      ..color = beatColor
      ..strokeWidth = 1;
    for (var i = 0; i <= layerList; i++) {
      final y = MusicTimeline.waveHeight + i * MusicTimeline.blockHeight;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
    }

    // ── time ruler ─────────────────────────────────────────────────────────
    final stepS = _rulerStep();
    final rulerBrush = Paint()
      ..color = beatColor
      ..strokeWidth = 1;
    final rulerTop = size.height - MusicTimeline.rulerHeight;
    for (var s = 0.0; s <= durationS; s += stepS) {
      final x = s * pxPerSecond;
      canvas.drawLine(
        Offset(x, rulerTop),
        Offset(x, rulerTop + 5),
        rulerBrush,
      );
      final textValue = TextPainter(
        text: TextSpan(
          text: _clock(s),
          style: TextStyle(color: textColor, fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      textValue.paint(canvas, Offset(x + 3, rulerTop + 5));
    }

    // ── the first frame ────────────────────────────────────────────────────
    // The ruler starts at the start of the video, and the mark says so
    // without relying on the user remembering that zero is zero.
    canvas.drawLine(
      Offset(0, 0),
      Offset(0, size.height),
      Paint()
        ..color = onColor
        ..strokeWidth = 2,
    );
  }

  /// How often the ruler gets a number, so the labels do not run over each
  /// other at any zoom.
  double _rulerStep() {
    for (final step in const [1.0, 2.0, 5.0, 10.0, 15.0, 30.0, 60.0]) {
      if (step * pxPerSecond >= 56) return step;
    }
    return 120;
  }

  static String _clock(double s) {
    final t = s.round();
    return '${t ~/ 60}:${(t % 60).toString().padLeft(2, '0')}';
  }

  @override
  bool shouldRepaint(_RulerPainter old) =>
      old.beats != beats ||
      old.pxPerSecond != pxPerSecond ||
      old.durationS != durationS ||
      old.layerList != layerList;
}
