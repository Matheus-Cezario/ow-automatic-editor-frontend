import 'dart:math' as math;
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import 'frame.dart';

const _svgNs = 'http://www.w3.org/2000/svg';

/// The web monitor: one DOM element holding a `<video>` or `<img>` per piece.
///
/// Each clip keeps its own element while it is on screen and a little after,
/// so a cut does not reload anything and two clips of the same recording can
/// run at once under a dissolve. Everything the server does with filters is
/// done here with CSS: `object-fit` for the fit, `transform` for the zoom
/// window, the scale and the place, `opacity` for the alpha, and an SVG filter
/// for the `eq` colour.
///
/// The elements are muted: the montage's sound is the music player's.
class MonitorPicture extends StatefulWidget {
  const MonitorPicture({
    super.key,
    required this.frame,
    required this.playing,
    this.upcoming,
  });

  final Frame frame;
  final bool playing;

  /// The frame a moment ahead: its clips are loaded and parked on their first
  /// frame before the cut reaches them.
  final Frame? upcoming;

  @override
  State<MonitorPicture> createState() => _MonitorPictureState();
}

class _MonitorPictureState extends State<MonitorPicture> {
  static int _views = 0;

  final int _view = _views++;
  late final String _viewType = 'ow-monitor-$_view';
  final web.HTMLDivElement _root = web.HTMLDivElement();
  late final web.Element _defs;
  final Map<String, _Slot> _slots = {};
  web.HTMLImageElement? _mark;

  /// Clock for the least-recently-used eviction of parked elements.
  int _tick = 0;

  /// More elements than this and the oldest parked ones are dropped: each
  /// `<video>` holds a decoder.
  static const _maxSlots = 10;

  @override
  void initState() {
    super.initState();
    _root.style
      ..setProperty('position', 'relative')
      ..setProperty('width', '100%')
      ..setProperty('height', '100%')
      ..setProperty('overflow', 'hidden')
      ..setProperty('background', '#000')
      // the text and the badges are Flutter's, drawn over this: the pointer is
      // theirs
      ..setProperty('pointer-events', 'none');
    final svg = web.document.createElementNS(_svgNs, 'svg');
    svg.setAttribute('width', '0');
    svg.setAttribute('height', '0');
    svg.setAttribute('style', 'position:absolute');
    _defs = web.document.createElementNS(_svgNs, 'defs');
    svg.appendChild(_defs);
    _root.appendChild(svg);
    ui_web.platformViewRegistry.registerViewFactory(
      _viewType,
      (int _) => _root,
    );
    _apply();
  }

  @override
  void didUpdateWidget(MonitorPicture old) {
    super.didUpdateWidget(old);
    _apply();
  }

  @override
  void dispose() {
    for (final s in _slots.values) {
      s.dispose();
    }
    _slots.clear();
    super.dispose();
  }

  void _apply() {
    _tick++;
    final shown = <String>{};
    final pieces = widget.frame.pieces;
    for (var i = 0; i < pieces.length; i++) {
      final p = pieces[i];
      shown.add(p.clipId);
      final slot = _slotFor(p);
      slot.lastUsed = _tick;
      slot.show(p, z: i + 1, playing: widget.playing);
    }

    // what comes next waits, loaded and parked, out of sight
    for (final p in widget.upcoming?.pieces ?? const <FramePiece>[]) {
      if (shown.contains(p.clipId)) continue;
      final slot = _slotFor(p);
      slot.lastUsed = _tick;
      slot.park(p);
      shown.add(p.clipId);
    }

    for (final entry in _slots.entries) {
      if (!shown.contains(entry.key)) entry.value.hide();
    }
    _evict(shown);
    _applyWatermark(widget.frame.watermark);
  }

  _Slot _slotFor(FramePiece p) {
    final existing = _slots[p.clipId];
    if (existing != null && existing.kind == p.kind && !existing.broken) {
      return existing;
    }
    existing?.dispose();
    final slot = _Slot(
      p.kind,
      filterId: 'ow-f-$_view-${p.clipId}',
      defs: _defs,
    );
    _root.appendChild(slot.wrapper);
    _slots[p.clipId] = slot;
    return slot;
  }

  void _evict(Set<String> shown) {
    if (_slots.length <= _maxSlots) return;
    final parked = [
      for (final e in _slots.entries)
        if (!shown.contains(e.key)) e,
    ]..sort((a, b) => a.value.lastUsed.compareTo(b.value.lastUsed));
    for (final e in parked.take(_slots.length - _maxSlots)) {
      e.value.dispose();
      _slots.remove(e.key);
    }
  }

  void _applyWatermark(WatermarkPiece? w) {
    if (w == null) {
      _mark?.style.setProperty('display', 'none');
      return;
    }
    final mark = _mark ??= () {
      final img = web.HTMLImageElement();
      img.style
        ..setProperty('position', 'absolute')
        ..setProperty('transform', 'translate(-50%, -50%)')
        ..setProperty('z-index', '100000');
      _root.appendChild(img);
      return img;
    }();
    if (mark.getAttribute('src') != w.url) mark.src = w.url;
    mark.style
      ..setProperty('display', 'block')
      ..setProperty('left', '${w.centreX * 100}%')
      ..setProperty('top', '${w.centreY * 100}%')
      ..setProperty('width', '${w.widthFraction * 100}%')
      ..setProperty('opacity', '${w.opacity}');
  }

  @override
  Widget build(BuildContext context) => HtmlElementView(viewType: _viewType);
}

/// One clip's element: a frame-sized wrapper (place, scale, alpha) holding the
/// picture (fit, zoom window, colour) and a veil for dips.
class _Slot {
  _Slot(this.kind, {required this.filterId, required web.Element defs}) {
    wrapper.style
      ..setProperty('position', 'absolute')
      ..setProperty('inset', '0')
      ..setProperty('overflow', 'hidden')
      ..setProperty('transform-origin', '50% 50%')
      ..setProperty('display', 'none');

    if (kind == PieceKind.video) {
      final v = web.HTMLVideoElement()
        ..muted = true
        ..preload = 'auto'
        ..playsInline = true;
      v.addEventListener('seeked', ((web.Event _) => _settle()).toJS);
      v.addEventListener('loadedmetadata', ((web.Event _) => _settle()).toJS);
      v.addEventListener('error', ((web.Event _) => broken = true).toJS);
      _video = v;
      media = v;
    } else {
      media = web.HTMLImageElement();
    }
    media.style
      ..setProperty('position', 'absolute')
      ..setProperty('inset', '0')
      ..setProperty('width', '100%')
      ..setProperty('height', '100%')
      ..setProperty('transform-origin', '0 0');
    wrapper.appendChild(media);

    vignette.style
      ..setProperty('position', 'absolute')
      ..setProperty('inset', '0')
      ..setProperty('pointer-events', 'none')
      ..setProperty('display', 'none');
    wrapper.appendChild(vignette);

    veil.style
      ..setProperty('position', 'absolute')
      ..setProperty('inset', '0')
      ..setProperty('display', 'none');
    wrapper.appendChild(veil);

    _filter = web.document.createElementNS(_svgNs, 'filter');
    _filter.setAttribute('id', filterId);
    _filter.setAttribute('color-interpolation-filters', 'sRGB');
    final transfer = web.document.createElementNS(
      _svgNs,
      'feComponentTransfer',
    );
    for (final channel in ['feFuncR', 'feFuncG', 'feFuncB']) {
      final f = web.document.createElementNS(_svgNs, channel);
      f.setAttribute('type', 'linear');
      _channels.add(f);
      transfer.appendChild(f);
    }
    _saturate = web.document.createElementNS(_svgNs, 'feColorMatrix');
    _saturate.setAttribute('type', 'saturate');
    _filter.appendChild(transfer);
    _filter.appendChild(_saturate);

    // the chroma key, last as on the server, in a filter of its own
    _keyFilter = web.document.createElementNS(_svgNs, 'filter');
    _keyFilter.setAttribute('id', '$filterId-key');
    _keyFilter.setAttribute('color-interpolation-filters', 'sRGB');
    _keyMatrix = web.document.createElementNS(_svgNs, 'feColorMatrix');
    _keyMatrix.setAttribute('type', 'matrix');
    _keyFilter.appendChild(_keyMatrix);
    defs.appendChild(_keyFilter);
    defs.appendChild(_filter);
  }

  final PieceKind kind;
  final String filterId;
  final web.HTMLDivElement wrapper = web.HTMLDivElement();
  final web.HTMLDivElement veil = web.HTMLDivElement();
  final web.HTMLDivElement vignette = web.HTMLDivElement();
  late final web.HTMLElement media;
  web.HTMLVideoElement? _video;
  late final web.Element _filter;
  late final web.Element _saturate;
  late final web.Element _keyFilter;
  late final web.Element _keyMatrix;
  final List<web.Element> _channels = [];

  String? _url;
  int lastUsed = 0;

  /// The element failed to load or decode: the next frame builds a new one.
  bool broken = false;

  /// Where the picture should be while it is not simply playing, so a seek
  /// that lands late is followed by the one that is due now.
  double? _wanted;

  void _load(String url) {
    if (_url == url) return;
    _url = url;
    final v = _video;
    if (v != null) {
      v.src = url;
    } else {
      (media as web.HTMLImageElement).src = url;
    }
  }

  void show(FramePiece p, {required int z, required bool playing}) {
    _load(p.url);
    wrapper.style
      ..setProperty('display', 'block')
      ..setProperty('z-index', '$z')
      ..setProperty('opacity', '${p.opacity}')
      // as the server does it: crop, mirror, rotate, then size and place —
      // a CSS transform list applies right to left, and the clip-path is in
      // the element's own, untransformed box
      ..setProperty(
        'transform',
        'translate(${p.offsetX * 100}%, ${p.offsetY * 100}%) scale(${p.scale})'
            '${(p.crop.rotation + p.turn) % 360 != 0 ? ' rotate(${p.crop.rotation + p.turn}deg)' : ''}'
            '${p.crop.flipH || p.crop.flipV ? ' scale(${p.crop.flipH ? -1 : 1}, ${p.crop.flipV ? -1 : 1})' : ''}',
      )
      // the crop and a wipe both cover edges: the larger of the two wins
      ..setProperty('clip-path', _inset(p));
    // the shake moves an enlarged picture under the frame, around its centre;
    // the zoom window works inside that (its origin is the top-left corner)
    final shaking = p.shakeZoom != 1;
    final shake = shaking
        ? 'translate(${-p.shakeX * 100}%, ${-p.shakeY * 100}%) '
              'translate(50%, 50%) scale(${p.shakeZoom}) translate(-50%, -50%) '
        : '';
    final zoom = p.zoom == 1
        ? ''
        : 'translate(${-p.zoomLeft * p.zoom * 100}%, '
              '${-p.zoomTop * p.zoom * 100}%) scale(${p.zoom})';
    // the server's blur is up to a 12 px sigma on a 1080p frame
    final blurPx = p.fx.blur * 12 * wrapper.clientHeight / 1080;
    final filters = [
      if (p.hasColor) 'url(#$filterId)',
      ?lookCss(p.fx.look),
      if (blurPx > 0) 'blur(${blurPx.toStringAsFixed(2)}px)',
    ];
    final key = p.chroma == null ? null : chromaMatrix(p.chroma!);
    if (key != null) {
      _keyMatrix.setAttribute('values', key);
      filters.add('url(#$filterId-key)');
    }
    wrapper.style.setProperty('mix-blend-mode', p.blend.css);
    media.style
      // the blurred fill behind is the render's: here the whole frame shows
      ..setProperty('object-fit', p.fit == 'cover' ? 'cover' : 'contain')
      ..setProperty(
        'transform',
        shake.isEmpty && zoom.isEmpty ? 'none' : '$shake$zoom',
      )
      ..setProperty('filter', filters.isEmpty ? 'none' : filters.join(' '));
    if (p.fx.vignette > 0) {
      vignette.style
        ..setProperty('display', 'block')
        ..setProperty(
          'background',
          'radial-gradient(ellipse at center, transparent 45%, '
              'rgba(0,0,0,${(p.fx.vignette * 0.85).toStringAsFixed(3)}) 100%)',
        );
    } else {
      vignette.style.setProperty('display', 'none');
    }
    if (p.hasColor) {
      final intercept = 0.5 * (1 - p.contrast) + p.brightness;
      for (final f in _channels) {
        f.setAttribute('slope', '${p.contrast}');
        f.setAttribute('intercept', '$intercept');
      }
      _saturate.setAttribute('values', '${p.saturation}');
    }
    if (p.veil != null && p.veilOpacity > 0) {
      veil.style
        ..setProperty('display', 'block')
        ..setProperty('background', p.veil!)
        ..setProperty('opacity', '${p.veilOpacity}');
    } else {
      veil.style.setProperty('display', 'none');
    }
    _sync(p, playing: playing && !p.seekEachFrame);
  }

  static String _inset(FramePiece p) {
    final c = p.crop;
    final w = p.wipe;
    final top = math.max(c.cropTop, w.top);
    final right = math.max(c.cropRight, w.right);
    final bottom = math.max(c.cropBottom, w.bottom);
    final left = math.max(c.cropLeft, w.left);
    if (top == 0 && right == 0 && bottom == 0 && left == 0) return 'none';
    return 'inset(${top * 100}% ${right * 100}% ${bottom * 100}% ${left * 100}%)';
  }

  /// Loads the clip and puts it on the frame it will open with, out of sight.
  void park(FramePiece p) {
    _load(p.url);
    wrapper.style.setProperty('display', 'none');
    _sync(p, playing: false);
  }

  void hide() {
    wrapper.style.setProperty('display', 'none');
    final v = _video;
    if (v != null && !v.paused) v.pause();
  }

  void _sync(FramePiece p, {required bool playing}) {
    final v = _video;
    if (v == null) return;
    var target = p.sourceT;
    final length = v.duration;
    if (length.isFinite && length > 0) {
      target = target.clamp(0.0, length - 0.05);
    }
    _wanted = target;
    if (v.readyState < 1) return; // `loadedmetadata` will place it

    if (!playing) {
      if (!v.paused) v.pause();
      if (!v.seeking && (v.currentTime - target).abs() > 0.02) {
        v.currentTime = target;
      }
      return;
    }

    v.playbackRate = p.rate.clamp(0.0625, 16.0);
    final drift = (v.currentTime - target).abs();
    if (v.paused) {
      if (drift > 0.05 && !v.seeking) v.currentTime = target;
      v.play().toDart.ignore();
    } else if (drift > 0.3 && !v.seeking) {
      // the playhead's clock and the element's run apart; past this, the cut
      // would land visibly off
      v.currentTime = target;
    }
    _wanted = null;
  }

  /// After a seek or a load: if the picture is still not where it should be,
  /// one more seek to where it is wanted now.
  void _settle() {
    final v = _video;
    final wanted = _wanted;
    if (v == null || wanted == null || !v.paused) return;
    if ((v.currentTime - wanted).abs() > 0.02) v.currentTime = wanted;
  }

  void dispose() {
    final v = _video;
    if (v != null) {
      v.pause();
      // dropping the source is what frees the decoder; removing the element
      // alone keeps it until garbage collection
      v.removeAttribute('src');
      v.load();
    }
    wrapper.remove();
    _filter.remove();
  }
}
