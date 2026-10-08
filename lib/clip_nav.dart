import 'api.dart';
import 'widgets/highlight_style.dart';

/// Moving through the montage without a mouse, and saying what is there.
///
/// The ruler is drawn: a screen reader sees nothing in it and the keyboard
/// could only move the playhead. These give each clip a sentence and an
/// order, so it can be reached and heard one by one.

/// Every clip with its layer, in the order they play: by start, then by
/// layer from the top.
List<(TimelineClip, int)> clipsInOrder(List<Layer> layers) {
  final all = [
    for (var i = 0; i < layers.length; i++)
      for (final c in layers[i].clips) (c, i),
  ];
  all.sort((a, b) {
    final t = a.$1.atS.compareTo(b.$1.atS);
    return t != 0 ? t : a.$2.compareTo(b.$2);
  });
  return all;
}

/// The clip after (or before) [fromId]; with nothing selected, the first one
/// starting at or after the playhead (or the last one before it).
(TimelineClip, int)? neighbourClip(
  List<Layer> layers, {
  required String? fromId,
  required double cursor,
  required bool forward,
}) {
  final order = clipsInOrder(layers);
  if (order.isEmpty) return null;
  final at = fromId == null
      ? -1
      : order.indexWhere((e) => e.$1.id == fromId);
  if (at >= 0) {
    final next = at + (forward ? 1 : -1);
    return next >= 0 && next < order.length ? order[next] : null;
  }
  const eps = 1e-6;
  if (forward) {
    return order.where((e) => e.$1.atS >= cursor - eps).firstOrNull;
  }
  return order.where((e) => e.$1.atS < cursor - eps).lastOrNull;
}

/// The next place something starts or ends, after (or before) [cursor].
double? nextEdit(List<Layer> layers, double cursor, {required bool forward}) {
  const eps = 1e-3;
  final points = <double>{
    0,
    for (final l in layers)
      for (final c in l.clips) ...[c.atS, c.untilS],
  }.toList()..sort();
  return forward
      ? points.where((t) => t > cursor + eps).firstOrNull
      : points.where((t) => t < cursor - eps).lastOrNull;
}

/// What a clip is called: the name the user gave, the text it shows, the
/// song, or the kind of play.
String clipName(TimelineClip c, {Track? track}) {
  if (c.label.isNotEmpty) return c.label;
  if (c.isText && c.text.trim().isNotEmpty) return 'Text "${c.text.trim()}"';
  if (track != null) return track.name;
  return EventStyle.of(c.kind).label;
}

/// One sentence for a clip, as a screen reader says it.
String describeClip(
  TimelineClip c, {
  required int layer,
  String layerName = '',
  Track? track,
  bool locked = false,
}) {
  final parts = [
    clipName(c, track: track),
    layerName.isEmpty ? 'layer ${layer + 1}' : 'layer "$layerName"',
    'from ${formatClock(c.atS)} to ${formatClock(c.untilS)}',
    '${c.durationS.toStringAsFixed(1)} seconds',
    if (locked) 'locked',
  ];
  return parts.join(', ');
}
