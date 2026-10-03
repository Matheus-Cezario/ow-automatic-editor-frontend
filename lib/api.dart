import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;

import 'upload.dart';

/// API base. When the Flutter app is served by the gateway itself it is
/// empty and calls become relative — so it works on any host without a
/// rebuild. In development the app runs on one port and the API on another.
const String kApiBase = String.fromEnvironment(
  'API_BASE',
  defaultValue: 'http://localhost:8000',
);

/// Turns a path returned by the API into an absolute URL.
///
/// In production the app is built with an empty [kApiBase] so it calls the
/// API on a relative path — which works for `fetch` and for the `<video>` tag,
/// which the browser resolves on its own. But opening a download needs an
/// absolute URL: `Uri.parse('/api/...')` has no scheme and no host, and
/// `url_launcher` refuses it. `Uri.base` is the page address, so resolving
/// against it gives the full URL on any host.
String absoluteUrl(String pathOrUrl) {
  final uri = Uri.parse(pathOrUrl);
  if (uri.hasScheme) return pathOrUrl;
  return Uri.base.resolve(pathOrUrl).toString();
}

/// The thumbnail of an instant of the match.
///
/// The `.toStringAsFixed(2)` is not cosmetic: the file key on the server comes
/// from the instant rounded to hundredths, so asking with another precision is
/// asking for a file that does not exist.
String frameUrl(String jobId, double t) =>
    absoluteUrl('$kApiBase/api/jobs/$jobId/frame?t=${t.toStringAsFixed(2)}');

class ApiException implements Exception {
  ApiException(this.message, [this.statusCode]);
  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

// ─────────────────────────────── models ──────────────────────────────────────

/// **Analysis** parameters: how to read the match.
///
/// They apply to the whole match and are decided at upload. There used to be
/// many more — how many kills made a streak, how many made a "one against
/// all" — because the analysis ended by proposing finished videos. It no
/// longer does: it delivers the moments, and grouping them is the editor's job.
class JobParams {
  const JobParams({this.ultNegateWindowS = 6});

  /// An enemy ultimate followed by a kill within this window counts as a
  /// negated ultimate — the only reading that needs two detectors.
  final double ultNegateWindowS;

  Map<String, dynamic> toJson() => {'ult_negate_window_s': ultNegateWindowS};

  JobParams copyWith({double? ultNegateWindowS}) =>
      JobParams(ultNegateWindowS: ultNegateWindowS ?? this.ultNegateWindowS);
}

/// A song uploaded for the match, already listened to by the system.
///
/// It goes up **before** any video exists: it is by listening to the song,
/// with the beats and the waveform drawn, that the user decides where each cut
/// lands. That is why it belongs to the match and not to a request — the same
/// track serves as many montages as they want.
class Track {
  Track({
    required this.id,
    required this.status,
    required this.name,
    required this.durationS,
    required this.bpm,
    required this.beats,
    required this.peaks,
    required this.audioUrl,
    this.error,
  });

  factory Track.fromJson(Map<String, dynamic> j) => Track(
    id: j['id'] as String,
    status: j['status'] as String,
    name: j['name'] as String? ?? '',
    durationS: (j['duration_s'] as num?)?.toDouble() ?? 0,
    bpm: (j['bpm'] as num?)?.toDouble() ?? 0,
    beats: ((j['beats'] as List?) ?? [])
        .map((e) => (e as num).toDouble())
        .toList(),
    peaks: ((j['peaks'] as List?) ?? [])
        .map((e) => (e as num).toDouble())
        .toList(),
    audioUrl: absoluteUrl('$kApiBase${j['audio_url']}'),
    error: j['error'] as String?,
  );

  final String id;
  final String status;
  final String name;
  final double durationS;
  final double bpm;

  /// Beat instants. This is what the magnet uses to snap the cuts.
  final List<double> beats;

  /// Song envelope in 0..1, already reduced by the server: the app draws the
  /// wave without downloading the whole audio just for that.
  final List<double> peaks;
  final String audioUrl;
  final String? error;

  bool get isReady => status == 'ready';
  bool get isFailed => status == 'failed';
  bool get isPending => status == 'pending';
}

/// Where and at what size the clip appears in the frame.
///
/// It is called `ClipTransform` and not `Transform` because Flutter already has
/// a widget with that name, and the two meet on every screen that draws the
/// timeline.
///
/// [x] and [y] are offsets from the centre normalised by half the frame:
/// -1 touches the left/top edge, +1 the right/bottom. So the same montage
/// works at any resolution — what matters is the proportion.
class ClipTransform {
  const ClipTransform({
    this.scale = 1,
    this.x = 0,
    this.y = 0,
    this.opacity = 1,
  });

  factory ClipTransform.fromJson(Map<String, dynamic> j) => ClipTransform(
    scale: (j['scale'] as num?)?.toDouble() ?? 1,
    x: (j['x'] as num?)?.toDouble() ?? 0,
    y: (j['y'] as num?)?.toDouble() ?? 0,
    opacity: (j['opacity'] as num?)?.toDouble() ?? 1,
  );

  final double scale;
  final double x;
  final double y;
  final double opacity;

  /// The clip comes in as it came, with nothing on top.
  bool get isNeutral => scale == 1 && x == 0 && y == 0 && opacity == 1;

  ClipTransform copyWith({
    double? scale,
    double? x,
    double? y,
    double? opacity,
  }) => ClipTransform(
    scale: scale ?? this.scale,
    x: x ?? this.x,
    y: y ?? this.y,
    opacity: opacity ?? this.opacity,
  );

  Map<String, dynamic> toJson() => {
    'scale': scale,
    'x': x,
    'y': y,
    'opacity': opacity,
  };
}

/// The clip's own sound — which is not the video's soundtrack.
class ClipAudio {
  const ClipAudio({
    this.volume = 1,
    this.mute = false,
    this.fadeInS = 0,
    this.fadeOutS = 0,
  });

  factory ClipAudio.fromJson(Map<String, dynamic> j) => ClipAudio(
    volume: (j['volume'] as num?)?.toDouble() ?? 1,
    mute: j['mute'] as bool? ?? false,
    fadeInS: (j['fade_in_s'] as num?)?.toDouble() ?? 0,
    fadeOutS: (j['fade_out_s'] as num?)?.toDouble() ?? 0,
  );

  final double volume;
  final bool mute;
  final double fadeInS;
  final double fadeOutS;

  bool get isNeutral => volume == 1 && !mute && fadeInS == 0 && fadeOutS == 0;

  ClipAudio copyWith({
    double? volume,
    bool? mute,
    double? fadeInS,
    double? fadeOutS,
  }) => ClipAudio(
    volume: volume ?? this.volume,
    mute: mute ?? this.mute,
    fadeInS: fadeInS ?? this.fadeInS,
    fadeOutS: fadeOutS ?? this.fadeOutS,
  );

  Map<String, dynamic> toJson() => {
    'volume': volume,
    'mute': mute,
    'fade_in_s': fadeInS,
    'fade_out_s': fadeOutS,
  };
}

/// A timeline layer.
///
/// It is called a layer, not a track, because `Track` in this system is already
/// the song the user uploaded. The list order is the stacking order: the first
/// is the background, the last is on top.
class Layer {
  const Layer({
    this.kind = 'video',
    this.name = '',
    this.muted = false,
    this.hidden = false,
    this.locked = false,
    this.clips = const [],
  });

  factory Layer.fromJson(Map<String, dynamic> j) => Layer(
    kind: j['kind'] as String? ?? 'video',
    name: j['name'] as String? ?? '',
    muted: j['muted'] as bool? ?? false,
    hidden: j['hidden'] as bool? ?? false,
    locked: j['locked'] as bool? ?? false,
    clips: ((j['clips'] as List?) ?? [])
        .map((e) => TimelineClip.fromJson(e as Map<String, dynamic>))
        .toList(),
  );

  /// `video` or `audio`. A layer draws or plays — not both.
  final String kind;

  bool get isAudio => kind == 'audio';

  final String name;
  final bool muted;
  final bool hidden;

  /// Locked changes nothing in the video — it is the app that refuses edits.
  final bool locked;
  final List<TimelineClip> clips;

  double get durationS => clips.fold(0, (m, c) => c.untilS > m ? c.untilS : m);

  Layer copyWith({
    String? kind,
    String? name,
    bool? muted,
    bool? hidden,
    bool? locked,
    List<TimelineClip>? clips,
  }) => Layer(
    kind: kind ?? this.kind,
    name: name ?? this.name,
    muted: muted ?? this.muted,
    hidden: hidden ?? this.hidden,
    locked: locked ?? this.locked,
    clips: clips ?? this.clips,
  );

  Map<String, dynamic> toJson() => {
    'kind': kind,
    'name': name,
    'muted': muted,
    'hidden': hidden,
    'locked': locked,
    'clips': [for (final c in clips) c.toJson()],
  };
}

/// Clip colour adjustment.
///
/// The three that fix almost everything in a gameplay montage: dark footage,
/// washed-out footage, colourless footage.
class ClipColor {
  const ClipColor({
    this.brightness = 0,
    this.contrast = 1,
    this.saturation = 1,
  });

  factory ClipColor.fromJson(Map<String, dynamic> j) => ClipColor(
    brightness: (j['brightness'] as num?)?.toDouble() ?? 0,
    contrast: (j['contrast'] as num?)?.toDouble() ?? 1,
    saturation: (j['saturation'] as num?)?.toDouble() ?? 1,
  );

  final double brightness;
  final double contrast;
  final double saturation;

  bool get isNeutral => brightness == 0 && contrast == 1 && saturation == 1;

  ClipColor copyWith({
    double? brightness,
    double? contrast,
    double? saturation,
  }) => ClipColor(
    brightness: brightness ?? this.brightness,
    contrast: contrast ?? this.contrast,
    saturation: saturation ?? this.saturation,
  );

  Map<String, dynamic> toJson() => {
    'brightness': brightness,
    'contrast': contrast,
    'saturation': saturation,
  };
}

/// Clip fade in and fade out, in seconds.
///
/// These are transitions from and to the **background** — which in a layered
/// montage is black. The transition *between two clips* is something else
/// (see [ClipTransition]).
class ClipFade {
  const ClipFade({this.inS = 0, this.outS = 0});

  factory ClipFade.fromJson(Map<String, dynamic> j) => ClipFade(
    inS: (j['in_s'] as num?)?.toDouble() ?? 0,
    outS: (j['out_s'] as num?)?.toDouble() ?? 0,
  );

  final double inS;
  final double outS;

  bool get isNeutral => inS == 0 && outS == 0;

  ClipFade copyWith({double? inS, double? outS}) =>
      ClipFade(inS: inS ?? this.inS, outS: outS ?? this.outS);

  Map<String, dynamic> toJson() => {'in_s': inS, 'out_s': outS};
}

/// How a clip enters, at the cut with the previous clip on the same layer.
///
/// It belongs to the clip that **enters**, not to the cut: moving the clip
/// takes its entrance along, and a clip with nothing before it (the first one,
/// or one after a gap) still has an entrance — out of the background.
class ClipTransition {
  const ClipTransition({required this.kind, this.durationS = 0.5});

  factory ClipTransition.fromJson(Map<String, dynamic> j) => ClipTransition(
    kind: j['kind'] as String,
    durationS: (j['duration_s'] as num?)?.toDouble() ?? 0.5,
  );

  /// `dissolve`, `fade_black`, `fade_white` or `slide_*` — the server's names.
  /// What each one is for the screen lives in `TransitionType`.
  final String kind;
  final double durationS;

  static const minS = 0.1;
  static const maxS = 3.0;

  ClipTransition copyWith({String? kind, double? durationS}) => ClipTransition(
    kind: kind ?? this.kind,
    durationS: durationS ?? this.durationS,
  );

  /// Never longer than the clip: the server would refuse it, and trimming the
  /// clip must not leave the montage impossible to render.
  Map<String, dynamic> toJsonFor(double clipDuration) => {
    'kind': kind,
    'duration_s': durationS.clamp(minS, math.max(minS, clipDuration)),
  };

  @override
  bool operator ==(Object other) =>
      other is ClipTransition &&
      other.kind == kind &&
      other.durationS == durationS;

  @override
  int get hashCode => Object.hash(kind, durationS);
}

/// How the text appears.
///
/// It is called `ClipTextStyle` and not `TextStyle` because Flutter already has
/// a class with that name, and the two meet on every screen that draws text.
///
/// Size and outline are **fractions of the frame height**, not pixels: the
/// same montage has to come out the same in 720p and in 4K.
class ClipTextStyle {
  const ClipTextStyle({
    this.size = 0.08,
    this.color = 'white',
    this.outline = 0.12,
    this.outlineColor = 'black',
  });

  factory ClipTextStyle.fromJson(Map<String, dynamic> j) => ClipTextStyle(
    size: (j['size'] as num?)?.toDouble() ?? 0.08,
    color: j['color'] as String? ?? 'white',
    outline: (j['outline'] as num?)?.toDouble() ?? 0.12,
    outlineColor: j['outline_color'] as String? ?? 'black',
  );

  final double size;
  final String color;

  /// The outline is not decoration: without it, white text vanishes on bright scenes.
  final double outline;
  final String outlineColor;

  ClipTextStyle copyWith({
    double? size,
    String? color,
    double? outline,
    String? outlineColor,
  }) => ClipTextStyle(
    size: size ?? this.size,
    color: color ?? this.color,
    outline: outline ?? this.outline,
    outlineColor: outlineColor ?? this.outlineColor,
  );

  Map<String, dynamic> toJson() => {
    'size': size,
    'color': color,
    'outline': outline,
    'outline_color': outlineColor,
  };
}

/// A point of the zoom animation, inside the clip.
///
/// [t] goes from 0 to 1 — it is the fraction of the clip, not seconds. So the
/// animation survives stretching or trimming the block: a zoom that closes at
/// the end keeps closing at the end.
class ZoomKey {
  const ZoomKey({required this.t, this.scale = 1, this.x = 0, this.y = 0});

  factory ZoomKey.fromJson(Map<String, dynamic> j) => ZoomKey(
    t: (j['t'] as num).toDouble(),
    scale: (j['scale'] as num?)?.toDouble() ?? 1,
    x: (j['x'] as num?)?.toDouble() ?? 0,
    y: (j['y'] as num?)?.toDouble() ?? 0,
  );

  final double t;
  final double scale;
  final double x;
  final double y;

  Map<String, dynamic> toJson() => {'t': t, 'scale': scale, 'x': x, 'y': y};
}

/// An item of the match media library.
///
/// It started as "the job's song" and became the library — because it was the
/// same thing: a file goes up, a worker analyses it and the gateway serves it
/// with `Range`. A song is an item of kind `audio`, with beats on top.
class Media {
  Media({
    required this.id,
    required this.kind,
    required this.status,
    required this.name,
    required this.durationS,
    this.width = 0,
    this.height = 0,
    this.fps = 0,
    this.thumbUrl,
    this.proxyUrl,
    this.fileUrl,
    this.error,
    this.bpm = 0,
    this.beats = const [],
    this.peaks = const [],
    this.audioUrl = '',
  });

  factory Media.fromJson(Map<String, dynamic> j) => Media(
    id: j['id'] as String,
    kind: j['kind'] as String? ?? 'audio',
    status: j['status'] as String? ?? 'pending',
    name: j['name'] as String? ?? '',
    durationS: (j['duration_s'] as num?)?.toDouble() ?? 0,
    width: (j['width'] as num?)?.toInt() ?? 0,
    height: (j['height'] as num?)?.toInt() ?? 0,
    fps: (j['fps'] as num?)?.toDouble() ?? 0,
    thumbUrl: j['thumb_url'] == null
        ? null
        : absoluteUrl('$kApiBase${j['thumb_url']}'),
    proxyUrl: j['proxy_url'] == null
        ? null
        : absoluteUrl('$kApiBase${j['proxy_url']}'),
    fileUrl: j['file_url'] == null
        ? null
        : absoluteUrl('$kApiBase${j['file_url']}'),
    error: j['error'] as String?,
    bpm: (j['bpm'] as num?)?.toDouble() ?? 0,
    beats: ((j['beats'] as List?) ?? const [])
        .map((e) => (e as num).toDouble())
        .toList(),
    peaks: ((j['peaks'] as List?) ?? const [])
        .map((e) => (e as num).toDouble())
        .toList(),
    audioUrl: j['audio_url'] == null
        ? ''
        : absoluteUrl('$kApiBase${j['audio_url']}'),
  );

  final String id;

  /// `audio`, `video` or `image`.
  final String kind;
  final String status;
  final String name;
  final double durationS;
  final int width;
  final int height;
  final double fps;
  final String? thumbUrl;
  final String? proxyUrl;

  /// The uploaded file itself. An image has no proxy: this is what the
  /// monitor shows of it.
  final String? fileUrl;
  final String? error;

  /// Audio only: what the timeline needs to draw the song and snap cuts to
  /// the beat. It comes in the same library item — asking again through
  /// another route would be a wasted trip.
  final double bpm;
  final List<double> beats;
  final List<double> peaks;
  final String audioUrl;

  bool get isReady => status == 'ready';
  bool get isFailed => status == 'failed';
  bool get isPending => status == 'pending';
  bool get isAudio => kind == 'audio';
  bool get isImage => kind == 'image';

  /// The same song, seen as a track.
  ///
  /// `Track` and audio `Media` are the same database row; the app has both
  /// names because the timeline talks about music and the library about files.
  Track get asMusic => Track(
    id: id,
    status: status,
    name: name,
    durationS: durationS,
    bpm: bpm,
    beats: beats,
    peaks: peaks,
    audioUrl: audioUrl,
    error: error,
  );

  /// How long a clip of this item lasts by default.
  ///
  /// An image has no duration of its own — how long it stays on screen is the
  /// montage's choice —, and from a long video you use a piece, not all of it.
  double get suggestedDuration =>
      isImage ? 2.0 : (durationS > 0 ? math.min(durationS, 3.0) : 2.0);
}

/// A block on the timeline: a piece of the recording placed at a point of the video.
///
/// [startS] and [durationS] say *what* goes in (in the recording); [atS] says
/// *where* (in the output video). They are independent — the same moment can
/// appear twice, at different points of the song and with different durations.
class TimelineClip {
  const TimelineClip({
    required this.startS,
    required this.durationS,
    required this.atS,
    this.sourceT = 0,
    this.kind = '',
    this.id = '',
    this.source = 'recording',
    this.mediaId,
    this.transform = const ClipTransform(),
    this.audio = const ClipAudio(),
    this.color = const ClipColor(),
    this.fade = const ClipFade(),
    this.speed = 1,
    this.zoom = const [],
    this.freeze = false,
    this.reverse = false,
    this.text = '',
    this.textStyle = const ClipTextStyle(),
    this.transition,
  });

  /// Identity of the block **inside the editor**. It does not go to the server
  /// and means nothing there.
  ///
  /// It exists because an index is not an identity: deleting a block shifts
  /// all the following ones, and a multiple selection or an "undo" step would
  /// end up pointing at the neighbour. With an id, who is who does not depend
  /// on where it sits in the list.
  final String id;

  /// Instant of the moment that originated the block. It does not affect the
  /// cut: it is used for labels and to recompute the framing when the duration changes.
  final double sourceT;
  final double startS;
  final double durationS;
  final double atS;
  final String kind;

  /// Where the picture comes from: `recording`, `media` or `text`.
  final String source;

  /// Which library item, when [source] is `media`.
  final String? mediaId;
  final ClipTransform transform;
  final ClipAudio audio;
  final ClipColor color;
  final ClipFade fade;

  /// How much faster the clip runs. 2 = double, 0.5 = slow motion.
  ///
  /// It changes how much of the source it consumes, not how much it takes in
  /// the video — that is [durationS], which is what gets dragged on the timeline.
  final double speed;

  /// Zoom animation inside the clip. Empty = no animation.
  ///
  /// It is the *punch* on the beat. Zoom belongs to the content — looking
  /// closer at what is there — and is not to be confused with
  /// [ClipTransform.scale], which is the size of the clip inside the frame.
  final List<ZoomKey> zoom;

  /// Freezes instead of running. The duration is still the block's.
  final bool freeze;
  final bool reverse;

  /// What is written, when [source] is `text`.
  final String text;
  final ClipTextStyle textStyle;

  /// How it enters over the previous clip. `null` = a hard cut.
  final ClipTransition? transition;

  bool get isText => source == 'text';

  /// How much of the recording this clip eats. At 2×, two seconds of video eat
  /// four of recording — and a frozen one eats a single frame.
  double get sourceConsumedS => freeze ? 0.05 : durationS * speed;

  /// The clip comes in as it came, with no layer or adjustment — what the
  /// server's cut-and-concat path can assemble.
  bool get simple =>
      source == 'recording' &&
      transform.isNeutral &&
      audio.isNeutral &&
      color.isNeutral &&
      fade.isNeutral &&
      transition == null &&
      speed == 1 &&
      zoom.isEmpty &&
      !freeze &&
      !reverse;

  /// Where the cut ends in the recording.
  double get endS => startS + durationS;

  /// Where the block ends in the video.
  double get untilS => atS + durationS;

  TimelineClip copyWith({
    double? sourceT,
    double? startS,
    double? durationS,
    double? atS,
    String? kind,
    String? id,
    String? source,
    String? mediaId,
    ClipTransform? transform,
    ClipAudio? audio,
    ClipColor? color,
    ClipFade? fade,
    double? speed,
    List<ZoomKey>? zoom,
    bool? freeze,
    bool? reverse,
    String? text,
    ClipTextStyle? textStyle,
    ClipTransition? transition,
    bool clearTransition = false,
  }) => TimelineClip(
    sourceT: sourceT ?? this.sourceT,
    startS: startS ?? this.startS,
    durationS: durationS ?? this.durationS,
    atS: atS ?? this.atS,
    kind: kind ?? this.kind,
    id: id ?? this.id,
    source: source ?? this.source,
    mediaId: mediaId ?? this.mediaId,
    transform: transform ?? this.transform,
    audio: audio ?? this.audio,
    color: color ?? this.color,
    fade: fade ?? this.fade,
    speed: speed ?? this.speed,
    zoom: zoom ?? this.zoom,
    freeze: freeze ?? this.freeze,
    reverse: reverse ?? this.reverse,
    text: text ?? this.text,
    textStyle: textStyle ?? this.textStyle,
    transition: clearTransition ? null : transition ?? this.transition,
  );

  /// The `id` does not come from the server: it is assigned on load, by
  /// `montageFromDraft`.
  factory TimelineClip.fromJson(Map<String, dynamic> j) => TimelineClip(
    sourceT: (j['source_t'] as num?)?.toDouble() ?? 0,
    startS: (j['start_s'] as num).toDouble(),
    durationS: (j['duration_s'] as num).toDouble(),
    atS: (j['at_s'] as num).toDouble(),
    kind: j['kind'] as String? ?? '',
    source: j['source'] as String? ?? 'recording',
    mediaId: j['media_id'] as String?,
    transform: ClipTransform.fromJson(
      (j['transform'] as Map?)?.cast<String, dynamic>() ?? const {},
    ),
    audio: ClipAudio.fromJson(
      (j['audio'] as Map?)?.cast<String, dynamic>() ?? const {},
    ),
    color: ClipColor.fromJson(
      (j['color'] as Map?)?.cast<String, dynamic>() ?? const {},
    ),
    fade: ClipFade.fromJson(
      (j['fade'] as Map?)?.cast<String, dynamic>() ?? const {},
    ),
    speed: (j['speed'] as num?)?.toDouble() ?? 1,
    zoom: ((j['zoom'] as List?) ?? [])
        .map((e) => ZoomKey.fromJson(e as Map<String, dynamic>))
        .toList(),
    freeze: j['freeze'] as bool? ?? false,
    reverse: j['reverse'] as bool? ?? false,
    text: j['text'] as String? ?? '',
    textStyle: ClipTextStyle.fromJson(
      (j['text_style'] as Map?)?.cast<String, dynamic>() ?? const {},
    ),
    transition: j['transition'] == null
        ? null
        : ClipTransition.fromJson(
            (j['transition'] as Map).cast<String, dynamic>(),
          ),
  );

  Map<String, dynamic> toJson() => {
    'source_t': sourceT,
    'start_s': startS,
    'duration_s': durationS,
    'at_s': atS,
    'kind': kind,
    'source': source,
    if (mediaId != null) 'media_id': mediaId,
    if (!transform.isNeutral) 'transform': transform.toJson(),
    if (!audio.isNeutral) 'audio': audio.toJson(),
    if (!color.isNeutral) 'color': color.toJson(),
    if (!fade.isNeutral) 'fade': fade.toJson(),
    if (speed != 1) 'speed': speed,
    if (zoom.isNotEmpty) 'zoom': [for (final k in zoom) k.toJson()],
    if (freeze) 'freeze': true,
    if (reverse) 'reverse': true,
    if (isText) 'text': text,
    if (isText) 'text_style': textStyle.toJson(),
    if (transition != null) 'transition': transition!.toJsonFor(durationS),
  };
}

/// How the final video is written.
///
/// Kept apart from the montage on purpose: the same montage becomes a 16:9 for
/// YouTube and a 9:16 for Shorts without any of it changing. What changes is
/// the window you look through.
class ExportSpec {
  const ExportSpec({
    this.width = 0,
    this.height = 0,
    this.fps = 0,
    this.crf = 20,
    this.fit = 'cover',
    this.fromS = 0,
    this.toS,
    this.watermarkId,
    this.watermarkScale = 0.12,
    this.watermarkX = 0.82,
    this.watermarkY = -0.82,
    this.watermarkOpacity = 0.65,
  });

  factory ExportSpec.fromJson(Map<String, dynamic> j) => ExportSpec(
    width: (j['width'] as num?)?.toInt() ?? 0,
    height: (j['height'] as num?)?.toInt() ?? 0,
    fps: (j['fps'] as num?)?.toDouble() ?? 0,
    crf: (j['crf'] as num?)?.toInt() ?? 20,
    fit: j['fit'] as String? ?? 'cover',
    fromS: (j['from_s'] as num?)?.toDouble() ?? 0,
    toS: (j['to_s'] as num?)?.toDouble(),
    watermarkId: j['watermark_id'] as String?,
    watermarkScale: (j['watermark_scale'] as num?)?.toDouble() ?? 0.12,
    watermarkX: (j['watermark_x'] as num?)?.toDouble() ?? 0.82,
    watermarkY: (j['watermark_y'] as num?)?.toDouble() ?? -0.82,
    watermarkOpacity: (j['watermark_opacity'] as num?)?.toDouble() ?? 0.65,
  );

  /// `0` on both = the recording size.
  final int width;
  final int height;
  final double fps;

  /// H.264 quality: lower is better.
  final int crf;

  /// `cover` fills and crops the excess; `contain` shows everything with bars.
  final String fit;

  final double fromS;
  final double? toS;

  /// Library item drawn on top of everything.
  final String? watermarkId;

  /// Watermark size as a fraction of the width, and the corner where it sits,
  /// measured from the centre: `(1, -1)` is the top right corner.
  final double watermarkScale;
  final double watermarkX;
  final double watermarkY;
  final double watermarkOpacity;

  bool get standard =>
      width == 0 &&
      fps == 0 &&
      crf == 20 &&
      fit == 'cover' &&
      fromS == 0 &&
      toS == null &&
      watermarkId == null;

  ExportSpec copyWith({
    int? width,
    int? height,
    double? fps,
    int? crf,
    String? fit,
    double? fromS,
    double? toS,
    bool clearTo = false,
    String? watermarkId,
    bool clearWatermark = false,
    double? watermarkScale,
    double? watermarkX,
    double? watermarkY,
    double? watermarkOpacity,
  }) => ExportSpec(
    width: width ?? this.width,
    height: height ?? this.height,
    fps: fps ?? this.fps,
    crf: crf ?? this.crf,
    fit: fit ?? this.fit,
    fromS: fromS ?? this.fromS,
    toS: clearTo ? null : (toS ?? this.toS),
    watermarkId: clearWatermark ? null : (watermarkId ?? this.watermarkId),
    watermarkScale: watermarkScale ?? this.watermarkScale,
    watermarkX: watermarkX ?? this.watermarkX,
    watermarkY: watermarkY ?? this.watermarkY,
    watermarkOpacity: watermarkOpacity ?? this.watermarkOpacity,
  );

  Map<String, dynamic> toJson() => {
    'width': width,
    'height': height,
    'fps': fps,
    'crf': crf,
    'fit': fit,
    'from_s': fromS,
    if (toS != null) 'to_s': toS,
    if (watermarkId != null) 'watermark_id': watermarkId,
    'watermark_scale': watermarkScale,
    'watermark_x': watermarkX,
    'watermark_y': watermarkY,
    'watermark_opacity': watermarkOpacity,
  };
}

/// A hand-made video: the layers and blocks that form it.
class Montage {
  const Montage({
    this.title = '',
    this.trackId,
    this.musicStartS = 0,
    this.layers = const [],
    this.beatOffsetS = 0,
    this.beatMultiplier = 1,
    this.beatBar = 1,
    this.musicVolume = 1,
    this.gameVolume = 0,
    this.export = const ExportSpec(),
  });

  final String title;

  /// **Old format**: the continuous track that played under everything and
  /// could not be cut. It is still read — it becomes a block on the sound
  /// layer on open —, and never written again.
  final String? trackId;

  /// At which point of the song the continuous track started.
  final double musicStartS;

  /// The layers, from bottom to top.
  final List<Layer> layers;

  /// All the clips, from every layer. For whoever only wants to know what the
  /// video shows — the monitor, the duration, the summary.
  List<TimelineClip> get clips => [for (final l in layers) ...l.clips];

  /// Corrections to the beat grid. They do not change the video — the cut
  /// stores absolute instants —, but they change where the magnet snaps, so
  /// they are worth remembering between sessions.
  final double beatOffsetS;
  final double beatMultiplier;
  final int beatBar;

  /// Music and game sound volume. With [gameVolume] at 0 the music replaces
  /// the audio; above that the two mix. With no music block at all, the cuts'
  /// audio stands on its own.
  final double musicVolume;
  final double gameVolume;

  /// How the final video is written. It does not change the montage — it changes the window.
  final ExportSpec export;

  /// Rebuilds the montage saved on the server.
  ///
  /// It is what keeps an F5 in the middle of work from costing the whole
  /// montage. It reads both formats.
  ///
  /// A draft saved before layers existed arrives with `cuts`, and becomes a
  /// single layer — the same conversion the server does when reading it.
  factory Montage.fromJson(Map<String, dynamic> j) {
    final layerList = (j['layers'] as List?) ?? const [];
    final olds = (j['cuts'] as List?) ?? const [];
    return Montage(
      title: j['title'] as String? ?? '',
      trackId: j['track_id'] as String?,
      musicStartS: (j['music_start_s'] as num?)?.toDouble() ?? 0,
      layers: layerList.isNotEmpty
          ? layerList
                .map((e) => Layer.fromJson(e as Map<String, dynamic>))
                .toList()
          : [
              if (olds.isNotEmpty)
                Layer(
                  clips: olds
                      .map(
                        (e) => TimelineClip.fromJson(e as Map<String, dynamic>),
                      )
                      .toList(),
                ),
            ],
      beatOffsetS: (j['beat_offset_s'] as num?)?.toDouble() ?? 0,
      beatMultiplier: (j['beat_multiplier'] as num?)?.toDouble() ?? 1,
      beatBar: (j['beat_bar'] as num?)?.toInt() ?? 1,
      musicVolume: (j['music_volume'] as num?)?.toDouble() ?? 1,
      gameVolume: (j['game_volume'] as num?)?.toDouble() ?? 0,
      export: ExportSpec.fromJson(
        (j['export'] as Map?)?.cast<String, dynamic>() ?? const {},
      ),
    );
  }

  bool get isEmpty => clips.isEmpty;

  Map<String, dynamic> toJson() => {
    'title': title,
    // `track_id` and `music_start_s` are not sent: whoever had them already
    // turned them into a block on open, and sending them back would create a second song
    'layers': [for (final l in layers) l.toJson()],
    'beat_offset_s': beatOffsetS,
    'beat_multiplier': beatMultiplier,
    'beat_bar': beatBar,
    'music_volume': musicVolume,
    'game_volume': gameVolume,
    'export': export.toJson(),
  };
}

/// A named montage of a match.
///
/// Until Phase 8 there was only one, and you had to choose between the 30 s cut
/// for Shorts and the long montage. They are different jobs on the same
/// material, and now each has its own name.
class SavedMontage {
  const SavedMontage({
    required this.id,
    required this.name,
    required this.montage,
    required this.nClips,
    required this.durationS,
    required this.hasMusic,
    required this.nVersions,
    required this.updatedAt,
  });

  factory SavedMontage.fromJson(Map<String, dynamic> j) => SavedMontage(
    id: j['id'] as String,
    name: j['name'] as String? ?? '',
    montage: Montage.fromJson(
      (j['data'] as Map?)?.cast<String, dynamic>() ?? const {},
    ),
    nClips: (j['n_clips'] as num?)?.toInt() ?? 0,
    durationS: (j['duration_s'] as num?)?.toDouble() ?? 0,
    hasMusic: j['has_music'] as bool? ?? false,
    nVersions: (j['n_versions'] as num?)?.toInt() ?? 0,
    updatedAt: DateTime.parse(j['updated_at'] as String),
  );

  final String id;
  final String name;

  /// The content. Empty in responses that only carry the summary.
  final Montage montage;

  final int nClips;
  final double durationS;
  final bool hasMusic;
  final int nVersions;
  final DateTime updatedAt;

  bool get isEmpty => nClips == 0;
}

/// A snapshot of a montage, kept so you can go back to it.
///
/// It is not undo — that lives on the screen and dies with the tab. These are
/// milestones: "what I generated" and "it was good like this".
class MontageVersion {
  const MontageVersion({
    required this.id,
    required this.label,
    required this.nClips,
    required this.durationS,
    required this.createdAt,
  });

  factory MontageVersion.fromJson(Map<String, dynamic> j) => MontageVersion(
    id: j['id'] as String,
    label: j['label'] as String? ?? '',
    nClips: (j['n_clips'] as num?)?.toInt() ?? 0,
    durationS: (j['duration_s'] as num?)?.toDouble() ?? 0,
    createdAt: DateTime.parse(j['created_at'] as String),
  );

  final String id;
  final String label;
  final int nClips;
  final double durationS;
  final DateTime createdAt;
}

/// How to build a video from what happened in a match.
///
/// A preset does not store cuts — it stores the **way** of cutting. "Two
/// seconds per kill, snapped to the beat, with zoom" works for any match,
/// while a list of cuts only works for that one.
class Recipe {
  const Recipe({
    this.kinds = const ['kill', 'sleep', 'stun'],
    this.leadS = 1.0,
    this.durationS = 2.0,
    this.beatsPerCut = 0,
    this.gapS = 0,
    this.maxCuts = 0,
    this.zoom = false,
    this.fadeS = 0,
    this.speed = 1.0,
    this.counter = false,
    this.streaks = false,
    this.musicVolume = 1,
    this.gameVolume = 0,
    this.export = const ExportSpec(),
  });

  factory Recipe.fromJson(Map<String, dynamic> j) => Recipe(
    kinds: [
      for (final k in (j['kinds'] as List?) ?? const ['kill', 'sleep', 'stun'])
        k as String,
    ],
    leadS: (j['lead_s'] as num?)?.toDouble() ?? 1.0,
    durationS: (j['duration_s'] as num?)?.toDouble() ?? 2.0,
    beatsPerCut: (j['beats_per_cut'] as num?)?.toDouble() ?? 0,
    gapS: (j['gap_s'] as num?)?.toDouble() ?? 0,
    maxCuts: (j['max_cuts'] as num?)?.toInt() ?? 0,
    zoom: j['zoom'] as bool? ?? false,
    fadeS: (j['fade_s'] as num?)?.toDouble() ?? 0,
    speed: (j['speed'] as num?)?.toDouble() ?? 1.0,
    counter: j['counter'] as bool? ?? false,
    streaks: j['streaks'] as bool? ?? false,
    musicVolume: (j['music_volume'] as num?)?.toDouble() ?? 1,
    gameVolume: (j['game_volume'] as num?)?.toDouble() ?? 0,
    export: ExportSpec.fromJson(
      (j['export'] as Map?)?.cast<String, dynamic>() ?? const {},
    ),
  );

  /// Which events become cuts.
  final List<String> kinds;

  /// How long before the event the cut starts — the moment needs a run-up,
  /// otherwise the kill shows up on the first frame.
  final double leadS;

  /// Length of each cut. Ignored when [beatsPerCut] is in charge.
  final double durationS;

  /// With a track, each cut lasts N beats instead of [durationS].
  final double beatsPerCut;

  final double gapS;

  /// `0` = every moment there is.
  final int maxCuts;

  final bool zoom;
  final double fadeS;
  final double speed;

  /// Text the system writes on its own.
  final bool counter;
  final bool streaks;

  final double musicVolume;
  final double gameVolume;
  final ExportSpec export;

  Recipe copyWith({
    List<String>? kinds,
    double? leadS,
    double? durationS,
    double? beatsPerCut,
    double? gapS,
    int? maxCuts,
    bool? zoom,
    double? fadeS,
    double? speed,
    bool? counter,
    bool? streaks,
    double? musicVolume,
    double? gameVolume,
    ExportSpec? export,
  }) => Recipe(
    kinds: kinds ?? this.kinds,
    leadS: leadS ?? this.leadS,
    durationS: durationS ?? this.durationS,
    beatsPerCut: beatsPerCut ?? this.beatsPerCut,
    gapS: gapS ?? this.gapS,
    maxCuts: maxCuts ?? this.maxCuts,
    zoom: zoom ?? this.zoom,
    fadeS: fadeS ?? this.fadeS,
    speed: speed ?? this.speed,
    counter: counter ?? this.counter,
    streaks: streaks ?? this.streaks,
    musicVolume: musicVolume ?? this.musicVolume,
    gameVolume: gameVolume ?? this.gameVolume,
    export: export ?? this.export,
  );

  Map<String, dynamic> toJson() => {
    'kinds': kinds,
    'lead_s': leadS,
    'duration_s': durationS,
    'beats_per_cut': beatsPerCut,
    'gap_s': gapS,
    'max_cuts': maxCuts,
    'zoom': zoom,
    'fade_s': fadeS,
    'speed': speed,
    'counter': counter,
    'streaks': streaks,
    'music_volume': musicVolume,
    'game_volume': gameVolume,
    'export': export.toJson(),
  };
}

/// A saved preset: the recipe with a name.
class Preset {
  const Preset({required this.id, required this.name, required this.recipe});

  factory Preset.fromJson(Map<String, dynamic> j) => Preset(
    id: j['id'] as String,
    name: j['name'] as String? ?? '',
    recipe: Recipe.fromJson(
      (j['data'] as Map?)?.cast<String, dynamic>() ?? const {},
    ),
  );

  final String id;
  final String name;
  final Recipe recipe;
}

class DetectionEvent {
  DetectionEvent({
    required this.kind,
    required this.t,
    required this.confidence,
    this.meta = const {},
  });

  factory DetectionEvent.fromJson(Map<String, dynamic> j) => DetectionEvent(
    kind: j['kind'] as String,
    t: (j['t'] as num).toDouble(),
    confidence: (j['confidence'] as num?)?.toDouble() ?? 1.0,
    meta: (j['meta'] as Map?)?.cast<String, dynamic>() ?? const {},
  );

  final String kind;
  final double t;
  final double confidence;

  /// What the detector saw besides the instant. It varies by kind: an
  /// `ability_kill` carries `ability` (`"orisa/energy_javelin"`), an
  /// `ult_negated` carries whose ultimate it was and how long it took.
  final Map<String, dynamic> meta;

  /// The ability that killed, when the event is an ability one.
  ///
  /// It comes in the icon file format — `hero/ability` — because that is
  /// how the detector recognises it.
  String? get ability {
    final a = meta['ability'];
    return a is String && a.isNotEmpty ? a : null;
  }
}

class DetectorReport {
  DetectorReport({
    required this.detector,
    required this.ok,
    required this.nEvents,
    this.error,
  });

  factory DetectorReport.fromJson(Map<String, dynamic> j) => DetectorReport(
    detector: j['detector'] as String,
    ok: j['ok'] as bool? ?? true,
    nEvents: j['n_events'] as int? ?? 0,
    error: j['error'] as String?,
  );

  final String detector;
  final bool ok;
  final int nEvents;
  final String? error;
}

class Clip {
  Clip({
    required this.id,
    required this.kind,
    required this.title,
    required this.startS,
    required this.endS,
    required this.score,
    this.renderId,
    this.videoUrl,
    this.thumbUrl,
    this.segmentsZipUrl,
    this.meta = const {},
  });

  factory Clip.fromJson(Map<String, dynamic> j) => Clip(
    id: j['id'] as String,
    kind: j['kind'] as String,
    title: j['title'] as String? ?? '',
    startS: (j['start_s'] as num).toDouble(),
    endS: (j['end_s'] as num).toDouble(),
    score: (j['score'] as num).toDouble(),
    renderId: j['render_id'] as String?,
    videoUrl: j['video_url'] == null
        ? null
        : absoluteUrl('$kApiBase${j['video_url']}'),
    thumbUrl: j['thumb_url'] == null
        ? null
        : absoluteUrl('$kApiBase${j['thumb_url']}'),
    segmentsZipUrl: j['segments_zip_url'] == null
        ? null
        : absoluteUrl('$kApiBase${j['segments_zip_url']}'),
    meta: (j['meta'] as Map?)?.cast<String, dynamic>() ?? const {},
  );

  final String id;
  final String kind;
  final String title;
  final double startS;
  final double endS;
  final double score;
  final String? renderId;

  /// Null when the montage failed: only the cuts were left.
  final String? videoUrl;
  final String? thumbUrl;

  /// Zip with the montage's individual cuts, when they exist.
  final String? segmentsZipUrl;
  final Map<String, dynamic> meta;

  double get durationS =>
      (meta['duration_s'] as num?)?.toDouble() ?? (endS - startS);

  bool get isBeatSynced => meta['beat_synced'] == true;
  int get segments => (meta['segments'] as int?) ?? 1;
  bool get isLooped => meta['looped'] == true;
  num? get bpm => meta['bpm'] as num?;
  String? get musicName => meta['music_name'] as String?;

  /// With no track chosen, the video kept the match sound.
  bool get keepsOriginalAudio => meta['original_audio'] == true;

  /// The montage failed but the cuts are available.
  bool get onlyCuts => videoUrl == null && segmentsZipUrl != null;
  String? get renderError => meta['render_error'] as String?;
}

/// A generation request: the montages sent to the server at once.
/// A match piles up as many requests as the user wants.
class Render {
  Render({
    required this.id,
    required this.status,
    required this.stage,
    required this.progress,
    required this.createdAt,
    this.error,
    this.clips = const [],
  });

  factory Render.fromJson(Map<String, dynamic> j) => Render(
    id: j['id'] as String,
    status: j['status'] as String,
    stage: j['stage'] as String? ?? '',
    progress: (j['progress'] as num?)?.toDouble() ?? 0,
    createdAt: DateTime.parse(j['created_at'] as String),
    error: j['error'] as String?,
    clips: ((j['clips'] as List?) ?? [])
        .map((e) => Clip.fromJson(e as Map<String, dynamic>))
        .toList(),
  );

  final String id;
  final String status;
  final String stage;
  final double progress;
  final DateTime createdAt;
  final String? error;
  final List<Clip> clips;

  /// Names of the songs used in this request, without repeats.
  ///
  /// They come from the **generated clips**, not from the request: a montage's
  /// track is a block on its timeline, and it is the editor that knows which
  /// one ended up playing. It used to come from the request's `selections`,
  /// when the song was chosen apart from the video — with that field removed,
  /// reading from there was always empty, and every video showed up in the
  /// list as if it had come out with the match audio.
  List<String> get musicNames => {
    for (final c in clips)
      if (c.meta['music_name'] case final String displayName) displayName,
  }.toList();

  bool get isActive => status == 'pending' || status == 'rendering';
  bool get isFailed => status == 'failed';
}

class Job {
  Job({
    required this.id,
    required this.status,
    required this.stage,
    required this.progress,
    required this.videoName,
    required this.durationS,
    required this.createdAt,
    required this.nClips,
    this.nMoments,
    this.fps = 0,
    this.width = 0,
    this.height = 0,
    this.videoUrl,
    this.proxyUrl,
    this.waveform = const [],
    this.nRenders = 0,
    this.zipUrl,
    this.hasCuts = false,
    this.hasActiveRender = false,
    this.error,
    this.events = const [],
    this.renders = const [],
    this.clips = const [],
    this.detectors = const [],
    this.tracks = const [],
    this.media = const [],
    this.draft,
    this.montages = const [],
  });

  factory Job.fromJson(Map<String, dynamic> j) => Job(
    id: j['id'] as String,
    status: j['status'] as String,
    stage: j['stage'] as String? ?? '',
    progress: (j['progress'] as num?)?.toDouble() ?? 0,
    videoName: j['video_name'] as String? ?? '',
    durationS: (j['duration_s'] as num?)?.toDouble() ?? 0,
    fps: (j['fps'] as num?)?.toDouble() ?? 0,
    width: (j['width'] as num?)?.toInt() ?? 0,
    height: (j['height'] as num?)?.toInt() ?? 0,
    createdAt: DateTime.parse(j['created_at'] as String),
    nClips: j['n_clips'] as int? ?? 0,
    nMoments: (j['n_moments'] as num?)?.toInt(),
    videoUrl: j['video_url'] == null
        ? null
        : absoluteUrl('$kApiBase${j['video_url']}'),
    proxyUrl: j['proxy_url'] == null
        ? null
        : absoluteUrl('$kApiBase${j['proxy_url']}'),
    waveform: ((j['waveform'] as List?) ?? [])
        .map((e) => (e as num).toDouble())
        .toList(),
    nRenders: j['n_renders'] as int? ?? 0,
    zipUrl: j['zip_url'] == null
        ? null
        : absoluteUrl('$kApiBase${j['zip_url']}'),
    hasCuts: j['has_cuts'] as bool? ?? false,
    hasActiveRender: j['has_active_render'] as bool? ?? false,
    error: j['error'] as String?,
    events: ((j['events'] as List?) ?? [])
        .map((e) => DetectionEvent.fromJson(e as Map<String, dynamic>))
        .toList(),
    renders: ((j['renders'] as List?) ?? [])
        .map((e) => Render.fromJson(e as Map<String, dynamic>))
        .toList(),
    clips: ((j['clips'] as List?) ?? [])
        .map((e) => Clip.fromJson(e as Map<String, dynamic>))
        .toList(),
    detectors: ((j['detectors'] as List?) ?? [])
        .map((e) => DetectorReport.fromJson(e as Map<String, dynamic>))
        .toList(),
    tracks: ((j['tracks'] as List?) ?? [])
        .map((e) => Track.fromJson(e as Map<String, dynamic>))
        .toList(),
    media: ((j['media'] as List?) ?? [])
        .map((e) => Media.fromJson(e as Map<String, dynamic>))
        .toList(),
    montages: [
      for (final m in (j['montages'] as List?) ?? const [])
        SavedMontage.fromJson(m as Map<String, dynamic>),
    ],
    draft: (j['draft'] as Map?)?.isEmpty ?? true
        ? null
        : Montage.fromJson((j['draft'] as Map).cast<String, dynamic>()),
  );

  final String id;
  final String status;
  final String stage;
  final double progress;
  final String videoName;
  final double durationS;

  /// Recording frames per second. It is what gives meaning to a one-frame
  /// step in the editor — 33 ms in a 30 fps video, 16 ms in a 60 fps one.
  final double fps;

  /// Recording size. It is the export default — and what lets the editor
  /// tell whether the requested output crops the frame or adds bars.
  final int width;
  final int height;

  final DateTime createdAt;
  final int nClips;

  /// How many moments the analysis found. `null` until it ends.
  final int? nMoments;

  /// The original recording, served with `Range`. It is where the cuts come from.
  final String? videoUrl;

  /// The reduced copy of the recording. It is what the monitor opens: seeking
  /// inside the original file dozens of times per second once brought down
  /// the browser's video element.
  ///
  /// Null for matches analysed before the proxy existed — then the monitor
  /// falls back to the original recording, as it used to.
  final String? proxyUrl;

  /// Waveform of the match audio: it is where you see the shot and the
  /// explosion, to match the cut with the game sound.
  final List<double> waveform;

  /// What the monitor should open.
  String? get monitorUrl => proxyUrl ?? videoUrl;
  final int nRenders;

  /// Package of the whole match: final videos and individual cuts.
  final String? zipUrl;
  final bool hasCuts;

  /// Some generation request still in progress. It comes from the API because
  /// the listing does not load the full requests.
  final bool hasActiveRender;
  final String? error;
  final List<DetectionEvent> events;
  final List<Render> renders;
  final List<Clip> clips;
  final List<DetectorReport> detectors;

  /// Songs already uploaded for this match, ready to build on.
  ///
  /// They are the audio items of [media] — the list exists separately because
  /// it is the one the track picker uses.
  final List<Track> tracks;

  /// The whole library: music, clips and images the user brought.
  final List<Media> media;

  /// The montage in progress, if any. It is what the montage screen loads on
  /// open — reloading the page no longer costs all the work.
  final Montage? draft;

  /// The montages of this match. A match yields more than one video: the
  /// vertical cut for Shorts and the long montage are different jobs on the
  /// same material.
  final List<SavedMontage> montages;

  /// The analysis is still running.
  bool get isAnalyzing => status != 'ready' && status != 'failed';

  /// The analysis finished: you can choose what to generate.
  bool get isReady => status == 'ready';
  bool get isFailed => status == 'failed';

  /// Worth polling the server again.
  bool get isActive =>
      isAnalyzing || hasActiveRender || renders.any((r) => r.isActive);

  /// How much is left until the analysis finishes, or null when it cannot be
  /// said honestly.
  ///
  /// The maths is the simplest there is — what has progressed, at the speed it
  /// progressed — and it only holds because the server bar became
  /// proportional to the *time* of each stage, not to the number of stages.
  /// While the cropping, which is three quarters of the work, took a tenth of
  /// the bar, any estimate from here would be off by minutes.
  ///
  /// Null below 3%: with little progress, the estimate's error is bigger than it.
  Duration? get remaining {
    if (!isAnalyzing || progress < 0.03) return null;
    final elapsed = DateTime.now().toUtc().difference(createdAt.toUtc());
    if (elapsed <= Duration.zero) return null;
    final total = elapsed.inMilliseconds / progress;
    final missing = total - elapsed.inMilliseconds;
    if (missing <= 0 || missing > const Duration(hours: 3).inMilliseconds) {
      return null;
    }
    return Duration(milliseconds: missing.round());
  }
}

/// "~6 min", "~40 s" — coarse on purpose. A to-the-second estimate would claim
/// a precision it does not have, and would jump on every reload.
String? formatRemaining(Duration? d) {
  if (d == null) return null;
  final s = d.inSeconds;
  if (s < 45) return 'under 1 min';
  final min = (s / 60).round();
  if (min < 60) return '~$min min';
  final h = d.inHours;
  return '~${h}h${(d.inMinutes % 60).toString().padLeft(2, '0')}';
}

// ─────────────────────────────── client ──────────────────────────────────────

class ApiClient {
  ApiClient({this.baseUrl = kApiBase});

  final String baseUrl;

  Future<List<Job>> listJobs() async {
    final r = await http.get(Uri.parse('$baseUrl/api/jobs'));
    _check(r);
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    return (body['jobs'] as List)
        .map((e) => Job.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Job> getJob(String id) async {
    final r = await http.get(Uri.parse('$baseUrl/api/jobs/$id'));
    _check(r);
    return Job.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  Future<void> deleteJob(String id) async {
    final r = await http.delete(Uri.parse('$baseUrl/api/jobs/$id'));
    if (r.statusCode != 204) _check(r);
  }

  Future<Render> getRender(String id) async {
    final r = await http.get(Uri.parse('$baseUrl/api/renders/$id'));
    _check(r);
    return Render.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  Future<void> deleteRender(String id) async {
    final r = await http.delete(Uri.parse('$baseUrl/api/renders/$id'));
    if (r.statusCode != 204) _check(r);
  }

  /// Uploads the recording. `onProgress` gets 0..1 as the bytes go out — for
  /// a match video this matters: the file is usually hundreds of megabytes.
  ///
  /// The file is read as a stream, never whole in memory: a match recording
  /// would not fit in a phone's RAM.
  Future<String> createJob({
    required PlatformFile video,
    JobParams params = const JobParams(),
    void Function(double sent)? onProgress,
  }) async {
    final total = await video.length();
    final r = await uploadFile(
      url: Uri.parse('$baseUrl/api/jobs'),
      field: 'video',
      file: video,
      length: total,
      // the size goes along so the server can check what arrived: a truncated
      // upload does not look like any error on that side
      fields: {'params': jsonEncode(params.toJson()), 'size': '$total'},
      onProgress: onProgress,
    );
    _check(r);
    return (jsonDecode(r.body) as Map<String, dynamic>)['id'] as String;
  }

  /// Uploads a song for the match and has the system listen to it.
  ///
  /// Returns immediately, with the song still `pending` — the analysis
  /// (duration, BPM, beats and waveform) runs on the server. Use
  /// [waitForTrack] to wait for it.
  Future<Track> uploadTrack({
    required String jobId,
    required PlatformFile audio,
    void Function(double sent)? onProgress,
  }) async {
    final total = await audio.length();
    final r = await uploadFile(
      url: Uri.parse('$baseUrl/api/jobs/$jobId/tracks'),
      field: 'audio',
      file: audio,
      length: total,
      fields: {'size': '$total'},
      onProgress: onProgress,
    );
    _check(r);
    final id = (jsonDecode(r.body) as Map<String, dynamic>)['id'] as String;
    return getTrack(id);
  }

  /// Saves the montage in progress.
  ///
  /// Called by the editor on its own while editing, with slack between calls:
  /// what matters is not losing work, not recording every pixel.
  Future<void> saveDraft(String jobId, Montage draft) async {
    final r = await http.put(
      Uri.parse('$baseUrl/api/jobs/$jobId/draft'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode(draft.toJson()),
    );
    _check(r);
  }

  Future<void> deleteDraft(String jobId) async {
    final r = await http.delete(Uri.parse('$baseUrl/api/jobs/$jobId/draft'));
    if (r.statusCode != 204) _check(r);
  }

  // ── named montages ──────────────────────────────────────────────────────────

  Future<List<SavedMontage>> listMontages(String jobId) async {
    final r = await http.get(Uri.parse('$baseUrl/api/jobs/$jobId/montages'));
    _check(r);
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return [
      for (final m in (j['items'] as List))
        SavedMontage.fromJson(m as Map<String, dynamic>),
    ];
  }

  Future<SavedMontage> createMontage(
    String jobId, {
    String name = '',
    Montage? montage,
  }) async {
    final r = await http.post(
      Uri.parse('$baseUrl/api/jobs/$jobId/montages'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({
        if (name.isNotEmpty) 'name': name,
        if (montage != null) 'data': montage.toJson(),
      }),
    );
    _check(r);
    return SavedMontage.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// Saves the montage. Called by the editor on its own while editing, with
  /// slack between calls: what matters is not losing work, not recording
  /// every pixel of a drag.
  Future<void> saveMontage(
    String jobId,
    String montageId, {
    Montage? montage,
    String? name,
  }) async {
    final r = await http.put(
      Uri.parse('$baseUrl/api/jobs/$jobId/montages/$montageId'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({
        if (montage != null) 'data': montage.toJson(),
        'name': ?name,
      }),
    );
    _check(r);
  }

  Future<SavedMontage> duplicateMontage(String jobId, String montageId) async {
    final r = await http.post(
      Uri.parse('$baseUrl/api/jobs/$jobId/montages/$montageId/duplicate'),
    );
    _check(r);
    return SavedMontage.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  Future<void> deleteMontage(String jobId, String montageId) async {
    final r = await http.delete(
      Uri.parse('$baseUrl/api/jobs/$jobId/montages/$montageId'),
    );
    if (r.statusCode != 204) _check(r);
  }

  // ── history ─────────────────────────────────────────────────────────────────

  Future<List<MontageVersion>> listVersions(
    String jobId,
    String montageId,
  ) async {
    final r = await http.get(
      Uri.parse('$baseUrl/api/jobs/$jobId/montages/$montageId/versions'),
    );
    _check(r);
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return [
      for (final v in (j['items'] as List))
        MontageVersion.fromJson(v as Map<String, dynamic>),
    ];
  }

  /// Marks the montage as it is.
  ///
  /// Returns `false` when there was nothing new to mark — the server refuses
  /// snapshots identical to the last one, and that is not an error: generating
  /// the same video twice in a row produced no version.
  Future<bool> createVersion(
    String jobId,
    String montageId, {
    String label = '',
  }) async {
    final r = await http.post(
      Uri.parse('$baseUrl/api/jobs/$jobId/montages/$montageId/versions'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({'label': label}),
    );
    if (r.statusCode == 409) return false;
    _check(r);
    return true;
  }

  Future<SavedMontage> restoreVersion(
    String jobId,
    String montageId,
    String versionId,
  ) async {
    final r = await http.post(
      Uri.parse(
        '$baseUrl/api/jobs/$jobId/montages/$montageId/versions/$versionId/restore',
      ),
    );
    _check(r);
    return SavedMontage.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  // ── presets ─────────────────────────────────────────────────────────────────

  Future<List<Preset>> listPresets() async {
    final r = await http.get(Uri.parse('$baseUrl/api/presets'));
    _check(r);
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return [
      for (final p in (j['items'] as List))
        Preset.fromJson(p as Map<String, dynamic>),
    ];
  }

  Future<Preset> createPreset(String name, Recipe recipe) async {
    final r = await http.post(
      Uri.parse('$baseUrl/api/presets'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({'name': name, 'data': recipe.toJson()}),
    );
    _check(r);
    return Preset.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  Future<void> deletePreset(String presetId) async {
    final r = await http.delete(Uri.parse('$baseUrl/api/presets/$presetId'));
    if (r.statusCode != 204) _check(r);
  }

  /// Brings a file into the match library.
  ///
  /// Returns immediately, still `pending`: the analysis (dimensions, thumbnail,
  /// proxy; beats for audio) runs on the server.
  Future<Media> uploadMedia({
    required String jobId,
    required PlatformFile file,
    void Function(double sent)? onProgress,
  }) async {
    final total = await file.length();
    final r = await uploadFile(
      url: Uri.parse('$baseUrl/api/jobs/$jobId/media'),
      field: 'file',
      file: file,
      length: total,
      fields: {'size': '$total'},
      onProgress: onProgress,
    );
    _check(r);
    final id = (jsonDecode(r.body) as Map<String, dynamic>)['id'] as String;
    return getMedia(id);
  }

  Future<Media> getMedia(String id) async {
    final r = await http.get(Uri.parse('$baseUrl/api/media/$id'));
    _check(r);
    return Media.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  Future<void> deleteMedia(String id) async {
    final r = await http.delete(Uri.parse('$baseUrl/api/media/$id'));
    if (r.statusCode != 204) _check(r);
  }

  /// Waits for the item to be ready, polling now and then.
  Future<Media> waitForMedia(
    String id, {
    Duration timeout = const Duration(minutes: 3),
    Duration every = const Duration(seconds: 1),
  }) async {
    final limit = DateTime.now().add(timeout);
    var item = await getMedia(id);
    while (item.isPending && DateTime.now().isBefore(limit)) {
      await Future<void>.delayed(every);
      item = await getMedia(id);
    }
    return item;
  }

  /// Asks for the missing thumbnails of this match to be extracted.
  ///
  /// New jobs already come out with them; this covers old ones and the ones
  /// that failed. The service skips what is already in place, so calling it
  /// needlessly is cheap.
  Future<void> requestFrames(String jobId) async {
    final r = await http.post(Uri.parse('$baseUrl/api/jobs/$jobId/frames'));
    if (r.statusCode != 202) _check(r);
  }

  Future<Track> getTrack(String id) async {
    final r = await http.get(Uri.parse('$baseUrl/api/tracks/$id'));
    _check(r);
    return Track.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  Future<void> deleteTrack(String id) async {
    final r = await http.delete(Uri.parse('$baseUrl/api/tracks/$id'));
    if (r.statusCode != 204) _check(r);
  }

  /// Waits for the song to be ready, polling now and then.
  ///
  /// A 3-minute song takes a few seconds to be listened to; the montage screen
  /// has nothing to draw before that. It gives up after [timeout] returning
  /// the song as it is — the caller decides what to tell the user.
  Future<Track> waitForTrack(
    String id, {
    Duration timeout = const Duration(minutes: 3),
    Duration every = const Duration(seconds: 1),
  }) async {
    final limit = DateTime.now().add(timeout);
    var track = await getTrack(id);
    while (track.isPending && DateTime.now().isBefore(limit)) {
      await Future<void>.delayed(every);
      track = await getTrack(id);
    }
    return track;
  }

  /// Requests the rendering of the montages.
  ///
  /// They already carry the positioned blocks and point to songs that **were
  /// already uploaded** through the library, so the request carries no file.
  ///
  /// There used to be a second path here: the chosen proposals, each with its
  /// song in a `music_<proposal_id>` field. There are no proposals anymore.
  Future<String> createRender({
    required String jobId,
    required List<Montage> montages,
  }) async {
    final r = await http.post(
      Uri.parse('$baseUrl/api/jobs/$jobId/renders'),
      headers: {'content-type': 'application/x-www-form-urlencoded'},
      body: {
        'timelines': jsonEncode([for (final m in montages) m.toJson()]),
      },
    );
    _check(r);
    return (jsonDecode(r.body) as Map<String, dynamic>)['id'] as String;
  }

  void _check(http.Response r) {
    if (r.statusCode >= 400) {
      String detail = r.body;
      try {
        final decoded = jsonDecode(r.body);
        if (decoded is Map && decoded['detail'] != null) {
          detail = decoded['detail'].toString();
        }
      } catch (_) {}
      throw ApiException(detail, r.statusCode);
    }
  }
}
