/// A text's entrance and exit, at one instant — the same formulas the server
/// writes as `drawtext` expressions (`owcore/textfx.py`). Change one, change
/// the other.
library;

import 'dart:math' as math;

import 'api.dart';

/// How far a slide travels, in frame heights.
const kSlideDistance = 0.08;

/// The typewriter's pace, in characters a second, and its most steps.
const kTypeRate = 25.0;
const kTypeMaxSteps = 40;

/// What a text looks like [localS] seconds into its clip.
class TextMotion {
  const TextMotion({
    this.alpha = 1,
    this.size = 1,
    this.drop = 0,
    required this.text,
  });

  final double alpha;

  /// Factor on the letter size.
  final double size;

  /// Downward offset, in frame heights.
  final double drop;

  /// What shows — less than all of it while the typewriter types.
  final String text;
}

TextMotion textMotion(TimelineClip clip, double localS) {
  final style = clip.textStyle;
  final total = clip.durationS;
  final d = math.min(style.animS, total / 2);
  double clamp01(double v) => v.clamp(0.0, 1.0).toDouble();
  final pIn = clamp01(localS / d);
  final pOut = clamp01((total - localS) / d);
  double easeOut(double p) => p * (2 - p);

  var alpha = 1.0, size = 1.0, drop = 0.0;
  for (final (anim, p) in [(style.animIn, pIn), (style.animOut, pOut)]) {
    final e = easeOut(p);
    switch (anim) {
      case TextAnim.fade:
        alpha *= e;
      case TextAnim.pop:
        size *= 0.5 + 0.5 * e;
        alpha *= math.min(1, 3 * p);
      case TextAnim.slide:
        drop += kSlideDistance * (1 - e);
        alpha *= e;
      case TextAnim.none:
      case TextAnim.typewriter:
        break;
    }
  }

  var text = clip.text;
  if (style.animIn == TextAnim.typewriter && text.isNotEmpty) {
    final n = text.length;
    final typing = math.min(math.max(d, n / kTypeRate), total);
    final steps = math.min(n, kTypeMaxSteps);
    // the server's steps: step k shows ceil(n·k/steps) letters from
    // typing·(k−1)/steps on
    final k = math.min(steps, (localS / typing * steps).floor() + 1);
    text = text.substring(0, (n * k / steps).ceil());
  }
  return TextMotion(alpha: alpha, size: size, drop: drop, text: text);
}
