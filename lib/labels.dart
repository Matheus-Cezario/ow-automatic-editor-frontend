import 'api.dart';
import 'montage.dart';

/// Text the system writes itself, from what happened in the match.
///
/// It is this editor's edge, and it is not in ffmpeg: it is in the editor
/// **knowing what happened in the video**. A kill counter that goes up by
/// itself is not a hard effect to render — it is an effect no other editor can
/// offer, because to them the video is a rectangle of pixels with no story.
///
/// Everything here returns ordinary text clips. Once created, they move, fade
/// and edit like any other — the generator is a shortcut, not a new entity.

/// How long each label stays on screen, when nothing says otherwise.
const double kLabelDuration = 1.6;

/// A ready label, at the requested point of the montage.
TimelineClip textClip(
  String textValue, {
  required double atS,
  double durationS = kLabelDuration,
  double size = 0.1,
  String color = 'white',
  double y = -0.55,
}) => TimelineClip(
  atS: atS,
  durationS: durationS,
  startS: 0,
  source: 'text',
  text: textValue,
  textStyle: ClipTextStyle(size: size, color: color),
  transform: ClipTransform(y: y),
  fade: const ClipFade(inS: 0.15, outS: 0.25),
);

/// The cut kinds the counter and the streaks count as a kill.
///
/// `ability_kill` counts: an Orisa javelin that kills is a kill like any other
/// — the detector just reads it in a different place on screen (the killfeed,
/// not the crosshair). Leaving it out gave a counter that skipped numbers right
/// in front of someone who had just watched the kill happen.
///
/// `headshot` does **not** count: the red marker on the crosshair is a
/// critical hit, not a kill. Counting it would inflate the number with shots
/// that only hurt.
const _kills = {'kill', 'ability_kill'};

/// The kill counter, going up with every cut that came from a kill.
///
/// One label per kill, each starting where its cut starts and lasting until
/// the next one — so the number on screen is always the current one. The last
/// one stays until the end of the video.
List<TimelineClip> killCounter(
  List<TimelineClip> clips, {
  double? endS,
  String suffix = '',
}) {
  final kills = [
    for (final c in clips)
      if (_kills.contains(c.kind)) c,
  ]..sort((a, b) => a.atS.compareTo(b.atS));
  if (kills.isEmpty) return const [];

  final endTime = endS ?? videoDuration(clips);
  final labels = <TimelineClip>[];
  for (var i = 0; i < kills.length; i++) {
    final starts = kills[i].atS;
    final ends = i + 1 < kills.length ? kills[i + 1].atS : endTime;
    if (ends - starts < kMinCutS) continue;
    labels.add(
      textClip(
        '${i + 1}$suffix',
        atS: starts,
        durationS: ends - starts,
        size: 0.12,
        y: -0.72,
      ),
    );
  }
  return labels;
}

/// What a sequence of N kills in a row is called.
///
/// The names are the game's own — whoever edits Overwatch videos recognises
/// them at once, and a label saying "3 KILLS" where "TRIPLE KILL" fits sounds
/// like a spreadsheet.
String? streakName(int howMany) => switch (howMany) {
  2 => 'DOUBLE KILL',
  3 => 'TRIPLE KILL',
  4 => 'QUAD KILL',
  >= 5 => 'TEAM KILL',
  _ => null,
};

/// Labels for streaks: kills close to each other.
///
/// The window is the same idea the server's `planner` used to propose a streak
/// — but here it looks at the cuts that **are in the montage**, not the match's
/// events: what counts is what the viewer will see in a row.
List<TimelineClip> streakLabels(
  List<TimelineClip> clips, {
  double windowS = 2.5,
}) {
  final kills = [
    for (final c in clips)
      if (_kills.contains(c.kind)) c,
  ]..sort((a, b) => a.atS.compareTo(b.atS));
  if (kills.length < 2) return const [];

  final labels = <TimelineClip>[];
  var runStart = 0;
  for (var i = 1; i <= kills.length; i++) {
    final broke =
        i == kills.length || kills[i].atS - kills[i - 1].untilS > windowS;
    if (!broke) continue;

    final displayName = streakName(i - runStart);
    if (displayName != null) {
      // the label goes on the streak's last kill: that is where it closes
      labels.add(
        textClip(
          displayName,
          atS: kills[i - 1].atS,
          durationS: kLabelDuration,
          size: 0.11,
          color: 'yellow',
        ),
      );
    }
    runStart = i;
  }
  return labels;
}
