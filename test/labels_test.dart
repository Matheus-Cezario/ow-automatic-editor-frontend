import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart';
import 'package:ow_editor/labels.dart';

/// The text the system writes on its own, from what happened in the match.
///
/// It is what sets the editor apart, and it is not in ffmpeg: it is in the
/// editor knowing what happened in the video. For anyone else, the video is a
/// rectangle of pixels with no story.
void main() {
  TimelineClip kill(double at, {double dur = 1}) => TimelineClip(
    atS: at,
    durationS: dur,
    startS: 10,
    kind: 'kill',
    sourceT: 10,
  );

  TimelineClip other(double at) =>
      TimelineClip(atS: at, durationS: 1, startS: 10, kind: 'sleep');

  group('kill counter', () {
    test('goes up on every cut, and each number lasts until the next', () {
      final r = killCounter([kill(0), kill(2), kill(5)], endS: 8);

      expect(r.map((c) => c.text), ['1', '2', '3']);
      expect(r[0].atS, 0);
      expect(r[0].durationS, 2.0, reason: 'until the next kill');
      expect(r[1].durationS, 3.0);
      expect(r[2].durationS, 3.0, reason: 'the last one lasts until the end of the video');
    });

    test('only counts kills — sleep darts and stuns do not add up', () {
      final r = killCounter([kill(0), other(1), kill(3)], endS: 5);
      expect(r.map((c) => c.text), ['1', '2']);
    });

    test('without kills, there is nothing to count', () {
      expect(killCounter([other(0)]), isEmpty);
    });

    test('comes out as a plain text clip, which can be moved and edited', () {
      final r = killCounter([kill(0)], endS: 3).single;

      expect(r.source, 'text');
      expect(r.isText, isTrue);
      expect(r.toJson()['text'], '1');
      // the generator is a shortcut, not a new entity
      expect(r.toJson().containsKey('text_style'), isTrue);
    });

    test('the order of the cuts in the list does not matter', () {
      final r = killCounter([kill(5), kill(0), kill(2)], endS: 8);
      expect(r.map((c) => c.text), ['1', '2', '3']);
      expect(r.map((c) => c.atS), [0.0, 2.0, 5.0]);
    });
  });

  group('streak labels', () {
    test('uses the game names, not a count', () {
      // "3 KILLS" where "TRIPLE KILL" fits sounds like a spreadsheet
      expect(streakName(2), 'DOUBLE KILL');
      expect(streakName(3), 'TRIPLE KILL');
      expect(streakName(4), 'QUAD KILL');
      expect(streakName(7), 'TEAM KILL');
    });

    test('a single kill is not a streak', () {
      expect(streakName(1), isNull);
      expect(streakLabels([kill(0), kill(20)]), isEmpty);
    });

    test('groups what the viewer sees in a row', () {
      // three back to back, then a gap, then two
      final r = streakLabels([
        kill(0),
        kill(1.2),
        kill(2.4),
        kill(20),
        kill(21.2),
      ]);

      expect(r.map((c) => c.text), ['TRIPLE KILL', 'DOUBLE KILL']);
    });

    test('the label goes on the last kill of the streak', () {
      // that is where it closes, and where announcing it makes sense
      final r = streakLabels([kill(0), kill(1.2), kill(2.4)]).single;
      expect(r.atS, 2.4);
    });

    test('the gap is measured from the end of one cut to the start of the next', () {
      // two long back-to-back cuts are a streak; the gap between them is zero
      final together = streakLabels([kill(0, dur: 3), kill(3, dur: 3)]);
      expect(together, hasLength(1));

      final separate = streakLabels([kill(0, dur: 1), kill(10, dur: 1)]);
      expect(separate, isEmpty);
    });
  });

  group('standalone label', () {
    test('is born visible: with an outline and fading at the ends', () {
      final r = textClip('TEXT', atS: 3);

      expect(r.text, 'TEXT');
      expect(r.atS, 3);
      // without an outline, white text vanishes on bright scenes
      expect(r.textStyle.outline, greaterThan(0));
      expect(r.fade.isNeutral, isFalse);
      // and sits at the top, away from the crosshair
      expect(r.transform.y, lessThan(0));
    });
  });
}
