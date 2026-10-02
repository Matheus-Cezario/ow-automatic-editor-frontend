import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart';
import 'package:ow_editor/montage_state.dart';
import 'package:ow_editor/recipe.dart';

/// A preset does not store cuts — it stores the **way** of cutting. It is what
/// makes the second match cost one click instead of half an hour of fitting.
void main() {
  DetectionEvent ev(String kind, double t) =>
      DetectionEvent(kind: kind, t: t, confidence: 1);

  final match = [
    ev('kill', 30),
    ev('sleep', 50),
    ev('kill', 75),
    ev('low_hp', 90),
    ev('kill', 120),
  ];

  group('applying', () {
    test('only the events the recipe asks for become cuts', () {
      final s = applyRecipe(
        const Recipe(kinds: ['kill']),
        eventList: match,
        sourceDurationS: 600,
      );

      expect(s.clips, hasLength(3));
      expect(s.clips.every((c) => c.kind == 'kill'), isTrue);
    });

    test('the cuts come out in a row, in the order they happened', () {
      final s = applyRecipe(
        const Recipe(kinds: ['kill'], durationS: 2),
        eventList: match,
        sourceDurationS: 600,
      );

      expect(s.clips.map((c) => c.atS), [0.0, 2.0, 4.0]);
      expect(s.clips.map((c) => c.sourceT), [30.0, 75.0, 120.0]);
    });

    test('the space between cuts becomes black screen with the music playing', () {
      final s = applyRecipe(
        const Recipe(kinds: ['kill'], durationS: 2, gapS: 0.5),
        eventList: match,
        sourceDurationS: 600,
      );

      expect(s.clips.map((c) => c.atS), [0.0, 2.5, 5.0]);
    });

    test('the cut starts before the moment: it needs a run-up', () {
      // without it the kill shows up on the first frame, before the
      // viewer understands what they are seeing
      final s = applyRecipe(
        const Recipe(kinds: ['kill'], leadS: 1.5),
        eventList: match,
        sourceDurationS: 600,
      );

      expect(s.clips.first.startS, 28.5);
      expect(s.clips.first.sourceT, 30.0);
    });

    test('a moment near the end of the recording does not ask for what does not exist', () {
      final s = applyRecipe(
        const Recipe(kinds: ['kill'], durationS: 4, leadS: 1),
        eventList: [ev('kill', 119)],
        sourceDurationS: 120,
      );

      expect(s.clips.single.startS, 116.0, reason: '120 - 4 de corte');
    });

    test('the cut limit is respected', () {
      final s = applyRecipe(
        const Recipe(kinds: ['kill'], maxCuts: 2),
        eventList: match,
        sourceDurationS: 600,
      );

      expect(s.clips, hasLength(2));
    });

    test('speed eats more recording per cut', () {
      final s = applyRecipe(
        const Recipe(kinds: ['kill'], durationS: 2, speed: 2, leadS: 0),
        eventList: [ev('kill', 3)],
        sourceDurationS: 4,
      );

      // 2s of video at 2x eat 4s of recording, and there are only 4s
      expect(s.clips.single.startS, 0.0);
      expect(s.clips.single.speed, 2.0);
    });
  });

  group('snapping to the beat', () {
    // a 0.5 s grid, like a 120 bpm song
    final grid = [for (var i = 0; i < 40; i++) i * 0.5];

    test('each cut goes from one beat to another', () {
      final s = applyRecipe(
        const Recipe(kinds: ['kill'], beatsPerCut: 2),
        eventList: match,
        sourceDurationS: 600,
        beatTimes: grid,
      );

      expect(s.clips.map((c) => c.atS), [0.0, 1.0, 2.0]);
      expect(s.clips.every((c) => c.durationS == 1.0), isTrue);
    });

    test('the grid rules, and the requested length is ignored', () {
      // that is the point of fitting to the rhythm: the bar decides, not the stopwatch
      final s = applyRecipe(
        const Recipe(kinds: ['kill'], beatsPerCut: 1, durationS: 7),
        eventList: match,
        sourceDurationS: 600,
        beatTimes: grid,
      );

      expect(s.clips.first.durationS, 0.5);
    });

    test('without beats, the rhythm recipe falls back to the fixed length', () {
      // choosing the preset before choosing the song must not end up in
      // no montage at all
      final s = applyRecipe(
        const Recipe(kinds: ['kill'], beatsPerCut: 2, durationS: 3),
        eventList: match,
        sourceDurationS: 600,
      );

      expect(s.clips, hasLength(3));
      expect(s.clips.first.durationS, 3.0);
    });

    test('a short song stops instead of overflowing the grid', () {
      final s = applyRecipe(
        const Recipe(kinds: ['kill'], beatsPerCut: 2),
        eventList: match,
        sourceDurationS: 600,
        beatTimes: const [0, 0.5, 1.0, 1.5],
      );

      expect(s.clips, hasLength(1), reason: 'only one two-beat cut fitted');
    });
  });

  group('effects and text', () {
    test('the zoom comes in as the usual punch', () {
      final s = applyRecipe(
        const Recipe(kinds: ['kill'], zoom: true),
        eventList: match,
        sourceDurationS: 600,
      );

      expect(s.clips.first.zoom, isNotEmpty);
      expect(s.clips.first.zoom.first.scale, 1.0);
    });

    test('the counter goes on its own layer, over the cuts', () {
      final s = applyRecipe(
        const Recipe(kinds: ['kill'], counter: true),
        eventList: match,
        sourceDurationS: 600,
      );

      expect(s.layers, hasLength(2));
      expect(s.layers[1].clips.map((c) => c.text), ['1', '2', '3']);
      expect(s.layers[0].clips.every((c) => !c.isText), isTrue);
    });

    test('without requested text, no layer is created for nothing', () {
      final s = applyRecipe(
        const Recipe(kinds: ['kill']),
        eventList: match,
        sourceDurationS: 600,
      );

      expect(s.layers, hasLength(1));
    });

    test('streak labels look at the cuts, not the events', () {
      // three kills far apart in the match end up back to back in the
      // montage — and what counts is what the viewer sees in a row
      final s = applyRecipe(
        const Recipe(kinds: ['kill'], durationS: 1, streaks: true),
        eventList: match,
        sourceDurationS: 600,
      );

      expect(s.layers[1].clips.map((c) => c.text), ['TRIPLE KILL']);
    });

    test('each clip comes out with its own id', () {
      final s = applyRecipe(
        const Recipe(kinds: ['kill'], counter: true),
        eventList: match,
        sourceDurationS: 600,
      );

      final ids = s.clips.map((c) => c.id).toSet();
      expect(ids, hasLength(s.clips.length));
      expect(ids.contains(''), isFalse);
    });
  });

  group('mix and output', () {
    test('the recipe brings the mix and the format along', () {
      final s = applyRecipe(
        const Recipe(
          kinds: ['kill'],
          musicVolume: 0.7,
          gameVolume: 0.3,
          export: ExportSpec(width: 1080, height: 1920),
        ),
        eventList: match,
        sourceDurationS: 600,
      );

      expect(s.musicVolume, 0.7);
      expect(s.gameVolume, 0.3);
      expect(s.export.width, 1080);
    });

    test('the music already on the timeline is not lost', () {
      // applying a preset swaps the cuts, not the music already placed
      final base = MontageState(
        layers: [
          const Layer(),
          Layer(
            kind: 'audio',
            clips: [
              TimelineClip(
                atS: 0,
                durationS: 30,
                startS: 12.5,
                source: 'media',
                mediaId: 't1',
              ),
            ],
          ),
        ],
        title: 'mine',
      );
      final s = applyRecipe(
        const Recipe(kinds: ['kill']),
        eventList: match,
        sourceDurationS: 600,
        base: base,
      );

      final sound = s.layers.firstWhere((l) => l.isAudio);
      expect(sound.clips.single.mediaId, 't1');
      expect(sound.clips.single.startS, 12.5);
      expect(s.title, 'mine');
    });
  });

  group('reading the recipe of a montage', () {
    MontageState withCuts(List<TimelineClip> c) =>
        MontageState(layers: [Layer(clips: c)]);

    TimelineClip cut({
      required double dur,
      double t = 30,
      double lead = 1,
      String kind = 'kill',
    }) => TimelineClip(
      atS: 0,
      durationS: dur,
      startS: t - lead,
      sourceT: t,
      kind: kind,
    );

    test('the length comes from the median, not the mean', () {
      // a block stretched to the end of the song would pull the mean far from
      // what all the others are
      final r = recipeFromMontage(
        withCuts([
          cut(dur: 2),
          cut(dur: 2),
          cut(dur: 2),
          cut(dur: 60),
        ]),
      );

      expect(r.durationS, 2.0);
    });

    test('the run-up is read from where the cut starts relative to the moment', () {
      final r = recipeFromMontage(
        withCuts([cut(dur: 2, t: 30, lead: 1.5)]),
      );

      expect(r.leadS, 1.5);
    });

    test('moment kinds come from the cuts that are there', () {
      final r = recipeFromMontage(
        withCuts([
          cut(dur: 2, kind: 'kill'),
          cut(dur: 2, kind: 'sleep'),
          cut(dur: 2, kind: 'kill'),
        ]),
      );

      expect(r.kinds, ['kill', 'sleep']);
    });

    test('the zoom is read if any cut has it', () {
      final withoutZoom = recipeFromMontage(withCuts([cut(dur: 2)]));
      expect(withoutZoom.zoom, isFalse);

      final withZoom = recipeFromMontage(
        withCuts([cut(dur: 2), cut(dur: 2).copyWith(zoom: punch())]),
      );
      expect(withZoom.zoom, isTrue);
    });

    test('an empty montage still gives a usable recipe', () {
      final r = recipeFromMontage(
        MontageState(
          layers: const [],
          musicVolume: 0.5,
          export: const ExportSpec(width: 720, height: 1280),
        ),
      );

      expect(r.durationS, greaterThan(0));
      expect(r.musicVolume, 0.5);
      expect(r.export.width, 720);
    });

    test('round trip: the read recipe rebuilds the same kind of montage', () {
      final original = applyRecipe(
        const Recipe(kinds: ['kill'], durationS: 1.8, leadS: 1.2, zoom: true),
        eventList: match,
        sourceDurationS: 600,
      );

      final read = recipeFromMontage(original);
      final redone = applyRecipe(
        read,
        eventList: match,
        sourceDurationS: 600,
      );

      expect(redone.clips.map((c) => c.durationS), [1.8, 1.8, 1.8]);
      expect(redone.clips.map((c) => c.startS), original.clips.map((c) => c.startS));
      expect(redone.clips.first.zoom, isNotEmpty);
    });
  });

  test('the recipe travels through JSON whole', () {
    const r = Recipe(
      kinds: ['kill', 'sleep'],
      beatsPerCut: 2,
      zoom: true,
      counter: true,
      export: ExportSpec(width: 1080, height: 1920, crf: 26),
    );
    final back = Recipe.fromJson(r.toJson());

    expect(back.kinds, ['kill', 'sleep']);
    expect(back.beatsPerCut, 2.0);
    expect(back.zoom, isTrue);
    expect(back.counter, isTrue);
    expect(back.export.width, 1080);
    expect(back.export.crf, 26);
  });
}
