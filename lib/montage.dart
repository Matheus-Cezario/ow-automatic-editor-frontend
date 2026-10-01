import 'dart:math' as math;

import 'api.dart';

/// The manual montage's computations, away from any widget.
///
/// The screen draws and drags; what decides where a block can land, how long
/// it lasts and where the cut starts in the recording is this file. Separate
/// because it is the part with right answers — and the only one that can be
/// tested without painting a single pixel.

/// Where the detected instant falls inside the cut.
///
/// 0.7 puts the kill at 70% of the block: there is run-up before it and the
/// impact lands near the end, which is where it works in a montage. The user
/// repositions it later if they want — this is only the initial guess.
const double kMomentAnchor = 0.7;

/// Initial duration of a freshly placed block, when there is no beat to
/// suggest anything else.
const double kDefaultCutS = 1.2;

/// The smallest block that makes sense. Below that the cut flickers and
/// nothing is seen.
const double kMinCutS = 0.2;

/// The magnet only acts when the beat is close: further than this, the user
/// really wanted that point, and snapping would be disobeying.
const double kSnapToleranceS = 0.12;

/// Snaps an instant to the nearest beat, if there is one within reach.
double snapToBeat(
  double value,
  List<double> beats, {
  double tolerance = kSnapToleranceS,
}) {
  if (beats.isEmpty) return value;
  var best = beats.first;
  for (final b in beats) {
    if ((b - value).abs() < (best - value).abs()) best = b;
  }
  return (best - value).abs() <= tolerance ? best : value;
}

/// How long the interval between two beats lasts — the natural cutting unit.
///
/// It comes from the median, not the mean: a beat missed at the start of the
/// music would stretch the mean and make every suggested block start out with
/// the wrong size.
double beatIntervalS(List<double> beats) {
  if (beats.length < 2) return kDefaultCutS;
  final gaps = <double>[
    for (var i = 1; i < beats.length; i++) beats[i] - beats[i - 1],
  ]..sort();
  return gaps[gaps.length ~/ 2];
}

/// The beat grid after the user's adjustments.
///
/// The rhythm detector gets the tempo right almost always and gets it wrong in
/// two predictable ways: it picks the offbeat (the grid ends up half a beat
/// early) or counts double/half the beats. Neither can be fixed by dragging
/// blocks — it is the ruler that is wrong, and fixing it fixes all of them at
/// once.
///
/// [multiplier] doubles (2) or halves (0.5) the density; [offsetS] shifts the
/// whole grid; [bar] above 1 keeps only the downbeat of every N beats, which
/// is where a scene change usually lands best.
List<double> adjustedGrid(
  List<double> beats, {
  double offsetS = 0,
  double multiplier = 1,
  int bar = 1,
}) {
  if (beats.isEmpty) return const [];

  var grid = [...beats]..sort();

  if (multiplier >= 2) {
    // a beat in the middle of each pair: double the density
    final dense = <double>[];
    for (var i = 0; i < grid.length; i++) {
      dense.add(grid[i]);
      if (i + 1 < grid.length) dense.add((grid[i] + grid[i + 1]) / 2);
    }
    grid = dense;
  } else if (multiplier <= 0.5) {
    grid = [for (var i = 0; i < grid.length; i += 2) grid[i]];
  }

  if (bar > 1) {
    grid = [for (var i = 0; i < grid.length; i += bar) grid[i]];
  }

  if (offsetS != 0) {
    grid = [
      for (final b in grid)
        if (b + offsetS >= 0) b + offsetS,
    ];
  }
  return grid;
}

/// How a match moment is identified without ambiguity.
///
/// The instant alone is not enough: a headshot kill lights up the kills
/// detector and the critical hits one almost on the same frame, and both
/// events can fall at the same rounded time. With the kind included, each card
/// on the shelf has its own key and knows by itself whether it is already on
/// the ruler.
String momentKey(String kind, double t) => '$kind@${t.toStringAsFixed(3)}';

/// The block born when the user drops a moment on the timeline.
///
/// The duration comes from a whole number of beats when there are beats: that
/// way the block is born on the rhythm, and the magnet has somewhere to snap
/// its edges.
TimelineClip cutForMoment(
  DetectionEvent event, {
  required double atS,
  required List<double> beats,
  int beatsPerCut = 2,
  double? sourceDurationS,
}) {
  final durationValue = beats.length >= 2
      ? beatIntervalS(beats) * beatsPerCut
      : kDefaultCutS;
  return TimelineClip(
    sourceT: event.t,
    kind: event.kind,
    atS: math.max(0, atS),
    durationS: durationValue,
    startS: sourceStartFor(event.t, durationValue, sourceDurationS: sourceDurationS),
  );
}

/// The clip born when the user brings a library item to the ruler.
///
/// Unlike a match moment, there is no instant to frame here: the file starts
/// where it starts. What is chosen is how long it stays.
TimelineClip mediaClip(
  Media item, {
  required double atS,
  required List<double> beats,
  int beatsPerCut = 2,
}) {
  final onBeat = beats.length >= 2 ? beatIntervalS(beats) * beatsPerCut : 0.0;
  // a short item rules the duration; otherwise, a whole number of beats
  final durationValue = onBeat > 0
      ? math.min(onBeat, item.suggestedDuration)
      : item.suggestedDuration;
  return TimelineClip(
    atS: math.max(0, atS),
    durationS: math.max(kMinCutS, durationValue),
    startS: 0,
    source: 'media',
    kind: item.kind,
  );
}

/// Where the cut starts in the recording so the instant lands at
/// [kMomentAnchor].
double sourceStartFor(
  double momentT,
  double durationS, {
  double? sourceDurationS,
}) {
  var startTime = momentT - durationS * kMomentAnchor;
  if (sourceDurationS != null && startTime + durationS > sourceDurationS) {
    startTime = sourceDurationS - durationS;
  }
  return math.max(0, startTime);
}

/// Does a block fit at [atS] without touching its neighbours?
///
/// [ignore] is the block's own index while it is being dragged — without it
/// the block would collide with itself and never leave its place.
bool fits(
  List<TimelineClip> cuts,
  double atS,
  double durationS, {
  int? ignore,
}) => fitsIgnoring(cuts, atS, durationS, ignore == null ? const {} : {ignore});

/// Like [fits], but ignoring several blocks at once.
///
/// It is what a batch move needs: the blocks moving together must not collide
/// with each other — they keep their distance — only with the ones that stayed
/// still.
bool fitsIgnoring(
  List<TimelineClip> cuts,
  double atS,
  double durationS,
  Set<int> ignored,
) {
  if (atS < 0) return false;
  for (var i = 0; i < cuts.length; i++) {
    if (ignored.contains(i)) continue;
    final other = cuts[i];
    if (atS < other.untilS - 1e-6 && other.atS < atS + durationS - 1e-6) {
      return false;
    }
  }
  return true;
}

/// Where to put the next block: right after the last one, or at the requested
/// point if it is free.
///
/// It serves the common case of filling the montage in sequence without having
/// to aim the cursor at each slot.
double nextSlot(List<TimelineClip> cuts, double desired, double durationValue) {
  if (fits(cuts, desired, durationValue)) return desired;
  var t = 0.0;
  for (final c in [...cuts]..sort((a, b) => a.atS.compareTo(b.atS))) {
    t = math.max(t, c.untilS);
  }
  return t;
}

/// Moves a block to [atS], snapping to the beat and refusing overlap.
///
/// It returns the block standing in its old place when the target is taken:
/// that is less surprising than pushing the neighbour, which would move a cut
/// the user had already fitted.
TimelineClip move(
  List<TimelineClip> cuts,
  int index,
  double atS, {
  required List<double> beats,
  required bool snap,
}) {
  final present = cuts[index];
  var destination = math.max(0.0, atS);
  if (snap) {
    // It snaps by the start, but if it is the end that is close to a beat, the
    // end rules: in a montage, what is heard is the scene change.
    //
    // Only the edges that **snapped** to something enter the contest.
    // Comparing both distances directly had a hidden effect: the edge that did
    // not snap stays exactly where the finger let go, distance zero, and always
    // won — the magnet stopped existing for any block whose duration was not a
    // multiple of the bar.
    // Three candidates: the two edges and the **play**. The play is what lines
    // up with the percussion in a montage — the edge can be half a second
    // before it — and without it in the contest, fitting the kill to the beat
    // meant eyeballing the mark drawn inside the block.
    final fromMark = present.sourceT > 0
        ? present.sourceT - present.startS
        : null;
    final candidates = <double>[
      snapToBeat(destination, beats),
      snapToBeat(destination + present.durationS, beats) - present.durationS,
      if (fromMark != null && fromMark >= 0 && fromMark <= present.durationS)
        snapToBeat(destination + fromMark, beats) - fromMark,
    ];

    // only the ones that snapped count: whoever did not snap stays exactly
    // where the finger let go, distance zero, and would always win
    final snapped = [
      for (final c in candidates)
        if ((c - destination).abs() > 1e-9) c,
    ];
    if (snapped.isNotEmpty) {
      destination = snapped.reduce(
        (a, b) => (a - destination).abs() <= (b - destination).abs() ? a : b,
      );
    }
    destination = math.max(0, destination);
  }
  if (!fits(cuts, destination, present.durationS, ignore: index)) return present;
  return present.copyWith(atS: destination);
}

/// Stretches or shortens a block by its **right edge**.
///
/// The cut's start does not move: the tail grows. It is what any editor does
/// when dragging the edge, and it is what makes the gesture predictable — if
/// the content reframed on every pixel, the picture would slide under the
/// finger.
///
/// (When the block is *created*, the framing is anchored at 70% — see
/// [cutForMoment]. After that, what repositions the content inside the block
/// is the framing control, not the duration.)
TimelineClip stretchRight(
  List<TimelineClip> cuts,
  int index,
  double durationValue, {
  required List<double> beats,
  required bool snap,
  double? sourceDurationS,
}) {
  final present = cuts[index];
  var fresh = math.max(kMinCutS, durationValue);

  // what was not recorded cannot be shown
  if (sourceDurationS != null) {
    fresh = math.min(fresh, math.max(kMinCutS, sourceDurationS - present.startS));
  }
  if (snap) {
    final endTime = snapToBeat(present.atS + fresh, beats);
    if (endTime - present.atS >= kMinCutS) fresh = endTime - present.atS;
  }

  // it stops against the neighbour instead of refusing: stopping exactly at
  // the limit is what the user is trying to do when stretching up to it
  final neighbour = _nextAfter(cuts, index, present.atS);
  if (neighbour != null) fresh = math.min(fresh, neighbour - present.atS);
  if (fresh < kMinCutS) return present;

  return present.copyWith(durationS: fresh);
}

/// Trims the block by its **left edge**, without moving what is already
/// framed.
///
/// Dragging the left edge eats the cut's start: the edge moves, the content
/// stays in place. That is why the start in the recording moves along, by the
/// same amount — it is what tells *trimming* apart from *moving*.
TimelineClip trimLeft(
  List<TimelineClip> cuts,
  int index,
  double newAt, {
  required List<double> beats,
  required bool snap,
}) {
  final present = cuts[index];
  var destination = math.max(0.0, newAt);
  if (snap) destination = math.max(0, snapToBeat(destination, beats));

  // it cannot run into the neighbour behind nor start before the recording
  final previous = _previousBefore(cuts, index, present.atS);
  if (previous != null) destination = math.max(destination, previous);
  destination = math.max(destination, present.atS - present.startS);

  final fresh = present.untilS - destination;
  if (fresh < kMinCutS) return present;

  return present.copyWith(
    atS: destination,
    durationS: fresh,
    startS: present.startS + (destination - present.atS),
  );
}

/// Where the next block starts — the ceiling for whoever stretches right.
double? _nextAfter(List<TimelineClip> cuts, int index, double at) {
  double? smaller;
  for (var i = 0; i < cuts.length; i++) {
    if (i == index) continue;
    final other = cuts[i].atS;
    if (other >= at - 1e-6 && (smaller == null || other < smaller)) smaller = other;
  }
  return smaller;
}

/// Where the previous block ends — the floor for whoever trims from the left.
double? _previousBefore(List<TimelineClip> cuts, int index, double at) {
  double? larger;
  for (var i = 0; i < cuts.length; i++) {
    if (i == index) continue;
    final endTime = cuts[i].untilS;
    if (endTime <= at + 1e-6 && (larger == null || endTime > larger)) larger = endTime;
  }
  return larger;
}

/// Where, from 0 to 1 of the block, the instant it came from falls.
///
/// It is the mark drawn inside the block. Without it, fitting the kill to the
/// beat would be guessing: what lines up with the percussion is the play, not
/// the cut's edge — and the edge can be half a second before it.
///
/// `null` when the moment ended up outside the block: you can trim until it
/// leaves, and then there is nothing to mark.
double? momentMark(TimelineClip cut) {
  if (cut.durationS <= 0) return null;
  final f = (cut.sourceT - cut.startS) / cut.durationS;
  return f < 0 || f > 1 ? null : f;
}

/// Where the moment the block came from falls in the **video**, in seconds.
///
/// `null` when the moment ended up outside the block — you can trim until it
/// leaves — or when the block came from no moment at all (music, text, media).
double? momentInVideo(TimelineClip cut) {
  if (cut.sourceT <= 0 || momentMark(cut) == null) return null;
  return cut.atS + (cut.sourceT - cut.startS);
}

/// The block under the playhead at [atS], or `null` if it is a gap there.
int? blockAt(List<TimelineClip> cuts, double atS) {
  for (var i = 0; i < cuts.length; i++) {
    if (atS >= cuts[i].atS - 1e-6 && atS < cuts[i].untilS - 1e-6) return i;
  }
  return null;
}

/// The transition happening at [t], for the monitor to imitate.
///
/// `p` runs from 0 to 1 across it. `leaving` is the outgoing side of a dip:
/// the clip before darkens (or brightens) over its last half, and the clip
/// after comes back over its first half — the way the server renders it.
({String kind, double p, bool leaving})? transitionAt(
  List<TimelineClip> cuts,
  double t,
) {
  final i = blockAt(cuts, t);
  if (i == null) return null;
  final c = cuts[i];
  final tr = c.transition;
  if (tr != null && t < c.atS + tr.durationS) {
    return (
      kind: tr.kind,
      p: ((t - c.atS) / tr.durationS).clamp(0, 1),
      leaving: false,
    );
  }
  // a dip starts before the cut, still on the outgoing clip
  for (final n in cuts) {
    final nt = n.transition;
    if (nt == null || (n.atS - c.untilS).abs() > 1e-3) continue;
    if (nt.kind != 'fade_black' && nt.kind != 'fade_white') continue;
    final half = nt.durationS / 2;
    if (t >= n.atS - half) {
      return (
        kind: nt.kind,
        p: ((t - (n.atS - half)) / half).clamp(0, 1),
        leaving: true,
      );
    }
  }
  return null;
}

/// Which instant of the **recording** the preview should show at [atS] of the
/// video.
///
/// `null` means a black screen — the same the server will render there. It is
/// this function that makes the preview and the final file tell the same
/// story: it is the read version of the `plan()` the backend uses to cut.
double? sourceAt(List<TimelineClip> cuts, double atS) {
  final i = blockAt(cuts, atS);
  if (i == null) return null;
  return cuts[i].startS + (atS - cuts[i].atS);
}

/// Duration of the video that will come out — gaps included.
///
/// It is the number the screen shows, and it must match what the server will
/// produce: empty space becomes black with the music playing, not shortening.
double videoDuration(List<TimelineClip> cuts) {
  var endTime = 0.0;
  for (final c in cuts) {
    endTime = math.max(endTime, c.untilS);
  }
  return endTime;
}

/// How much of the video is black — what the user left empty between blocks.
double blackDuration(List<TimelineClip> cuts) {
  final total = videoDuration(cuts);
  var withPicture = 0.0;
  for (final c in cuts) {
    withPicture += c.durationS;
  }
  return math.max(0, total - withPicture);
}
