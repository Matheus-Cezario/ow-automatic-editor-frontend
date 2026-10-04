import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart';
import 'package:ow_editor/montage_state.dart';
import 'package:ow_editor/recipe.dart';

/// Templates: a preset that carries the montage's look, not only its cuts.
void main() {
  DetectionEvent ev(String kind, double t) =>
      DetectionEvent(kind: kind, t: t, confidence: 1);
  final match = [ev('kill', 30), ev('kill', 75), ev('kill', 120)];

  List<TimelineClip> cuts(MontageState s) => [
    for (final l in s.layers)
      if (!l.isAudio)
        for (final c in l.clips)
          if (!c.isText) c,
  ]..sort((a, b) => a.atS.compareTo(b.atS));

  const label = ClipTextStyle(
    font: 'anton',
    color: 'yellow',
    animIn: TextAnim.pop,
  );
  const style = Recipe(
    kinds: ['kill'],
    durationS: 3,
    zoom: true,
    zoomSmooth: true,
    transition: 'dissolve',
    transitionS: 0.4,
    ramp: true,
    rampSlow: 0.3,
    duckPlays: true,
    duckLevel: 0.2,
    counter: true,
    labelStyle: label,
  );

  group('building from a template', () {
    final s = applyRecipe(style, eventList: match, sourceDurationS: 600);
    final cs = cuts(s);

    test('every cut but the first enters with the transition', () {
      expect(cs.first.transition, isNull);
      for (final c in cs.skip(1)) {
        expect(c.transition?.kind, 'dissolve');
        expect(c.transition?.durationS, 0.4);
      }
    });

    test('a smooth zoom eases', () {
      expect(cs.every((c) => c.zoom.first.ease == Ease.easeInOut), isTrue);
    });

    test('each cut ramps through its play, and the next starts after it', () {
      for (final c in cs) {
        expect(c.isRamped, isTrue);
        final play = c.localForSourceOffset(c.sourceT - c.startS);
        expect(c.speedAt(play), closeTo(0.3, 0.01));
      }
      for (var i = 1; i < cs.length; i++) {
        expect(cs[i].atS, greaterThanOrEqualTo(cs[i - 1].untilS - 1e-9));
      }
    });

    test('ducking and the labels\' look come along', () {
      expect((s.duckPlays, s.duckLevel), (true, 0.2));
      final labels = s.clips.where((c) => c.isText).toList();
      expect(labels, isNotEmpty);
      expect(labels.every((t) => t.textStyle.font == 'anton'), isTrue);
      expect(labels.every((t) => t.textStyle.animIn == TextAnim.pop), isTrue);
    });
  });

  test(
    'fitted to the beat, cuts keep their length; a ramp fits or stays out',
    () {
      final beats = [for (var i = 0; i < 40; i++) i * 0.5];
      final s = applyRecipe(
        style.copyWith(beatsPerCut: 4), // 2 s per cut
        eventList: match,
        sourceDurationS: 600,
        beatTimes: beats,
      );
      for (final c in cuts(s)) {
        expect(c.durationS, closeTo(2, 1e-9), reason: 'the grid rules');
      }
      // the copy kept the look: a ramp needs ~2.5 s around the play, so none
      // fits in 2 s, while the transition still goes on
      expect(cuts(s).any((c) => c.isRamped), isFalse);
      expect(cuts(s).last.transition?.kind, 'dissolve');
    },
  );

  test('the style alone goes on the cuts on screen, which stay', () {
    final handMade = MontageState(
      layers: [
        Layer(
          clips: [
            TimelineClip(id: 'a', atS: 0, durationS: 2, startS: 10),
            TimelineClip(
              id: 'b',
              atS: 5,
              durationS: 4,
              startS: 40,
              sourceT: 42,
            ),
          ],
        ),
        Layer(
          clips: [
            TimelineClip(
              id: 't',
              atS: 0,
              durationS: 2,
              startS: 0,
              source: 'text',
              text: 'ACE',
            ),
          ],
        ),
      ],
    );
    final s = applyStyle(handMade, style);
    final a = s.clipItem('a')!, b = s.clipItem('b')!;
    expect((a.atS, a.startS, b.atS, b.startS), (0.0, 10.0, 5.0, 40.0));
    expect(a.transition, isNull);
    expect(b.transition?.kind, 'dissolve');
    expect(b.isRamped, isTrue, reason: 'b has a play and room');
    expect(a.isRamped, isFalse, reason: 'a has no play');
    expect(s.clipItem('t')!.textStyle.font, 'anton');
    expect(s.duckPlays, isTrue);
  });

  test('saving reads the look back from the montage', () {
    final s = applyRecipe(style, eventList: match, sourceDurationS: 600);
    final r = recipeFromMontage(s);
    expect((r.transition, r.transitionS), ('dissolve', 0.4));
    expect((r.zoom, r.zoomSmooth, r.ramp), (true, true, true));
    expect(r.rampSlow, closeTo(0.3, 1e-9));
    expect((r.duckPlays, r.duckLevel), (true, 0.2));
    expect(r.labelStyle?.font, 'anton');
  });

  test('the template goes to the server and comes back', () {
    final back = Recipe.fromJson(style.toJson());
    expect(
      (back.transition, back.ramp, back.duckPlays, back.zoomSmooth),
      ('dissolve', true, true, true),
    );
    expect(back.labelStyle?.animIn, TextAnim.pop);
    // an old preset has none of it
    final old = Recipe.fromJson(const {
      'kinds': ['kill'],
    });
    expect((old.transition, old.ramp, old.labelStyle), ('', false, null));
  });
}
