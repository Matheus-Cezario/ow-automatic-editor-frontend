import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../api.dart';
import '../montage.dart';
import '../export_options.dart';
import '../fullscreen.dart';
import '../fonts.dart';
import '../montage_state.dart';
import '../recipe.dart';
import '../labels.dart';
import '../widgets/exact_preview.dart';
import '../widgets/highlight_style.dart';
import '../widgets/moment_preview.dart';
import '../widgets/motion_panel.dart';
import '../widgets/music_timeline.dart';
import '../monitor/frame.dart';
import '../widgets/preview_player.dart';
import '../widgets/blend_panel.dart';
import '../widgets/crop_panel.dart';
import '../widgets/fx_panel.dart';
import '../widgets/source_cutter.dart';
import '../zoom.dart';

/// Building the video by hand: listening to the song and placing each moment
/// wherever you want.
///
/// It is the other half of the system. The analysis says *when* each thing
/// happened — kill, sleep dart, stun — and stops there; here the user decides
/// which ones go in, at which point of the song each lands and how long it lasts.
///
/// The song goes up before any video exists, precisely because none of this
/// can be decided without hearing it. What the screen draws — waveform, beats,
/// duration — comes from the server along with it.
///
/// On top sits the monitor: it opens the original recording and seeks the
/// instant the playhead asks for, so you can see the cut before rendering.
/// Nothing is rendered while editing.
class TimelineScreen extends StatefulWidget {
  const TimelineScreen({super.key, required this.job});

  final Job job;

  @override
  State<TimelineScreen> createState() => _TimelineScreenState();
}

/// Events worth a block. `death` and `low_hp` are left out: they are the
/// context that makes a play worth it, not the play.
///
/// `headshot` and `ability_kill` are in because they are exactly what you look
/// for in a montage — the headshot and the ability kill are the play, not its
/// context. They were left out while the editor was only a plan B for the
/// automatic generation, and the result was the worst of both worlds: the
/// detector found the moments, the proposal list announced them, and whoever
/// opened the manual montage could not find them anywhere.
///
/// This list has to match `THUMB_KINDS` on the server: it decides which
/// instants get a thumbnail extracted. A kind here that is missing there
/// becomes a card without a frame.
const _usefulMoments = {
  'kill',
  'headshot',
  'ability_kill',
  'sleep',
  'stun',
  'ult_negated',
  'escape',
};

class _TimelineScreenState extends State<TimelineScreen> {
  final _api = ApiClient();

  /// The server's text fonts, loaded as they are needed.
  late final FontLibrary _fonts = FontLibrary(_api)
    ..addListener(() {
      if (mounted) setState(() {});
    });

  /// The exact preview asked of the server: on its way, done, or failed.
  ExactPreview? _exact;

  /// Is the finished preview playing over the monitor?
  bool _exactOpen = false;

  /// The montage as it was sent, to tell when the preview no longer shows it.
  String? _exactPayload;
  Timer? _exactPoll;
  final _scroll = ScrollController();
  final _title = TextEditingController(text: 'My montage');

  /// The montage and everything that came before it.
  ///
  /// Every edit goes through here — it is what makes undo possible, and it is
  /// why the screen no longer keeps any list of blocks on its own.
  late final MontageHistory _history = MontageHistory(MontageState.blank());
  MontageState get _state => _history.present;

  /// What was copied, waiting for a Ctrl+V.
  List<TimelineClip> _clipboard = const [];

  /// Which of the copied clips came from a sound layer — a clip does not know
  /// it is music, its layer does, and pasting must put it back on one.
  Set<String> _clipboardAudio = const {};

  /// The clip whose effects were copied, as it was then — "Paste effects"
  /// puts its look on other clips.
  TimelineClip? _effectsFrom;

  /// The match media library. It starts with what came from the server and
  /// grows as the user brings files.
  late List<Media> _library = [...widget.job.media];
  bool _importing = false;
  String? _importError;

  /// The player of the song playing right now — the one of the block under the
  /// playhead, and no other. Switching tracks costs network, so it only
  /// switches when the block switches.
  VideoPlayerController? _audio;
  String? _audioDe;
  String? _blockInPlayer;
  bool _adjustingAudio = false;
  String? _musicError;

  /// Is someone typing in a field right now? Kept in state, because the answer
  /// changes the set of registered shortcuts — and that requires rebuilding
  /// the screen.
  bool _typing = false;

  /// The montage focus. Shortcuts apply from it — and focus goes back to it
  /// as soon as someone touches the timeline.
  final FocusNode _focus = FocusNode(debugLabel: 'montage');

  /// The video clock. Null when stopped — it is what tells whether it is
  /// playing.
  Timer? _clock;

  /// Timeline zoom. 60 px/s shows about 10 seconds on a phone — close enough
  /// to snap to the beat without needing a surgeon's precision.
  double _px = 60;

  /// How tall an open track is on the ruler — see [MusicTimeline.trackHeights].
  double _trackHeight = MusicTimeline.blockHeight;

  /// Playback loops: inside the in/out range when there is one, over the
  /// whole video when not.
  bool _loop = false;

  /// The monitor over the whole window (and the screen, if the browser lets).
  bool _fullscreen = false;

  /// Is the right-hand settings sidebar open (on a wide screen)?
  bool _settingsOpen = true;

  /// Framing guides over the monitor — see [MonitorGuide].
  Set<MonitorGuide> _guides = const {};
  final _monitorKey = GlobalKey(debugLabel: 'monitor');
  void Function()? _stopFullscreenWatch;
  bool _magnet = true;

  /// Insert mode: a clip dropped on others pushes them right instead of going
  /// to the first free spot.
  bool _insert = false;

  /// The magnet's guide line: the edge or playhead the dragged clip is stuck
  /// to, in video seconds; `null` when it is stuck to none.
  double? _snapGuide;
  double _cursor = 0;

  /// What the finger is doing right now, so the screen can say in numbers
  /// what the drag is doing in pixels.
  String? _dragLabel;

  /// The text clip being typed on the monitor itself, if any.
  String? _editingTextId;

  /// The duration the next transition gets. It lives on the screen, not on the
  /// clip, so applying the same transition to several cuts needs no
  /// adjustment on each one.
  double _transitionDuration = 0.5;

  /// Monitor height, draggable by the handle below it.
  double _monitorH = 200;

  /// Autosave state, so the screen can say the work is saved.
  /// The montages of this match, and which one is on screen.
  ///
  /// A match yields more than one video — the vertical cut and the long
  /// montage are different jobs on the same material.
  late List<SavedMontage> _montages = [...widget.job.montages];
  String? _montageId;

  Timer? _debounce;
  bool _saving = false;
  DateTime? _savedAt;
  String? _saveError;

  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_fonts.start());
    // the most recent one is the one being edited -- and the one you want back
    final present = _montages.firstOrNull;
    final draft = present?.montage ?? widget.job.draft;
    _montageId = present?.id;
    if (draft != null) {
      // there was a montage in progress: pick up where it stopped. The song,
      // if any, is in its blocks -- there is no track to resume
      _history.replace(montageFromDraft(draft));
      if (draft.title.isNotEmpty) _title.text = draft.title;
    } else {
      _history.replace(_state.copyWith(title: _title.text));
    }
    // jobs analysed before thumbnails existed have none; asking is cheap and
    // the service skips what is already there
    _api.requestFrames(widget.job.id).ignore();
    FocusManager.instance.addListener(_checkFocus);
    // Esc belongs to the browser in full screen: when it leaves, so do we
    _stopFullscreenWatch = onFullscreenExit(() {
      if (mounted && _fullscreen) setState(() => _fullscreen = false);
    });
  }

  /// Is someone typing in a field?
  ///
  /// The primary focus of a `TextField` sits in a `Focus` **inside** the
  /// `EditableText`, not on it; that is why the lookup is by ancestor state.
  bool get _someoneTyping {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    return ctx.findAncestorStateOfType<EditableTextState>() != null;
  }

  void _checkFocus() {
    final nowS = _someoneTyping;
    if (nowS != _typing && mounted) {
      setState(() => _typing = nowS);
    }
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_checkFocus);
    _stopFullscreenWatch?.call();
    _focus.dispose();
    _debounce?.cancel();
    _clock?.cancel();
    _exactPoll?.cancel();
    _audio?.dispose();
    _scroll.dispose();
    _title.dispose();
    super.dispose();
  }

  // ── editing ───────────────────────────────────────────────────────────────

  /// Applies an edit: it becomes the new state, goes into history and schedules a save.
  void _edit(MontageState updated) {
    if (identical(updated, _state)) return;
    setState(() => _history.apply(updated));
    _scheduleSave();
  }

  /// The monitor. The same widget, by its key, moves between the editor and
  /// full screen, so the player is not rebuilt — the picture does not go
  /// black and reload on the way.
  Widget _monitorView() => KeyedSubtree(
    key: _monitorKey,
    child: _withExact(PreviewPlayer(
                // the proxy when there is one; for old matches, the recording
                videoUrl: widget.job.monitorUrl,
                layers: _state.layers,
                cuts: _state.visibleClips,
                library: {for (final m in _library) m.id: m},
                export: _state.export,
                aspectRatio: frameAspect(
                  _state.export,
                  width: widget.job.width,
                  height: widget.job.height,
                ),
                atS: _cursor,
                playing: _playing,
                // the text is drawn over the picture, and dragging it there is
                // how you decide where it goes: the alternative was typing two
                // numbers and rendering the video to check
                texts: _visibleTexts,
                selectionIds: _state.selectionIds,
                onSelectText: _select,
                onMoveText: (id, x, y) =>
                    _edit(positionOnFrame(_state, id, x: x, y: y)),
                onDragging: (t) => setState(() => _dragLabel = t),
                editingId: _editingTextId,
                onEditing: _typeOnFrame,
                onTextChanged: (id, v) =>
                    _edit(changeText(_state, id, textValue: v)),
                onGestureStart: _history.startGesture,
                onGestureEnd: _history.endGesture,
                fontFamily: _fonts.familyFor,
                guides: _guides,
              )),
  );

  /// In the monitor's corner: the in/out range, looping and full screen —
  /// how the picture is watched, next to the picture.
  Widget _playbackControls() {
    final theme = Theme.of(context);
    final range = _range;
    return Material(
      color: theme.colorScheme.surface.withValues(alpha: 0.85),
      borderRadius: BorderRadius.circular(8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (range != null)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: InputChip(
                key: const Key('range-chip'),
                visualDensity: VisualDensity.compact,
                avatar: const Icon(Icons.straighten, size: 16),
                label: Text(
                  '${formatClock(range.from)} – ${formatClock(range.to)}',
                ),
                tooltip:
                    'In and out points (I / O): what loops and what is '
                    'exported. Click to go to the in point',
                onPressed: () => _goTo(range.from),
                onDeleted: _clearRange,
                deleteButtonTooltipMessage: 'Clear (Alt+X)',
              ),
            ),
          IconButton(
            key: const Key('loop'),
            visualDensity: VisualDensity.compact,
            tooltip: _loop
                ? 'Looping ${range == null ? 'the whole video' : 'the in/out range'} (Shift+L)'
                : 'Loop playback (Shift+L)',
            isSelected: _loop,
            onPressed: () => setState(() => _loop = !_loop),
            icon: const Icon(Icons.repeat),
            selectedIcon: Icon(Icons.repeat_on, color: theme.colorScheme.primary),
          ),
          PopupMenuButton<MonitorGuide>(
            key: const Key('guides'),
            tooltip: 'Framing guides',
            icon: Icon(
              Icons.grid_4x4,
              color: _guides.isEmpty ? null : theme.colorScheme.primary,
            ),
            onSelected: (g) => setState(() {
              _guides = _guides.contains(g)
                  ? ({..._guides}..remove(g))
                  : {..._guides, g};
            }),
            itemBuilder: (_) => [
              for (final g in MonitorGuide.values)
                CheckedPopupMenuItem(
                  key: ValueKey('guide-${g.name}'),
                  value: g,
                  checked: _guides.contains(g),
                  child: Text(g.label),
                ),
            ],
          ),
          IconButton(
            key: const Key('fullscreen'),
            visualDensity: VisualDensity.compact,
            tooltip: 'Full screen (F)',
            onPressed: () => _setFullscreen(true),
            icon: const Icon(Icons.fullscreen),
          ),
        ],
      ),
    );
  }

  Future<void> _setFullscreen(bool on) async {
    if (on == _fullscreen) return;
    setState(() => _fullscreen = on);
    if (on) {
      await enterFullscreen();
    } else {
      await exitFullscreen();
    }
  }

  /// Full screen: the monitor over everything, and a bar to drive it.
  Widget _fullscreenLayer() {
    final theme = Theme.of(context);
    const light = Colors.white;
    return Material(
      key: const Key('fullscreen-layer'),
      color: Colors.black,
      child: SafeArea(
        child: Column(
          children: [
            Expanded(child: Center(child: _monitorView())),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Row(
                children: [
                  IconButton(
                    tooltip: _playing ? 'Pause (Space)' : 'Play (Space)',
                    onPressed: _state.isBlank ? null : _togglePlay,
                    icon: Icon(
                      _playing ? Icons.pause : Icons.play_arrow,
                      color: light,
                    ),
                  ),
                  Text(
                    '${formatClock(_cursor)} / '
                    '${formatClock(videoDuration(_state.clips))}',
                    style: theme.textTheme.titleSmall?.copyWith(color: light),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Loop playback (Shift+L)',
                    isSelected: _loop,
                    onPressed: () => setState(() => _loop = !_loop),
                    icon: const Icon(Icons.repeat, color: Colors.white54),
                    selectedIcon: const Icon(Icons.repeat_on, color: light),
                  ),
                  if (_range case final r?)
                    Text(
                      'in/out ${formatClock(r.from)} – ${formatClock(r.to)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.white70,
                      ),
                    ),
                  Expanded(
                    child: Slider(
                      value: _cursor
                          .clamp(0.0, math.max(0.001, videoDuration(_state.clips)))
                          .toDouble(),
                      max: math.max(0.001, videoDuration(_state.clips)),
                      onChanged: (v) => _goTo(v, reveal: false),
                    ),
                  ),
                  IconButton(
                    key: const Key('exit-fullscreen'),
                    tooltip: 'Leave full screen (Esc or F)',
                    onPressed: () => _setFullscreen(false),
                    icon: const Icon(Icons.fullscreen_exit, color: light),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The in/out range on the ruler, resolved — `null` when there is none.
  ({double from, double to})? get _range {
    if (!hasRange(_state.export)) return null;
    final t = stretchOf(_state.export, videoDuration(_state.clips));
    return (from: t.startTime, to: t.endTime);
  }

  /// What playback goes round, when looping.
  ({double from, double to})? get _loopSpan {
    if (!_loop) return null;
    final end = videoDuration(_state.clips);
    if (end <= 0) return null;
    return _range ?? (from: 0.0, to: end);
  }

  void _markIn() => _edit(setRangeIn(_state, _cursor));
  void _markOut() => _edit(setRangeOut(_state, _cursor));
  void _clearRange() => _edit(exportAll(_state));

  /// A marker at the playhead, or away with the one already there.
  void _toggleMarker() => _edit(toggleMarker(_state, _cursor));

  /// Changes the state **without** creating an undo step — selection and
  /// title, which are not edits of the video.
  void _withoutHistory(MontageState updated) {
    setState(() => _history.replace(updated));
  }

  void _undo() {
    if (!_history.canUndo) return;
    setState(_history.undo);
    _syncTitle();
    _scheduleSave();
  }

  void _redo() {
    if (!_history.canRedo) return;
    setState(_history.redo);
    _syncTitle();
    _scheduleSave();
  }

  void _syncTitle() {
    if (_title.text != _state.title) _title.text = _state.title;
  }

  void _select(String? id, {bool toggle = false}) {
    if (id == null) {
      _withoutHistory(_state.copyWith(selectionIds: const {}));
      return;
    }
    final fresh = <String>{..._state.selectionIds};
    if (toggle) {
      // shift-click removes what was already in, so the same gesture does and undoes
      if (!fresh.remove(id)) fresh.add(id);
    } else {
      fresh
        ..clear()
        ..add(id);
    }
    _withoutHistory(_state.copyWith(selectionIds: fresh));
  }

  // ── block operations ──────────────────────────────────────────────────────

  void _add(DetectionEvent e) {
    _edit(
      addClip(
        _state,
        cutForMoment(
          e,
          atS: _cursor,
          beats: _beats,
          sourceDurationS: widget.job.durationS,
        ),
        beats: _beats,
        snap: _magnet,
        insert: _insert,
      ),
    );
  }

  /// What the magnet pulls the clip [id] toward: beats, the other clips'
  /// edges and the playhead.
  List<double> _magnetFor(String id) => magnetPoints(
    _state,
    moving: {id},
    beats: _beats,
    playheadS: _cursor,
  );

  /// After a snapping gesture, the guide line at the edge or playhead the
  /// clip stuck to — while the gesture lasts.
  void _guideFor(String id) {
    final at = _magnet ? stuckTo(_state, id, playheadS: _cursor) : null;
    if (at != _snapGuide) setState(() => _snapGuide = at);
  }

  /// Is [id] one of several selected clips? Then a drag on it carries them all.
  bool _inGroup(String id) =>
      _state.selectionIds.length > 1 && _state.selectionIds.contains(id);

  void _move(String id, double atS) {
    if (_inGroup(id)) {
      _moveGroup(id, atS);
      return;
    }
    _edit(moveBlock(_state, id, atS, beats: _magnetFor(id), snap: _magnet));
    _guideFor(id);
  }

  /// The selection follows the dragged clip, keeping its spacing; the magnet
  /// works on the dragged clip, and nothing in the group goes before zero.
  void _moveGroup(String id, double atS) {
    final clip = _state.clipItem(id);
    if (clip == null) return;
    final landing = snapMove(
      clip,
      atS,
      beats: magnetPoints(
        _state,
        moving: _state.selectionIds,
        beats: _beats,
        playheadS: _cursor,
      ),
      snap: _magnet,
    );
    final first = _state.selectedClips
        .map((c) => c.atS)
        .reduce(math.min);
    final delta = math.max(landing - clip.atS, -first);
    if (delta.abs() < 1e-9) return;
    _edit(moveSelection(_state, delta, beats: const [], snap: false));
    _guideFor(id);
  }

  void _trim(String id, double atS) {
    _edit(trimBlock(_state, id, atS, beats: _magnetFor(id), snap: _magnet));
    _guideFor(id);
  }

  void _stretch(String id, double durationValue) {
    _edit(
      stretchBlock(
        _state,
        id,
        durationValue,
        beats: _magnetFor(id),
        snap: _magnet,
        sourceDurationS: widget.job.durationS,
      ),
    );
    _guideFor(id);
  }

  void _shift(String id, double delta) => _edit(
    shiftContent(_state, id, delta, sourceDurationS: widget.job.durationS),
  );

  void _deleteSelection() => _edit(removeClips(_state, _state.selectionIds));

  // ── motion: position, scale, opacity, volume, static or keyframed ────────

  void _rampIntoMoment(String id) {
    final ramped = rampIntoMoment(_state, id);
    if (ramped == null) {
      _notify('The clip is too short to slow down around its play.');
      return;
    }
    _edit(ramped);
    _notify('Ramped: full speed in, slow motion through the play, full speed out.');
  }

  /// The playhead in seconds from the clip's start.
  double _localIn(String id) => _cursor - (_state.clipItem(id)?.atS ?? 0);

  /// Motion, and crop & rotate for a picture: the panels that act on how the
  /// clip sits in the frame.
  Widget? _picturePanels(String id) {
    final panels = [
      ?_motionPanel(id),
      ?_cropPanel(id),
      ?_fxPanel(id),
      ?_blendPanel(id),
    ];
    if (panels.isEmpty) return null;
    if (panels.length == 1) return panels.single;
    return Column(mainAxisSize: MainAxisSize.min, children: panels);
  }

  /// Blend & key — pictures only.
  Widget? _blendPanel(String id) {
    final clip = _state.clipItem(id);
    final at = _state.locate(id);
    if (clip == null || at == null || clip.isText || _isAudioClip(id)) {
      return null;
    }
    // is there a visible picture layer under this one?
    final overSomething = [
      for (var i = 0; i < at.$1; i++) _state.layers[i],
    ].any((l) => !l.isAudio && !l.hidden && l.clips.isNotEmpty);
    return BlendPanel(
      blend: clip.blend,
      chroma: clip.chroma,
      overSomething: overSomething,
      onChanged: (blend, chroma) => _edit(
        setBlendKey(_state, id, blend: blend, chroma: chroma),
      ),
      onGestureStart: _history.startGesture,
      onGestureEnd: _history.endGesture,
    );
  }

  /// Look & FX — pictures only, like crop & rotate.
  Widget? _fxPanel(String id) {
    final clip = _state.clipItem(id);
    if (clip == null || clip.isText || _isAudioClip(id)) return null;
    return FxPanel(
      fx: clip.fx,
      hasPlay: momentInVideo(clip) != null,
      onChanged: (fx) => _edit(setFx(_state, id, fx)),
      onGestureStart: _history.startGesture,
      onGestureEnd: _history.endGesture,
    );
  }

  /// Crop & rotate — only for pictures: text is placed by its own style and a
  /// song has no picture.
  Widget? _cropPanel(String id) {
    final clip = _state.clipItem(id);
    if (clip == null || clip.isText || _isAudioClip(id)) return null;
    return CropPanel(
      transform: clip.transform,
      onChanged: (t) => _edit(setTransform(_state, id, t)),
      onGestureStart: _history.startGesture,
      onGestureEnd: _history.endGesture,
    );
  }

  /// The Motion panel of the selected clip, or `null` when it has nothing to
  /// animate (a text clip).
  Widget? _motionPanel(String id) {
    final clip = _state.clipItem(id);
    if (clip == null) return null;
    final props = motionPropsFor(
      clip,
      onSoundLayer: _isAudioClip(id),
      media: _blockMedia(id),
    );
    if (props.isEmpty) return null;
    return MotionPanel(
      clip: clip,
      props: props,
      localS: _localIn(id),
      onSet: (p, v) =>
          _edit(setMotion(_state, id, p, v, localS: _localIn(id))),
      onAnimate: (p, on) => _edit(
        animateMotion(_state, id, p, on: on, localS: _localIn(id)),
      ),
      onRemoveKey: (p) =>
          _edit(removeMotionKey(_state, id, p, localS: _localIn(id))),
      onEase: (p, e) =>
          _edit(easeMotionKey(_state, id, p, e, localS: _localIn(id))),
      onSeek: _goTo,
      onGestureStart: _history.startGesture,
      onGestureEnd: _history.endGesture,
    );
  }

  // ── text ──────────────────────────────────────────────────────────────────

  /// Puts a text wherever the song is, on the top layer.
  ///
  /// Text almost always goes over the picture, so a new layer is the right
  /// guess when only one exists.
  void _addText(String contents) {
    var updated = _state;
    if (_pictureLayers(updated) == 1) updated = addLayer(updated, displayName: 'Text');
    _edit(
      addClip(
        updated,
        textClip(contents, atS: _cursor),
        beats: _beats,
        snap: _magnet,
      ),
    );
  }

  /// How many layers draw pictures — sound layers do not take text.
  static int _pictureLayers(MontageState s) =>
      s.layers.where((l) => !l.isAudio).length;

  /// Writes into the montage what the system already knows about the match.
  void _generateLabels(List<TimelineClip> added, String what) {
    if (added.isEmpty) {
      _notify('There are no $what to label in this montage.');
      return;
    }
    var s = _state;
    if (_pictureLayers(s) == 1) s = addLayer(s, displayName: 'Text');
    for (final r in added) {
      s = addClip(s, r, beats: const [], snap: false);
    }
    _edit(s.copyWith(selectionIds: const {}));
    _notify('${added.length} label(s) written.');
  }

  void _effect(
    String id, {
    double? speed,
    ClipColor? color,
    ClipFade? fade,
    List<ZoomKey>? zoom,
    bool? freeze,
    bool? reverse,
  }) => _edit(
    adjustEffect(
      _state,
      id,
      speed: speed,
      color: color,
      fade: fade,
      zoom: zoom,
      freeze: freeze,
      reverse: reverse,
    ),
  );

  // ── media library ─────────────────────────────────────────────────────────

  Future<void> _import() async {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const [
        'mp4',
        'mov',
        'mkv',
        'webm',
        'm4v',
        'png',
        'jpg',
        'jpeg',
        'webp',
        'gif',
        'mp3',
        'wav',
        'm4a',
        'aac',
        'ogg',
        'flac',
      ],
    );
    if (picked == null) return;
    setState(() {
      _importing = true;
      _importError = null;
    });
    try {
      final sent = await _api.uploadMedia(
        jobId: widget.job.id,
        file: picked,
      );
      final ready = await _api.waitForMedia(sent.id);
      if (!mounted) return;
      setState(() {
        _library = [..._library, ready];
        if (ready.isFailed) {
          _importError = ready.error ?? 'could not read this file';
        }
      });
    } catch (e) {
      if (mounted) setState(() => _importError = '$e');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  /// Puts a library item on the timeline, at the playhead.
  ///
  /// Music goes to a sound layer — if there is none, one is created. It is the
  /// only way to bring music into a montage, and it is the same path as video
  /// and images: the library is the entry door for everything from outside.
  void _useMedia(Media item, {double? atS, int? layerIndex}) {
    final location = atS ?? _cursor;
    if (item.isAudio) {
      _putMusicOnRuler(item, atS: location, layerIndex: layerIndex);
      return;
    }
    var base = _state;
    if (layerIndex != null && layerIndex >= 0 && layerIndex < base.layers.length) {
      if (base.layers[layerIndex].isAudio) {
        _notify('This is a sound layer: pictures do not go in it.');
        return;
      }
      base = base.copyWith(activeLayer: layerIndex);
    }
    _edit(
      addClip(
        base,
        mediaClip(
          item,
          atS: location,
          beats: _beats,
        ).copyWith(mediaId: item.id),
        beats: _beats,
        snap: _magnet,
        insert: _insert,
      ),
    );
  }

  Future<void> _removeFromLibrary(Media item) async {
    // a clip pointing at it would be orphaned, and the request would be refused
    final inUse = _state.clips.any((c) => c.mediaId == item.id);
    if (inUse) {
      _notify('This item is in the montage. Remove its cuts first.');
      return;
    }
    setState(
      () => _library = [
        for (final m in _library)
          if (m.id != item.id) m,
      ],
    );
    try {
      await _api.deleteMedia(item.id);
    } catch (e) {
      if (mounted) setState(() => _importError = '$e');
    }
  }

  void _selectAll() => _withoutHistory(
    _state.copyWith(selectionIds: {for (final c in _state.clips) c.id}),
  );

  void _copy() {
    if (_state.selectionIds.isEmpty) return;
    setState(() {
      _clipboard = _state.selectedClips;
      _clipboardAudio = {
        for (final c in _clipboard)
          if (_isAudioClip(c.id)) c.id,
      };
    });
    _notify('${_clipboard.length} cut(s) copied');
  }

  void _paste() {
    if (_clipboard.isEmpty) return;
    // pictures and music land apart, each on a layer of its own kind
    var s = _state;
    final copies = <String>{};
    for (final audio in [false, true]) {
      final group = [
        for (final c in _clipboard)
          if (_clipboardAudio.contains(c.id) == audio) c,
      ];
      if (group.isEmpty) continue;
      s = paste(s, group, _cursor, audio: audio);
      copies.addAll(s.selectionIds);
    }
    _edit(s.copyWith(selectionIds: copies));
  }

  void _duplicate() => _edit(duplicate(_state, _state.selectionIds));

  /// Brings a block's play under the playhead.
  ///
  /// The block moves; the play is what stays where it was asked. It is the
  /// gesture of snapping the kill to the beat without counting the run-up.
  void _alignMomentToCursor([String? id]) {
    final target =
        id ?? (_state.selectionIds.length == 1 ? _state.selectionIds.first : null);
    if (target == null) {
      _notify('Pick a block to align its play.');
      return;
    }
    if (momentInVideo(_state.clipItem(target)!) == null) {
      _notify('This block has no marked play.');
      return;
    }
    final done = alignMoment(
      _state,
      target,
      _cursor,
      sourceDurationS: widget.job.durationS,
    );
    if (done == null) {
      _notify('The play cannot reach this point: the recording ends before.');
      return;
    }
    _edit(done.state);
    if (done.didSlide) {
      // the user needs to know *what* changed: the block stayed where it was
      // and it was the recording span that moved
      _notify(
        'The neighbours did not let the block move, so the span slid '
        'inside it instead.',
      );
    }
  }

  /// Splits in two the block under the playhead.
  /// Cuts at the playhead: the chosen clips under it, else the active
  /// layer's, else the top one — or, with [everyLayer], every unlocked layer.
  void _splitAtCursor({bool everyLayer = false}) {
    final at = _cursor;
    final ids = splitTargets(_state, at, everyLayer: everyLayer);
    if (ids.isEmpty) {
      _notify('Put the cursor over a cut to split it.');
      return;
    }
    final beforeState = _state.clips.length;
    var s = _state;
    for (final id in ids) {
      s = split(s, id, at);
    }
    _edit(s);
    if (_state.clips.length == beforeState) {
      _notify('Too close to the edge: an invisible piece would be left.');
    }
  }

  /// Takes the effects of [id] — or of the one selected clip.
  void _copyEffects([String? id]) {
    final from = id ?? (_state.selectionIds.length == 1 ? _state.selectionIds.first : null);
    final clip = from == null ? null : _state.clipItem(from);
    if (clip == null) {
      _notify('Select one clip to copy its effects.');
      return;
    }
    setState(() => _effectsFrom = clip);
    _notify('Effects copied. Select clips and paste them (Ctrl+Shift+V).');
  }

  /// Puts the copied effects on [ids] — or on the selection.
  void _pasteEffects([Set<String>? ids]) {
    final from = _effectsFrom;
    final targets = ids ?? _state.selectionIds;
    if (from == null) {
      _notify('Copy a clip\'s effects first (Ctrl+Shift+C).');
      return;
    }
    if (targets.isEmpty) {
      _notify('Select the clips that should get the effects.');
      return;
    }
    _edit(pasteEffects(_state, targets, from));
  }

  /// Deletes the selection and closes the gaps it leaves.
  void _rippleDeleteSelection() =>
      _edit(rippleDelete(_state, _state.selectionIds));

  /// Moves one recording frame, for the adjustment a second cannot reach.
  ///
  /// The step comes from the match's own fps: in a 30 fps video it is 33 ms,
  /// and that is the smallest move that changes anything on screen.
  void _frameStep(int count) {
    final fps = widget.job.fps > 0 ? widget.job.fps : 30.0;
    _goTo(_cursor + count / fps);
  }

  /// Nudges the selection with the keyboard, for the adjustment a finger misses.
  void _push(double delta) {
    if (_state.selectionIds.isEmpty) return;
    _edit(moveSelection(_state, delta, beats: _beats, snap: false));
  }

  /// Trims the selected block's edge up to the playhead.
  void _trimAtCursor({required bool startTime}) {
    if (_state.selectionIds.length != 1) return;
    final c = _state.clipItem(_state.selectionIds.first)!;
    final at = _cursor;
    if (at <= c.atS || at >= c.untilS) return;
    _edit(
      startTime
          ? trimBlock(_state, c.id, at, beats: _beats, snap: false)
          : stretchBlock(
              _state,
              c.id,
              at - c.atS,
              beats: _beats,
              snap: false,
              sourceDurationS: widget.job.durationS,
            ),
    );
  }

  void _notify(String textValue) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(textValue)));
  }

  // ── saving ────────────────────────────────────────────────────────────────

  /// Saves the montage on the server, with slack between saves.
  ///
  /// Called on every change. What matters is not losing work, not recording
  /// every pixel of a drag — hence the second and a half wait: a whole drag
  /// becomes a single save.
  void _scheduleSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 1500), _save);
  }

  Future<void> _save() async {
    if (!mounted) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      final thisMontage = _state.toPayload();
      var id = _montageId;
      if (id == null) {
        // the first montage is only created when there is something to save:
        // opening the editor and closing it untouched leaves no junk in the list
        final fresh = await _api.createMontage(
          widget.job.id,
          name: _title.text.trim(),
          montage: thisMontage,
        );
        id = fresh.id;
        if (mounted) {
          setState(() {
            _montageId = id;
            _montages = [fresh, ..._montages];
          });
        }
      } else {
        await _api.saveMontage(widget.job.id, id, montage: thisMontage);
      }
      if (mounted) {
        setState(() {
          _savedAt = DateTime.now();
          _saving = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _saveError = '$e';
          _saving = false;
        });
      }
    }
  }

  // ── music ─────────────────────────────────────────────────────────────────

  List<DetectionEvent> get _matchMoments =>
      widget.job.events.where((e) => _usefulMoments.contains(e.kind)).toList();

  /// The beats in **video** time: blocks snap to them, because a block's
  /// position is measured from the start of the video, not of the song.
  List<double> get _beats {
    // With music blocks on the timeline, the grid is that of the song playing
    // under the playhead: a video with two tracks has two tempos, and
    // snapping to the other one's beat would be worse than not snapping at all.
    final here = _musicAt(_cursor);
    if (here != null) {
      final adjusted = adjustedGrid(
        here.music.beats,
        offsetS: _state.beatOffsetS,
        multiplier: _state.beatMultiplier,
        bar: _state.beatBar,
      );
      // the song's beats are measured in it; the block brings them to video
      // time, discounting the part of the track left out
      final shifts = here.block.atS - here.block.startS;
      return [
        for (final b in adjusted)
          if (b >= here.block.startS && b <= here.block.endS) b + shifts,
      ];
    }

    // with no block under the playhead there is no grid: the magnet has
    // nothing to snap to, and inventing a beat would be worse than having none
    return const [];
  }

  // ── music on the timeline ─────────────────────────────────────────────────

  /// The match songs, by id — each block's waveform comes from them.
  ///
  /// They come from the **library**, the entry door of everything from
  /// outside: a song uploaded just now is already here, not only in the
  /// snapshot that came with the match.
  Map<String, Track> get _tracks => {
    for (final m in _library)
      if (m.isAudio && m.isReady) m.id: m.asMusic,
  };

  /// The music block playing at [t] seconds of video, if any.
  ({TimelineClip block, Track music})? _musicAt(double t) {
    for (final layerIndex in _state.layers) {
      if (!layerIndex.isAudio || layerIndex.muted) continue;
      for (final c in layerIndex.clips) {
        if (t < c.atS - 1e-6 || t >= c.untilS - 1e-6) continue;
        final m = _tracks[c.mediaId];
        if (m != null) return (block: c, music: m);
      }
    }
    return null;
  }

  /// The library item a block came from, if it came from one.
  ///
  /// It is what makes the bottom panel talk about the file instead of the
  /// event: a media block did not come from a match moment, and a music one
  /// draws nothing.
  Media? _blockMedia(String id) {
    final clip = _state.clipItem(id);
    if (clip == null || clip.mediaId == null) return null;
    return _library.where((m) => m.id == clip.mediaId).firstOrNull;
  }

  /// Opens a sound-only layer and moves the focus to it.
  void _newMusicLayer() {
    _edit(addMusicLayer(_state));
    _notify('Drag a song from the Library onto this layer.');
  }

  /// Moves a block to another layer — and, when it cannot, says why.
  ///
  /// Refusing silently is the worst of both worlds: the block goes back to its
  /// place and whoever dragged it cannot tell whether the gesture missed or
  /// the operation was impossible.
  ///
  /// Dragging a picture above the top layer opens a new one there: it is the
  /// gesture of "put this over everything", and asking for the layer first
  /// would be red tape.
  void _changeLayer(String id, int destination) {
    final location = _state.locate(id);
    if (location == null) return;
    final origin = _state.layers[location.$1];
    var base = _state;
    if (destination >= base.layers.length && !origin.isAudio) {
      base = addLayer(base);
      destination = base.layers.length - 1;
    }
    if (destination < 0 || destination >= base.layers.length) {
      _notify('There is no layer there. Open a new one to move the block.');
      return;
    }
    final target = base.layers[destination];

    if (origin.isAudio != target.isAudio) {
      _notify(
        origin.isAudio
            ? 'Music only goes on a sound layer.'
            : 'This is a sound layer: pictures do not go in it.',
      );
      return;
    }
    if (target.locked) {
      _notify('The layer "${target.name}" is locked.');
      return;
    }
    final updated = moveToLayer(base, id, destination);
    if (identical(updated, base)) {
      _notify('There is already a block at that instant on the other layer.');
      return;
    }
    _edit(updated);
  }

  /// Where a dragged clip lands when let go: a free spot, another layer, or a
  /// swap with the clip under it — see [dropClip].
  ///
  /// The checks are [_changeLayer]'s, so a refused layer explains itself the
  /// same way whether the clip came by menu or by drag.
  void _dropClip(String id, double fromS, double atS, int destination) {
    final location = _state.locate(id);
    if (location == null) return;
    if (_inGroup(id)) {
      _shiftSelection(destination - location.$1);
      return;
    }
    final origin = _state.layers[location.$1];
    var base = _state;
    if (destination >= base.layers.length && !origin.isAudio) {
      base = addLayer(base);
      destination = base.layers.length - 1;
    }
    if (destination < 0 || destination >= base.layers.length) {
      _notify('There is no layer there. Open a new one to move the block.');
      return;
    }
    final target = base.layers[destination];
    if (origin.isAudio != target.isAudio) {
      _notify(
        origin.isAudio
            ? 'Music only goes on a sound layer.'
            : 'This is a sound layer: pictures do not go in it.',
      );
      return;
    }
    if (destination != location.$1 && target.locked) {
      _notify('The layer "${target.name}" is locked.');
      return;
    }
    final updated = dropClip(
      base,
      id,
      fromS: fromS,
      atS: atS,
      destination: destination,
      beats: _magnetFor(id),
      snap: _magnet,
    );
    if (identical(updated, base)) {
      // on its own layer the clip just stays where the drag left it
      if (destination != location.$1) {
        _notify(
          'It does not fit there: drop it on a free spot or on a clip to swap.',
        );
      }
      return;
    }
    _edit(updated);
  }

  /// The selection, whole, [shift] layers up (down when negative): each
  /// clip the same number of layers, at the same instant. A group let go on
  /// another track comes here — across time it already moved with the drag —
  /// and so do Alt+↑ / Alt+↓.
  void _shiftSelection(int shift) {
    if (shift == 0 || _state.selectionIds.isEmpty) return;
    var base = _state;
    // going up past the top opens layers for the pictures, as a single clip does
    final top = base.selectedClips
        .map((c) => base.locate(c.id)!.$1 + shift)
        .reduce(math.max);
    final pictures = base.selectedClips.every((c) => !_isAudioClip(c.id));
    while (pictures && top >= base.layers.length) {
      base = addLayer(base).copyWith(selectionIds: base.selectionIds);
    }
    final refusal = selectionLayerRefusal(base, shift);
    if (refusal != null) {
      _notify(refusal);
      return;
    }
    _edit(moveSelectionToLayers(base, shift));
  }

  /// The text clips the monitor draws over the picture.
  ///
  /// A hidden layer is left out: the monitor shows what will come out, and
  /// what is hidden will not.
  List<TimelineClip> get _visibleTexts => [
    for (final l in _state.layers)
      if (!l.hidden && !l.isAudio)
        for (final c in l.clips)
          if (c.isText) c,
  ];

  /// Does the montage have music? It decides whether the mix has anything to balance.
  bool get _hasMusic =>
      _state.layers.any((l) => l.isAudio && l.clips.isNotEmpty);

  /// What was dropped on the timeline, and where.
  ///
  /// Dragging is the path for whoever already knows where they want the thing;
  /// clicking still places at the playhead. Both doors lead to the same operation.
  void _dropOnRuler(RulerDrop o, double atS, int layerIndex) {
    final media = o.media;
    if (media != null) {
      _useMedia(media, atS: atS, layerIndex: layerIndex);
      return;
    }
    final span = o.span;
    if (span != null) {
      _addSpan(span, atS: atS, layerIndex: layerIndex);
      return;
    }
    final event = o.event!;
    if (layerIndex >= 0 &&
        layerIndex < _state.layers.length &&
        _state.layers[layerIndex].isAudio) {
      _notify('This is a sound layer: a match moment does not go in it.');
      return;
    }
    var base = _state;
    if (layerIndex >= 0 && layerIndex < base.layers.length) {
      base = base.copyWith(activeLayer: layerIndex);
    }
    _edit(
      addClip(
        base,
        cutForMoment(
          event,
          atS: atS,
          beats: _beats,
          sourceDurationS: widget.job.durationS,
        ),
        beats: _beats,
        snap: _magnet,
        insert: _insert,
      ),
    );
  }

  /// Puts a stretch marked on the recording on the timeline — at the playhead,
  /// or where it was dropped.
  void _addSpan(SourceSpan span, {double? atS, int? layerIndex}) {
    if (!span.isValid) {
      _notify('Mark an in and an out point on the recording first.');
      return;
    }
    if (layerIndex != null &&
        layerIndex >= 0 &&
        layerIndex < _state.layers.length &&
        _state.layers[layerIndex].isAudio) {
      _notify('This is a sound layer: a cut of the recording does not go in it.');
      return;
    }
    var base = _state;
    if (layerIndex != null && layerIndex >= 0 && layerIndex < base.layers.length) {
      base = base.copyWith(activeLayer: layerIndex);
    }
    _edit(
      addClip(
        base,
        spanClip(span, atS: atS ?? _cursor),
        beats: _beats,
        snap: _magnet,
        insert: _insert,
      ),
    );
  }

  /// Puts a library song on the timeline.
  ///
  /// With no sound layer chosen it opens one — asking for music and getting
  /// a request for a layer would be red tape.
  void _putMusicOnRuler(Media item, {double? atS, int? layerIndex}) {
    final music = _tracks[item.id];
    if (music == null) {
      _notify(
        item.isFailed
            ? 'Could not listen to this file.'
            : 'Still listening to this song.',
      );
      return;
    }
    var base = _state;
    // the layer under the finger only counts if it is a sound one; dropping
    // music on a picture track means "put it here at this instant", not "draw this"
    if (layerIndex != null &&
        layerIndex >= 0 &&
        layerIndex < base.layers.length &&
        base.layers[layerIndex].isAudio) {
      base = base.copyWith(activeLayer: layerIndex);
    }
    final beforeState = base.clips.length;
    final updated = putMusic(base, music, atS: atS ?? _cursor);
    _edit(updated);
    if (updated.clips.length == beforeState) {
      _notify('It did not fit: there is already music at that point.');
    }
  }

  // ── transport ─────────────────────────────────────────────────────────────
  //
  // The clock is the **video**, not the song. While the track was continuous
  // its player could own the time — there was a sound playing from the first
  // to the last frame. With blocks that come and go there is no player
  // playing the whole video, so the playhead got its own clock and the music
  // follows it: the block under it plays, at its point matching that instant.

  bool get _playing => _clock != null;

  /// How often the playhead moves while playing.
  static const _clockStep = Duration(milliseconds: 33);

  void _togglePlay() => _playing ? _pause() : _play();

  void _play() {
    if (_state.isBlank) return;
    // playing is asking for the live monitor back
    if (_exactOpen) setState(() => _exactOpen = false);
    // at the end, play restarts: stopping on the last frame and doing nothing
    // would leave the button without effect
    final endTime = videoDuration(_state.clips);
    final loop = _loopSpan;
    setState(() {
      if (loop != null) {
        // looping a stretch starts in it
        if (_cursor < loop.from || _cursor >= loop.to - 0.05) _cursor = loop.from;
      } else if (_cursor >= endTime - 0.05) {
        _cursor = 0;
      }
      _clock = Timer.periodic(_clockStep, (_) => _tick());
    });
    _syncMusic();
  }

  void _pause() {
    _clock?.cancel();
    _audio?.pause();
    if (mounted) setState(() => _clock = null);
  }

  // ── exact preview ─────────────────────────────────────────────────────────
  //
  // The monitor composes in the browser: instant, but its own approximation.
  // This asks the server for the real thing — the final video's graph on a
  // small frame — over the stretch being worked on.

  Future<void> _requestExact() async {
    if (_state.isBlank) return;
    _pause();
    _exactPoll?.cancel();
    final window = exactPreviewWindow(videoDuration(_state.clips), _cursor);
    final montage = _state.toPayload();
    setState(() {
      _exact = const ExactPreview(id: '', status: 'pending');
      _exactOpen = false;
      _exactPayload = jsonEncode(montage.toJson());
    });
    try {
      final asked = await _api.createPreview(
        jobId: widget.job.id,
        montage: montage,
        fromS: window.from,
        toS: window.to,
      );
      if (!mounted) return;
      setState(() => _exact = asked);
      _exactPoll = Timer.periodic(
        const Duration(milliseconds: 700),
        (_) => _checkExact(asked.id),
      );
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _exact = ExactPreview(id: '', status: 'failed', error: '$e'),
      );
    }
  }

  Future<void> _checkExact(String id) async {
    try {
      final now = await _api.getPreview(id);
      if (!mounted || _exact?.id != id) return;
      setState(() {
        _exact = now;
        if (now.isDone) {
          _exactOpen = true;
          _pause();
        }
      });
      if (!now.isWorking) _exactPoll?.cancel();
    } catch (_) {
      // one failed poll is noise; the next tick asks again
    }
  }

  /// The monitor, with the exact preview over it when there is one to show.
  Widget _withExact(Widget monitor) {
    final exact = _exact;
    return Stack(
      children: [
        monitor,
        if (exact != null && exact.isDone && _exactOpen)
          Positioned.fill(
            child: ExactPreviewOverlay(
              key: ValueKey('exact-${exact.id}'),
              url: exact.videoUrl!,
              fromS: exact.fromS,
              toS: exact.toS,
              outdated: _exactOutdated,
              onClose: () => setState(() => _exactOpen = false),
            ),
          )
        else if (exact != null && !exact.isDone)
          Positioned(
            left: 8,
            bottom: 8,
            child: ExactPreviewStatus(
              progress: exact.progress,
              error: exact.isFailed ? (exact.error ?? 'unknown error') : null,
              onDismiss: () => setState(() => _exact = null),
            ),
          ),
      ],
    );
  }

  /// Has the montage changed since the preview was asked for?
  bool get _exactOutdated =>
      _exactPayload != null &&
      _exactPayload != jsonEncode(_state.toPayload().toJson());

  /// One clock step.
  ///
  /// While music is playing, **it** is the clock: the player position becomes
  /// the playhead position. It is the sound the user is hearing, and pulling it
  /// back on every drift would cause an audible hiccup every few seconds. In
  /// stretches without music, the timer step is enough.
  void _tick() {
    final endTime = videoDuration(_state.clips);
    var t = _cursor + _clockStep.inMilliseconds / 1000.0;

    final here = _musicAt(_cursor);
    final c = _audio;
    if (here != null &&
        c != null &&
        c.value.isInitialized &&
        c.value.isPlaying &&
        _blockInPlayer == here.block.id) {
      final byRecording =
          here.block.atS +
          (c.value.position.inMilliseconds / 1000.0 - here.block.startS);
      // the player stutters now and then; when it gets lost for good, the
      // clock goes on without it instead of throwing the playhead far away
      if ((byRecording - t).abs() < 0.5) t = byRecording;
    }

    final loop = _loopSpan;
    if (loop != null && t >= loop.to) {
      // round again: the music follows the jump on the next sync
      setState(() => _cursor = loop.from);
      _followCursor(loop.from);
      _syncMusic();
      return;
    }
    if (t >= endTime) {
      setState(() => _cursor = endTime);
      _pause();
      return;
    }
    setState(() => _cursor = t);
    _followCursor(t);
    _syncMusic();
  }

  /// Puts the player at the point of the song matching the cursor.
  ///
  /// Switching tracks costs a network load, so it only switches when the block
  /// under the playhead changes. Otherwise the drift is corrected: the video
  /// clock and the audio element's run separately, and in a long video they
  /// drift apart enough for the beat to slip.
  Future<void> _syncMusic() async {
    if (_adjustingAudio) return;
    _adjustingAudio = true;
    try {
      final here = _musicAt(_cursor);
      if (here == null) {
        // silence is the lack of a block, not a block of silence
        if (_audio?.value.isPlaying ?? false) await _audio?.pause();
        _blockInPlayer = null;
        return;
      }
      if (_blockInPlayer != here.block.id || _audioDe != here.music.id) {
        _blockInPlayer = here.block.id;
        if (_audioDe != here.music.id) await _openAudio(here.music);
      }
      final c = _audio;
      if (c == null || !c.value.isInitialized) return;

      final location = here.block.startS + (_cursor - here.block.atS);
      final nowS = c.value.position.inMilliseconds / 1000.0;
      // the montage's music volume, and the dip at each play, so ducking is
      // heard while editing — the player cannot go above full
      final duck = _state.duckPlays
          ? duckAt(playTimes(_state.layers), _cursor) * (1 - _state.duckLevel)
          : 0.0;
      final volume = (_state.musicVolume * (1 - duck)).clamp(0.0, 1.0);
      if ((c.value.volume - volume).abs() > 0.01) await c.setVolume(volume);
      if ((nowS - location).abs() > 0.2) {
        await c.seekTo(Duration(milliseconds: (location * 1000).round()));
      }
      if (_playing && !c.value.isPlaying) {
        await c.play();
      } else if (!_playing && c.value.isPlaying) {
        await c.pause();
      }
    } finally {
      _adjustingAudio = false;
    }
  }

  Future<void> _openAudio(Track music) async {
    final old = _audio;
    _audio = null;
    _audioDe = null;
    await old?.dispose();

    final controller = VideoPlayerController.networkUrl(
      Uri.parse(music.audioUrl),
    );
    try {
      await controller.initialize();
    } catch (e) {
      // without a player the montage is still possible: the waveform and the
      // beats are already drawn, and they are what you snap the cut to
      await controller.dispose();
      if (mounted) setState(() => _musicError = 'cannot play here ($e)');
      return;
    }
    if (!mounted) {
      await controller.dispose();
      return;
    }
    setState(() {
      _audio = controller;
      _audioDe = music.id;
      _musicError = null;
    });
  }

  /// Keeps the playhead on screen while the video runs.
  /// Changes the zoom keeping [anchorS] where it is on screen — the instant
  /// under the mouse for Ctrl+scroll, the playhead otherwise.
  void _setZoom(double px, {double? anchorS, double? anchorDx}) {
    final next = clampZoom(px);
    if (next == _px) return;
    var at = anchorS, dx = anchorDx;
    if (at == null || dx == null) {
      at = _cursor;
      if (_scroll.hasClients) {
        final window = _scroll.position.viewportDimension;
        final x = _cursor * _px - _scroll.offset;
        // the playhead stays where it is if it is on screen; brought to a
        // third of the window if not
        dx = x >= 0 && x <= window ? x : window / 3;
      } else {
        dx = 0;
      }
    }
    setState(() => _px = next);
    final offset = anchoredOffset(at, dx, next);
    // the ruler's new width is only known after the next layout
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(offset.clamp(0.0, _scroll.position.maxScrollExtent));
    });
  }

  /// The whole montage in the window.
  void _zoomToFit() {
    if (!_scroll.hasClients) return;
    final window = _scroll.position.viewportDimension;
    setState(() => _px = fitZoom(videoDuration(_state.clips), window));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(0);
    });
  }

  void _followCursor(double t) {
    if (!_scroll.hasClients) return;
    final x = t * _px;
    final window = _scroll.position.viewportDimension;
    final startTime = _scroll.offset;
    if (x < startTime + 40 || x > startTime + window - 80) {
      _scroll.jumpTo(
        (x - window / 3).clamp(0.0, _scroll.position.maxScrollExtent),
      );
    }
  }

  /// Moves the playhead. A jump that lands off screen (the keyboard, the
  /// keyframe arrows) brings the ruler to it; a tap on the ruler itself is
  /// already in view and must not move the ruler under the finger.
  Future<void> _goTo(double s, {bool reveal = true}) async {
    // not limited to the end of the montage: putting the playhead after the
    // last block is exactly how you place the next one
    final t = math.max(0.0, s);
    setState(() => _cursor = t);
    if (reveal) _revealCursor(t);
    await _syncMusic();
  }

  /// Scrolls to the playhead only when it is out of the window.
  void _revealCursor(double t) {
    if (!_scroll.hasClients) return;
    final x = t * _px;
    final window = _scroll.position.viewportDimension;
    if (x >= _scroll.offset && x <= _scroll.offset + window) return;
    final to = (x - window / 3).clamp(0.0, _scroll.position.maxScrollExtent);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(to.toDouble());
    });
  }

  // ── request and discard ───────────────────────────────────────────────────

  Future<void> _render() async {
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await _save();
      await _api.createRender(
        jobId: widget.job.id,
        montages: [_state.toPayload()],
      );
      // what came out was *this*: keeping the snapshot here is what makes the
      // history useful without filling the database on every autosave
      final id = _montageId;
      if (id != null) {
        await _api
            .createVersion(widget.job.id, id, label: 'rendered the video')
            .catchError((_) => false);
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _sending = false;
        });
      }
    }
  }

  // ── match montages ────────────────────────────────────────────────────────

  SavedMontage? get _currentMontage =>
      _montages.where((m) => m.id == _montageId).firstOrNull;

  String get _montageName => _currentMontage?.name ?? 'Montage';

  /// Puts a montage on screen, saving the one that was there first.
  ///
  /// The undo history does **not** cross the switch: it is the memory of a
  /// work session on one montage, and undoing into another would erase what
  /// was just opened.
  Future<void> _open(SavedMontage m) async {
    if (m.id == _montageId) return;
    _debounce?.cancel();
    await _save();
    if (!mounted) return;

    setState(() {
      _montageId = m.id;
      _title.text = m.montage.title;
    });
    _history.reset();
    _history.replace(montageFromDraft(m.montage));
    // the other montage has its own music, in its own blocks
    _blockInPlayer = null;
    await _syncMusic();
  }

  Future<void> _reloadMontages({String? open}) async {
    try {
      final list = await _api.listMontages(widget.job.id);
      if (!mounted) return;
      setState(() => _montages = list);
      if (open != null) {
        final fresh = list.where((m) => m.id == open).firstOrNull;
        if (fresh != null) await _open(fresh);
      }
    } catch (e) {
      if (mounted) setState(() => _saveError = '$e');
    }
  }

  Future<void> _newMontage() async {
    _debounce?.cancel();
    await _save();
    try {
      final fresh = await _api.createMontage(widget.job.id);
      if (!mounted) return;
      setState(() {
        _montages = [fresh, ..._montages];
        _montageId = fresh.id;
        _title.text = '';
      });
      _history.reset();
      _history.replace(MontageState.blank());
    } catch (e) {
      if (mounted) setState(() => _saveError = '$e');
    }
  }

  Future<void> _duplicateMontage() async {
    final present = _montageId;
    if (present == null) return;
    _debounce?.cancel();
    await _save();
    try {
      final copy = await _api.duplicateMontage(widget.job.id, present);
      await _reloadMontages(open: copy.id);
    } catch (e) {
      if (mounted) setState(() => _saveError = '$e');
    }
  }

  Future<void> _renameMontage() async {
    final present = _currentMontage;
    if (present == null) return;
    final displayName = await _askName('Rename', initial: present.name);
    if (displayName == null || !mounted) return;
    try {
      await _api.saveMontage(widget.job.id, present.id, name: displayName);
      await _reloadMontages();
    } catch (e) {
      if (mounted) setState(() => _saveError = '$e');
    }
  }

  Future<void> _deleteMontage() async {
    final present = _currentMontage;
    if (present == null) return;
    final ok = await _confirm(
      'Delete "${present.name}"?',
      'The cuts of this montage are gone. The other montages of this match '
          'stay as they are.',
    );
    if (!ok || !mounted) return;

    _debounce?.cancel();
    try {
      await _api.deleteMontage(widget.job.id, present.id);
      final remainingOnes = [..._montages]..removeWhere((m) => m.id == present.id);
      if (!mounted) return;
      setState(() {
        _montages = remainingOnes;
        _montageId = null;
      });
      _history.reset();
      if (remainingOnes.isNotEmpty) {
        await _open(remainingOnes.first);
      } else {
        _history.replace(MontageState.blank());
        setState(() => _title.text = '');
      }
    } catch (e) {
      if (mounted) setState(() => _saveError = '$e');
    }
  }

  Future<String?> _askName(String heading, {String initial = ''}) {
    final inputField = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(heading),
        content: TextField(
          controller: inputField,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(inputField.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    ).then((v) => (v == null || v.isEmpty) ? null : v);
  }

  Future<bool> _confirm(String heading, String textValue) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(heading),
        content: Text(textValue),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return r ?? false;
  }

  // ── version history ───────────────────────────────────────────────────────

  Future<void> _markVersion() async {
    final present = _montageId;
    if (present == null) return;
    _debounce?.cancel();
    await _save();
    try {
      final happened = await _api.createVersion(
        widget.job.id,
        present,
        label: 'marked by hand',
      );
      if (!mounted) return;
      _notify(
        happened ? 'Version marked.' : 'Nothing changed since the last marked version.',
      );
      await _reloadMontages();
    } catch (e) {
      if (mounted) setState(() => _saveError = '$e');
    }
  }

  Future<void> _showHistory() async {
    final present = _montageId;
    if (present == null) return;
    _debounce?.cancel();
    await _save();

    List<MontageVersion> snapshots;
    try {
      snapshots = await _api.listVersions(widget.job.id, present);
    } catch (e) {
      if (mounted) setState(() => _saveError = '$e');
      return;
    }
    if (!mounted) return;

    final selectedOne = await showDialog<MontageVersion>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('History'),
        content: SizedBox(
          width: 420,
          child: snapshots.isEmpty
              ? const Text(
                  'No versions yet. One is kept for every rendered video, '
                  'and you can mark one now from the menu.',
                )
              : ListView(
                  shrinkWrap: true,
                  children: [
                    for (final v in snapshots)
                      ListTile(
                        key: ValueKey('version-${v.id}'),
                        title: Text(v.label.isEmpty ? 'unlabelled' : v.label),
                        subtitle: Text(
                          '${v.nClips} cut(s) · '
                          '${formatDuration(v.durationS)} · '
                          '${_when(v.createdAt)}',
                        ),
                        trailing: const Icon(Icons.restore),
                        onTap: () => Navigator.of(ctx).pop(v),
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
    if (selectedOne == null || !mounted) return;

    try {
      final back = await _api.restoreVersion(
        widget.job.id,
        present,
        selectedOne.id,
      );
      if (!mounted) return;
      _history.reset();
      _history.replace(montageFromDraft(back.montage));
      setState(() => _title.text = back.montage.title);
      _notify(
        'Back to "${selectedOne.label}". What was there before became '
        'a version too.',
      );
      await _reloadMontages();
    } catch (e) {
      if (mounted) setState(() => _saveError = '$e');
    }
  }

  static String _when(DateTime t) {
    final d = t.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)} ${two(d.hour)}:${two(d.minute)}';
  }

  // ── presets ───────────────────────────────────────────────────────────────

  Future<void> _savePreset() async {
    final displayName = await _askName('Save as template');
    if (displayName == null || !mounted) return;
    try {
      await _api.createPreset(
        displayName,
        recipeFromMontage(_state, beatsPerCut: _beatsPerCut),
      );
      if (mounted) {
        _notify('Template "$displayName" saved: it works for any match.');
      }
    } catch (e) {
      if (mounted) setState(() => _saveError = '$e');
    }
  }

  /// How many beats each cut takes, if it takes a round number of them.
  ///
  /// It is what tells "1.8 s cuts" from "two-beat cuts": the second reading
  /// survives a song with another tempo, and the first does not.
  double? get _beatsPerCut {
    final grid = _beats;
    if (grid.length < 3 || _state.clips.isEmpty) return null;
    var sum = 0.0;
    for (var i = 1; i < grid.length; i++) {
      sum += grid[i] - grid[i - 1];
    }
    final bar = sum / (grid.length - 1);
    if (bar <= 0) return null;

    final durations = [
      for (final c in _state.clips)
        if (!c.isText) c.durationS,
    ];
    if (durations.isEmpty) return null;
    final media = durations.reduce((a, b) => a + b) / durations.length;
    final howMany = media / bar;
    final isRound = howMany.roundToDouble();
    // far from a whole number of beats, the montage is not a rhythm one
    if (isRound < 1 || (howMany - isRound).abs() > 0.15) return null;
    return isRound;
  }

  /// Applies a saved template: rebuilding the cuts from this match's
  /// moments, or — [styleOnly] — only its look on the cuts already here.
  Future<void> _applyPreset({bool styleOnly = false}) async {
    List<Preset> presets;
    try {
      presets = await _api.listPresets();
    } catch (e) {
      if (mounted) setState(() => _saveError = '$e');
      return;
    }
    if (!mounted) return;

    final pickedOne = await showDialog<Preset>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(styleOnly ? 'Apply a template\'s style' : 'Templates'),
        content: SizedBox(
          width: 420,
          child: presets.isEmpty
              ? const Text(
                  'None yet. Build a video the way you like it and use '
                  '"Save as template" — from then on the next match '
                  'comes out ready.',
                )
              : ListView(
                  shrinkWrap: true,
                  children: [
                    for (final p in presets)
                      ListTile(
                        key: ValueKey('preset-${p.id}'),
                        title: Text(p.name),
                        subtitle: Text(_describeRecipe(p.recipe)),
                        onTap: () => Navigator.of(ctx).pop(p),
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
    if (pickedOne == null || !mounted) return;

    if (styleOnly) {
      _edit(applyStyle(_state, pickedOne.recipe));
      _notify('The style of "${pickedOne.name}" is on your cuts.');
      return;
    }

    if (!_state.isBlank) {
      final ok = await _confirm(
        'Apply "${pickedOne.name}"?',
        'The cuts on screen are replaced. You can undo it '
            'with Ctrl+Z. To keep them and take only the look, use '
            '"Apply template style".',
      );
      if (!ok || !mounted) return;
    }

    _edit(
      applyRecipe(
        pickedOne.recipe,
        eventList: _matchMoments,
        sourceDurationS: widget.job.durationS,
        beatTimes: _beats,
        base: _state,
      ),
    );
    _notify('"${pickedOne.name}" applied: ${_state.clips.length} cut(s).');
  }

  String _describeRecipe(Recipe r) {
    final sizeValue = r.beatsPerCut > 0
        ? '${r.beatsPerCut.toStringAsFixed(0)} beat(s) per cut'
        : '${r.durationS.toStringAsFixed(1)}s per cut';
    final extras = [
      if (r.zoom) r.zoomSmooth ? 'smooth zoom' : 'zoom',
      if (r.transition.isNotEmpty)
        TransitionType.of(r.transition)?.name ?? r.transition,
      if (r.ramp) 'slow-mo ramps',
      if (r.duckPlays) 'ducking',
      if (r.counter) 'counter',
      if (r.streaks) 'streaks',
      if (r.labelStyle?.font case final f? when f.isNotEmpty) 'font $f',
      if (r.export.width > 0) '${r.export.width}x${r.export.height}',
    ];
    return '${r.kinds.join(', ')} · $sizeValue'
        '${extras.isEmpty ? '' : ' · ${extras.join(' · ')}'}';
  }

  // ── keyboard ──────────────────────────────────────────────────────────────

  /// Gives the focus back to the montage — and the shortcuts with it.
  ///
  /// Called by the fields when a tap lands **outside** them. Nothing takes the
  /// focus away from a `TextField` on its own in Flutter: without this, tapping
  /// the name field once left "S" and Delete dead for the rest of the session.
  void _restoreFocus() {
    if (mounted) _focus.requestFocus();
  }

  /// Opens (id) or closes (`null`) typing on the monitor.
  ///
  /// Everything typed in one opening becomes **one** undo step: keystroke by
  /// keystroke, Ctrl+Z would erase one letter at a time.
  void _typeOnFrame(String? id) {
    if (id == _editingTextId) return;
    if (_editingTextId != null) _history.endGesture();
    if (id != null) {
      _history.startGesture();
      _pause();
    }
    setState(() => _editingTextId = id);
    if (id != null) _withoutHistory(_state.copyWith(selectionIds: {id}));
    if (id == null) _restoreFocus();
  }

  /// The shortcuts, with Ctrl and Cmd working the same.
  Map<ShortcutActivator, VoidCallback> get _shortcuts {
    final b = <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.space): _togglePlay,
      const SingleActivator(LogicalKeyboardKey.keyK): _togglePlay,
      const SingleActivator(LogicalKeyboardKey.keyL): () {
        if (!_playing) _play();
      },
      const SingleActivator(LogicalKeyboardKey.keyJ): () =>
          _goTo(_cursor - 2),
      const SingleActivator(LogicalKeyboardKey.keyS): _splitAtCursor,
      const SingleActivator(
        LogicalKeyboardKey.keyC,
        control: true,
        shift: true,
      ): _copyEffects,
      const SingleActivator(
        LogicalKeyboardKey.keyC,
        meta: true,
        shift: true,
      ): _copyEffects,
      const SingleActivator(
        LogicalKeyboardKey.keyV,
        control: true,
        shift: true,
      ): _pasteEffects,
      const SingleActivator(
        LogicalKeyboardKey.keyV,
        meta: true,
        shift: true,
      ): _pasteEffects,
      const SingleActivator(LogicalKeyboardKey.equal): () =>
          _setZoom(_px * kZoomStep),
      const SingleActivator(LogicalKeyboardKey.minus): () =>
          _setZoom(_px / kZoomStep),
      const SingleActivator(LogicalKeyboardKey.backslash): _zoomToFit,
      const SingleActivator(LogicalKeyboardKey.keyS, shift: true): () =>
          _splitAtCursor(everyLayer: true),
      const SingleActivator(LogicalKeyboardKey.keyM): _alignMomentToCursor,
      const SingleActivator(LogicalKeyboardKey.keyN): _toggleMarker,
      const SingleActivator(LogicalKeyboardKey.keyI): _markIn,
      const SingleActivator(LogicalKeyboardKey.keyO): _markOut,
      const SingleActivator(LogicalKeyboardKey.keyX, alt: true): _clearRange,
      const SingleActivator(LogicalKeyboardKey.keyL, shift: true): () =>
          setState(() => _loop = !_loop),
      const SingleActivator(LogicalKeyboardKey.keyN, shift: true): () {
        if (nextMarker(_state, _cursor) case final t?) _goTo(t);
      },
      // comma and period move one frame, like in any editor. The arrows keep
      // the coarse one-second step — both have their use.
      const SingleActivator(LogicalKeyboardKey.comma): () => _frameStep(-1),
      const SingleActivator(LogicalKeyboardKey.period): () => _frameStep(1),
      const SingleActivator(LogicalKeyboardKey.delete): _deleteSelection,
      const SingleActivator(LogicalKeyboardKey.backspace): _deleteSelection,
      const SingleActivator(LogicalKeyboardKey.delete, shift: true):
          _rippleDeleteSelection,
      const SingleActivator(LogicalKeyboardKey.backspace, shift: true):
          _rippleDeleteSelection,
      const SingleActivator(LogicalKeyboardKey.escape): () =>
          _fullscreen ? _setFullscreen(false) : _select(null),
      const SingleActivator(LogicalKeyboardKey.keyF): () =>
          _setFullscreen(!_fullscreen),
      const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
          _goTo(_cursor - 1),
      const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
          _goTo(_cursor + 1),
      const SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true): () =>
          _push(-0.1),
      const SingleActivator(LogicalKeyboardKey.arrowRight, shift: true): () =>
          _push(0.1),
      const SingleActivator(LogicalKeyboardKey.arrowUp, alt: true): () =>
          _shiftSelection(1),
      const SingleActivator(LogicalKeyboardKey.arrowDown, alt: true): () =>
          _shiftSelection(-1),
      const SingleActivator(LogicalKeyboardKey.bracketLeft): () =>
          _trimAtCursor(startTime: true),
      const SingleActivator(LogicalKeyboardKey.bracketRight): () =>
          _trimAtCursor(startTime: false),
    };

    // Ctrl on Windows/Linux, Cmd on Mac: the same shortcut registered twice
    // costs one line and avoids a "why does it not work here".
    void command(
      LogicalKeyboardKey keyName,
      VoidCallback action, {
      bool shift = false,
    }) {
      b[SingleActivator(keyName, control: true, shift: shift)] = action;
      b[SingleActivator(keyName, meta: true, shift: shift)] = action;
    }

    command(LogicalKeyboardKey.keyZ, _undo);
    command(LogicalKeyboardKey.keyZ, _redo, shift: true);
    command(LogicalKeyboardKey.keyY, _redo);
    command(LogicalKeyboardKey.keyC, _copy);
    command(LogicalKeyboardKey.keyV, _paste);
    command(LogicalKeyboardKey.keyD, _duplicate);
    command(LogicalKeyboardKey.keyA, _selectAll);

    return b;
  }

  // ── screen ────────────────────────────────────────────────────────────────

  /// Below this width the sidebar does not fit, and the screen becomes a
  /// single column — the app stays usable on a phone.
  static const double _editorWidth = 900;

  /// From this width the settings move to a sidebar on the right; below it
  /// the ruler would be too narrow to work on, and they stay under it.
  static const double _settingsAsideWidth = 1200;
  static const double _settingsWidth = 360;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      // While someone is typing, **no shortcut is registered** — and that is
      // quite different from having one that does nothing: `CallbackShortcuts`
      // marks the key as handled as soon as some shortcut accepts it, and in
      // the browser a handled key becomes `preventDefault`. The letter would no
      // longer reach the field, which was the intermediate state of this fix.
      bindings: _typing
          ? const <ShortcutActivator, VoidCallback>{}
          : _shortcuts,
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        child: Stack(
          children: [
            Scaffold(
          appBar: AppBar(
            title: _MontagePicker(
              displayName: _montageName,
              montageList: _montages,
              present: _montageId,
              onOpen: _open,
              onNew: _newMontage,
            ),
            actions: [
              _DraftStatus(
                saving: _saving,
                savedAt: _savedAt,
                err: _saveError,
                onRetry: _save,
              ),
              IconButton(
                tooltip: 'Undo (Ctrl+Z)',
                onPressed: _history.canUndo ? _undo : null,
                icon: const Icon(Icons.undo),
              ),
              IconButton(
                tooltip: 'Redo (Ctrl+Shift+Z)',
                onPressed: _history.canRedo ? _redo : null,
                icon: const Icon(Icons.redo),
              ),
              IconButton(
                tooltip: _magnet
                    ? 'magnet on: snaps to the beat, clip edges and the playhead'
                    : 'magnet off',
                onPressed: () => setState(() => _magnet = !_magnet),
                icon: Icon(_magnet ? Icons.grid_on : Icons.grid_off),
              ),
              IconButton(
                key: const Key('insert-mode'),
                tooltip: _insert
                    ? 'insert mode: new clips push the others right'
                    : 'overwrite-free mode: new clips go to a free spot',
                isSelected: _insert,
                onPressed: () => setState(() => _insert = !_insert),
                icon: const Icon(Icons.keyboard_tab),
                selectedIcon: const Icon(Icons.keyboard_tab, color: Colors.orange),
              ),
              PopupMenuButton<String>(
                key: const Key('screen-menu'),
                onSelected: (v) {
                  if (v == 'discard') _deleteMontage();
                  if (v == 'shortcuts') _showShortcuts();
                  if (v == 'rename') _renameMontage();
                  if (v == 'duplicate') _duplicateMontage();
                  if (v == 'mark') _markVersion();
                  if (v == 'history') _showHistory();
                  if (v == 'apply-preset') _applyPreset();
                  if (v == 'apply-style') _applyPreset(styleOnly: true);
                  if (v == 'save-preset') _savePreset();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'rename', child: Text('Rename')),
                  PopupMenuItem(
                    value: 'duplicate',
                    child: Text('Duplicate this montage'),
                  ),
                  PopupMenuDivider(),
                  PopupMenuItem(
                    value: 'apply-preset',
                    child: Text('Apply template…'),
                  ),
                  PopupMenuItem(
                    key: Key('apply-style'),
                    value: 'apply-style',
                    child: Text('Apply template style…'),
                  ),
                  PopupMenuItem(
                    value: 'save-preset',
                    child: Text('Save as template…'),
                  ),
                  PopupMenuDivider(),
                  PopupMenuItem(
                    value: 'mark',
                    child: Text('Mark this version'),
                  ),
                  PopupMenuItem(
                    value: 'history',
                    child: Text('Version history…'),
                  ),
                  PopupMenuDivider(),
                  PopupMenuItem(
                    value: 'shortcuts',
                    child: Text('Keyboard shortcuts'),
                  ),
                  PopupMenuItem(
                    value: 'discard',
                    child: Text('Delete this montage'),
                  ),
                ],
              ),
            ],
          ),
          body: LayoutBuilder(
            builder: (context, bounds) {
              final sidebarFits = bounds.maxWidth >= _editorWidth;
              if (!sidebarFits) {
                return _main(dockMoments: true);
              }
              final aside = bounds.maxWidth >= _settingsAsideWidth;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: 300, child: _sidebar()),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: _main(dockMoments: false, settingsAside: aside),
                  ),
                  if (aside) ...[
                    const VerticalDivider(width: 1),
                    _settingsSidebar(),
                  ],
                ],
              );
            },
          ),
            ),
            // the monitor over everything; the editor stays built underneath,
            // so leaving full screen is instant
            if (_fullscreen) Positioned.fill(child: _fullscreenLayer()),
          ],
        ),
      ),
    );
  }

  void _showShortcuts() {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Shortcuts'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              _Shortcut('Space / K', 'play or pause'),
              _Shortcut('J / L', 'back 2s / play'),
              _Shortcut('← →', 'move the playhead (1s)'),
              _Shortcut(', / .', 'step one frame'),
              _Shortcut('Shift + ← →', 'nudge the selected cuts'),
              _Shortcut('Alt + ↑ ↓', 'move the selected cuts a layer up / down'),
              _Shortcut('S', 'split the cut under the cursor'),
              _Shortcut('Shift + S', 'split every layer at the cursor'),
              _Shortcut('= / -', 'zoom the ruler in / out'),
              _Shortcut('\\', 'fit the whole montage'),
              _Shortcut('Ctrl + scroll', 'zoom around the mouse'),
              _Shortcut('Shift + Delete', 'delete and close the gap'),
              _Shortcut('drag on an empty track', 'select with a rectangle'),
              _Shortcut('M', 'align the selected block\'s play to the cursor'),
              _Shortcut('[ / ]', 'trim the start / end to the cursor'),
              _Shortcut('N / Shift + N', 'marker at the playhead / next marker'),
              _Shortcut('I / O', 'in / out point at the playhead'),
              _Shortcut('F', 'monitor full screen (Esc leaves)'),
              _Shortcut('Alt + X', 'clear the in and out points'),
              _Shortcut('Shift + L', 'loop playback (the in/out range, or all)'),
              _Shortcut('Delete', 'remove from the montage'),
              _Shortcut('Ctrl+Z / Ctrl+Shift+Z', 'undo / redo'),
              _Shortcut('Ctrl+C / Ctrl+V', 'copy / paste'),
              _Shortcut('Ctrl+D', 'duplicate'),
              _Shortcut('Ctrl+Shift+C / V', 'copy / paste effects'),
              _Shortcut('Ctrl+A', 'select all'),
              _Shortcut('Shift + click', 'add to the selection'),
              _Shortcut('drag ↑ ↓', 'move the cut to another layer'),
              _Shortcut('right-click a layer', 'rename, reorder or delete it'),
              _Shortcut('Esc', 'clear the selection'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  /// The sidebar: what the system found and what the user brought, side by
  /// side — both answer the same question, "what do I put in now?".
  /// The right-hand sidebar with the settings. Collapsed, it is a thin strip
  /// that gives the room back to the ruler and opens again with a click.
  Widget _settingsSidebar() {
    final theme = Theme.of(context);
    final selected = _state.selectionIds.length;
    if (!_settingsOpen) {
      return SizedBox(
        key: const Key('settings-collapsed'),
        width: 44,
        child: Column(
          children: [
            const SizedBox(height: 4),
            IconButton(
              key: const Key('settings-expand'),
              tooltip: 'Show the settings',
              onPressed: () => setState(() => _settingsOpen = true),
              icon: const Icon(Icons.chevron_left),
            ),
            const SizedBox(height: 4),
            Tooltip(
              message: selected == 0
                  ? 'Settings'
                  : '$selected clip${selected == 1 ? '' : 's'} selected',
              child: Badge(
                isLabelVisible: selected > 0,
                label: Text('$selected'),
                child: Icon(Icons.tune, color: theme.hintColor),
              ),
            ),
          ],
        ),
      );
    }
    return SizedBox(
      key: const Key('settings-sidebar'),
      width: _settingsWidth,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 4, 0),
            child: Row(
              children: [
                const Icon(Icons.tune, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Settings', style: theme.textTheme.titleSmall),
                ),
                IconButton(
                  key: const Key('settings-collapse'),
                  tooltip: 'Hide the settings',
                  onPressed: () => setState(() => _settingsOpen = false),
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              key: const Key('montage-panels'),
              padding: const EdgeInsets.fromLTRB(0, 0, 0, 32),
              children: _settingsChildren(dockMoments: false),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sidebar() => DefaultTabController(
    length: 4,
    child: Column(
      children: [
        const TabBar(
          // four tabs in 300px: short labels, tight padding — a scrolling
          // bar hid the last tabs off the edge
          labelPadding: EdgeInsets.symmetric(horizontal: 2),
          tabs: [
            Tab(text: 'Moments'),
            Tab(text: 'Source'),
            Tab(text: 'Library'),
            Tab(text: 'Transitions'),
          ],
        ),
        Expanded(
          child: TabBarView(
            children: [
              _moments(docked: false),
              SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: _recordingPanel(),
              ),
              _libraryPanel(docked: false),
              _transitions(docked: false),
            ],
          ),
        ),
      ],
    ),
  );

  /// The whole recording, to cut by hand what the analysis did not find.
  ///
  /// The cutting itself happens in a large window: choosing a frame needs a
  /// picture bigger than a sidebar.
  Widget _recordingPanel() {
    final theme = Theme.of(context);
    return Column(
      key: const Key('recording-panel'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Cut from the recording', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          'Find what the analysis missed: drag the start and end lines over '
          'the match, name the cut and add it at the playhead.',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
        ),
        const SizedBox(height: 10),
        FilledButton.tonalIcon(
          key: const Key('open-source-cutter'),
          onPressed: _sending ? null : _openSourceCutter,
          icon: const Icon(Icons.content_cut),
          label: const Text('Open the recording'),
        ),
      ],
    );
  }

  Future<void> _openSourceCutter() => openSourceCutter(
    context,
    videoUrl: widget.job.monitorUrl,
    durationS: widget.job.durationS,
    fps: widget.job.fps,
    events: widget.job.events,
    onAdd: (span) {
      final at = _cursor;
      _addSpan(span);
      // the next cut follows this one
      _goTo(at + span.lengthS);
    },
  );

  Widget _transitions({required bool docked}) {
    final selected = [
      for (final id in _state.selectionIds)
        if (_state.clipItem(id) case final c?)
          if (!_isAudioClip(id)) c,
    ];
    return _Transitions(
      selected: selected,
      duration: _transitionDuration,
      enabled: !_sending,
      docked: docked,
      onApply: (kind) => _edit(
        applyTransition(_state, [
          for (final c in selected) c.id,
        ], ClipTransition(kind: kind, durationS: _transitionDuration)),
      ),
      onClear: () => _edit(
        applyTransition(_state, [for (final c in selected) c.id], null),
      ),
      onBeat: _beats.isEmpty || selected.isEmpty
          ? null
          : () {
              final (s, moved) = landOnBeats(
                _state,
                {for (final c in selected) c.id},
                _beats,
              );
              _edit(s);
              _notify(
                moved == selected.length
                    ? 'On the beat.'
                    : moved == 0
                    ? 'Already on the beat, or no room to move there.'
                    : '$moved of ${selected.length} moved; the others had '
                          'no room at their beat.',
              );
            },
      onDuration: (d) {
        setState(() => _transitionDuration = d);
        // clips that already have a transition follow the adjustment: it is
        // the clip being looked at, and moving the control without changing
        // it would be odd
        var s = _state;
        for (final c in selected) {
          final t = c.transition;
          if (t != null) {
            s = applyTransition(s, [c.id], t.copyWith(durationS: d));
          }
        }
        _edit(s);
      },
      onGestureStart: _history.startGesture,
      onGestureEnd: _history.endGesture,
    );
  }

  /// Does the clip live on an audio layer?
  bool _isAudioClip(String id) {
    final where = _state.locate(id);
    return where != null && _state.layers[where.$1].isAudio;
  }

  Widget _libraryPanel({required bool docked}) => _Library(
    itemList: _library,
    sending: _importing,
    err: _importError,
    enabled: !_sending,
    docked: docked,
    onImport: _import,
    onUse: _useMedia,
    onRemove: _removeFromLibrary,
  );

  Widget _moments({required bool docked}) => _Moments(
    jobId: widget.job.id,
    videoUrl: widget.job.monitorUrl,
    recordingS: widget.job.durationS,
    moments: _matchMoments,
    usedKeys: {for (final c in _state.clips) momentKey(c.kind, c.sourceT)},
    enabled: !_sending,
    docked: docked,
    onAdd: _add,
  );

  /// The settings: the selected clip, the mix, the beat grid, the export and
  /// the render. Under the ruler on a narrow screen, in the right-hand
  /// sidebar on a wide one.
  List<Widget> _settingsChildren({required bool dockMoments}) {
    final theme = Theme.of(context);
    final durationValue = videoDuration(_state.clips);
    final blackS = blackDuration(_state.clips);
    final selectionIds = _state.selectionIds;
    return <Widget>[
      if (selectionIds.length == 1) ...[
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _SelectedBlock(
            cut: _state.clipItem(selectionIds.first)!,
            mediaItem: _blockMedia(selectionIds.first),
            onSpeed: (v) => _effect(selectionIds.first, speed: v),
            onColor: (v) => _effect(selectionIds.first, color: v),
            onFade: (v) => _effect(selectionIds.first, fade: v),
            onZoom: (v) => _effect(selectionIds.first, zoom: v),
            onFreeze: (v) => _effect(selectionIds.first, freeze: v),
            onReverse: (v) => _effect(selectionIds.first, reverse: v),
            onStyle: (v) =>
                _edit(changeText(_state, selectionIds.first, styleSpec: v)),
            onTypeOnFrame: () => _typeOnFrame(selectionIds.first),
            onDurationChange: (d) => _stretch(selectionIds.first, d),
            onShift: (d) => _shift(selectionIds.first, d),
            onToCursor: () => _move(selectionIds.first, _cursor),
            onMomentAtCursor: () => _alignMomentToCursor(selectionIds.first),
            onDelete: _deleteSelection,
            onSplit: _splitAtCursor,
            onDuplicate: _duplicate,
            motion: _picturePanels(selectionIds.first),
            fonts: _fonts,
            onRamp: () => _rampIntoMoment(selectionIds.first),
          ),
        ),
      ] else if (selectionIds.length > 1) ...[
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _MultiSelection(
            count: selectionIds.length,
            onDelete: _deleteSelection,
            onDuplicate: _duplicate,
            onClearSelection: () => _select(null),
            onRippleDelete: _rippleDeleteSelection,
            onPasteEffects: _effectsFrom == null ? null : _pasteEffects,
          ),
        ),
      ],

      if (_hasMusic) ...[
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _Mix(
            musicVolume: _state.musicVolume,
            gameVolume: _state.gameVolume,
            hasMusic: true,
            onChange: (music, game) => _edit(
              _state.copyWith(musicVolume: music, gameVolume: game),
            ),
            duckPlays: _state.duckPlays,
            duckLevel: _state.duckLevel,
            plays: playTimes(_state.layers).length,
            onDuck: (on, level) =>
                _edit(_state.copyWith(duckPlays: on, duckLevel: level)),
          ),
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _BeatGrid(
            offsetS: _state.beatOffsetS,
            multiplier: _state.beatMultiplier,
            bar: _state.beatBar,
            howMany: _beats.length,
            onChange: (offset, mult, bar) => _edit(
              _state.copyWith(
                beatOffsetS: offset,
                beatMultiplier: mult,
                beatBar: bar,
              ),
            ),
          ),
        ),
      ],

      if (dockMoments) ...[
        const SizedBox(height: 18),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _moments(docked: true),
        ),
        const SizedBox(height: 18),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _recordingPanel(),
        ),
        const SizedBox(height: 18),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _libraryPanel(docked: true),
        ),
        const SizedBox(height: 18),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _transitions(docked: true),
        ),
      ],

      const SizedBox(height: 14),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: _ExportPanel(
          spec: _state.export,
          durationSecs: durationValue,
          widthPx: widget.job.width,
          heightPx: widget.job.height,
          hasSelection: selectionIds.isNotEmpty,
          pictures: [
            for (final m in _library)
              if (m.kind == 'image' && m.isReady) m,
          ],
          enabled: !_sending,
          onChange: (e) => _edit(_state.copyWith(export: e)),
          onExportSelection: () => _edit(exportSelection(_state)),
          onExportAll: () => _edit(exportAll(_state)),
        ),
      ),

      const SizedBox(height: 20),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _title,
              enabled: !_sending,
              // Tapping outside gives the focus back to the montage, and the
              // shortcuts with it. Nothing takes the focus away from a
              // `TextField` on its own: without this, one tap here killed "S"
              // and Delete for good.
              onTapOutside: (_) => _restoreFocus(),
              onChanged: (v) => _withoutHistory(_state.copyWith(title: v)),
              decoration: const InputDecoration(
                labelText: 'Video name',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              _state.isBlank
                  ? 'Pick a moment to place the first cut where the '
                        'playhead is.'
                  // a music block is not a cut: whoever counts cuts wants to
                  // know how many scenes the video has
                  // a clip covered in the middle becomes two pieces on the
                  // monitor, but it is still one cut
                  : '${{for (final c in _state.visibleClips) c.id}.length} cut(s)'
                        '${_hasMusic ? '  ·  with music' : ''}'
                        '  ·  ${formatDuration(durationValue)} video'
                        '${blackS > 0.05 ? '  ·  ${formatDuration(blackS)} of black screen' : ''}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
              ),
            ),
            if (blackS > 0.05)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Empty gaps between blocks stay black, with the '
                  'music playing.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.hintColor,
                  ),
                ),
              ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.error.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            ],
            const SizedBox(height: 16),
            if (_sending)
              const Center(child: CircularProgressIndicator())
            else
              FilledButton.icon(
                onPressed: _state.isBlank ? null : _render,
                icon: const Icon(Icons.movie_creation_outlined),
                label: Text(
                  _state.isBlank
                      ? 'Add at least one cut'
                      : 'Render this video',
                ),
              ),
          ],
        ),
      ),
    ];

  }

  Widget _main({required bool dockMoments, bool settingsAside = false}) {
    final theme = Theme.of(context);
    final selectionIds = _state.selectionIds;

    // The monitor, transport and ruler stay pinned at the top; only the panels
    // below scroll. Scrolling to the bottom to adjust an effect and losing
    // sight of the video and the ruler was editing blind.
    //
    // In a short window the pinned part would take the whole screen: past 70%
    // of the height it scrolls by itself, and the panels stay within reach.
    final pinned = <Widget>[
      const SizedBox(height: 8),
      // ── the monitor, with the height handle ─────────────────────────────
      if (widget.job.monitorUrl != null) ...[
        SizedBox(
          height: _monitorH,
          child: Stack(
            children: [
              Positioned.fill(
                child: Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: _fullscreen
                        ? const SizedBox.shrink()
                        : _monitorView(),
                  ),
                ),
              ),
              Positioned(top: 4, right: 4, child: _playbackControls()),
            ],
          ),
        ),
        _HeightHandle(
          key: const Key('monitor-handle'),
          onDrag: (dy) =>
              setState(() => _monitorH = (_monitorH + dy).clamp(120.0, 560.0)),
        ),
      ],

      // ── transport ───────────────────────────────────────────────────────
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
        child: Row(
          children: [
            IconButton.filledTonal(
              // depends on there being something to play, not on music: a
              // video with no track at all is still a video to review
              onPressed: _state.isBlank ? null : _togglePlay,
              icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(formatClock(_cursor), style: theme.textTheme.titleMedium),
                // the ruler is the time of the output video, and nothing else:
                // the music lives in it, not it in the music
                Text(
                  'of ${formatClock(videoDuration(_state.clips))}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.hintColor,
                  ),
                ),
              ],
            ),
            const SizedBox(width: 6),
            IconButton(
              key: const Key('exact-preview-button'),
              tooltip: 'Exact preview — render this stretch on the server',
              onPressed: _state.isBlank || (_exact?.isWorking ?? false)
                  ? null
                  : _requestExact,
              icon: const Icon(Icons.high_quality_outlined),
            ),
            // On a narrow screen these controls do not fit next to the
            // clock. `reverse` keeps them against the right edge when they
            // fit, and scrolling when not — instead of breaking the layout.
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                reverse: true,
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Split at the cursor (S)',
                      onPressed: _state.isBlank ? null : _splitAtCursor,
                      icon: const Icon(Icons.content_cut),
                    ),
                    PopupMenuButton<String>(
                      tooltip: 'Write on screen',
                      icon: const Icon(Icons.title),
                      onSelected: (v) => switch (v) {
                        'free' => _addText('TEXT'),
                        'counter' => _generateLabels(
                          killCounter(_state.clips),
                          'kills',
                        ),
                        'streak' => _generateLabels(
                          streakLabels(_state.clips),
                          'streaks',
                        ),
                        _ => null,
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: 'free',
                          child: Text('Free text'),
                        ),
                        PopupMenuDivider(),
                        PopupMenuItem(
                          value: 'counter',
                          child: Text('Kill counter'),
                        ),
                        PopupMenuItem(
                          value: 'streak',
                          child: Text('Streak labels'),
                        ),
                      ],
                    ),
                    IconButton(
                      tooltip: 'New layer',
                      onPressed: () => _edit(addLayer(_state)),
                      icon: const Icon(Icons.layers_outlined),
                    ),
                    IconButton(
                      key: const Key('new-music-layer'),
                      tooltip: 'New music layer',
                      onPressed: _newMusicLayer,
                      icon: const Icon(Icons.queue_music_outlined),
                    ),
                    IconButton(
                      tooltip: _state.layers.length > 1
                          ? 'Remove the active layer'
                          : 'The last layer cannot be removed',
                      onPressed: _state.layers.length > 1
                          ? () => _edit(
                              removeLayer(_state, _state.activeLayer),
                            )
                          : null,
                      icon: const Icon(Icons.layers_clear_outlined),
                    ),
                    IconButton(
                      key: const Key('add-marker'),
                      tooltip: markerAt(_state, _cursor) == null
                          ? 'Marker at the playhead (N)'
                          : 'Remove the marker at the playhead (N)',
                      onPressed: _toggleMarker,
                      icon: Icon(
                        markerAt(_state, _cursor) == null
                            ? Icons.bookmark_add_outlined
                            : Icons.bookmark_remove_outlined,
                      ),
                    ),
                    IconButton(
                      key: const Key('zoom-fit'),
                      tooltip: 'Fit the whole montage (\\)',
                      onPressed: _zoomToFit,
                      icon: const Icon(Icons.fit_screen_outlined),
                    ),
                    const Icon(Icons.zoom_out, size: 18),
                    SizedBox(
                      width: 120,
                      child: Slider(
                        key: const Key('zoom-slider'),
                        value: zoomToSlider(_px),
                        onChanged: (v) => _setZoom(sliderToZoom(v)),
                      ),
                    ),
                    const Icon(Icons.zoom_in, size: 18),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),

      // ── the music ruler with the blocks ─────────────────────────────────
      MusicTimeline(
        tracks: _tracks,
        beatTimes: _beats,
        layers: _state.layers,
        activeLayer: _state.activeLayer,
        selectionIds: selectionIds,
        pxPerSecond: _px,
        playheadS: _cursor,
        scroll: _scroll,
        onSeek: (s) => _goTo(s, reveal: false),
        onSelect: _select,
        onMove: _move,
        onTrim: _trim,
        onStretch: _stretch,
        onDragLabel: (textValue) => setState(() => _dragLabel = textValue),
        onGestureStart: _history.startGesture,
        onGestureEnd: () {
          _history.endGesture();
          // the guide only lives while the clip is held
          if (_snapGuide != null) setState(() => _snapGuide = null);
        },
        snapGuideS: _snapGuide,
        onZoom: (factor, anchorS, anchorDx) =>
            _setZoom(_px * factor, anchorS: anchorS, anchorDx: anchorDx),
        onChangeLayer: _changeLayer,
        onDropClip: _dropClip,
        onDuplicateClip: (id) => _edit(duplicate(_state, {id})),
        onDeleteClip: (id) => _edit(removeClips(_state, {id})),
        onRippleDeleteClip: (id) => _edit(rippleDelete(_state, {id})),
        onCopyEffects: _copyEffects,
        onPasteEffects: _effectsFrom == null
            ? null
            : (id) => _pasteEffects(
                // pasting on a clip of the selection pastes on all of it
                _state.selectionIds.contains(id) ? _state.selectionIds : {id},
              ),
        onSelectMany: (ids, {bool add = false}) => _withoutHistory(
          _state.copyWith(
            selectionIds: add ? {..._state.selectionIds, ...ids} : ids,
          ),
        ),
        onActiveLayer: (i) => _withoutHistory(_state.copyWith(activeLayer: i)),
        onReorderLayers: (from, to) =>
            _edit(reorderLayers(_state, from, to)),
        onRenameLayer: (i, name) => _edit(adjustLayer(_state, i, name: name)),
        onRemoveLayer: (i) => _edit(removeLayer(_state, i)),
        markers: _state.markers,
        onMoveMarker: (i, t) => _edit(moveMarker(_state, i, t)),
        onRenameMarker: (i, label) => _edit(renameMarker(_state, i, label)),
        onRemoveMarker: (i) => _edit(removeMarker(_state, i)),
        trackHeight: _trackHeight,
        onTrackHeight: (h) => setState(() => _trackHeight = h),
        range: switch (_range) {
          final r? => (r.from, r.to),
          null => null,
        },
        onRange: (from, to) => _edit(
          _state.copyWith(
            export: _state.export.copyWith(fromS: from, toS: to),
          ),
        ),
        onAdjustLayer: (i, {muted, hidden, locked, collapsed}) => _edit(
          adjustLayer(
            _state,
            i,
            muted: muted,
            hidden: hidden,
            locked: locked,
            collapsed: collapsed,
          ),
        ),
        matchWaveform: widget.job.waveform,
        matchDuration: widget.job.durationS,
        onDrop: _dropOnRuler,
      ),

      Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
        child: Text(
          _dragLabel ??
              (_musicError ??
                  'Drag a moment or a Library item onto the timeline.'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: _dragLabel != null
                ? theme.colorScheme.primary
                : _musicError != null
                ? theme.colorScheme.error
                : theme.hintColor,
          ),
        ),
      ),

      const SizedBox(height: 4),
    ];

    final scrolling = _settingsChildren(dockMoments: dockMoments);

    // wide: the settings live in the sidebar on the right, and the monitor,
    // transport and ruler have the whole height
    if (settingsAside) {
      return SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: pinned,
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, box) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: box.maxHeight * 0.7),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: pinned,
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              key: const Key('montage-panels'),
              padding: const EdgeInsets.fromLTRB(0, 0, 0, 32),
              children: scrolling,
            ),
          ),
        ],
      ),
    );
  }
}

/// The name of the open montage, and the door to the others.
///
/// It takes the place of the screen title on purpose: in a match with three
/// montages, knowing **which** one is open matters more than reading "Build
/// video" for the tenth time.
class _MontagePicker extends StatelessWidget {
  const _MontagePicker({
    required this.displayName,
    required this.montageList,
    required this.present,
    required this.onOpen,
    required this.onNew,
  });

  final String displayName;
  final List<SavedMontage> montageList;
  final String? present;
  final ValueChanged<SavedMontage> onOpen;
  final VoidCallback onNew;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopupMenuButton<String>(
      key: const Key('montage-picker'),
      tooltip: 'Montages of this match',
      onSelected: (v) {
        if (v == '+') {
          onNew();
          return;
        }
        final m = montageList.where((x) => x.id == v).firstOrNull;
        if (m != null) onOpen(m);
      },
      itemBuilder: (_) => [
        for (final m in montageList)
          PopupMenuItem(
            value: m.id,
            key: ValueKey('open-${m.id}'),
            child: Row(
              children: [
                Icon(
                  m.id == present ? Icons.check : Icons.movie_outlined,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(m.name, overflow: TextOverflow.ellipsis),
                      Text(
                        m.isEmpty
                            ? 'empty'
                            : '${m.nClips} cut(s) · '
                                  '${formatDuration(m.durationS)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.hintColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        if (montageList.isNotEmpty) const PopupMenuDivider(),
        const PopupMenuItem(
          value: '+',
          child: Row(
            children: [
              Icon(Icons.add, size: 18),
              SizedBox(width: 8),
              Text('New montage'),
            ],
          ),
        ),
      ],
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: Text(displayName, overflow: TextOverflow.ellipsis)),
          const Icon(Icons.arrow_drop_down),
        ],
      ),
    );
  }
}

/// A row of the shortcut list.
class _Shortcut extends StatelessWidget {
  const _Shortcut(this.keyName, this.whatItDoes);

  final String keyName;
  final String whatItDoes;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        SizedBox(
          width: 170,
          child: Text(keyName, style: const TextStyle(fontFeatures: [])),
        ),
        Expanded(
          child: Text(
            whatItDoes,
            style: TextStyle(color: Theme.of(context).hintColor),
          ),
        ),
      ],
    ),
  );
}

/// The beat grid control.
///
/// The rhythm detector gets the tempo right almost always and fails in two
/// predictable ways: it picks the off-beat, or counts double/half the beats.
/// Neither is fixed by dragging block by block — what is wrong is the ruler,
/// and straightening it fixes all of them at once.
class _BeatGrid extends StatelessWidget {
  const _BeatGrid({
    required this.offsetS,
    required this.multiplier,
    required this.bar,
    required this.howMany,
    required this.onChange,
  });

  final double offsetS;
  final double multiplier;
  final int bar;
  final int howMany;

  /// (offset, multiplier, bar)
  final void Function(double, double, int) onChange;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final adjusted = offsetS != 0 || multiplier != 1 || bar != 1;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.straighten, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Beat grid',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                Text(
                  '$howMany in the video',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.hintColor,
                  ),
                ),
                if (adjusted)
                  TextButton(
                    onPressed: () => onChange(0, 1, 1),
                    child: const Text('As detected'),
                  ),
              ],
            ),
            Text(
              'If the magnet snaps off the beat, this is where you fix it '
              '— and it fixes every cut at once.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Expanded(child: Text('Density')),
                SegmentedButton<double>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                  segments: const [
                    ButtonSegment(value: 0.5, label: Text('½')),
                    ButtonSegment(value: 1.0, label: Text('1×')),
                    ButtonSegment(value: 2.0, label: Text('2×')),
                  ],
                  selected: {multiplier},
                  onSelectionChanged: (v) =>
                      onChange(offsetS, v.first, bar),
                ),
              ],
            ),
            Row(
              children: [
                const Expanded(child: Text('Snap to')),
                SegmentedButton<int>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                  segments: const [
                    ButtonSegment(value: 1, label: Text('beat')),
                    ButtonSegment(value: 2, label: Text('2')),
                    ButtonSegment(value: 4, label: Text('bar')),
                  ],
                  selected: {bar},
                  onSelectionChanged: (v) =>
                      onChange(offsetS, multiplier, v.first),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    offsetS == 0
                        ? 'Offset'
                        : 'Offset ${offsetS > 0 ? '+' : ''}'
                              '${offsetS.toStringAsFixed(2)}s',
                  ),
                ),
                _Step(
                  onLess: () =>
                      onChange(offsetS - 0.02, multiplier, bar),
                  onMore: () =>
                      onChange(offsetS + 0.02, multiplier, bar),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The panel for when more than one block is selected.
class _MultiSelection extends StatelessWidget {
  const _MultiSelection({
    required this.count,
    required this.onDelete,
    required this.onDuplicate,
    required this.onClearSelection,
    required this.onRippleDelete,
    this.onPasteEffects,
  });

  final int count;

  /// `null` while nothing was copied.
  final VoidCallback? onPasteEffects;
  final VoidCallback onDelete;
  final VoidCallback onRippleDelete;
  final VoidCallback onDuplicate;
  final VoidCallback onClearSelection;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      child: Row(
        children: [
          Expanded(child: Text('$count cuts selected')),
          IconButton(
            tooltip: 'Duplicate (Ctrl+D)',
            onPressed: onDuplicate,
            icon: const Icon(Icons.copy_all_outlined),
          ),
          IconButton(
            tooltip: 'Remove from the montage (Delete)',
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline),
          ),
          IconButton(
            key: const Key('paste-effects'),
            tooltip: 'Paste effects (Ctrl+Shift+V)',
            onPressed: onPasteEffects,
            icon: const Icon(Icons.format_paint_outlined),
          ),
          IconButton(
            key: const Key('ripple-delete'),
            tooltip: 'Remove and close the gaps (Shift+Delete)',
            onPressed: onRippleDelete,
            icon: const Icon(Icons.format_indent_decrease),
          ),
          IconButton(
            tooltip: 'Clear the selection (Esc)',
            onPressed: onClearSelection,
            icon: const Icon(Icons.deselect),
          ),
        ],
      ),
    ),
  );
}

/// The handle that changes the monitor height.
///
/// An editor splits the screen between seeing the frame and seeing the rhythm,
/// and the right split changes every minute of work — so whoever is editing decides.
class _HeightHandle extends StatelessWidget {
  const _HeightHandle({super.key, required this.onDrag});

  final ValueChanged<double> onDrag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.resizeUpDown,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (d) => onDrag(d.delta.dy),
        child: SizedBox(
          height: 16,
          child: Center(
            child: Container(
              width: 46,
              height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SelectedBlock extends StatelessWidget {
  const _SelectedBlock({
    required this.cut,
    required this.mediaItem,
    required this.onDurationChange,
    required this.onShift,
    required this.onToCursor,
    required this.onMomentAtCursor,
    required this.onDelete,
    required this.onSplit,
    required this.onDuplicate,
    required this.onSpeed,
    required this.onColor,
    required this.onFade,
    required this.onZoom,
    required this.onFreeze,
    required this.onReverse,
    required this.onStyle,
    required this.onTypeOnFrame,
    this.motion,
    this.onRamp,
    this.fonts,
  });

  final TimelineClip cut;

  /// Position, scale, opacity and volume — `null` when the clip has none.
  final Widget? motion;

  /// The slow-motion ramp around the play.
  final VoidCallback? onRamp;

  /// The fonts a text can use.
  final FontLibrary? fonts;

  /// The file the block came from, when it came from the library. A music
  /// block talks about the sound, not the picture — which it does not have.
  final Media? mediaItem;

  final ValueChanged<double> onDurationChange;
  final ValueChanged<double> onShift;
  final VoidCallback onToCursor;

  /// Brings this block's play under the playhead.
  final VoidCallback onMomentAtCursor;
  final VoidCallback onDelete;
  final VoidCallback onSplit;
  final VoidCallback onDuplicate;
  final ValueChanged<double> onSpeed;
  final ValueChanged<ClipColor> onColor;
  final ValueChanged<ClipFade> onFade;
  final ValueChanged<List<ZoomKey>> onZoom;
  final ValueChanged<bool> onFreeze;
  final ValueChanged<bool> onReverse;
  final ValueChanged<ClipTextStyle> onStyle;

  /// Opens typing on the monitor, over the video.
  final VoidCallback onTypeOnFrame;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = EventStyle.of(cut.kind);
    final m = mediaItem;
    final sound = m?.isAudio ?? false;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  sound
                      ? Icons.music_note
                      : m != null
                      ? Icons.movie_outlined
                      : Icons.crop_free,
                  size: 16,
                  color: m == null ? style.color : theme.colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    cut.label.isNotEmpty
                        ? cut.label
                        : m != null
                        ? m.name
                        : cut.sourceT > 0
                        ? '${style.label} at ${formatClock(cut.sourceT)}'
                        // a hand-made cut has no moment: say where it starts
                        : '${style.label} from ${formatClock(cut.startS)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                IconButton(
                  tooltip: 'Split at the cursor (S)',
                  visualDensity: VisualDensity.compact,
                  onPressed: onSplit,
                  icon: const Icon(Icons.content_cut),
                ),
                IconButton(
                  tooltip: 'Duplicate (Ctrl+D)',
                  visualDensity: VisualDensity.compact,
                  onPressed: onDuplicate,
                  icon: const Icon(Icons.copy_all_outlined),
                ),
                IconButton(
                  tooltip: 'Remove from the montage (Delete)',
                  visualDensity: VisualDensity.compact,
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            Text(
              'enters at ${formatClock(cut.atS)} of the video  ·  '
              '${cut.durationS.toStringAsFixed(2)}s'
              // which point of the track this piece came from: it tells whether
              // the block took the chorus or the intro
              '${sound ? '  ·  from ${formatClock(cut.startS)} of the song' : ''}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                const Expanded(child: Text('Duration')),
                _Step(
                  onLess: () => onDurationChange(cut.durationS - 0.1),
                  onMore: () => onDurationChange(cut.durationS + 0.1),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: Text(sound ? 'Song span' : 'Framing'),
                ),
                _Step(
                  onLess: () => onShift(-0.2),
                  onMore: () => onShift(0.2),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  // Align by the **play**, not by the edge: the cut starts
                  // before it for the run-up, and it is the play that must land
                  // on the beat. Only shown when there is a play inside the block.
                  if (momentInVideo(cut) != null)
                    TextButton.icon(
                      key: const Key('align-moment'),
                      onPressed: onMomentAtCursor,
                      icon: const Icon(Icons.center_focus_strong, size: 18),
                      label: const Text('Align the play to the cursor'),
                    ),
                  TextButton.icon(
                    onPressed: onToCursor,
                    icon: const Icon(Icons.vertical_align_center, size: 18),
                    label: const Text('Move to the cursor'),
                  ),
                ],
              ),
            ),
            if (cut.isText)
              _ClipText(
                cut: cut,
                onStyle: onStyle,
                onTypeOnFrame: onTypeOnFrame,
                fonts: fonts,
              ),
            ?motion,
            // a music block draws nothing: zoom, colour and freeze would have
            // nothing to act on
            if (!sound)
              _Effects(
                cut: cut,
                onSpeed: onSpeed,
                onColor: onColor,
                onFade: onFade,
                onZoom: onZoom,
                onFreeze: onFreeze,
                onReverse: onReverse,
                onRamp: momentInVideo(cut) == null ? null : onRamp,
              ),
          ],
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.onLess, required this.onMore});

  final VoidCallback onLess;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(
        visualDensity: VisualDensity.compact,
        onPressed: onLess,
        icon: const Icon(Icons.remove_circle_outline),
      ),
      IconButton(
        visualDensity: VisualDensity.compact,
        onPressed: onMore,
        icon: const Icon(Icons.add_circle_outline),
      ),
    ],
  );
}

/// Transitions: how the selected clip enters over the previous one.
class _Transitions extends StatelessWidget {
  const _Transitions({
    required this.selected,
    required this.duration,
    required this.enabled,
    required this.docked,
    required this.onApply,
    required this.onClear,
    required this.onDuration,
    this.onBeat,
    required this.onGestureStart,
    required this.onGestureEnd,
  });

  /// The picture clips selected on the ruler — the transition goes on them.
  final List<TimelineClip> selected;
  final double duration;
  final bool enabled;

  /// `true` when the list lives inside the main column (narrow screen) and so
  /// cannot scroll on its own.
  final bool docked;
  final ValueChanged<String> onApply;
  final VoidCallback onClear;
  final ValueChanged<double> onDuration;

  /// Moves the selected clips' entrances onto the nearest beat; `null` when
  /// there is no music grid or nothing selected.
  final VoidCallback? onBeat;
  final VoidCallback onGestureStart;
  final VoidCallback onGestureEnd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canApply = enabled && selected.isNotEmpty;
    // the one all selected clips share, to highlight in the list
    final kinds = {for (final c in selected) c.transition?.kind};
    final current = kinds.length == 1 ? kinds.single : null;
    final anyHasOne = selected.any((c) => c.transition != null);

    final header = Padding(
      padding: EdgeInsets.fromLTRB(docked ? 0 : 14, 12, 14, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Transitions', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            selected.isEmpty
                ? 'Pick a clip on the ruler: the transition applies to its '
                      'entrance, at the cut with the previous clip.'
                : selected.length == 1
                ? 'Tap a transition for the selected clip\'s entrance.'
                : 'Tap a transition for the entrance of the '
                      '${selected.length} selected clips.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ],
      ),
    );

    final controls = Padding(
      padding: EdgeInsets.fromLTRB(docked ? 0 : 14, 0, 14, 0),
      child: Row(
        children: [
          const Text('Duration'),
          Expanded(
            child: Slider(
              key: const Key('transition-duration'),
              value: duration,
              min: ClipTransition.minS,
              max: 2,
              divisions: 19,
              label: '${duration.toStringAsFixed(1)}s',
              onChangeStart: (_) => onGestureStart(),
              onChangeEnd: (_) => onGestureEnd(),
              onChanged: enabled ? onDuration : null,
            ),
          ),
          Text('${duration.toStringAsFixed(1)}s'),
        ],
      ),
    );

    final items = [
      for (final t in TransitionType.all)
        ListTile(
          key: ValueKey('transition-${t.kind}'),
          dense: true,
          enabled: canApply,
          selected: current == t.kind,
          contentPadding: EdgeInsets.symmetric(horizontal: docked ? 0 : 14),
          leading: Icon(t.icon),
          title: Text(t.name),
          subtitle: Text(t.description),
          onTap: () => onApply(t.kind),
        ),
      Padding(
        padding: EdgeInsets.fromLTRB(docked ? 0 : 8, 4, 8, 12),
        child: Wrap(
          spacing: 4,
          children: [
            TextButton.icon(
              key: const Key('no-transition'),
              onPressed: canApply && anyHasOne ? onClear : null,
              icon: const Icon(Icons.content_cut, size: 18),
              label: const Text('Hard cut (no transition)'),
            ),
            Tooltip(
              message: onBeat == null
                  ? 'Needs music on the timeline and a selected clip'
                  : 'Move the selected clips so their entrance lands on the '
                        'nearest beat',
              child: TextButton.icon(
                key: const Key('land-on-beat'),
                onPressed: enabled ? onBeat : null,
                icon: const Icon(Icons.graphic_eq, size: 18),
                label: const Text('Land on the beat'),
              ),
            ),
          ],
        ),
      ),
    ];

    if (docked) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [header, controls, ...items],
      );
    }
    return ListView(children: [header, controls, ...items]);
  }
}

/// The moment shelf: what can go into the video.
///
/// Each item carries the frame of that instant of the match. Without a picture,
/// choosing among thirty kills is choosing among thirty clocks — and the
/// difference between the play that matters and the others is precisely in
/// what you see.
///
/// A moment is not used up: the item stays there, marked, because the same
/// instant can go into the same montage twice.
class _Moments extends StatelessWidget {
  const _Moments({
    required this.jobId,
    required this.videoUrl,
    required this.recordingS,
    required this.moments,
    required this.usedKeys,
    required this.enabled,
    required this.docked,
    required this.onAdd,
  });

  final String jobId;

  /// What the hover preview plays; `null` when the match has no recording to
  /// play from, and then there is no preview.
  final String? videoUrl;
  final double recordingS;
  final List<DetectionEvent> moments;

  /// The moments already on the ruler, by [momentKey].
  ///
  /// By kind **and** instant, not only by instant: a headshot kill lights up
  /// both detectors almost together, and marking by time would make placing the
  /// kill strike out the headshot that has not gone in yet.
  final Set<String> usedKeys;
  final bool enabled;

  /// `true` when the list lives inside the main column (narrow screen) and so
  /// cannot scroll on its own.
  final bool docked;
  final ValueChanged<DetectionEvent> onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (moments.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          'The analysis found no moments in this match.',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
        ),
      );
    }

    final headerWidget = Padding(
      padding: EdgeInsets.fromLTRB(docked ? 0 : 14, 12, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Match moments', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            'Click to place the cut where the song is. The same moment '
            'can go in more than once.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ],
      ),
    );

    final itemList = [
      for (final e in moments)
        _MomentTile(
          // kind + instant: two detectors can land on the same time, and two
          // equal keys in the same list bring the screen down
          key: ValueKey('moment-${momentKey(e.kind, e.t)}'),
          jobId: jobId,
          videoUrl: videoUrl,
          recordingS: recordingS,
          event: e,
          used: usedKeys.contains(momentKey(e.kind, e.t)),
          enabled: enabled,
          onAdd: () => onAdd(e),
        ),
    ];

    if (docked) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [headerWidget, ...itemList],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        headerWidget,
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 24),
            children: itemList,
          ),
        ),
      ],
    );
  }
}

/// What sits under the finger while dragging to the ruler.
///
/// A rectangle the size and colour of the block about to be born: the gesture
/// shows the result before it happens.
class _DropGhost extends StatelessWidget {
  const _DropGhost({required this.textClip, required this.fillColour});

  final String textClip;
  final Color fillColour;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: Container(
      width: 140,
      height: 44,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: fillColour.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        textClip,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white, fontSize: 12),
      ),
    ),
  );
}

class _MomentTile extends StatelessWidget {
  const _MomentTile({
    super.key,
    required this.jobId,
    required this.videoUrl,
    required this.recordingS,
    required this.event,
    required this.used,
    required this.enabled,
    required this.onAdd,
  });

  final String jobId;
  final String? videoUrl;
  final double recordingS;
  final DetectionEvent event;
  final bool used;
  final bool enabled;
  final VoidCallback onAdd;

  /// The name this moment carries on the card and on the ghost.
  ///
  /// An ability kill says **which** — "Orisa: Energy Javelin" and not "Ability
  /// kill". In a match with five different abilities, the generic label would
  /// give five identical cards, and choosing among them would be choosing in
  /// the dark.
  String get _label {
    final ability = event.ability;
    return ability != null
        ? abilityName(ability)
        : EventStyle.of(event.kind).label;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = EventStyle.of(event.kind);

    // `affinity: horizontal` lets the shelf keep scrolling vertically: the
    // drag that matters is the one leaving it towards the ruler
    return Draggable<RulerDrop>(
      data: RulerDrop.moment(event),
      affinity: Axis.horizontal,
      // the ghost hangs from the finger, not from the point of the card where
      // it was grabbed: the finger says where the block lands, and the ruler
      // does that maths with the ghost's corner
      dragAnchorStrategy: pointerDragAnchorStrategy,
      maxSimultaneousDrags: enabled ? 1 : 0,
      feedback: _DropGhost(textClip: _label, fillColour: style.color),
      childWhenDragging: Opacity(
        opacity: 0.4,
        child: _card(context, theme, style),
      ),
      child: videoUrl == null
          ? _card(context, theme, style)
          : MomentHoverPreview(
              videoUrl: videoUrl!,
              t: event.t,
              recordingS: recordingS,
              child: _card(context, theme, style),
            ),
    );
  }

  Widget _card(BuildContext context, ThemeData theme, EventStyle style) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: enabled ? onAdd : null,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: _Frame(
                  url: frameUrl(jobId, event.t),
                  fillColour: style.color,
                  widthPx: 104,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: style.color,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      formatClock(event.t),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.hintColor,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                used ? Icons.check_circle : Icons.add_circle_outline,
                size: 20,
                color: used ? style.color : theme.hintColor,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A moment's frame, patient enough to wait for it to exist.
///
/// Thumbnails are extracted by a worker after the analysis, so in a freshly
/// opened match they may not be there yet — and an old match only gets its
/// own when the editor asks. Instead of showing a final error, the frame
/// retries a few times and shows up on its own.
class _Frame extends StatefulWidget {
  const _Frame({required this.url, required this.fillColour, required this.widthPx});

  final String url;
  final Color fillColour;
  final double widthPx;

  @override
  State<_Frame> createState() => _FrameState();
}

class _FrameState extends State<_Frame> {
  static const _maxAttempts = 6;
  int _attempt = 0;
  Timer? _next;

  @override
  void dispose() {
    _next?.cancel();
    super.dispose();
  }

  void _retry() {
    if (_attempt >= _maxAttempts || _next != null) return;
    _next = Timer(const Duration(seconds: 3), () async {
      _next = null;
      // without evicting, Flutter keeps the 404 and never fetches this URL again
      await NetworkImage(widget.url).evict();
      if (mounted) setState(() => _attempt++);
    });
  }

  @override
  Widget build(BuildContext context) {
    final heightPx = widget.widthPx * 9 / 16;
    return SizedBox(
      width: widget.widthPx,
      height: heightPx,
      child: Image.network(
        widget.url,
        key: ValueKey('${widget.url}#$_attempt'),
        fit: BoxFit.cover,
        errorBuilder: (context, _, _) {
          _retry();
          return ColoredBox(
            color: widget.fillColour.withValues(alpha: 0.18),
            child: Center(
              child: Icon(
                Icons.image_outlined,
                size: 18,
                color: widget.fillColour.withValues(alpha: 0.7),
              ),
            ),
          );
        },
        loadingBuilder: (context, child, progress) => progress == null
            ? child
            : ColoredBox(color: widget.fillColour.withValues(alpha: 0.10)),
      ),
    );
  }
}

/// Says, discreetly, that the work is saved.
///
/// It exists because the montage came to live on the server: without a sign,
/// the user would have no way of knowing they can close the tab — and losing
/// everything on an F5 is precisely what motivated the autosave.
class _DraftStatus extends StatelessWidget {
  const _DraftStatus({
    required this.saving,
    required this.savedAt,
    required this.err,
    required this.onRetry,
  });

  final bool saving;
  final DateTime? savedAt;
  final String? err;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (err != null) {
      return TextButton.icon(
        onPressed: onRetry,
        icon: Icon(Icons.cloud_off, size: 16, color: theme.colorScheme.error),
        label: Text(
          'not saved',
          style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
        ),
      );
    }
    if (saving) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Center(
          child: Text(
            'saving…',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ),
      );
    }
    if (savedAt == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_done_outlined, size: 15, color: theme.hintColor),
            const SizedBox(width: 5),
            Text(
              'saved',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The match media library: what the user brought from outside.
///
/// It sits next to the moment shelf because both answer the same question —
/// "what do I put in now?". The difference is that the system found the
/// moments, and the user brought these.
class _Library extends StatelessWidget {
  const _Library({
    required this.itemList,
    required this.sending,
    required this.err,
    required this.enabled,
    required this.docked,
    required this.onImport,
    required this.onUse,
    required this.onRemove,
  });

  final List<Media> itemList;
  final bool sending;
  final String? err;
  final bool enabled;
  final bool docked;
  final VoidCallback onImport;
  final ValueChanged<Media> onUse;
  final ValueChanged<Media> onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final headerWidget = Padding(
      padding: EdgeInsets.fromLTRB(docked ? 0 : 14, 12, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Library', style: theme.textTheme.titleSmall),
              ),
              if (sending)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                TextButton.icon(
                  onPressed: enabled ? onImport : null,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Import'),
                ),
            ],
          ),
          Text(
            'Video, image or music from outside the match — this is where '
            'music comes in. Click to place it at the playhead, or drag it '
            'onto the timeline.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
          if (err != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                err!,
                style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
              ),
            ),
        ],
      ),
    );

    // music lives here with the rest: it is media from outside the match like
    // any other, and having a second door just for it is what made it look
    // like there were two ways of putting sound in the video
    final visuals = itemList;

    final list = visuals.isEmpty
        ? [
            Padding(
              padding: EdgeInsets.fromLTRB(docked ? 0 : 14, 0, 14, 12),
              child: Text(
                'Nothing here yet.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.hintColor,
                ),
              ),
            ),
          ]
        : [
            for (final m in visuals)
              _LibraryItem(
                key: ValueKey('media-${m.id}'),
                item: m,
                enabled: enabled,
                onUse: () => onUse(m),
                onRemove: () => onRemove(m),
              ),
          ];

    if (docked) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [headerWidget, ...list],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        headerWidget,
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 24),
            children: list,
          ),
        ),
      ],
    );
  }
}

class _LibraryItem extends StatelessWidget {
  const _LibraryItem({
    super.key,
    required this.item,
    required this.enabled,
    required this.onUse,
    required this.onRemove,
  });

  final Media item;
  final bool enabled;
  final VoidCallback onUse;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ready = item.isReady;

    return Draggable<RulerDrop>(
      data: RulerDrop.mediaItem(item),
      affinity: Axis.horizontal,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      maxSimultaneousDrags: enabled && ready ? 1 : 0,
      feedback: _DropGhost(
        textClip: item.name,
        fillColour: item.isAudio
            ? theme.colorScheme.primary
            : theme.colorScheme.secondary,
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: _card(theme, ready)),
      child: _card(theme, ready),
    );
  }

  Widget _card(ThemeData theme, bool ready) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: enabled && ready ? onUse : null,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  width: 72,
                  height: 41,
                  child: item.thumbUrl == null
                      ? ColoredBox(
                          color: theme.colorScheme.primary.withValues(
                            alpha: 0.15,
                          ),
                          child: Icon(
                            item.isAudio
                                ? Icons.music_note
                                : item.isImage
                                ? Icons.image_outlined
                                : Icons.movie_outlined,
                            size: 18,
                            color: item.isAudio
                                ? theme.colorScheme.primary
                                : theme.hintColor,
                          ),
                        )
                      : Image.network(item.thumbUrl!, fit: BoxFit.cover),
                  // sound has no thumbnail: the icon is what says what it is
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      item.isFailed
                          ? (item.error ?? 'could not read this file')
                          : item.isPending
                          ? 'analysing…'
                          : [
                              item.isImage
                                  ? 'image'
                                  : formatDuration(item.durationS),
                              if (item.width > 0)
                                '${item.width}×${item.height}',
                              // for music what matters is the tempo: it is
                              // what decides the cut length
                              if (item.isAudio && item.bpm > 0)
                                '${item.bpm.round()} BPM',
                            ].join('  ·  '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: item.isFailed
                            ? theme.colorScheme.error
                            : theme.hintColor,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Remove from the library',
                visualDensity: VisualDensity.compact,
                onPressed: enabled ? onRemove : null,
                icon: const Icon(Icons.close, size: 18),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The effects of the selected clip.
///
/// Collapsed by default: most montages are hard cuts, and an always-open
/// panel would push the timeline off the screen.
class _Effects extends StatelessWidget {
  const _Effects({
    required this.cut,
    required this.onSpeed,
    required this.onColor,
    required this.onFade,
    required this.onZoom,
    required this.onFreeze,
    required this.onReverse,
    this.onRamp,
  });

  final TimelineClip cut;
  final ValueChanged<double> onSpeed;
  final ValueChanged<ClipColor> onColor;
  final ValueChanged<ClipFade> onFade;
  final ValueChanged<List<ZoomKey>> onZoom;
  final ValueChanged<bool> onFreeze;
  final ValueChanged<bool> onReverse;

  /// Full speed into the play, slow motion through it — `null` when the clip
  /// has no play to ramp around.
  final VoidCallback? onRamp;

  /// How many effects are in use — so the title says something is there
  /// without having to open it.
  int get _active =>
      (cut.speed != 1 || cut.isRamped ? 1 : 0) +
      (cut.color.isNeutral ? 0 : 1) +
      (cut.fade.isNeutral ? 0 : 1) +
      (cut.zoom.isEmpty ? 0 : 1) +
      (cut.freeze ? 1 : 0) +
      (cut.reverse ? 1 : 0);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 8),
      title: Row(
        children: [
          const Icon(Icons.auto_fix_high, size: 16),
          const SizedBox(width: 8),
          Text('Effects', style: theme.textTheme.labelLarge),
          if (_active > 0) ...[
            const SizedBox(width: 8),
            Text(
              '$_active in use',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ],
        ],
      ),
      children: [
        // The zoom comes ready-made: two points cover the most used effect in a
        // montage, and that beats a curve editor nobody opens.
        Row(
          children: [
            const SizedBox(width: 92, child: Text('Zoom in')),
            Expanded(
              child: Wrap(
                spacing: 6,
                children: [
                  for (final (textClip, until) in const [
                    ('light', 1.3),
                    ('medium', 1.6),
                    ('strong', 2.2),
                  ])
                    ChoiceChip(
                      label: Text(textClip),
                      selected:
                          cut.zoom.isNotEmpty &&
                          (cut.zoom[1].scale - until).abs() < 0.01,
                      onSelected: (_) => onZoom(punch(until: until)),
                    ),
                  if (cut.zoom.isNotEmpty) ...[
                    // slow in and out of the punch: the camera move, not the cut
                    FilterChip(
                      key: const Key('zoom-smooth'),
                      label: const Text('smooth'),
                      selected: cut.zoom.first.ease == Ease.easeInOut,
                      onSelected: (on) => onZoom([
                        cut.zoom.first.copyWith(
                          ease: on ? Ease.easeInOut : Ease.linear,
                        ),
                        ...cut.zoom.skip(1),
                      ]),
                    ),
                    ActionChip(
                      avatar: const Icon(Icons.close, size: 14),
                      label: const Text('remove'),
                      onPressed: () => onZoom(const []),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: cut.freeze,
          onChanged: onFreeze,
          title: const Text('Freeze'),
          subtitle: const Text('the picture stops; the block lasts the same'),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: cut.reverse,
          onChanged: onReverse,
          title: const Text('Reverse'),
        ),
        if (cut.isRamped)
          // a ramp lives in Motion, as keyframes; one number here would lie
          ListTile(
            key: const Key('speed-ramped'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: const Icon(Icons.speed, size: 18),
            title: const Text('Speed: ramped'),
            subtitle: Text(
              'edit it in Motion · eats '
              '${cut.sourceConsumedS.toStringAsFixed(1)}s of recording · '
              'no game sound',
            ),
          )
        else
          _LabeledSlider(
            textClip: 'Speed',
            amount: cut.speed,
            minimum: 0.25,
            maximum: 4,
            // the duration in the video does not change: what changes is how much of the recording goes in
            caption: cut.speed == 1
                ? 'normal'
                : '${cut.speed.toStringAsFixed(2)}×  ·  eats '
                      '${cut.sourceConsumedS.toStringAsFixed(1)}s of recording',
            onChanged: onSpeed,
            onReset: cut.speed == 1 ? null : () => onSpeed(1),
          ),
        if (onRamp != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('ramp-into-play'),
              onPressed: onRamp,
              icon: const Icon(Icons.slow_motion_video, size: 18),
              label: const Text('Ramp into the play'),
            ),
          ),
        _LabeledSlider(
          textClip: 'Fade in',
          amount: cut.fade.inS,
          minimum: 0,
          maximum: 2,
          caption: cut.fade.inS == 0
              ? 'hard cut'
              : 'appears over ${cut.fade.inS.toStringAsFixed(2)}s',
          onChanged: (v) => onFade(cut.fade.copyWith(inS: v)),
          onReset: cut.fade.inS == 0
              ? null
              : () => onFade(cut.fade.copyWith(inS: 0)),
        ),
        _LabeledSlider(
          textClip: 'Fade out',
          amount: cut.fade.outS,
          minimum: 0,
          maximum: 2,
          caption: cut.fade.outS == 0
              ? 'hard cut'
              : 'vanishes over ${cut.fade.outS.toStringAsFixed(2)}s',
          onChanged: (v) => onFade(cut.fade.copyWith(outS: v)),
          onReset: cut.fade.outS == 0
              ? null
              : () => onFade(cut.fade.copyWith(outS: 0)),
        ),
        _LabeledSlider(
          textClip: 'Brightness',
          amount: cut.color.brightness,
          minimum: -0.5,
          maximum: 0.5,
          onChanged: (v) => onColor(cut.color.copyWith(brightness: v)),
          onReset: cut.color.brightness == 0
              ? null
              : () => onColor(cut.color.copyWith(brightness: 0)),
        ),
        _LabeledSlider(
          textClip: 'Contrast',
          amount: cut.color.contrast,
          minimum: 0.5,
          maximum: 2,
          onChanged: (v) => onColor(cut.color.copyWith(contrast: v)),
          onReset: cut.color.contrast == 1
              ? null
              : () => onColor(cut.color.copyWith(contrast: 1)),
        ),
        _LabeledSlider(
          textClip: 'Colour',
          amount: cut.color.saturation,
          minimum: 0,
          maximum: 2,
          caption: cut.color.saturation == 0 ? 'black and white' : null,
          onChanged: (v) => onColor(cut.color.copyWith(saturation: v)),
          onReset: cut.color.saturation == 1
              ? null
              : () => onColor(cut.color.copyWith(saturation: 1)),
        ),
      ],
    );
  }
}

class _LabeledSlider extends StatelessWidget {
  const _LabeledSlider({
    required this.textClip,
    required this.amount,
    required this.minimum,
    required this.maximum,
    required this.onChanged,
    this.caption,
    this.onReset,
  });

  final String textClip;
  final double amount;
  final double minimum;
  final double maximum;
  final String? caption;
  final ValueChanged<double> onChanged;

  /// `null` when already at the neutral value — there is nothing to undo.
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        SizedBox(
          width: 92,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(textClip, style: theme.textTheme.bodyMedium),
              if (caption != null)
                Text(
                  caption!,
                  maxLines: 2,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.hintColor,
                    fontSize: 10,
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: Slider(
            value: amount.clamp(minimum, maximum),
            min: minimum,
            max: maximum,
            onChanged: onChanged,
          ),
        ),
        IconButton(
          tooltip: 'Back to normal',
          visualDensity: VisualDensity.compact,
          onPressed: onReset,
          icon: const Icon(Icons.restart_alt, size: 18),
        ),
      ],
    );
  }
}

/// The audio mix of the whole montage.
class _Mix extends StatelessWidget {
  const _Mix({
    required this.musicVolume,
    required this.gameVolume,
    required this.hasMusic,
    required this.onChange,
    this.duckPlays = false,
    this.duckLevel = 0.3,
    this.plays = 0,
    this.onDuck,
  });

  final double musicVolume;
  final double gameVolume;
  final bool hasMusic;

  /// Ducking at the plays, how low the music goes, how many plays there are.
  final bool duckPlays;
  final double duckLevel;
  final int plays;
  final void Function(bool on, double level)? onDuck;

  /// (music volume, game volume)
  final void Function(double, double) onChange;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.graphic_eq, size: 18),
                const SizedBox(width: 8),
                Text('Mix', style: theme.textTheme.titleSmall),
              ],
            ),
            Text(
              hasMusic
                  ? 'With the game at zero, the music plays alone. Above that the '
                        'gunfire comes through under it.'
                  : 'Without a track, the video keeps the match audio.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
              ),
            ),
            const SizedBox(height: 6),
            _LabeledSlider(
              textClip: 'Music',
              amount: musicVolume,
              minimum: 0,
              maximum: 2,
              onChanged: hasMusic ? (v) => onChange(v, gameVolume) : (_) {},
              onReset: musicVolume == 1 ? null : () => onChange(1, gameVolume),
            ),
            _LabeledSlider(
              textClip: 'Game',
              amount: gameVolume,
              minimum: 0,
              maximum: 2,
              caption: gameVolume == 0 && hasMusic ? 'muted' : null,
              onChanged: hasMusic ? (v) => onChange(musicVolume, v) : (_) {},
              onReset: gameVolume == 0 ? null : () => onChange(musicVolume, 0),
            ),
            if (onDuck != null) ...[
              SwitchListTile(
                key: const Key('duck-plays'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: duckPlays,
                onChanged: (on) => onDuck!(on, duckLevel),
                title: const Text('Duck the music at each play'),
                subtitle: Text(
                  plays == 0
                      ? 'no plays in the montage yet'
                      : 'the shot comes through over the song at '
                            '$plays play${plays == 1 ? '' : 's'}',
                ),
              ),
              if (duckPlays)
                _LabeledSlider(
                  textClip: 'Music at a play',
                  amount: duckLevel,
                  minimum: 0,
                  maximum: 0.9,
                  caption: '${(duckLevel * 100).round()}% of its volume',
                  onChanged: (v) => onDuck!(true, v),
                  onReset: duckLevel == 0.3 ? null : () => onDuck!(true, 0.3),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// What comes out when you press "render".
///
/// Kept apart from the rest of the inspector on purpose: nothing here changes
/// the montage. Switching 16:9 for 9:16 does not move a single clip — it
/// changes the window onto the same work, and you can go back without undoing anything.
class _ExportPanel extends StatelessWidget {
  const _ExportPanel({
    required this.spec,
    required this.durationSecs,
    required this.widthPx,
    required this.heightPx,
    required this.hasSelection,
    required this.pictures,
    required this.enabled,
    required this.onChange,
    required this.onExportSelection,
    required this.onExportAll,
  });

  final ExportSpec spec;
  final double durationSecs;
  final int widthPx;
  final int heightPx;
  final bool hasSelection;

  /// The library, filtered: only images work as a watermark.
  final List<Media> pictures;
  final bool enabled;
  final ValueChanged<ExportSpec> onChange;
  final VoidCallback onExportSelection;
  final VoidCallback onExportAll;

  /// Does the output require cropping or bars? Only then does choosing between them matter.
  bool get _changesAspect {
    if (spec.width == 0 || widthPx == 0 || heightPx == 0) return false;
    return ((spec.width / spec.height) - (widthPx / heightPx)).abs() > 0.01;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final excerpt = stretchOf(spec, durationSecs);
    final cropped = excerpt.endTime - excerpt.startTime < durationSecs - 0.05;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.aspect_ratio, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Output', style: theme.textTheme.titleSmall),
                ),
                if (!spec.standard)
                  TextButton(
                    onPressed: enabled
                        ? () => onChange(const ExportSpec())
                        : null,
                    child: const Text('Default'),
                  ),
              ],
            ),
            Text(
              exportSummary(
                spec,
                durationSecs: durationSecs,
                widthPx: widthPx == 0 ? 1920 : widthPx,
                heightPx: heightPx == 0 ? 1080 : heightPx,
              ),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
              ),
            ),

            const SizedBox(height: 8),
            _OptionRow(
              textClip: 'Format',
              children: [
                for (final f in outputFormats)
                  ChoiceChip(
                    label: Text(f.displayName),
                    tooltip: f.note,
                    selected: f.matches(spec),
                    onSelected: enabled
                        ? (_) => onChange(
                            spec.copyWith(width: f.width, height: f.height),
                          )
                        : null,
                  ),
              ],
            ),

            if (_changesAspect)
              _OptionRow(
                textClip: 'Fit',
                children: [
                  ChoiceChip(
                    label: const Text('Fill'),
                    tooltip: 'crops the excess on the sides',
                    selected: spec.fit == 'cover',
                    onSelected: enabled
                        ? (_) => onChange(spec.copyWith(fit: 'cover'))
                        : null,
                  ),
                  ChoiceChip(
                    label: const Text('Contain'),
                    tooltip: 'shows the whole frame, with bars',
                    selected: spec.fit == 'contain',
                    onSelected: enabled
                        ? (_) => onChange(spec.copyWith(fit: 'contain'))
                        : null,
                  ),
                ],
              ),

            _OptionRow(
              textClip: 'Frame rate',
              children: [
                for (final f in outputFps)
                  ChoiceChip(
                    label: Text(f == 0 ? 'Original' : f.toStringAsFixed(0)),
                    selected: spec.fps == f,
                    onSelected: enabled
                        ? (_) => onChange(spec.copyWith(fps: f))
                        : null,
                  ),
              ],
            ),

            _OptionRow(
              textClip: 'Quality',
              children: [
                for (final q in qualities)
                  ChoiceChip(
                    label: Text(q.displayName),
                    tooltip: q.note,
                    selected: qualityOf(spec).crf == q.crf,
                    onSelected: enabled
                        ? (_) => onChange(spec.copyWith(crf: q.crf))
                        : null,
                  ),
              ],
            ),

            _OptionRow(
              textClip: 'Range',
              children: [
                ChoiceChip(
                  label: const Text('All'),
                  selected: !cropped,
                  onSelected: enabled ? (_) => onExportAll() : null,
                ),
                ChoiceChip(
                  label: const Text('Selection only'),
                  tooltip: hasSelection
                      ? 'exports from the first to the last selected block'
                      : 'select blocks on the timeline',
                  selected: cropped,
                  onSelected: enabled && hasSelection
                      ? (_) => onExportSelection()
                      : null,
                ),
                if (cropped)
                  Text(
                    '${formatDuration(excerpt.startTime)} → '
                    '${formatDuration(excerpt.endTime)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.hintColor,
                    ),
                  ),
              ],
            ),

            _OptionRow(
              textClip: 'Watermark',
              children: [
                ChoiceChip(
                  label: const Text('None'),
                  selected: spec.watermarkId == null,
                  onSelected: enabled
                      ? (_) => onChange(spec.copyWith(clearWatermark: true))
                      : null,
                ),
                for (final m in pictures)
                  ChoiceChip(
                    label: Text(m.name, overflow: TextOverflow.ellipsis),
                    selected: spec.watermarkId == m.id,
                    onSelected: enabled
                        ? (_) => onChange(spec.copyWith(watermarkId: m.id))
                        : null,
                  ),
                if (pictures.isEmpty)
                  Text(
                    'import an image into the library',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.hintColor,
                    ),
                  ),
              ],
            ),

            if (spec.watermarkId != null) ...[
              _OptionRow(
                textClip: 'Corner',
                children: [
                  for (final corner in kWatermarkCorners)
                    ChoiceChip(
                      label: Text(corner.displayName),
                      selected:
                          (spec.watermarkX > 0) == (corner.x > 0) &&
                          (spec.watermarkY > 0) == (corner.y > 0),
                      onSelected: enabled
                          ? (_) => onChange(
                              spec.copyWith(
                                watermarkX: corner.x,
                                watermarkY: corner.y,
                              ),
                            )
                          : null,
                    ),
                ],
              ),
              _LabeledSlider(
                textClip: 'Size',
                amount: spec.watermarkScale,
                minimum: 0.03,
                maximum: 0.5,
                onChanged: (v) => onChange(spec.copyWith(watermarkScale: v)),
                onReset: spec.watermarkScale == 0.12
                    ? null
                    : () => onChange(spec.copyWith(watermarkScale: 0.12)),
              ),
              _LabeledSlider(
                textClip: 'Opacity',
                amount: spec.watermarkOpacity,
                minimum: 0.05,
                maximum: 1,
                onChanged: (v) => onChange(spec.copyWith(watermarkOpacity: v)),
                onReset: spec.watermarkOpacity == 0.65
                    ? null
                    : () => onChange(spec.copyWith(watermarkOpacity: 0.65)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A label on the left and the options on the right, wrapping when they do not fit.
class _OptionRow extends StatelessWidget {
  const _OptionRow({required this.textClip, required this.children});

  final String textClip;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 74,
            child: Text(textClip, style: theme.textTheme.bodyMedium),
          ),
          Expanded(
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: children,
            ),
          ),
        ],
      ),
    );
  }
}

/// How a text clip looks. **What** it says is edited on the monitor itself,
/// over the video: that is where the real size, colour and position show.
class _ClipText extends StatelessWidget {
  const _ClipText({
    required this.cut,
    required this.onStyle,
    required this.onTypeOnFrame,
    this.fonts,
  });

  final TimelineClip cut;
  final FontLibrary? fonts;
  final ValueChanged<ClipTextStyle> onStyle;
  final VoidCallback onTypeOnFrame;

  /// The colours that suit a label over gameplay. A small palette beats a
  /// picker: what matters is the text showing up.
  static const _colours = ['white', 'yellow', 'orange', 'red', 'cyan', 'black'];

  static const _onScreen = {
    'white': Colors.white,
    'yellow': Color(0xFFFFD54F),
    'orange': Color(0xFFFF9800),
    'red': Color(0xFFFF5252),
    'cyan': Color(0xFF4DD0E1),
    'black': Colors.black,
  };

  @override
  Widget build(BuildContext context) {
    final styleSpec = cut.textStyle;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextButton.icon(
          key: const Key('type-on-frame'),
          onPressed: onTypeOnFrame,
          icon: const Icon(Icons.edit, size: 18),
          label: const Text('Type on the video'),
        ),
        Text(
          'Or tap the text on the video once it is selected.',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const SizedBox(width: 92, child: Text('Colour')),
            Expanded(
              child: Wrap(
                spacing: 6,
                children: [
                  for (final fillColour in _colours)
                    GestureDetector(
                      onTap: () => onStyle(styleSpec.copyWith(color: fillColour)),
                      child: Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: _onScreen[fillColour],
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: styleSpec.color == fillColour
                                ? Theme.of(context).colorScheme.primary
                                : Colors.white24,
                            width: styleSpec.color == fillColour ? 3 : 1,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        _LabeledSlider(
          textClip: 'Size',
          amount: styleSpec.size,
          minimum: 0.03,
          maximum: 0.3,
          caption: '${(styleSpec.size * 100).round()}% of the height',
          onChanged: (v) => onStyle(styleSpec.copyWith(size: v)),
          onReset: styleSpec.size == 0.08
              ? null
              : () => onStyle(styleSpec.copyWith(size: 0.08)),
        ),
        _LabeledSlider(
          textClip: 'Outline',
          amount: styleSpec.outline,
          minimum: 0,
          maximum: 0.4,
          caption: styleSpec.outline == 0
              ? 'no outline — vanishes on bright scenes'
              : null,
          onChanged: (v) => onStyle(styleSpec.copyWith(outline: v)),
          onReset: styleSpec.outline == 0.12
              ? null
              : () => onStyle(styleSpec.copyWith(outline: 0.12)),
        ),
        if (fonts != null && fonts!.fonts.isNotEmpty)
          Row(
            children: [
              const SizedBox(width: 92, child: Text('Font')),
              Expanded(
                child: DropdownButton<String>(
                  key: const Key('text-font'),
                  isExpanded: true,
                  value: styleSpec.font.isEmpty
                      ? fonts!.defaultId
                      : styleSpec.font,
                  onChanged: (id) => onStyle(
                    styleSpec.copyWith(
                      font: id == fonts!.defaultId ? '' : id,
                    ),
                  ),
                  items: [
                    for (final f in fonts!.fonts)
                      DropdownMenuItem(
                        value: f.id,
                        // each name in its own face, once it has loaded
                        child: Text(
                          f.name,
                          style: TextStyle(
                            fontFamily: fonts!.familyFor(f.id),
                            fontSize: 16,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        _OptionRow(
          textClip: 'Comes in',
          children: [
            for (final a in TextAnim.values)
              ChoiceChip(
                key: ValueKey('text-in-${a.wire}'),
                label: Text(a.label),
                selected: styleSpec.animIn == a,
                onSelected: (_) => onStyle(styleSpec.copyWith(animIn: a)),
              ),
          ],
        ),
        _OptionRow(
          textClip: 'Goes out',
          children: [
            // typing is an entrance: there is no typing out
            for (final a in TextAnim.values)
              if (a != TextAnim.typewriter)
                ChoiceChip(
                  key: ValueKey('text-out-${a.wire}'),
                  label: Text(a.label),
                  selected: styleSpec.animOut == a,
                  onSelected: (_) => onStyle(styleSpec.copyWith(animOut: a)),
                ),
          ],
        ),
        if (styleSpec.animIn != TextAnim.none ||
            styleSpec.animOut != TextAnim.none)
          _LabeledSlider(
            textClip: 'Animation',
            amount: styleSpec.animS,
            minimum: 0.1,
            maximum: 1.5,
            caption: '${styleSpec.animS.toStringAsFixed(2)}s in and out',
            onChanged: (v) => onStyle(styleSpec.copyWith(animS: v)),
            onReset: styleSpec.animS == 0.35
                ? null
                : () => onStyle(styleSpec.copyWith(animS: 0.35)),
          ),
      ],
    );
  }
}
