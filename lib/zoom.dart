/// The ruler's zoom: how many pixels one second of video is worth.
library;

import 'dart:math' as math;

/// From a whole long montage at a glance to frame-by-frame work.
const kMinPxPerSecond = 4.0;
const kMaxPxPerSecond = 400.0;

/// One step of the keyboard zoom (= and -).
const kZoomStep = 1.25;

double clampZoom(double px) =>
    px.clamp(kMinPxPerSecond, kMaxPxPerSecond).toDouble();

/// The zoom that fits [durationS] of video in [viewportPx], with a little
/// room after the end — to see where the next clip would go.
double fitZoom(double durationS, double viewportPx) {
  final seconds = math.max(durationS, 1.0) * 1.05;
  return clampZoom(viewportPx / seconds);
}

/// Where the ruler has to scroll so the instant [anchorS], which was
/// [anchorDx] pixels into the visible window, stays there at the new zoom.
double anchoredOffset(double anchorS, double anchorDx, double px) =>
    math.max(0.0, anchorS * px - anchorDx);

/// The zoom slider runs on a log scale: from 4 to 400 px/s a linear slider
/// spends nearly all its travel on the close-ups.
double zoomToSlider(double px) =>
    (math.log(px) - math.log(kMinPxPerSecond)) /
    (math.log(kMaxPxPerSecond) - math.log(kMinPxPerSecond));

double sliderToZoom(double v) => clampZoom(
  math.exp(
    math.log(kMinPxPerSecond) +
        v * (math.log(kMaxPxPerSecond) - math.log(kMinPxPerSecond)),
  ),
);
