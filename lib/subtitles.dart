/// Subtitles: reading and writing `.srt` / `.vtt`, and the subtitles layer.
///
/// A subtitle is an ordinary text clip — it moves, trims and restyles like any
/// other, and the server renders it with no special case. What makes it a
/// subtitle is its [kSubtitleKind] and the layer it lives on: one picture
/// layer, on top, that importing fills and the `.srt` download reads back.
library;

import 'dart:math' as math;

import 'api.dart';
import 'montage.dart';
import 'montage_state.dart';

/// The `kind` that marks a text clip as a subtitle.
const kSubtitleKind = 'subtitle';

/// The layer subtitles go on.
const kSubtitlesLayerName = 'Subtitles';

/// How long a subtitle written at the playhead lasts.
const kSubtitleDuration = 2.0;

/// The look of a subtitle: small, low, white on a dark band, breaking inside
/// most of the width — what a viewer expects a caption to look like.
const kSubtitleStyle = ClipTextStyle(
  size: 0.055,
  outline: 0.08,
  width: 0.8,
  box: 'black',
  boxOpacity: 0.55,
);

/// Where a subtitle sits: near the bottom, clear of the safe-area edge.
const kSubtitleY = 0.78;

/// One line (or a few) of a subtitles file, in seconds of the video.
class SubtitleCue {
  const SubtitleCue(this.startS, this.endS, this.text);

  final double startS;
  final double endS;
  final String text;

  @override
  String toString() => 'SubtitleCue($startS, $endS, $text)';
}

final _timing = RegExp(
  r'^\s*((?:\d+:)?\d{1,2}:\d{2}[.,]\d{1,3})\s*-->\s*((?:\d+:)?\d{1,2}:\d{2}[.,]\d{1,3})',
);

/// `01:02:03,456`, `02:03.456` → seconds.
double _seconds(String s) {
  final parts = s.replaceAll(',', '.').split(':');
  var total = 0.0;
  for (final p in parts) {
    total = total * 60 + double.parse(p);
  }
  return total;
}

/// What a cue shows, without the markup players use to style it: `<i>`,
/// `<c.yellow>`, `<00:01.000>` from VTT, `{\an8}` from SRT.
String _plain(String line) => line
    .replaceAll(RegExp(r'<[^>]*>'), '')
    .replaceAll(RegExp(r'\{\\[^}]*\}'), '')
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&nbsp;', ' ')
    .trim();

/// The cues of an `.srt` or `.vtt` file, in time order.
///
/// Both are blocks separated by a blank line, each with a `start --> end`
/// line and the text under it; numbers, `WEBVTT`, `NOTE`s and styles are
/// skipped. A block without a timing line is not a cue, and a cue without text
/// shows nothing — both are left out rather than refusing the whole file.
List<SubtitleCue> parseSubtitles(String source) {
  final text = source
      .replaceFirst('﻿', '')
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n');
  final cues = <SubtitleCue>[];
  for (final block in text.split(RegExp(r'\n\s*\n'))) {
    final lines = block.split('\n');
    final at = lines.indexWhere(_timing.hasMatch);
    if (at < 0) continue;
    final m = _timing.firstMatch(lines[at])!;
    final start = _seconds(m.group(1)!);
    final end = _seconds(m.group(2)!);
    final body = [
      for (final l in lines.skip(at + 1))
        if (_plain(l).isNotEmpty) _plain(l),
    ].join('\n');
    if (body.isEmpty || end <= start) continue;
    cues.add(SubtitleCue(start, end, body));
  }
  cues.sort((a, b) => a.startS.compareTo(b.startS));
  return cues;
}

/// `3725.5` → `01:02:05,500`.
String _srtTime(double s) {
  final ms = (math.max(0.0, s) * 1000).round();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(ms ~/ 3600000)}:${two(ms ~/ 60000 % 60)}:'
      '${two(ms ~/ 1000 % 60)},${(ms % 1000).toString().padLeft(3, '0')}';
}

/// The montage's subtitles as an `.srt` file, for a platform that shows its
/// own captions (YouTube takes it as is).
String writeSrt(List<TimelineClip> subtitles) {
  final sorted = [...subtitles]..sort((a, b) => a.atS.compareTo(b.atS));
  final out = StringBuffer();
  for (var i = 0; i < sorted.length; i++) {
    final c = sorted[i];
    out
      ..writeln(i + 1)
      ..writeln('${_srtTime(c.atS)} --> ${_srtTime(c.untilS)}')
      ..writeln(c.text.trim())
      ..writeln();
  }
  return out.toString();
}

/// Every subtitle in the montage, wherever it was moved to.
List<TimelineClip> subtitlesOf(MontageState s) => [
  for (final l in s.layers)
    if (!l.isAudio)
      for (final c in l.clips)
        if (c.isText && c.kind == kSubtitleKind) c,
]..sort((a, b) => a.atS.compareTo(b.atS));

/// A subtitle block.
TimelineClip subtitleClip(
  String text, {
  required double atS,
  double durationS = kSubtitleDuration,
}) => TimelineClip(
  atS: math.max(0, atS),
  durationS: math.max(kMinCutS, durationS),
  startS: 0,
  source: 'text',
  kind: kSubtitleKind,
  text: text,
  textStyle: kSubtitleStyle,
  transform: const ClipTransform(y: kSubtitleY),
);

/// The subtitles layer, made on top when there is none yet.
(MontageState, int) _subtitlesLayer(MontageState s) {
  final i = s.layers.indexWhere(
    (l) => !l.isAudio && l.name == kSubtitlesLayerName,
  );
  if (i >= 0) return (s, i);
  final added = addLayer(s, displayName: kSubtitlesLayerName);
  return (added, added.layers.length - 1);
}

/// Puts a file's cues on the subtitles layer, replacing what was there:
/// importing a corrected file again is the usual reason to import twice.
///
/// [offsetS] moves every cue, for a file timed to something that starts
/// earlier or later than the montage. Cues that overlap are cut where the next
/// one starts — a layer holds one clip at a time — and a cue left shorter than
/// the shortest block is dropped.
MontageState putSubtitles(
  MontageState s,
  List<SubtitleCue> cues, {
  double offsetS = 0,
}) {
  final int index;
  (s, index) = _subtitlesLayer(s);
  final placed = <TimelineClip>[];
  for (var i = 0; i < cues.length; i++) {
    final start = math.max(0.0, cues[i].startS + offsetS);
    var end = cues[i].endS + offsetS;
    if (i + 1 < cues.length) {
      end = math.min(end, cues[i + 1].startS + offsetS);
    }
    if (end - start < kMinCutS) continue;
    placed.add(
      subtitleClip(
        cues[i].text,
        atS: start,
        durationS: end - start,
      ).copyWith(id: newCutId()),
    );
  }
  return s
      .withLayer(index, s.layers[index].copyWith(clips: placed))
      .copyWith(activeLayer: index, selectionIds: const {});
}

/// A subtitle at [atS] on the subtitles layer, in the first free stretch from
/// there, selected so it can be typed into straight away.
MontageState addSubtitle(MontageState s, double atS, {String text = 'Subtitle'}) {
  final int index;
  (s, index) = _subtitlesLayer(s);
  final existing = s.layers[index].clips;
  final at = nextSlot(existing, math.max(0, atS), kSubtitleDuration);
  final clip = subtitleClip(text, atS: at).copyWith(id: newCutId());
  return s
      .withLayer(index, s.layers[index].copyWith(clips: [...existing, clip]))
      .copyWith(activeLayer: index, selectionIds: {clip.id});
}
