import 'dart:math';

import 'api.dart';
import 'montage_state.dart';

/// Export choices, on the app's side.
///
/// The montage does not change: what changes is the window you look at it
/// through. That is why the same work becomes a 16:9 for YouTube and a 9:16 for
/// Shorts without a single clip moving — and why changing the format needs no
/// undo.

/// A named output size.
class OutputFormat {
  const OutputFormat(this.displayName, this.width, this.height, {this.note = ''});

  final String displayName;

  /// `0` in both = the recording's size.
  final int width;
  final int height;
  final String note;

  bool matches(ExportSpec e) => e.width == width && e.height == height;

  /// How much wider than tall the frame is. `null` when it follows the
  /// recording.
  double? get aspect => height == 0 ? null : width / height;
}

/// The formats really asked for in a gameplay editor.
///
/// Deliberately short. A list with every resolution H.264 accepts helps nobody
/// decide: whoever wants 1440x1080 knows how to type two numbers.
const outputFormats = [
  OutputFormat('Original', 0, 0, note: 'as recorded'),
  OutputFormat('1080p', 1920, 1080, note: 'YouTube, Twitch'),
  OutputFormat('720p', 1280, 720, note: 'lighter'),
  OutputFormat('Vertical', 1080, 1920, note: 'Shorts, Reels, TikTok'),
  OutputFormat('Square', 1080, 1080, note: 'feed'),
];

/// The formats a montage can also come out in, rendered together with the
/// main one: (aspect, width, height, where it goes).
const extraFormatList = [
  ('16:9', 1920, 1080, 'YouTube'),
  ('9:16', 1080, 1920, 'Shorts, Reels, TikTok'),
  ('1:1', 1080, 1080, 'feed'),
  ('4:5', 1080, 1350, 'Instagram feed'),
];

/// The main output's aspect, as a width/height ratio — the recording's when
/// the output keeps its size.
double outputRatio(ExportSpec e, {required int widthPx, required int heightPx}) {
  if (e.width > 0 && e.height > 0) return e.width / e.height;
  if (widthPx > 0 && heightPx > 0) return widthPx / heightPx;
  return 16 / 9;
}

/// Everything one render makes: the montage as set up, and one copy per
/// extra format — same cuts, another window. Each extra takes the extras'
/// framing, the killfeed only where it is portrait, and its aspect in the
/// title so the files tell themselves apart. An extra in the main output's
/// own aspect would be a duplicate, and is left out.
List<Montage> renderVariants(
  MontageState s, {
  required int widthPx,
  required int heightPx,
}) {
  final main = s.toPayload();
  final ratio = outputRatio(s.export, widthPx: widthPx, heightPx: heightPx);
  final out = [main];
  for (final (aspect, w, h, _) in extraFormatList) {
    if (!s.export.extraFormats.contains(aspect)) continue;
    if ((w / h - ratio).abs() < 0.01) continue;
    final title = main.title.isEmpty ? aspect : '${main.title} ($aspect)';
    out.add(
      s
          .copyWith(
            title: title,
            export: s.export.copyWith(
              width: w,
              height: h,
              fit: s.export.extraFit,
              killfeedInset: s.export.extraKillfeed && h > w,
              extraFormats: const [],
            ),
          )
          .toPayload(),
    );
  }
  return out;
}

/// Loudness targets, in LUFS, and where each is the norm.
const loudnessTargets = [
  (-14.0, 'YouTube, Spotify, TikTok'),
  (-16.0, 'Apple, podcasts'),
  (-23.0, 'TV (EBU R128)'),
];

/// Quality, in three steps.
///
/// The number is H.264's CRF, where lower is better and each +6 roughly halves
/// the file. Nobody wants to choose that in CRF units.
class Quality {
  const Quality(this.displayName, this.crf, this.note);

  final String displayName;
  final int crf;
  final String note;
}

const qualities = [
  Quality('High', 18, 'larger file'),
  Quality('Good', 20, 'the default'),
  Quality('Light', 26, 'for sharing around'),
];

Quality qualityOf(ExportSpec e) =>
    qualities.firstWhere((q) => q.crf == e.crf, orElse: () => qualities[1]);

/// The frame rates worth offering. `0` follows the recording.
const outputFps = <double>[0, 24, 30, 60];

/// The range that will come out, already resolved against the montage's
/// duration.
///
/// [ExportSpec.toS] as `null` means "to the end", and the end is only known
/// here — the spec does not know how long the montage lasts. A range that no
/// longer makes sense — because its clips were deleted afterwards — goes back
/// to the whole video, instead of becoming a zero-second request the server
/// would refuse.
({double startTime, double endTime}) stretchOf(ExportSpec e, double durationSecs) {
  final startTime = e.fromS.clamp(0.0, durationSecs).toDouble();
  final endTime = (e.toS ?? durationSecs).clamp(0.0, durationSecs).toDouble();
  if (endTime - startTime < 0.05) return (startTime: 0.0, endTime: durationSecs);
  return (startTime: startTime, endTime: endTime);
}

/// How long the exported video will be.
double exportedDuration(ExportSpec e, double durationSecs) {
  final t = stretchOf(e, durationSecs);
  return t.endTime - t.startTime;
}

/// Limits the export to what is selected.
///
/// The shortcut for "I just want to see this part": instead of exporting five
/// minutes to check a two-second splice, it exports the two seconds. The
/// montage stays intact — the range can be removed later to export everything.
MontageState exportSelection(MontageState s) {
  final chosenOnes = [
    for (final c in s.clips)
      if (s.selectionIds.contains(c.id)) c,
  ];
  if (chosenOnes.isEmpty) return s;

  var startTime = double.infinity;
  var endTime = 0.0;
  for (final c in chosenOnes) {
    if (c.atS < startTime) startTime = c.atS;
    if (c.untilS > endTime) endTime = c.untilS;
  }
  return s.copyWith(
    export: s.export.copyWith(fromS: startTime, toS: endTime),
  );
}

/// Is there an in or an out point? Without either, the range is the whole
/// video.
bool hasRange(ExportSpec e) => e.fromS > 0 || e.toS != null;

/// The in point at [tS]. An out point at or before it no longer makes a
/// range, so it goes — the range then runs to the end.
MontageState setRangeIn(MontageState s, double tS) {
  final t = max(0.0, tS);
  final out = s.export.toS;
  return s.copyWith(
    export: s.export.copyWith(
      fromS: t,
      clearTo: out != null && out <= t + 0.05,
    ),
  );
}

/// The out point at [tS]; an in point at or after it goes back to the start.
MontageState setRangeOut(MontageState s, double tS) {
  if (tS <= 0.05) return s;
  return s.copyWith(
    export: s.export.copyWith(
      toS: tS,
      fromS: s.export.fromS >= tS - 0.05 ? 0 : null,
    ),
  );
}

/// Undoes the time range: the whole video comes out again.
MontageState exportAll(MontageState s) =>
    s.copyWith(export: s.export.copyWith(fromS: 0, clearTo: true));

/// A guess at the file size, in MB.
///
/// It really is a guess — H.264 spends bits where the picture moves, and a
/// gameplay montage moves a lot. It serves to answer "will this be 8 MB or
/// 800?", which is the question asked before exporting, not to promise a
/// number.
double estimatedSizeMB(
  ExportSpec e, {
  required double durationSecs,
  required int widthPx,
  required int heightPx,
}) {
  final w = e.width == 0 ? widthPx : e.width;
  final h = e.height == 0 ? heightPx : e.height;
  final fps = e.fps == 0 ? 30.0 : e.fps;
  // bits per pixel per frame, calibrated on CRF: each +6 of CRF roughly halves
  // the rate
  final bpp = 0.09 * pow(0.5, (e.crf - 20) / 6.0);
  final bits = w * h * fps * bpp * exportedDuration(e, durationSecs);
  return bits / 8 / 1024 / 1024;
}

String _clock(double s) {
  final m = s ~/ 60;
  final sec = (s - m * 60).floor().toString().padLeft(2, '0');
  return '$m:$sec';
}

/// A one-line summary of what will come out, for the export bar.
String exportSummary(
  ExportSpec e, {
  required double durationSecs,
  required int widthPx,
  required int heightPx,
}) {
  final w = e.width == 0 ? widthPx : e.width;
  final h = e.height == 0 ? heightPx : e.height;
  final fps = e.fps == 0 ? '' : ' · ${e.fps.toStringAsFixed(0)}fps';
  final dur = _clock(exportedDuration(e, durationSecs));
  final mb = estimatedSizeMB(
    e,
    durationSecs: durationSecs,
    widthPx: widthPx,
    heightPx: heightPx,
  );
  return '${w}x$h$fps · $dur · ~${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
}

/// Where the watermark can go.
///
/// Four corners and no dragging: the mark is the one thing in the video nobody
/// wants to look at closely, and a corner picked in two clicks settles the
/// whole case. The coordinates are measured from the frame's centre.
class WatermarkCorner {
  const WatermarkCorner(this.displayName, this.x, this.y);

  final String displayName;
  final double x;
  final double y;
}

const kWatermarkCorners = [
  WatermarkCorner('↖', -0.82, -0.82),
  WatermarkCorner('↗', 0.82, -0.82),
  WatermarkCorner('↙', -0.82, 0.82),
  WatermarkCorner('↘', 0.82, 0.82),
];
