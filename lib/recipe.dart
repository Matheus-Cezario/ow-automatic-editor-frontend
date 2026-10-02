import 'dart:math' as math;

import 'api.dart';
import 'montage.dart';
import 'montage_state.dart';
import 'labels.dart';

/// Applying a preset: the way of cutting turned into cuts.
///
/// A preset does not store cuts — it stores the **way** of cutting. "Two
/// seconds per kill, fitted to the beat, with zoom" works for any match, and
/// is what makes the second match cost one click instead of half an hour of
/// fitting.
///
/// What comes out is an ordinary montage: once applied, each block moves,
/// trims and deletes like any other. The recipe is a starting point, not a
/// mould you cannot leave.

/// Assembles from the match's moments.
///
/// [beatTimes] are the beats **in video time** — the same the ruler's magnet
/// uses. With them and `beatsPerCut` above zero, each cut goes from one beat to
/// another: that is fitting to the rhythm, and then the gap between cuts does
/// not apply, because the grid already says where each one starts.
MontageState applyRecipe(
  Recipe r, {
  required List<DetectionEvent> eventList,
  required double sourceDurationS,
  List<double> beatTimes = const [],
  MontageState? base,
}) {
  final moments = [
    for (final e in eventList)
      if (r.kinds.contains(e.kind)) e,
  ]..sort((a, b) => a.t.compareTo(b.t));

  final count = r.maxCuts > 0
      ? math.min(r.maxCuts, moments.length)
      : moments.length;

  final onGrid = r.beatsPerCut > 0 && beatTimes.length > 1;
  final step = math.max(1, r.beatsPerCut.round());

  final clips = <TimelineClip>[];
  var position = 0.0;
  for (var i = 0; i < count; i++) {
    final moment = moments[i];

    double starts;
    double lasts;
    if (onGrid) {
      final k = i * step;
      if (k + step >= beatTimes.length) break; // the music ended first
      starts = beatTimes[k];
      lasts = beatTimes[k + step] - starts;
    } else {
      starts = position;
      lasts = r.durationS;
      position += lasts + r.gapS;
    }
    if (lasts < kMinCutS) continue;

    // the moment needs a run-up: without it the kill shows on the first
    // frame, before the viewer understands what they are seeing
    final consumed = lasts * r.speed;
    final entry = (moment.t - r.leadS).clamp(
      0.0,
      math.max(0.0, sourceDurationS - consumed),
    );

    clips.add(
      TimelineClip(
        id: newCutId(),
        atS: starts,
        durationS: lasts,
        startS: entry.toDouble(),
        sourceT: moment.t,
        kind: moment.kind,
        speed: r.speed,
        zoom: r.zoom ? punch() : const [],
        fade: r.fadeS > 0
            ? ClipFade(inS: r.fadeS, outS: r.fadeS)
            : const ClipFade(),
      ),
    );
  }

  final layerList = <Layer>[Layer(clips: clips)];

  // text goes on its own layer: it almost always sits over a picture, and
  // mixing it with the cuts would mean dodging one to place the other
  final texts = <TimelineClip>[
    if (r.counter) ...killCounter(clips),
    if (r.streaks) ...streakLabels(clips),
  ];
  if (texts.isNotEmpty) {
    layerList.add(
      Layer(
        name: 'text',
        clips: [for (final t in texts) t.copyWith(id: newCutId())]
          ..sort((a, b) => a.atS.compareTo(b.atS)),
      ),
    );
  }

  final previous = base ?? MontageState(layers: const []);
  // music already on the ruler stays: a preset describes the way of cutting,
  // not which music plays over it
  final sound = [
    for (final l in previous.layers)
      if (l.isAudio && l.clips.isNotEmpty) l,
  ];
  return previous.copyWith(
    layers: [...layerList, ...sound],
    selectionIds: const {},
    activeLayer: 0,
    musicVolume: r.musicVolume,
    gameVolume: r.gameVolume,
    export: r.export,
  );
}

/// The recipe describing a montage that already exists.
///
/// It is "save as preset": instead of asking to describe again what is already
/// on screen, it reads what is there. Size and run-up come from the cuts'
/// **median**, not the mean — a single block stretched to the end of the music
/// would pull the mean far from what all the others are.
Recipe recipeFromMontage(MontageState s, {double? beatsPerCut}) {
  final fromRecording = [
    for (final c in s.clips)
      if (c.source == 'recording' && !c.isText) c,
  ];
  if (fromRecording.isEmpty) {
    return Recipe(
      musicVolume: s.musicVolume,
      gameVolume: s.gameVolume,
      export: s.export,
    );
  }

  final kinds = {
    for (final c in fromRecording)
      if (c.kind.isNotEmpty) c.kind,
  };
  final leads = [
    for (final c in fromRecording)
      if (c.sourceT > 0) (c.sourceT - c.startS).clamp(0.0, 10.0).toDouble(),
  ];

  return Recipe(
    kinds: kinds.isEmpty ? const ['kill'] : (kinds.toList()..sort()),
    durationS: _median([for (final c in fromRecording) c.durationS]) ?? 2.0,
    leadS: _median(leads) ?? 1.0,
    beatsPerCut: beatsPerCut ?? 0,
    speed: _median([for (final c in fromRecording) c.speed]) ?? 1.0,
    zoom: fromRecording.any((c) => c.zoom.isNotEmpty),
    fadeS:
        _median([
          for (final c in fromRecording)
            if (!c.fade.isNeutral) c.fade.inS,
        ]) ??
        0,
    counter: s.clips.any((c) => c.isText && int.tryParse(c.text) != null),
    streaks:
        s.clips.any((c) => c.isText && streakName(2) == c.text) ||
        s.clips.any((c) => c.isText && c.text.endsWith(' KILL')),
    musicVolume: s.musicVolume,
    gameVolume: s.gameVolume,
    export: s.export,
  );
}

double? _median(List<double> v) {
  if (v.isEmpty) return null;
  final sorted = [...v]..sort();
  final middle = sorted.length ~/ 2;
  final m = sorted.length.isOdd
      ? sorted[middle]
      : (sorted[middle - 1] + sorted[middle]) / 2;
  return double.parse(m.toStringAsFixed(3));
}
