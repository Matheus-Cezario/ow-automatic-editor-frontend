import 'dart:math' as math;

import 'api.dart';
import 'montage.dart';

/// The montage's state, whole and immutable, plus the history that undoes it.
///
/// In V1 the screen kept a `List<TimelineClip>` and changed it in place, in
/// thirty different places. It worked for six operations and would not survive
/// twenty: there was no way to undo anything, because there was no "before" —
/// the previous state was overwritten on every change.
///
/// Here every operation takes a state and returns **another**. Keeping the
/// previous one becomes pushing a reference, and undoing becomes swapping
/// references. The computation that decides *where* a block can land stays in
/// `montage.dart`, tested on its own; this file only deals with who is who and
/// what came before.

/// Generator of the blocks' local ids. A counter is enough: they only need to
/// be unique within an editing session, and they never leave the app.
int _nextId = 0;
String newCutId() => 'c${_nextId++}';

/// The montage at one instant in time.
class MontageState {
  MontageState({
    required List<Layer> layers,
    Set<String>? selectionIds,
    this.activeLayer = 0,
    this.title = '',
    this.beatOffsetS = 0,
    this.beatMultiplier = 1,
    this.beatBar = 1,
    this.musicVolume = 1,
    this.gameVolume = 0,
    this.export = const ExportSpec(),
  }) : layers = List.unmodifiable(
         (layers.isEmpty ? const [Layer()] : layers).map(
           // the guarantee must reach the clips: `clips` is a getter that
           // returns a new list, and locking only it would leave the inner
           // list open to whoever had the layer in hand
           (l) => l.copyWith(clips: List.unmodifiable(l.clips)),
         ),
       ),
       selectionIds = Set.unmodifiable(selectionIds ?? const <String>{});

  static MontageState blank() => MontageState(layers: const [Layer()]);

  /// The layers, from bottom to top. Never empty: a montage with no layer at
  /// all would have nowhere to receive the first clip.
  final List<Layer> layers;

  /// Where new clips go.
  final int activeLayer;

  /// Who is selected, by clip id. Several, because batch operations are half
  /// of what makes an editor an editor.
  final Set<String> selectionIds;

  final String title;

  /// Corrections to the beat grid — the screen's magnet, not the video.
  final double beatOffsetS;
  final double beatMultiplier;
  final int beatBar;

  /// Volume of the music and of the game sound in the final mix.
  final double musicVolume;
  final double gameVolume;

  /// How the final video is written. It does not change the montage — it
  /// changes the window.
  final ExportSpec export;

  /// Every clip, from every layer, bottom to top.
  List<TimelineClip> get clips => [for (final l in layers) ...l.clips];

  /// What the monitor shows: the visible layers' clips, with the upper one
  /// winning over the one below at the same instant.
  ///
  /// The preview does not compose — it shows one frame. So when two layers
  /// overlap, what counts is the upper one, which is what the server will draw
  /// last.
  ///
  /// The upper clip only hides the lower one **where the two overlap**: before
  /// and after that, the lower one shows again, as in the final video. The
  /// leftover pieces keep the `id` of the clip they came from.
  ///
  /// Text is left out: it is a transparent canvas the monitor draws over the
  /// picture, and treating it as a clip erased the video underneath.
  List<TimelineClip> get visibleClips {
    var visible = <TimelineClip>[];
    for (final l in layers) {
      // an audio layer draws nothing: the monitor has nothing to show of a
      // music block, and considering it would erase the video underneath
      if (l.hidden || l.isAudio) continue;
      for (final c in l.clips) {
        if (c.isText) continue;
        visible = [for (final v in visible) ..._outside(v, c)];
        visible.add(c);
      }
    }
    return visible..sort((a, b) => a.atS.compareTo(b.atS));
  }

  /// What is left of [v] outside the interval [c] covers: nothing, all of it,
  /// or one piece on each side.
  static List<TimelineClip> _outside(TimelineClip v, TimelineClip c) {
    const eps = 1e-6;
    if (c.atS >= v.untilS - eps || v.atS >= c.untilS - eps) return [v];
    return [
      if (c.atS > v.atS + eps) v.copyWith(durationS: c.atS - v.atS),
      if (c.untilS < v.untilS - eps)
        v.copyWith(
          atS: c.untilS,
          durationS: v.untilS - c.untilS,
          clearTransition: true,
          // the piece after starts further into the source, in proportion to
          // the speed — otherwise the picture would jump back when it shows
          // again. A frozen frame does not move: same frame on both sides
          startS: v.freeze ? v.startS : v.startS + (c.untilS - v.atS) * v.speed,
        ),
    ];
  }

  bool get isBlank => clips.isEmpty;

  MontageState copyWith({
    List<Layer>? layers,
    Set<String>? selectionIds,
    int? activeLayer,
    String? title,
    double? beatOffsetS,
    double? beatMultiplier,
    int? beatBar,
    double? musicVolume,
    double? gameVolume,
    ExportSpec? export,
  }) => MontageState(
    layers: layers ?? this.layers,
    selectionIds: selectionIds ?? this.selectionIds,
    activeLayer: activeLayer ?? this.activeLayer,
    title: title ?? this.title,
    beatOffsetS: beatOffsetS ?? this.beatOffsetS,
    beatMultiplier: beatMultiplier ?? this.beatMultiplier,
    beatBar: beatBar ?? this.beatBar,
    musicVolume: musicVolume ?? this.musicVolume,
    gameVolume: gameVolume ?? this.gameVolume,
    export: export ?? this.export,
  );

  /// Which layer, and which position in it, the clip is at.
  ///
  /// `null` when it no longer exists — which happens all the time after an
  /// undo, and is why every operation asks before acting.
  (int, int)? locate(String id) {
    for (var c = 0; c < layers.length; c++) {
      final i = layers[c].clips.indexWhere((k) => k.id == id);
      if (i >= 0) return (c, i);
    }
    return null;
  }

  TimelineClip? clipItem(String id) {
    final location = locate(id);
    return location == null ? null : layers[location.$1].clips[location.$2];
  }

  List<TimelineClip> get selectedClips => [
    for (final c in clips)
      if (selectionIds.contains(c.id)) c,
  ];

  /// Swaps a clip for its successor, in the layer where it is.
  MontageState withClip(int layerIndex, int index, TimelineClip updated) {
    final list = [...layers[layerIndex].clips];
    list[index] = updated;
    return withLayer(layerIndex, layers[layerIndex].copyWith(clips: list));
  }

  MontageState withLayer(int index, Layer fresh) {
    final list = [...layers];
    list[index] = fresh;
    return copyWith(layers: list);
  }

  Montage toPayload() => Montage(
    title: title,
    layers: layers,
    beatOffsetS: beatOffsetS,
    beatMultiplier: beatMultiplier,
    beatBar: beatBar,
    musicVolume: musicVolume,
    gameVolume: gameVolume,
    export: export,
  );
}

/// Rebuilds the state from the draft that came back from the server.
///
/// This is where clips get their id: the server keeps none, because to it a
/// clip is just a stretch with a set time.
MontageState montageFromDraft(Montage draft) => MontageState(
  layers: [
    for (final l in draft.layers)
      l.copyWith(
        clips: [for (final c in l.clips) c.copyWith(id: newCutId())],
      ),
    // the old continuous track becomes a music block covering the video: that
    // is exactly what it did, and now it has ends to grab
    ...?_trackBecomesBlock(draft),
  ],
  title: draft.title,
  beatOffsetS: draft.beatOffsetS,
  beatMultiplier: draft.beatMultiplier,
  beatBar: draft.beatBar,
  musicVolume: draft.musicVolume,
  gameVolume: draft.gameVolume,
  export: draft.export,
);

/// The audio layer an old montage gets when it is opened.
///
/// There were two ways of having music: the continuous track, which played
/// under everything and could not be cut, and the block on the ruler. The
/// second one is what is left. The code that reads is what converts the old
/// format — the server does the same, with the same rule.
List<Layer>? _trackBecomesBlock(Montage draft) {
  final id = draft.trackId;
  if (id == null || id.isEmpty) return null;
  final until = videoDuration([for (final l in draft.layers) ...l.clips]);
  if (until < kMinCutS) return null;
  return [
    Layer(
      kind: 'audio',
      name: 'Music',
      clips: [
        TimelineClip(
          id: newCutId(),
          atS: 0,
          durationS: until,
          startS: draft.musicStartS,
          source: 'media',
          mediaId: id,
        ),
      ],
    ),
  ];
}

// ─────────────────────────────── operations ─────────────────────────────────
//
// They all take a state and return another. Collision is **per layer**: two
// clips at the same instant on different layers is exactly what layers are
// for.

/// The layer of the requested kind closest to the active one — the active
/// one itself when it already is of that kind.
///
/// Pictures and sound never share a layer: the server refuses the mix, and on
/// the ruler it would be a music block covering a cut. With no layer of that
/// kind at all, one is opened on top.
(MontageState, int) layerOfKind(MontageState s, {required bool audio}) {
  final active = s.activeLayer.clamp(0, s.layers.length - 1);
  int? best;
  for (var i = 0; i < s.layers.length; i++) {
    if (s.layers[i].isAudio != audio) continue;
    // a tie goes to the layer below: it is the one already covered by the
    // active one, so the new clip does not jump over anything
    if (best == null || (i - active).abs() < (best - active).abs()) best = i;
  }
  if (best != null) return (s, best);
  final opened = audio ? addMusicLayer(s) : addLayer(s);
  return (opened, opened.layers.length - 1);
}

/// Puts a new picture clip on the active layer — or on the nearest picture
/// layer when the active one is a sound layer — pushing it to the first free
/// slot.
MontageState addClip(
  MontageState s,
  TimelineClip clip, {
  required List<double> beats,
  required bool snap,
}) {
  final int layerIndex;
  (s, layerIndex) = layerOfKind(s, audio: false);
  final slot = nextSlot(s.layers[layerIndex].clips, clip.atS, clip.durationS);
  final updated = clip.copyWith(
    id: newCutId(),
    atS: snap ? math.max(0, snapToBeat(slot, beats)) : slot,
  );
  return s
      .withLayer(
        layerIndex,
        s.layers[layerIndex].copyWith(clips: [...s.layers[layerIndex].clips, updated]),
      )
      .copyWith(selectionIds: {updated.id});
}

MontageState moveBlock(
  MontageState s,
  String id,
  double atS, {
  required List<double> beats,
  required bool snap,
}) {
  final location = s.locate(id);
  if (location == null) return s;
  final (layerIndex, i) = location;
  return s.withClip(
    layerIndex,
    i,
    move(s.layers[layerIndex].clips, i, atS, beats: beats, snap: snap),
  );
}

MontageState stretchBlock(
  MontageState s,
  String id,
  double durationValue, {
  required List<double> beats,
  required bool snap,
  double? sourceDurationS,
}) {
  final location = s.locate(id);
  if (location == null) return s;
  final (layerIndex, i) = location;
  return s.withClip(
    layerIndex,
    i,
    stretchRight(
      s.layers[layerIndex].clips,
      i,
      durationValue,
      beats: beats,
      snap: snap,
      sourceDurationS: sourceDurationS,
    ),
  );
}

MontageState trimBlock(
  MontageState s,
  String id,
  double atS, {
  required List<double> beats,
  required bool snap,
}) {
  final location = s.locate(id);
  if (location == null) return s;
  final (layerIndex, i) = location;
  return s.withClip(
    layerIndex,
    i,
    trimLeft(s.layers[layerIndex].clips, i, atS, beats: beats, snap: snap),
  );
}

/// Moves the clip's content inside the frame.
///
/// [x] and [y] are offsets from the centre normalised by half the frame — -1
/// touches the left/top edge, +1 the right/bottom one. It is the same
/// computation the server uses, so dragging the text on the monitor puts the
/// line exactly where it will come out.
///
/// It stays within -1 to 1: beyond that the content leaves the frame, and a
/// clip that does not show is indistinguishable from a clip that vanished.
MontageState positionOnFrame(
  MontageState s,
  String id, {
  double? x,
  double? y,
  double? scaleFactor,
}) {
  final location = s.locate(id);
  if (location == null) return s;
  final (layerIndex, i) = location;
  final c = s.layers[layerIndex].clips[i];
  final t = c.transform;
  return s.withClip(
    layerIndex,
    i,
    c.copyWith(
      transform: ClipTransform(
        scale: (scaleFactor ?? t.scale).clamp(0.1, 4.0),
        x: (x ?? t.x).clamp(-1.0, 1.0),
        y: (y ?? t.y).clamp(-1.0, 1.0),
        opacity: t.opacity,
      ),
    ),
  );
}

/// Puts a block's **play** at [targetS] of the video, one way or another.
///
/// It is not the same as moving the block to the cursor: the cut starts before
/// the play, for run-up, and it is the play — the kill, the dart, the rock —
/// that needs to land on the beat. Aligning by the edge would leave the impact
/// half a second after it.
///
/// There are two ways of getting there, and they change different things:
///
/// * **moving the block** changes *when* the scene appears, and keeps the
///   framing — how much run-up there is before the play. It is the preferred
///   one;
/// * **sliding the content inside the block** keeps the block in place and
///   swaps *which* stretch of the recording shows there. It is what is left
///   when the neighbours do not let the block move — the common case in a
///   montage of adjacent blocks.
///
/// The result says which of the two happened, so the screen can tell.
({MontageState state, bool didSlide})? alignMoment(
  MontageState s,
  String id,
  double targetS, {
  required double sourceDurationS,
}) {
  final location = s.locate(id);
  if (location == null) return null;
  final (layerIndex, i) = location;
  final c = s.layers[layerIndex].clips[i];
  final mark = momentInVideo(c);
  if (mark == null) return null;

  // 1) move the block
  final destination = math.max(0.0, c.atS + (targetS - mark));
  final movedClip = move(
    s.layers[layerIndex].clips,
    i,
    destination,
    beats: const [],
    snap: false,
  );
  // "moved" means the block changed place, not `move` returning another
  // object: against the first frame, it returns the same instant — and then
  // the alignment has not happened yet
  if ((movedClip.atS - c.atS).abs() > 1e-6) {
    return (state: s.withClip(layerIndex, i, movedClip), didSlide: false);
  }

  // 2) slide the content: the play comes to the cursor without touching a
  // neighbour
  final limit = math.max(0.0, sourceDurationS - c.durationS);
  final startTime = (c.sourceT - (targetS - c.atS)).clamp(0.0, limit);
  final wasSlid = c.copyWith(startS: startTime);
  if ((startTime - c.startS).abs() < 1e-6 || momentMark(wasSlid) == null) {
    return null;
  }
  return (state: s.withClip(layerIndex, i, wasSlid), didSlide: true);
}

/// Swaps the order of the layers — which is the order the server draws them
/// in.
///
/// The bottom one is the background, the upper one wins over the one below at
/// the same instant. Reordering is therefore a real edit: it changes what
/// shows.
MontageState reorderLayers(MontageState s, int from, int to) {
  if (from == to) return s;
  if (from < 0 || from >= s.layers.length) return s;
  if (to < 0 || to >= s.layers.length) return s;

  final list = [...s.layers];
  final movedOne = list.removeAt(from);
  list.insert(to, movedOne);
  return s.copyWith(layers: list, activeLayer: to);
}

MontageState adjustEffect(
  MontageState s,
  String id, {
  double? speed,
  ClipColor? color,
  ClipFade? fade,
  List<ZoomKey>? zoom,
  bool? freeze,
  bool? reverse,
}) {
  final location = s.locate(id);
  if (location == null) return s;
  final (layerIndex, i) = location;
  final c = s.layers[layerIndex].clips[i];

  // a fade longer than the clip is refused by the server; trimming it here
  // avoids finding out only when rendering
  var newFade = fade ?? c.fade;
  final sum = newFade.inS + newFade.outS;
  if (sum > c.durationS) {
    final scaleFactor = c.durationS / sum;
    newFade = ClipFade(
      inS: newFade.inS * scaleFactor,
      outS: newFade.outS * scaleFactor,
    );
  }

  // the server refuses freezing and reversing at the same time; here one turns
  // the other off, which is what the person meant by turning the second on
  final willFreeze = freeze ?? c.freeze;
  final willReverse = reverse ?? c.reverse;

  return s.withClip(
    layerIndex,
    i,
    c.copyWith(
      speed: speed?.clamp(0.1, 10.0),
      color: color,
      fade: newFade,
      zoom: zoom,
      freeze: freeze ?? (willReverse ? false : willFreeze),
      reverse: reverse ?? (willFreeze ? false : willReverse),
    ),
  );
}

/// Changes what a text clip says, or how it looks.
MontageState changeText(
  MontageState s,
  String id, {
  String? textValue,
  ClipTextStyle? styleSpec,
}) {
  final location = s.locate(id);
  if (location == null) return s;
  final (layerIndex, i) = location;
  final c = s.layers[layerIndex].clips[i];
  if (!c.isText) return s;

  // the server refuses empty text, and an invisible clip on the ruler would be
  // worse than a blank space
  final updated = (textValue ?? c.text).trim().isEmpty ? c.text : (textValue ?? c.text);
  return s.withClip(layerIndex, i, c.copyWith(text: updated, textStyle: styleSpec));
}

/// Sets (or clears, with `null`) the entrance transition of clips [ids].
///
/// Music clips are skipped: a transition is about the picture. Locked layers
/// are skipped too, as with any other edit.
MontageState applyTransition(
  MontageState s,
  Iterable<String> ids,
  ClipTransition? transition,
) {
  var result = s;
  for (final id in ids) {
    final where = result.locate(id);
    if (where == null) continue;
    final (layer, i) = where;
    final l = result.layers[layer];
    if (l.isAudio || l.locked) continue;
    final c = l.clips[i];
    if (c.transition == transition) continue;
    result = result.withClip(
      layer,
      i,
      transition == null
          ? c.copyWith(clearTransition: true)
          : c.copyWith(transition: transition),
    );
  }
  return result;
}

/// The *punch*: the lens closes in fast and eases off until the end of the
/// clip.
///
/// Two movements solve the most used effect in a gameplay montage, and it is
/// better to offer it ready-made than a curve editor nobody will open.
List<ZoomKey> punch({double until = 1.6, double when = 0.25}) => [
  const ZoomKey(t: 0, scale: 1),
  ZoomKey(t: when, scale: until),
  ZoomKey(t: 1, scale: 1 + (until - 1) * 0.4),
];

/// Moves the content inside the clip without touching the clip — the fine
/// adjustment of the framing.
MontageState shiftContent(
  MontageState s,
  String id,
  double delta, {
  required double sourceDurationS,
}) {
  final location = s.locate(id);
  if (location == null) return s;
  final (layerIndex, i) = location;
  final c = s.layers[layerIndex].clips[i];
  final limit = math.max(0.0, sourceDurationS - c.durationS);
  return s.withClip(
    layerIndex,
    i,
    c.copyWith(startS: (c.startS + delta).clamp(0, limit)),
  );
}

/// Removes the chosen clips from the montage, wherever they are.
MontageState removeClips(MontageState s, Set<String> ids) {
  if (ids.isEmpty) return s;
  return s.copyWith(
    layers: [
      for (final l in s.layers)
        l.copyWith(
          clips: [
            for (final c in l.clips)
              if (!ids.contains(c.id)) c,
          ],
        ),
    ],
    selectionIds: const {},
  );
}

/// Moves several clips at once, keeping the distance between them.
///
/// The group moves together or not at all: if any of them would land on one
/// that stayed still — on its layer — or before the first frame, the whole move
/// is refused. Moving half a selection would undo an arrangement the user had
/// already made.
MontageState moveSelection(
  MontageState s,
  double delta, {
  required List<double> beats,
  required bool snap,
}) {
  if (s.selectionIds.isEmpty || delta == 0) return s;

  var step = delta;
  if (snap) {
    // snaps the group by the first clip's edge: it is the visible reference
    final first = s.selectedClips
        .map((c) => c.atS)
        .reduce((a, b) => a < b ? a : b);
    step = snapToBeat(first + delta, beats) - first;
  }

  final freshOnes = <Layer>[];
  for (final l in s.layers) {
    final indices = <int>{
      for (var i = 0; i < l.clips.length; i++)
        if (s.selectionIds.contains(l.clips[i].id)) i,
    };
    if (indices.isEmpty) {
      freshOnes.add(l);
      continue;
    }
    final list = [...l.clips];
    for (final i in indices) {
      final destination = list[i].atS + step;
      if (!fitsIgnoring(l.clips, destination, list[i].durationS, indices)) {
        return s;
      }
      list[i] = list[i].copyWith(atS: destination);
    }
    freshOnes.add(l.copyWith(clips: list));
  }
  return s.copyWith(layers: freshOnes);
}

/// Cuts a clip in two at the requested point.
///
/// What was framed stays framed: the right half starts in the recording
/// exactly where the left one stopped, so the splice is invisible until
/// someone touches one of the two.
MontageState split(MontageState s, String id, double atS) {
  final location = s.locate(id);
  if (location == null) return s;
  final (layerIndex, i) = location;
  final c = s.layers[layerIndex].clips[i];

  final leftEdge = atS - c.atS;
  final right = c.untilS - atS;
  if (leftEdge < kMinCutS || right < kMinCutS) return s;

  final a = c.copyWith(durationS: leftEdge);
  final b = c.copyWith(
    id: newCutId(),
    atS: atS,
    durationS: right,
    startS: c.startS + leftEdge,
    // the entrance belongs to the original clip; the right half carries on
    // where the other stopped, and a transition there would come out of
    // nowhere mid-scene
    clearTransition: true,
  );
  final list = [...s.layers[layerIndex].clips]
    ..[i] = a
    ..insert(i + 1, b);
  return s
      .withLayer(layerIndex, s.layers[layerIndex].copyWith(clips: list))
      .copyWith(selectionIds: {b.id});
}

/// Duplicates the chosen clips, putting the copies after the montage's end.
///
/// Pictures and music are pasted apart, each on a layer of its own kind.
MontageState duplicate(MontageState s, Set<String> ids) {
  final pictures = <TimelineClip>[];
  final sounds = <TimelineClip>[];
  for (final l in s.layers) {
    for (final c in l.clips) {
      if (ids.contains(c.id)) (l.isAudio ? sounds : pictures).add(c);
    }
  }
  final end = videoDuration(s.clips);
  var out = s;
  final copies = <String>{};
  for (final (group, audio) in [(pictures, false), (sounds, true)]) {
    if (group.isEmpty) continue;
    out = paste(out, group, end, audio: audio);
    copies.addAll(out.selectionIds);
  }
  return copies.isEmpty ? s : out.copyWith(selectionIds: copies);
}

/// Puts a copy of [area] from [atS] on, on the active layer — or on the
/// nearest layer of the same kind: [audio] clips only live on sound layers,
/// and pictures never do.
///
/// If it does not fit there, the whole group goes after the layer's last
/// clip: that is more predictable than scattering the copies across the
/// gaps.
MontageState paste(
  MontageState s,
  List<TimelineClip> area,
  double atS, {
  bool audio = false,
}) {
  if (area.isEmpty) return s;
  final int layerIndex;
  (s, layerIndex) = layerOfKind(s, audio: audio);
  final targetClips = s.layers[layerIndex].clips;
  final base = area.map((c) => c.atS).reduce(math.min);

  var destination = math.max(0.0, atS);
  final fitsThere = area.every(
    (c) => fits(targetClips, destination + (c.atS - base), c.durationS),
  );
  if (!fitsThere) destination = videoDuration(targetClips);

  final copies = [
    for (final c in area)
      c.copyWith(id: newCutId(), atS: destination + (c.atS - base)),
  ];
  return s
      .withLayer(
        layerIndex,
        s.layers[layerIndex].copyWith(clips: [...targetClips, ...copies]),
      )
      .copyWith(selectionIds: {for (final c in copies) c.id});
}

// ── the layers themselves ───────────────────────────────────────────────────

/// Adds a layer on top of all others, and starts working on it.
MontageState addLayer(MontageState s, {String displayName = ''}) {
  final fresh = Layer(
    name: displayName.isEmpty ? 'Layer ${s.layers.length + 1}' : displayName,
  );
  return s.copyWith(
    layers: [...s.layers, fresh],
    activeLayer: s.layers.length,
    selectionIds: const {},
  );
}

/// Removes a layer and everything on it.
///
/// The last one stays: a montage with no layer at all would have nowhere to
/// receive the next clip.
MontageState removeLayer(MontageState s, int index) {
  if (s.layers.length <= 1 || index < 0 || index >= s.layers.length) return s;
  final list = [...s.layers]..removeAt(index);
  return s.copyWith(
    layers: list,
    activeLayer: s.activeLayer.clamp(0, list.length - 1),
    selectionIds: const {},
  );
}

/// Changes a layer's muted, hidden or locked flags.
MontageState adjustLayer(
  MontageState s,
  int index, {
  bool? muted,
  bool? hidden,
  bool? locked,
  String? name,
}) {
  if (index < 0 || index >= s.layers.length) return s;
  return s.withLayer(
    index,
    s.layers[index].copyWith(
      muted: muted,
      hidden: hidden,
      locked: locked,
      name: name,
    ),
  );
}

/// Takes a clip to another layer, at the same instant of the video.
///
/// It refuses when the place is already taken there: pushing the clip to
/// another instant would change two things when one was asked.
MontageState moveToLayer(MontageState s, String id, int destination) {
  final location = s.locate(id);
  if (location == null || destination < 0 || destination >= s.layers.length) return s;
  final (origin, i) = location;
  if (origin == destination) return s;

  // sound does not go up to a picture layer, nor a picture down to an audio
  // layer: the server would refuse both, and refusing here explains better
  if (s.layers[origin].isAudio != s.layers[destination].isAudio) return s;

  final clip = s.layers[origin].clips[i];
  if (!fits(s.layers[destination].clips, clip.atS, clip.durationS)) return s;

  final list = [...s.layers];
  list[origin] = list[origin].copyWith(
    clips: [...list[origin].clips]..removeAt(i),
  );
  list[destination] = list[destination].copyWith(
    clips: [...list[destination].clips, clip],
  );
  return s.copyWith(layers: list, activeLayer: destination);
}

/// Opens an audio-only layer.
///
/// It does not enter the visual stacking — it draws nothing. It serves what
/// the continuous track never could do: cut the music, leave a stretch silent,
/// switch tracks in the middle of the video.
MontageState addMusicLayer(MontageState s, {String displayName = 'Music'}) {
  final fresh = Layer(kind: 'audio', name: displayName);
  return s.copyWith(
    layers: [...s.layers, fresh],
    activeLayer: s.layers.length,
    selectionIds: const {},
  );
}

/// Puts a piece of a music track on the ruler.
///
/// With no duration asked, what is left of the track from [startS] goes in —
/// the common case is wanting the whole song and trimming later, not
/// computing the size before listening.
MontageState putMusic(
  MontageState s,
  Track music, {
  required double atS,
  double? durationS,
  double startS = 0,
}) {
  if (!music.isReady) return s;

  var destination = s.activeLayer;
  var base = s;
  if (destination >= s.layers.length || !s.layers[destination].isAudio) {
    // with no audio layer chosen, the first there is; otherwise, a new one
    final existing = base.layers.indexWhere((l) => l.isAudio);
    if (existing >= 0) {
      destination = existing;
    } else {
      base = addMusicLayer(base);
      destination = base.layers.length - 1;
    }
  }

  final leftover = math.max(0.0, music.durationS - startS);
  var lasts = durationS ?? leftover;
  if (leftover > 0) lasts = math.min(lasts, leftover);
  if (lasts < kMinCutS) return s;

  // it pushes nothing: where there is music already, the new one goes after
  // what is there
  final location = fits(base.layers[destination].clips, atS, lasts)
      ? atS
      : base.layers[destination].durationS;

  final block = TimelineClip(
    id: newCutId(),
    atS: location,
    durationS: lasts,
    startS: startS,
    source: 'media',
    mediaId: music.id,
  );
  return base
      .withLayer(
        destination,
        base.layers[destination].copyWith(
          clips: [...base.layers[destination].clips, block]
            ..sort((a, b) => a.atS.compareTo(b.atS)),
        ),
      )
      .copyWith(selectionIds: {block.id}, activeLayer: destination);
}

// ──────────────────────────────── history ───────────────────────────────────

/// The undo stack, with grouping by gesture.
///
/// A drag produces a new state per frame. Pushing all of them would make
/// "undo" go back one pixel at a time — useless. That is why a gesture is
/// opened at the start of the drag and closed on release: while it is open,
/// the top of the stack is replaced instead of growing, and the step that
/// remains is the whole drag.
class MontageHistory {
  MontageHistory(this._current);

  MontageState _current;
  final List<MontageState> _past = [];
  final List<MontageState> _future = [];

  /// Ceiling of stored steps. Each state is a list of blocks — cheap — but a
  /// long session does not need infinite memory.
  static const int maxSteps = 200;

  bool _inGesture = false;
  bool _changedInGesture = false;

  MontageState get present => _current;
  bool get canUndo => _past.isNotEmpty;
  bool get canRedo => _future.isNotEmpty;

  /// Swaps the state, keeping the previous one.
  void apply(MontageState updated) {
    if (identical(updated, _current)) return;
    if (_inGesture && _changedInGesture) {
      // the gesture already pushed the "before"; from here on only the top
      // is updated
      _current = updated;
      return;
    }
    _past.add(_current);
    if (_past.length > maxSteps) _past.removeAt(0);
    _future.clear();
    _current = updated;
    if (_inGesture) _changedInGesture = true;
  }

  /// Swaps the state **without** creating a step — for what is not an edit
  /// (selecting, for instance, which undo should not revert).
  void replace(MontageState updated) => _current = updated;

  /// Throws the memory away, keeping the current state.
  ///
  /// Used when switching montages: the history is the memory of a working
  /// session **on one** montage, and undoing into another would erase what was
  /// just opened.
  void reset() {
    _past.clear();
    _future.clear();
    _inGesture = false;
    _changedInGesture = false;
  }

  void startGesture() {
    _inGesture = true;
    _changedInGesture = false;
  }

  void endGesture() {
    _inGesture = false;
    _changedInGesture = false;
  }

  MontageState undo() {
    if (_past.isEmpty) return _current;
    _future.add(_current);
    _current = _past.removeLast();
    return _current;
  }

  MontageState redo() {
    if (_future.isEmpty) return _current;
    _past.add(_current);
    _current = _future.removeLast();
    return _current;
  }
}
