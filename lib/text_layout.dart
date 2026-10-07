/// How a text's lines break and sit — the same rules the server follows
/// (`owcore/textlayout.py` and `owcore/textfx.py`). Change one, change the
/// other.
library;

import 'package:flutter/painting.dart';

/// From one line's top to the next, in letter sizes.
const kTextLineHeight = 1.2;

/// Room between the text and the edge of its box, in letter sizes.
const kTextBoxPad = 0.3;

/// How far the shadow falls, down and right, in letter sizes, and how dark.
const kTextShadowOffset = 0.06;
const kTextShadowOpacity = 0.8;

/// How wide [text] comes out in [style].
double lineWidth(String text, TextStyle style) {
  if (text.isEmpty) return 0;
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();
  final w = painter.width;
  painter.dispose();
  return w;
}

/// The lines [text] is drawn in.
///
/// A typed line break always breaks. With [maxWidth], each typed line also
/// breaks between words wherever the next word would cross it — greedily, the
/// server's way, rather than Flutter's own wrapping, so both sides break with
/// the same rule. A word wider than the box stays whole on its own line.
List<String> breakTextLines(String text, TextStyle style, double? maxWidth) {
  final lines = <String>[];
  for (final paragraph
      in text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n')) {
    if (maxWidth == null || maxWidth <= 0) {
      lines.add(paragraph);
      continue;
    }
    var current = '';
    for (final word in paragraph.split(' ')) {
      final candidate = current.isEmpty ? word : '$current $word';
      if (current.isNotEmpty && lineWidth(candidate, style) > maxWidth) {
        lines.add(current);
        current = word;
      } else {
        current = candidate;
      }
    }
    lines.add(current);
  }
  return lines;
}
