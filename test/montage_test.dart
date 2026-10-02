import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart';
import 'package:ow_editor/montage.dart';

/// The maths of the manual montage.
///
/// What is checked here is the screen's promise: the block lands where the
/// user sent it, with the duration they asked for, and never on top of another.
void main() {
  TimelineClip cut(
    double at,
    double dur, {
    double t = 10,
    String kind = 'kill',
  }) => TimelineClip(
    atS: at,
    durationS: dur,
    startS: t - dur * kMomentAnchor,
    sourceT: t,
    kind: kind,
  );

  group('magnet', () {
    const beatTimes = [0.0, 0.5, 1.0, 1.5, 2.0];

    test('snaps to a nearby beat', () {
      expect(snapToBeat(0.53, beatTimes), 0.5);
      expect(snapToBeat(0.96, beatTimes), 1.0);
    });

    test('leaves alone what is far from any beat', () {
      // halfway between two beats the user really meant that point
      expect(snapToBeat(0.75, beatTimes), 0.75);
    });

    test('without beats it does nothing', () {
      expect(snapToBeat(1.234, const []), 1.234);
    });

    test('the edge that does not snap does not beat the one that did', () {
      // hidden effect of comparing both distances directly: the edge that did not
      // snap stays where the finger dropped it, distance zero, and always won — the
      // magnet vanished for every block whose duration was not a multiple of the bar
      final cutList = [cut(0, 1.2, t: 10)];
      final movedClip = move(cutList, 0, 1.55, beats: beatTimes, snap: true);

      expect(movedClip.atS, closeTo(1.5, 1e-9));
    });

    test('when both edges snap, the closer one wins', () {
      // a block with a round duration has both on the same beat; the tie-break only
      // shows up when they disagree
      final cutList = [cut(0, 1.0, t: 10)];
      final movedClip = move(cutList, 0, 0.94, beats: beatTimes, snap: true);

      expect(movedClip.atS, closeTo(1.0, 1e-9));
    });

    test('the beat interval comes from the median', () {
      // a beat missed at the start would stretch the mean and make every
      // suggested block be born with the wrong length
      expect(beatIntervalS(const [0.0, 3.0, 3.5, 4.0, 4.5]), 0.5);
    });
  });

  group('the play inside the block', () {
    test('the instant of the play in video time', () {
      // the cut starts before it, for the run-up: the maths is where the block
      // enters plus how much recording was consumed up to the play
      final c = cut(3, 2, t: 90); // starts at 90 - 2*0.7 = 88.6
      expect(momentInVideo(c), closeTo(3 + 1.4, 1e-9));
    });

    test('without a play inside the block, there is nothing to align', () {
      // trimming until the play is gone is allowed; marking what is not there is not
      final c = cut(0, 2, t: 90).copyWith(startS: 200);
      expect(momentInVideo(c), isNull);
      // and a block that did not come from any moment has no mark either
      const media = TimelineClip(
        atS: 0,
        durationS: 2,
        startS: 0,
        source: 'media',
        mediaId: 'm1',
      );
      expect(momentInVideo(media), isNull);
    });
  });

  group('the magnet and the play', () {
    // beats every half second
    const beatTimes = [0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0];

    test('the play snaps to the beat, not only the edges', () {
      // that is what a montage on the beat means: the impact lands on the beat, and
      // the cut edge lands wherever it has to
      final cutList = [cut(0, 1.0, t: 10)]; // play 0.7s from the start
      // dropped at 0.85: the play would land at 1.55 — 0.05 after the 1.5 beat
      final movedClip = move(cutList, 0, 0.85, beats: beatTimes, snap: true);

      expect(movedClip.atS, closeTo(0.8, 1e-9));
      expect(momentInVideo(movedClip), closeTo(1.5, 1e-9));
    });

    test('between the edge and the play, the closer one wins', () {
      // the magnet stays predictable: what you see snap is what was close
      final cutList = [cut(0, 1.0, t: 10)];
      final movedClip = move(cutList, 0, 0.98, beats: beatTimes, snap: true);

      // the start is 0.02 from the 1.0 beat; the play, 0.18 from the 1.5 one
      expect(movedClip.atS, closeTo(1.0, 1e-9));
    });

    test('a block without a play keeps snapping by its edges', () {
      const media = TimelineClip(
        atS: 0,
        durationS: 1.0,
        startS: 0,
        source: 'media',
        mediaId: 'm1',
      );
      final movedClip = move([media], 0, 0.96, beats: beatTimes, snap: true);
      expect(movedClip.atS, closeTo(1.0, 1e-9));
    });
  });

  group('adjustable beat grid', () {
    const grid = [0.0, 0.5, 1.0, 1.5, 2.0];

    test('without adjustment, it is the grid that came from the server', () {
      expect(adjustedGrid(grid), grid);
    });

    test('doubling the density puts a beat between each pair', () {
      // the detector sometimes counts half the beats of a fast song
      expect(adjustedGrid(grid, multiplier: 2), [
        0.0,
        0.25,
        0.5,
        0.75,
        1.0,
        1.25,
        1.5,
        1.75,
        2.0,
      ]);
    });

    test('halving keeps every other one', () {
      expect(adjustedGrid(grid, multiplier: 0.5), [0.0, 1.0, 2.0]);
    });

    test('the offset fixes the off-beat at once', () {
      // half a beat early is the classic error, and it is not fixed by dragging
      // block by block: what is wrong is the ruler
      expect(adjustedGrid(grid, offsetS: 0.25), [
        0.25,
        0.75,
        1.25,
        1.75,
        2.25,
      ]);
    });

    test('shifting back does not invent a beat before the start', () {
      // 0.0 and 0.5 go away (they would become -0.7 and -0.2); 1.0 becomes 0.3 and stays
      final late = adjustedGrid(grid, offsetS: -0.7);
      expect(late, hasLength(3));
      expect(late.first, closeTo(0.3, 1e-9));
      expect(late.every((b) => b >= 0), isTrue);
    });

    test('the bar keeps only the downbeat', () {
      expect(adjustedGrid(grid, bar: 4), [0.0, 2.0]);
    });

    test('the adjustments add up, in the order that matters', () {
      // density first, then bar, then offset: asking for the downbeat of a
      // doubled grid has to give the same place as before
      expect(
        adjustedGrid(grid, multiplier: 2, bar: 2, offsetS: 0.1),
        [0.1, 0.6, 1.1, 1.6, 2.1],
      );
    });

    test('an empty grid stays empty', () {
      expect(adjustedGrid(const [], multiplier: 2), isEmpty);
    });
  });

  group('framing', () {
    test('the instant lands at 70% of the cut', () {
      final c = cutForMoment(
        DetectionEvent(kind: 'kill', t: 100, confidence: 1),
        atS: 0,
        beats: const [0.0, 0.5, 1.0, 1.5],
        beatsPerCut: 2,
      );

      expect(c.durationS, closeTo(1.0, 1e-9));
      // 1s cut with the kill at 100s => starts at 99.3
      expect(c.startS, closeTo(99.3, 1e-9));
      expect(c.sourceT, 100);
    });

    test('the duration is born in whole beats when there is music', () {
      final c = cutForMoment(
        DetectionEvent(kind: 'sleep', t: 30, confidence: 1),
        atS: 0,
        beats: const [0.0, 0.6, 1.2, 1.8],
        beatsPerCut: 4,
      );
      expect(c.durationS, closeTo(2.4, 1e-9));
    });

    test('a cut does not start before the start of the recording', () {
      expect(sourceStartFor(0.3, 2.0), 0);
    });

    test('nor goes past its end', () {
      // a 2s cut in a 60s recording only fits if it starts at 58
      expect(sourceStartFor(59.9, 2.0, sourceDurationS: 60), closeTo(58, 1e-9));
    });
  });

  group('placing without running over', () {
    test('a block does not go on top of another', () {
      final cuts = [cut(0, 2), cut(5, 1)];

      expect(fits(cuts, 2.0, 1.0), isTrue);
      expect(fits(cuts, 1.5, 1.0), isFalse);
      expect(fits(cuts, 4.5, 1.0), isFalse);
      expect(fits(cuts, -0.1, 1.0), isFalse);
    });

    test('while dragging, the block does not collide with itself', () {
      final cuts = [cut(0, 2), cut(5, 1)];
      expect(fits(cuts, 0.5, 2.0, ignore: 0), isTrue);
    });

    test('moving to an occupied place leaves the block where it was', () {
      // pushing the neighbour would move a cut the user had already fitted
      final cuts = [cut(0, 2), cut(5, 1)];
      final movedClip = move(cuts, 1, 1.0, beats: const [], snap: false);
      expect(movedClip.atS, 5);
    });

    test('moving with the magnet snaps to the beat', () {
      final cuts = [cut(0, 1)];
      final movedClip = move(
        cuts,
        0,
        2.05,
        beats: const [0.0, 1.0, 2.0, 3.0],
        snap: true,
      );
      expect(movedClip.atS, 2.0);
    });

    test('when it is the end that is near the beat, the end rules', () {
      // in a montage what you hear is the scene change, and it happens at the end
      final cuts = [cut(0, 1.0)];
      final movedClip = move(
        cuts,
        0,
        1.9, // end at 2.9; the start is 0.1 from the 2.0 beat, the end 0.1 from 3.0
        beats: const [0.0, 1.0, 2.0, 3.0],
        snap: true,
      );
      expect(movedClip.untilS, closeTo(3.0, 1e-9));
    });

    test('the next free slot is after the last block', () {
      final cuts = [cut(0, 2), cut(2, 1)];
      expect(nextSlot(cuts, 0.5, 1.0), 3.0);
      expect(nextSlot(cuts, 4.0, 1.0), 4.0);
    });
  });

  group('stretching by the right edge', () {
    test('grows the tail: the start of the cut does not move', () {
      // if the content reframed on every pixel, the picture would slide
      // under the finger — reframing is another control
      final cuts = [cut(0, 1, t: 10)];
      final larger = stretchRight(cuts, 0, 2.0, beats: const [], snap: false);

      expect(larger.durationS, 2.0);
      expect(larger.startS, cuts[0].startS);
      expect(larger.atS, 0);
    });

    test('stops at the neighbour instead of refusing', () {
      final cuts = [cut(0, 1), cut(3, 1)];
      final larger = stretchRight(cuts, 0, 5.0, beats: const [], snap: false);
      expect(larger.durationS, closeTo(3.0, 1e-9));
    });

    test('does not shrink below the visible minimum', () {
      final cuts = [cut(0, 1)];
      final smaller = stretchRight(cuts, 0, 0.01, beats: const [], snap: false);
      expect(smaller.durationS, kMinCutS);
    });

    test('does not stretch beyond what was recorded', () {
      // the cut starts at 9.3s of a 10s recording: 0.7s are left
      final cuts = [cut(0, 1, t: 10)];
      final larger = stretchRight(
        cuts,
        0,
        5.0,
        beats: const [],
        snap: false,
        sourceDurationS: 10,
      );
      expect(larger.endS, lessThanOrEqualTo(10.0 + 1e-9));
    });

    test('with the magnet, the right edge snaps to the beat', () {
      final cuts = [cut(0, 1)];
      final adjusted = stretchRight(
        cuts,
        0,
        1.45,
        beats: const [0.0, 0.5, 1.0, 1.5],
        snap: true,
      );
      expect(adjusted.durationS, closeTo(1.5, 1e-9));
    });
  });

  group('trimming by the left edge', () {
    test('eats the start without moving what is already framed', () {
      // the edge moves, the content stays: so the start in the recording moves
      // along, by the same amount. That is what tells trimming from moving.
      final cuts = [cut(0, 2, t: 10)];
      final trimmed = trimLeft(cuts, 0, 0.5, beats: const [], snap: false);

      expect(trimmed.atS, 0.5);
      expect(trimmed.durationS, closeTo(1.5, 1e-9));
      expect(trimmed.startS, closeTo(cuts[0].startS + 0.5, 1e-9));
      // the end, on both scales, did not move
      expect(trimmed.untilS, closeTo(2.0, 1e-9));
      expect(trimmed.endS, closeTo(cuts[0].endS, 1e-9));
    });

    test('does not invade the block behind', () {
      final cuts = [cut(0, 2), cut(2, 2)];
      final trimmed = trimLeft(cuts, 1, 0.5, beats: const [], snap: false);
      expect(trimmed.atS, 2.0, reason: 'stopped against the neighbour');
    });

    test('does not pull the cut before the start of the recording', () {
      // a block that starts at 0.3s of the recording can only be trimmed 0.3s
      final cuts = [
        TimelineClip(atS: 5, durationS: 2, startS: 0.3, sourceT: 1),
      ];
      final trimmed = trimLeft(cuts, 0, 3.0, beats: const [], snap: false);
      expect(trimmed.startS, greaterThanOrEqualTo(0));
      expect(trimmed.atS, closeTo(4.7, 1e-9));
    });

    test('leaving less than the minimum trims nothing', () {
      final cuts = [cut(0, 1)];
      final trimmed = trimLeft(cuts, 0, 0.95, beats: const [], snap: false);
      expect(trimmed.durationS, 1.0);
    });
  });

  group('the moment mark inside the block', () {
    test('sits where the play happens', () {
      // the block starts at 99.3s and the kill is at 100s: 70% of a 1s cut
      final c = cut(0, 1, t: 100);
      expect(momentMark(c), closeTo(kMomentAnchor, 1e-9));
    });

    test('moves when the block is trimmed from the left', () {
      // Trimming eats material *before* the play, so it ends up proportionally
      // closer to the start of the block. The 8.6→10.6 cut with the kill at
      // 10s has it at 70%; trimmed by a second, it goes 9.6→10.6 and it lands at
      // 40%. That is why the mark has to be drawn, not deduced.
      final cuts = [cut(0, 2, t: 10)];
      final trimmed = trimLeft(cuts, 0, 1.0, beats: const [], snap: false);

      expect(momentMark(cuts[0]), closeTo(0.7, 1e-9));
      expect(momentMark(trimmed), closeTo(0.4, 1e-9));
    });

    test('vanishes when the moment falls outside the cut', () {
      // a block that does not contain the instant has nothing to mark
      final c = TimelineClip(atS: 0, durationS: 1, startS: 50, sourceT: 10);
      expect(momentMark(c), isNull);
    });
  });

  group('media clips', () {
    Media mediaItem({String kind = 'video', double dur = 10}) =>
        Media(id: 'm1', kind: kind, status: 'ready', name: 'x', durationS: dur);

    test('a long video comes in as a piece, not whole', () {
      final c = mediaClip(mediaItem(dur: 300), atS: 0, beats: const []);
      expect(c.durationS, lessThanOrEqualTo(3.0));
      expect(c.source, 'media');
      expect(c.startS, 0, reason: 'the file starts where it starts');
    });

    test('a short item rules the duration', () {
      final c = mediaClip(mediaItem(dur: 1.2), atS: 0, beats: const []);
      expect(c.durationS, closeTo(1.2, 1e-9));
    });

    test('with music, the duration lands on a whole number of beats', () {
      final c = mediaClip(
        mediaItem(dur: 300),
        atS: 0,
        beats: const [0, 0.5, 1.0, 1.5],
        beatsPerCut: 4,
      );
      expect(c.durationS, closeTo(2.0, 1e-9));
    });

    test('an image has no duration of its own: the montage chooses', () {
      final c = mediaClip(
        mediaItem(kind: 'image', dur: 0),
        atS: 0,
        beats: const [],
      );
      expect(c.durationS, greaterThan(0));
      expect(c.kind, 'image');
    });

    test('copyWith does not lose the source or the transform', () {
      // copyWith is used in every state operation; losing the source here
      // would silently turn a media clip into a piece of the recording
      const c = TimelineClip(
        atS: 0,
        durationS: 1,
        startS: 0,
        source: 'media',
        mediaId: 'm1',
        transform: ClipTransform(scale: 0.5),
      );

      final movedClip = c.copyWith(atS: 5);

      expect(movedClip.source, 'media');
      expect(movedClip.mediaId, 'm1');
      expect(movedClip.transform.scale, 0.5);
    });

    test('what goes to the server carries the media id', () {
      const c = TimelineClip(
        atS: 0,
        durationS: 1,
        startS: 0,
        source: 'media',
        mediaId: 'm1',
      );
      expect(c.toJson()['media_id'], 'm1');
      // and a recording clip does not send the field for nothing
      expect(
        const TimelineClip(
          atS: 0,
          durationS: 1,
          startS: 0,
        ).toJson().containsKey('media_id'),
        isFalse,
      );
    });
  });

  group('what the monitor shows', () {
    test('over a block, the matching instant of the recording', () {
      // a block that enters at 2s of the video and comes from 100s of the recording:
      // half a second after entering, the monitor has to be at 100.5
      final cuts = [
        TimelineClip(atS: 2, durationS: 1.5, startS: 100, sourceT: 100.7),
      ];

      expect(blockAt(cuts, 2.5), 0);
      expect(sourceAt(cuts, 2.5), closeTo(100.5, 1e-9));
    });

    test('in the gap, black screen', () {
      final cuts = [cut(0, 1), cut(3, 1)];

      expect(blockAt(cuts, 2.0), isNull);
      expect(sourceAt(cuts, 2.0), isNull);
    });

    test('after the last block it is black too', () {
      expect(sourceAt([cut(0, 1)], 5.0), isNull);
    });

    test('the block edge belongs to it; the end edge does not', () {
      final cuts = [cut(0, 1)];
      expect(blockAt(cuts, 0.0), 0);
      expect(blockAt(cuts, 1.0), isNull);
    });
  });

  group('what the video will have', () {
    test(
      'the gap counts in the duration — it becomes black screen, not shortening',
      () {
        final cuts = [cut(0, 2), cut(5, 1)];

        expect(videoDuration(cuts), 6.0);
        expect(blackDuration(cuts), closeTo(3.0, 1e-9));
      },
    );

    test('back-to-back blocks have no black at all', () {
      final cuts = [cut(0, 2), cut(2, 1)];
      expect(blackDuration(cuts), 0);
    });

    test('an empty montage has no duration', () {
      expect(videoDuration(const []), 0);
    });
  });

  group('what goes to the server', () {
    test('the montage carries the blocks', () {
      final json = Montage(
        title: 'My montage',
        layers: [
          Layer(clips: [cut(0, 1.5, t: 90)]),
        ],
      ).toJson();

      expect(json['title'], 'My montage');
      final layerList = json['layers'] as List;
      expect(layerList, hasLength(1));
      final clips = (layerList.first as Map)['clips'] as List;
      expect(clips, hasLength(1));
      expect((clips.first as Map)['at_s'], 0);
      expect((clips.first as Map)['duration_s'], 1.5);
      expect((clips.first as Map)['source_t'], 90);
      expect((clips.first as Map)['kind'], 'kill');
      expect((clips.first as Map)['source'], 'recording');
      // neutral transform and sound are not sent: the server assumes them
      expect((clips.first as Map).containsKey('transform'), isFalse);
    });

    test('the continuous track is never written again', () {
      // it is still read -- it becomes a block on open --, and resending it would create a
      // second song playing under the one that already became a block
      final json = const Montage(trackId: 'abc123', musicStartS: 42.5).toJson();
      expect(json.containsKey('track_id'), isFalse);
      expect(json.containsKey('music_start_s'), isFalse);
    });

    test('the sound layer goes marked, and comes back marked', () {
      // it is what tells the server not to draw the block: without the mark, a
      // song on the timeline would become a picture over the video
      final json = Montage(
        layers: [
          Layer(clips: [cut(0, 1.5)]),
          Layer(
            kind: 'audio',
            name: 'Music',
            clips: [
              TimelineClip(
                atS: 0,
                durationS: 30,
                startS: 12,
                source: 'media',
                mediaId: 'm1',
              ),
            ],
          ),
        ],
      ).toJson();

      final layerList = json['layers'] as List;
      expect((layerList.first as Map)['kind'], 'video');
      expect((layerList.last as Map)['kind'], 'audio');

      final back = Montage.fromJson(json);
      expect(back.layers.last.isAudio, isTrue);
      expect(back.layers.last.clips.single.mediaId, 'm1');
      expect(back.layers.last.clips.single.startS, 12);
    });

    test('reads the single-layer format the app used to send', () {
      // a draft saved before layers existed has to open
      final m = Montage.fromJson(const {
        'title': 'from yesterday',
        'music_start_s': 3.0,
        'cuts': [
          {'start_s': 10.0, 'duration_s': 2.0, 'at_s': 0.0, 'kind': 'kill'},
        ],
      });

      expect(m.layers, hasLength(1));
      expect(m.clips, hasLength(1));
      expect(m.clips.first.kind, 'kill');
      expect(m.clips.first.source, 'recording');
      expect(m.musicStartS, 3.0);
    });
  });

  group('Track', () {
    test('reads the analysis the server returned', () {
      final t = Track.fromJson(const {
        'id': 'm1',
        'status': 'ready',
        'name': 'song.mp3',
        'duration_s': 180.5,
        'bpm': 128.0,
        'beats': [0.0, 0.47, 0.94],
        'peaks': [0.1, 0.9, 0.5],
        'audio_url': '/api/tracks/m1/audio',
      });

      expect(t.isReady, isTrue);
      expect(t.beats, hasLength(3));
      expect(t.peaks, hasLength(3));
      expect(Uri.parse(t.audioUrl).hasScheme, isTrue);
    });

    test('a song the server could not listen to announces itself', () {
      final t = Track.fromJson(const {
        'id': 'm2',
        'status': 'failed',
        'name': 'broken.mp3',
        'error': 'ffmpeg could not decode the song',
        'audio_url': '/api/tracks/m2/audio',
      });

      expect(t.isFailed, isTrue);
      expect(t.error, isNotNull);
      expect(t.beats, isEmpty);
    });
  });

  group('transition on the monitor', () {
    TimelineClip clip(double at, double dur, {ClipTransition? tr}) =>
        TimelineClip(atS: at, durationS: dur, startS: 10, transition: tr);

    test('happens at the start of the incoming clip, for its duration', () {
      final cuts = [
        clip(0, 2),
        clip(2, 2, tr: const ClipTransition(kind: 'dissolve', durationS: 1)),
      ];

      expect(transitionAt(cuts, 1.9), isNull);
      final middle = transitionAt(cuts, 2.5)!;
      expect(middle.kind, 'dissolve');
      expect(middle.p, closeTo(0.5, 1e-9));
      expect(middle.leaving, isFalse);
      expect(transitionAt(cuts, 3.1), isNull);
    });

    test('a dip starts before the cut, on the outgoing clip', () {
      final cuts = [
        clip(0, 2),
        clip(2, 2, tr: const ClipTransition(kind: 'fade_black', durationS: 1)),
      ];

      expect(transitionAt(cuts, 1.4), isNull);
      final leaving = transitionAt(cuts, 1.75)!;
      expect(leaving.leaving, isTrue);
      expect(leaving.p, closeTo(0.5, 1e-9));
    });

    test('a dissolve does not start before the cut', () {
      // the previous clip does not change in it: the new one shows over it
      final cuts = [
        clip(0, 2),
        clip(2, 2, tr: const ClipTransition(kind: 'dissolve', durationS: 1)),
      ];
      expect(transitionAt(cuts, 1.75), isNull);
    });
  });

  group('moment preview', () {
    test('plays 3 s with the play at 70%, like a fresh cut', () {
      final w = momentPreview(100);
      expect(w.startS, closeTo(97.9, 1e-9));
      expect(w.endS, closeTo(100.9, 1e-9));
    });

    test('near the start it slides instead of shrinking', () {
      final w = momentPreview(1, recordingS: 60);
      expect(w.startS, 0);
      expect(w.endS, 3);
    });

    test('near the end it slides back, and never passes the recording', () {
      final w = momentPreview(59.8, recordingS: 60);
      expect(w.startS, 57);
      expect(w.endS, 60);
    });

    test('a recording shorter than the window plays whole', () {
      final w = momentPreview(1, recordingS: 2);
      expect(w.startS, 0);
      expect(w.endS, 2);
    });
  });
}
