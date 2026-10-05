/// What the monitor shows at one instant — computed, not rendered.
///
/// The server builds the video with an ffmpeg graph (`owcore/compose.py`):
/// every picture layer from the bottom up, each clip fitted to the frame,
/// zoomed, coloured, scaled, faded and placed. This file does the same maths
/// for a single instant and hands back a list of [FramePiece]s, so the monitor
/// can stack real `<video>` elements the way the server stacks its overlays.
///
/// Keeping it pure — no widgets, no players — is what lets it be tested
/// against the server's rules without a browser.
library;

import 'dart:math' as math;

import '../api.dart';
import '../montage.dart';

/// Where a piece's picture comes from.
enum PieceKind { video, image }

/// One picture on the monitor, bottom to top.
class FramePiece {
  const FramePiece({
    required this.clipId,
    required this.kind,
    required this.url,
    required this.sourceT,
    required this.rate,
    required this.seekEachFrame,
    required this.opacity,
    required this.zoom,
    required this.zoomLeft,
    required this.zoomTop,
    required this.scale,
    required this.offsetX,
    required this.offsetY,
    required this.brightness,
    required this.contrast,
    required this.saturation,
    required this.fit,
    this.crop = const ClipTransform(),
    this.fx = const ClipFx(),
    this.shakeX = 0,
    this.shakeY = 0,
    this.veil,
    this.veilOpacity = 0,
  });

  /// The clip it shows. Players are kept per clip, so a clip keeps its element
  /// from one frame to the next.
  final String clipId;
  final PieceKind kind;
  final String url;

  /// Where in the source file this instant falls, in seconds.
  final double sourceT;

  /// How fast the source runs while playing — the clip's speed.
  final double rate;

  /// A frozen or reversed clip cannot just play: the picture has to be placed
  /// frame by frame.
  final bool seekEachFrame;

  /// Clip opacity × fades × a dissolve coming in.
  final double opacity;

  /// The lens inside the clip: magnification and the window's top-left corner,
  /// as fractions of the frame (see `_zoom_chain` on the server).
  final double zoom;
  final double zoomLeft;
  final double zoomTop;

  /// The clip's own size on the frame, and its centre's offset from the
  /// frame's centre, in frame widths and heights (a slide included).
  final double scale;
  final double offsetX;
  final double offsetY;

  /// The server's `eq` filter.
  final double brightness;
  final double contrast;
  final double saturation;

  /// `cover` or `contain`.
  final String fit;

  /// The crop, rotation and mirroring — only those fields are read; the place,
  /// size and alpha above are already resolved for this instant.
  final ClipTransform crop;

  /// Look, blur and vignette are drawn from here; sharpen has no CSS
  /// equivalent and shows only in the exact preview and the render.
  final ClipFx fx;

  /// Where the shake has moved the picture this instant, in frame widths and
  /// heights — 0 when the clip does not shake.
  final double shakeX;
  final double shakeY;

  /// The picture is enlarged a little while it shakes, so the edges never
  /// show — the server's margin.
  double get shakeZoom => fx.shake > 0 || fx.impact > 0 ? 1 + 2 * kShakeMargin : 1;

  /// A dip's colour over the clip (`#000000` / `#ffffff`), if one is on.
  final String? veil;
  final double veilOpacity;

  bool get hasColor => brightness != 0 || contrast != 1 || saturation != 1;
}

/// The watermark, over everything.
class WatermarkPiece {
  const WatermarkPiece({
    required this.url,
    required this.widthFraction,
    required this.centreX,
    required this.centreY,
    required this.opacity,
  });

  final String url;
  final double widthFraction;

  /// The mark's centre, as a fraction of the frame from its top-left corner.
  final double centreX;
  final double centreY;
  final double opacity;
}

class Frame {
  const Frame(this.pieces, {this.watermark});

  final List<FramePiece> pieces;
  final WatermarkPiece? watermark;

  bool get isBlack => pieces.isEmpty;
}

/// Transitions where the clip before keeps running underneath the next one.
const _overlapping = {
  'dissolve',
  'slide_left',
  'slide_right',
  'slide_up',
  'slide_down',
};

/// Dips and the colour they go through.
const _dipColour = {'fade_black': '#000000', 'fade_white': '#ffffff'};

/// Where a sliding clip starts, in frames — it comes from the side opposite to
/// the movement.
const _slideFrom = {
  'slide_left': (1.0, 0.0),
  'slide_right': (-1.0, 0.0),
  'slide_up': (0.0, 1.0),
  'slide_down': (0.0, -1.0),
};

/// The frame at [t], in assembled-video seconds.
///
/// [matchUrl] is what a recording clip shows (the match proxy); [library]
/// resolves media clips. A clip whose source cannot be found is left out —
/// the server would refuse it, and showing the match instead would lie.
Frame frameAt(
  List<Layer> layers,
  double t, {
  required String? matchUrl,
  Map<String, Media> library = const {},
  ExportSpec export = const ExportSpec(),
}) {
  final pieces = <FramePiece>[];
  for (final layer in layers) {
    if (layer.hidden || layer.isAudio) continue;
    final clips = [
      for (final c in layer.clips)
        if (!c.isText) c,
    ]..sort((a, b) => a.atS.compareTo(b.atS));

    for (var i = 0; i < clips.length; i++) {
      final clip = clips[i];
      // How the next clip enters decides how this one leaves: under a dissolve
      // or a slide it keeps running for the transition's length; before a dip
      // it goes dark on its way out.
      final next = i + 1 < clips.length ? clips[i + 1] : null;
      var tail = 0.0;
      (String, double)? dipOut;
      final tr = next?.transition;
      if (next != null && tr != null && (next.atS - clip.untilS).abs() < 1e-3) {
        if (_overlapping.contains(tr.kind)) {
          tail = tr.durationS;
        } else if (_dipColour[tr.kind] case final colour?) {
          dipOut = (colour, tr.durationS / 2);
        }
      }
      final drawn = clip.durationS + tail;
      if (t < clip.atS - 1e-6 || t >= clip.atS + drawn - 1e-6) continue;

      final piece = _piece(
        clip,
        t - clip.atS,
        drawn,
        dipOut: dipOut,
        matchUrl: matchUrl,
        library: library,
        fit: export.fit,
      );
      if (piece != null) pieces.add(piece);
    }
  }

  WatermarkPiece? watermark;
  final markId = export.watermarkId;
  final mark = markId == null ? null : library[markId];
  final markUrl = mark?.fileUrl ?? mark?.thumbUrl;
  if (markUrl != null) {
    watermark = WatermarkPiece(
      url: markUrl,
      widthFraction: export.watermarkScale,
      centreX: 0.5 + export.watermarkX / 2,
      centreY: 0.5 + export.watermarkY / 2,
      opacity: export.watermarkOpacity,
    );
  }
  return Frame(pieces, watermark: watermark);
}

FramePiece? _piece(
  TimelineClip clip,
  double local,
  double drawn, {
  required (String, double)? dipOut,
  required String? matchUrl,
  required Map<String, Media> library,
  required String fit,
}) {
  // ── the source ──
  final PieceKind kind;
  final String? url;
  if (clip.source == 'media') {
    final item = library[clip.mediaId];
    if (item == null) return null;
    kind = item.isImage ? PieceKind.image : PieceKind.video;
    url = item.isImage
        ? (item.fileUrl ?? item.thumbUrl)
        : (item.proxyUrl ?? item.fileUrl);
  } else {
    kind = PieceKind.video;
    url = matchUrl;
  }
  if (url == null) return null;

  // the speed is applied before everything: the clip's own clock is video time
  final consumed = clip.sourceConsumedS;
  final double sourceT;
  if (clip.freeze) {
    sourceT = clip.startS;
  } else if (clip.reverse) {
    sourceT = math.max(
      clip.startS,
      clip.startS + consumed - local * clip.speed,
    );
  } else {
    // the integral of the speed: under a ramp the source runs unevenly
    sourceT = clip.startS + clip.sourceOffsetAt(local);
  }

  // ── alpha ──
  var opacity = valueAt(clip, KeyProp.opacity, local);
  final tr = clip.transition;
  if (tr != null && tr.kind == 'dissolve' && tr.durationS > 0) {
    opacity *= (local / tr.durationS).clamp(0.0, 1.0);
  }
  final fade = clip.fade;
  if (fade.inS > 0) opacity *= (local / fade.inS).clamp(0.0, 1.0);
  if (fade.outS > 0) {
    // on the drawn length, as the server does: a tail fades with the clip
    opacity *= ((drawn - local) / fade.outS).clamp(0.0, 1.0);
  }

  // ── a dip's colour ──
  String? veil;
  var veilOpacity = 0.0;
  if (tr != null && _dipColour[tr.kind] != null && tr.durationS > 0) {
    final half = tr.durationS / 2;
    if (local < half) {
      veil = _dipColour[tr.kind];
      veilOpacity = 1 - local / half;
    }
  }
  if (dipOut != null && dipOut.$2 > 0) {
    final start = drawn - dipOut.$2;
    if (local > start) {
      veil = dipOut.$1;
      veilOpacity = math.max(
        veilOpacity,
        ((local - start) / dipOut.$2).clamp(0.0, 1.0),
      );
    }
  }

  // ── the lens ── on the clip as placed: a dissolve's longer picture does
  // not stretch the zoom
  var zoom = 1.0, zx = 0.0, zy = 0.0;
  if (clip.zoom.isNotEmpty) {
    double along(double Function(ZoomKey) field) => curveAt([
      for (final k in clip.zoom) (k.t * clip.durationS, field(k), k.ease),
    ], local);
    zoom = math.max(1.0, along((k) => k.scale));
    zx = along((k) => k.x);
    zy = along((k) => k.y);
  }
  final window = 1 - 1 / zoom;

  // ── shake and the impact's flash, on the server's formulas ──
  final fx = clip.fx;
  var shakeX = 0.0, shakeY = 0.0;
  if (fx.shake > 0 || fx.impact > 0) {
    final hit = impactAt(clip);
    final burst = local >= hit
        ? fx.impact * math.exp(-kImpactDecay * (local - hit))
        : 0.0;
    final amount = math.min(1.0, fx.shake * 0.5 + burst);
    shakeX = kShakeMargin * amount *
        (0.6 * math.sin(local * 41.3) + 0.4 * math.sin(local * 23.1 + 1.7));
    shakeY = kShakeMargin * amount *
        (0.6 * math.sin(local * 37.9 + 0.6) + 0.4 * math.sin(local * 19.7 + 2.3));
  }
  if (fx.impact > 0) {
    // the flash brightens towards white: on the monitor, a white veil
    final flash = fx.impact *
        0.6 *
        math.max(0.0, 1 - (local - impactAt(clip)).abs() / kFlashS);
    if (flash > veilOpacity) {
      veil = '#ffffff';
      veilOpacity = flash;
    }
  }

  // ── the place ──
  var ox = valueAt(clip, KeyProp.x, local) / 2;
  var oy = valueAt(clip, KeyProp.y, local) / 2;
  final from = tr == null ? null : _slideFrom[tr.kind];
  if (from != null && tr!.durationS > 0) {
    final remaining = 1 - (local / tr.durationS).clamp(0.0, 1.0);
    ox += from.$1 * remaining;
    oy += from.$2 * remaining;
  }

  return FramePiece(
    clipId: clip.id,
    kind: kind,
    url: url,
    sourceT: sourceT,
    rate: clip.speedAt(local),
    seekEachFrame: clip.freeze || clip.reverse,
    opacity: opacity.clamp(0.0, 1.0),
    zoom: zoom,
    zoomLeft: window * (0.5 + zx / 2),
    zoomTop: window * (0.5 + zy / 2),
    scale: valueAt(clip, KeyProp.scale, local),
    offsetX: ox,
    offsetY: oy,
    brightness: clip.color.brightness,
    contrast: clip.color.contrast,
    saturation: clip.color.saturation,
    fit: fit,
    crop: clip.transform,
    fx: fx,
    shakeX: shakeX,
    shakeY: shakeY,
    veil: veilOpacity > 0 ? veil : null,
    veilOpacity: veilOpacity,
  );
}

/// The shake's margin on each side, as a fraction of the frame (the server's
/// `_shake_chain`), how fast an impact's burst dies away, and how long its
/// flash lasts each side of the play.
const kShakeMargin = 0.03;
const kImpactDecay = 7.0;
const kFlashS = 0.18;

/// Where a clip's impact hits, from its first frame: its play, or its start.
double impactAt(TimelineClip clip) {
  final play = momentInVideo(clip);
  return play == null ? 0 : play - clip.atS;
}

/// A look as CSS filters — close to the server's grade, not identical.
String? lookCss(Look look) => switch (look) {
  Look.none => null,
  Look.noir => 'grayscale(1) contrast(1.25) brightness(0.98)',
  Look.tealOrange => 'sepia(0.2) hue-rotate(-12deg) saturate(1.25) contrast(1.05)',
  Look.warm => 'sepia(0.25) saturate(1.1)',
  Look.cold => 'hue-rotate(12deg) saturate(0.9) brightness(1.02)',
  Look.vivid => 'saturate(1.45) contrast(1.12)',
  Look.faded => 'contrast(0.82) brightness(1.06) saturate(0.75)',
};

/// The frame's aspect ratio: the export size when one was asked for,
/// otherwise the recording's.
double frameAspect(ExportSpec export, {int width = 0, int height = 0}) {
  if (export.width > 0 && export.height > 0) {
    return export.width / export.height;
  }
  if (width > 0 && height > 0) return width / height;
  return 16 / 9;
}
