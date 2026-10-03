import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart';
import 'package:ow_editor/montage.dart';
import 'package:ow_editor/montage_state.dart';

/// The montage state and the history that undoes it.
///
/// The maths of *where* a block can land is in `montage_test.dart`. What is
/// checked here is what V1 did not have: that an operation returns a new state
/// without spoiling the previous one, and that you can go back.
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

  /// A state with clips already identified, as it comes out of the draft.
  MontageState stateWith(List<TimelineClip> clips) =>
      montageFromDraft(Montage(layers: [Layer(clips: clips)]));

  /// A two-layer state, for what only layers do.
  MontageState layeredState(
    List<TimelineClip> lower,
    List<TimelineClip> upper,
  ) => montageFromDraft(
    Montage(
      layers: [
        Layer(clips: lower),
        Layer(name: 'upper', clips: upper),
      ],
    ),
  );

  group('immutability', () {
    test('operating returns a new state and does not spoil the previous one', () {
      // this is what V1 did not do: `_cuts` was changed in place, and the "before"
      // ceased to exist the instant the "after" was born
      final beforeState = stateWith([cut(0, 1)]);
      final id = beforeState.clips.first.id;

      final afterState = moveBlock(beforeState, id, 5, beats: const [], snap: false);

      expect(afterState.clips.first.atS, 5);
      expect(beforeState.clips.first.atS, 0, reason: 'the previous state was touched');
      expect(identical(beforeState, afterState), isFalse);
    });

    test('the lists do not accept changes from outside', () {
      final s = stateWith([cut(0, 1)]);
      expect(
        () => s.layers.first.clips.add(cut(2, 1)),
        throwsUnsupportedError,
      );
      expect(() => s.layers.add(const Layer()), throwsUnsupportedError);
      expect(() => s.selectionIds.add('x'), throwsUnsupportedError);
    });

    test('each block gets an identity when loaded', () {
      final s = stateWith([cut(0, 1), cut(2, 1)]);
      expect(s.clips[0].id, isNotEmpty);
      expect(s.clips[0].id, isNot(s.clips[1].id));
    });

    test('the identity does not go to the server', () {
      // for the server a block is a span with a set time, and nothing else
      final s = stateWith([cut(0, 1)]);
      final clip = s.toPayload().toJson()['layers'][0]['clips'][0] as Map;
      expect(clip.containsKey('id'), isFalse);
    });
  });

  group('beat grid corrections', () {
    test('come back from the draft and go back to the server', () {
      // fixing the grid twice annoys more than fixing it once
      final s = montageFromDraft(
        const Montage(
          layers: [],
          beatOffsetS: 0.12,
          beatMultiplier: 2,
          beatBar: 4,
        ),
      );

      expect(s.beatOffsetS, 0.12);
      expect(s.beatMultiplier, 2);
      expect(s.beatBar, 4);

      final json = s.toPayload().toJson();
      expect(json['beat_offset_s'], 0.12);
      expect(json['beat_multiplier'], 2);
      expect(json['beat_bar'], 4);
    });

    test('changing them is an edit, and edits can be undone', () {
      // the wrong grid makes every cut snap to the wrong place; going back
      // from it has to be as possible as going back from a drag
      final h = MontageHistory(stateWith([cut(0, 1)]));
      h.apply(h.present.copyWith(beatOffsetS: 0.25));

      expect(h.present.beatOffsetS, 0.25);
      expect(h.undo().beatOffsetS, 0);
    });
  });

  group('effects', () {
    test('speed changes what is eaten from the recording, not what is seen', () {
      final s = stateWith([cut(0, 2, t: 10)]);
      final id = s.clips.first.id;

      final slow = adjustEffect(s, id, speed: 0.5);

      expect(slow.clips.first.speed, 0.5);
      expect(slow.clips.first.sourceConsumedS, closeTo(1.0, 1e-9));
      expect(slow.clips.first.durationS, 2.0, reason: 'the block did not shrink');
    });

    test('an absurd speed is clamped instead of refused by the server', () {
      final s = stateWith([cut(0, 1)]);
      final id = s.clips.first.id;

      expect(adjustEffect(s, id, speed: 99).clips.first.speed, 10.0);
      expect(adjustEffect(s, id, speed: 0.001).clips.first.speed, 0.1);
    });

    test('fades longer than the clip are shrunk, keeping the proportion', () {
      // the server would refuse; finding that out only at render time would be worse
      final s = stateWith([cut(0, 1)]);
      final id = s.clips.first.id;

      final c = adjustEffect(
        s,
        id,
        fade: const ClipFade(inS: 1.0, outS: 3.0),
      ).clips.first;

      expect(c.fade.inS + c.fade.outS, closeTo(1.0, 1e-9));
      expect(c.fade.outS / c.fade.inS, closeTo(3.0, 1e-6));
    });

    test('an effect is an edit, and edits can be undone', () {
      final h = MontageHistory(stateWith([cut(0, 2)]));
      final id = h.present.clips.first.id;

      h.apply(adjustEffect(h.present, id, speed: 2));

      expect(h.present.clips.first.speed, 2);
      expect(h.undo().clips.first.speed, 1);
    });

    test('what goes to the server only carries what is not neutral', () {
      final s = stateWith([cut(0, 2)]);
      final id = s.clips.first.id;
      final clean = s.toPayload().toJson()['layers'][0]['clips'][0] as Map;
      expect(clean.containsKey('speed'), isFalse);
      expect(clean.containsKey('fade'), isFalse);

      final withEffect =
          adjustEffect(
                s,
                id,
                speed: 2,
              ).toPayload().toJson()['layers'][0]['clips'][0]
              as Map;
      expect(withEffect['speed'], 2);
    });

    test('the audio mix travels with the montage', () {
      final s = stateWith([
        cut(0, 1),
      ]).copyWith(musicVolume: 0.8, gameVolume: 0.4);
      final json = s.toPayload().toJson();

      expect(json['music_volume'], 0.8);
      expect(json['game_volume'], 0.4);
    });
  });

  group('zoom, freeze and reverse', () {
    test('the punch closes the lens and loosens until the end', () {
      final k = punch(until: 2.0);

      expect(k, hasLength(3));
      expect(k.first.t, 0);
      expect(k.first.scale, 1, reason: 'starts at full size');
      expect(k[1].scale, 2.0, reason: 'the peak is what was asked');
      expect(k.last.t, 1);
      expect(k.last.scale, greaterThan(1));
      expect(k.last.scale, lessThan(k[1].scale), reason: 'loosens afterwards');
    });

    test('the points are in order — the server would refuse them otherwise', () {
      final ts = punch().map((k) => k.t).toList();
      expect(ts, orderedEquals([...ts]..sort()));
    });

    test('freezing turns off reverse, and vice versa', () {
      // the server refuses both together; turning on the second means swapping
      var s = stateWith([cut(0, 2)]);
      final id = s.clips.first.id;

      s = adjustEffect(s, id, freeze: true);
      expect(s.clips.first.freeze, isTrue);

      s = adjustEffect(s, id, reverse: true);
      expect(s.clips.first.reverse, isTrue);
      expect(s.clips.first.freeze, isFalse, reason: 'one turned the other off');
    });

    test('a frozen clip eats a single frame of the recording', () {
      var s = stateWith([cut(0, 3, t: 10)]);
      final id = s.clips.first.id;
      s = adjustEffect(s, id, freeze: true);

      expect(s.clips.first.sourceConsumedS, lessThan(0.2));
      expect(s.clips.first.untilS, 3.0, reason: 'but takes the whole block');
    });

    test('what goes to the server only carries what is on', () {
      var s = stateWith([cut(0, 2)]);
      final id = s.clips.first.id;
      s = adjustEffect(s, id, zoom: punch(), freeze: true);

      final clip = s.toPayload().toJson()['layers'][0]['clips'][0] as Map;
      expect((clip['zoom'] as List), hasLength(3));
      expect(clip['freeze'], isTrue);
      expect(clip.containsKey('reverse'), isFalse);
    });
  });

  group('layers', () {
    test('collision is per layer: two clips at the same instant coexist', () {
      // that is precisely what layers are for
      final s = layeredState([cut(0, 2)], [cut(0, 2)]);

      expect(s.clips, hasLength(2));
      expect(s.layers[0].clips.first.atS, 0);
      expect(s.layers[1].clips.first.atS, 0);
    });

    test('the new clip goes into the active layer', () {
      var s = layeredState([cut(0, 1)], []);
      s = s.copyWith(activeLayer: 1);
      s = addClip(s, cut(0, 1), beats: const [], snap: false);

      expect(s.layers[0].clips, hasLength(1));
      expect(s.layers[1].clips, hasLength(1));
      // and it was not pushed: the top layer was free at that instant
      expect(s.layers[1].clips.first.atS, 0);
    });

    test('switching layers keeps the instant', () {
      final s = layeredState([cut(3, 1)], []);
      final id = s.layers[0].clips.first.id;

      final afterState = moveToLayer(s, id, 1);

      expect(afterState.layers[0].clips, isEmpty);
      expect(afterState.layers[1].clips.first.atS, 3.0);
      expect(afterState.activeLayer, 1);
    });

    test('does not switch layers if the place is taken there', () {
      // pushing to another instant would change two things when one was asked
      // uma
      final s = layeredState([cut(0, 2)], [cut(1, 2)]);
      final id = s.layers[0].clips.first.id;

      expect(moveToLayer(s, id, 1).layers[0].clips, hasLength(1));
    });

    test('the last layer cannot be removed', () {
      // with no layer at all there would be nowhere to receive the next clip
      final s = stateWith([cut(0, 1)]);
      expect(removeLayer(s, 0).layers, hasLength(1));
    });

    test('removing a layer takes its clips and re-anchors the active one', () {
      var s = layeredState([cut(0, 1)], [cut(0, 1)]);
      s = s.copyWith(activeLayer: 1);

      final afterState = removeLayer(s, 1);

      expect(afterState.layers, hasLength(1));
      expect(afterState.clips, hasLength(1));
      expect(afterState.activeLayer, 0);
    });

    test('hiding and muting do not touch the clips', () {
      var s = layeredState([cut(0, 1)], [cut(0, 1)]);
      s = adjustLayer(s, 1, hidden: true, muted: true);

      expect(s.layers[1].hidden, isTrue);
      expect(s.layers[1].muted, isTrue);
      expect(s.clips, hasLength(2), reason: 'the clips are still there');
    });

    test('the monitor shows the top layer where both overlap', () {
      // the preview does not composite: it shows one frame, and what counts is what
      // the server will draw last
      final s = layeredState([cut(0, 4, t: 10)], [cut(1, 1, t: 50)]);
      final below = s.layers[0].clips.single;

      final visible = s.visibleClips;
      expect(visible, hasLength(3));
      expect(visible[1].sourceT, 50, reason: 'where they overlap, upper wins');
      expect(
        sourceAt(visible, 1.5),
        closeTo(50 - 1 * kMomentAnchor + 0.5, 1e-9),
      );
      // before and after, the lower one carries on: it was only covered in
      // the middle
      expect(sourceAt(visible, 0.5), closeTo(below.startS + 0.5, 1e-9));
      expect(
        sourceAt(visible, 3),
        closeTo(below.startS + 3, 1e-9),
        reason: 'the piece after follows the recording where it would be',
      );
      expect({for (final v in visible) v.id}, hasLength(2));
    });

    test('text on top does not erase the video below', () {
      // text is drawn over the picture; when it ended, the monitor went black
      // even with the video clip still running underneath
      final s = layeredState(
        [cut(0, 6, t: 10)],
        [
          const TimelineClip(
            atS: 1,
            durationS: 2,
            startS: 0,
            source: 'text',
            text: 'TRIPLE KILL',
          ),
        ],
      );

      final visible = s.visibleClips;
      expect(visible.single.isText, isFalse);
      for (final t in [0.5, 2.0, 4.0, 5.5]) {
        expect(sourceAt(visible, t), isNotNull, reason: 'black at $t s');
      }
    });

    test('a hidden layer does not show on the monitor', () {
      var s = layeredState([cut(0, 1, t: 10)], [cut(0, 1, t: 50)]);
      s = adjustLayer(s, 1, hidden: true);

      expect(s.visibleClips.single.sourceT, 10);
    });

    test('the montage goes to the server in layers', () {
      final s = layeredState([cut(0, 1)], [cut(2, 1)]);
      final layerList = s.toPayload().toJson()['layers'] as List;

      expect(layerList, hasLength(2));
      expect(((layerList[0] as Map)['clips'] as List), hasLength(1));
      expect(((layerList[1] as Map)['clips'] as List), hasLength(1));
    });
  });

  group('adding and deleting', () {
    test('the new block comes in selected', () {
      final s = addClip(
        MontageState.blank(),
        cut(0, 1),
        beats: const [],
        snap: false,
      );

      expect(s.clips, hasLength(1));
      expect(s.selectionIds, {s.clips.first.id});
    });

    test('a new block on top of another goes to the first free slot', () {
      var s = stateWith([cut(0, 2)]);
      s = addClip(s, cut(0.5, 1), beats: const [], snap: false);

      expect(s.clips.last.atS, 2.0);
    });

    test('deleting removes only the selected ones and clears the selection', () {
      final s = stateWith([cut(0, 1), cut(2, 1), cut(4, 1)]);
      final afterState = removeClips(s, {s.clips[1].id});

      expect(afterState.clips.map((c) => c.atS), [0.0, 4.0]);
      expect(afterState.selectionIds, isEmpty);
    });
  });

  group('splitting', () {
    test(
      'the seam is invisible: the second half continues where the first stopped',
      () {
        final s = stateWith([cut(0, 2, t: 10)]);
        final original = s.clips.first;

        final afterState = split(s, original.id, 1.2);

        expect(afterState.clips, hasLength(2));
        final a = afterState.clips[0];
        final b = afterState.clips[1];
        expect(a.durationS, closeTo(1.2, 1e-9));
        expect(b.atS, closeTo(1.2, 1e-9));
        expect(b.durationS, closeTo(0.8, 1e-9));
        // the next frame of the recording, with no jump or repetition
        expect(b.startS, closeTo(a.endS, 1e-9));
        // and together they still cover exactly what the block covered
        expect(b.untilS, closeTo(original.untilS, 1e-9));
      },
    );

    test('the new half stays selected, to keep editing', () {
      final s = stateWith([cut(0, 2)]);
      final afterState = split(s, s.clips.first.id, 1);
      expect(afterState.selectionIds, {afterState.clips[1].id});
    });

    test('does not split if an invisible piece would be left', () {
      final s = stateWith([cut(0, 1)]);
      expect(split(s, s.clips.first.id, 0.99).clips, hasLength(1));
      expect(split(s, s.clips.first.id, 0.01).clips, hasLength(1));
    });

    test('splitting outside the block does nothing', () {
      final s = stateWith([cut(0, 1)]);
      expect(split(s, s.clips.first.id, 5).clips, hasLength(1));
    });
  });

  group('batch selection', () {
    test('the group moves together, keeping the distance between blocks', () {
      var s = stateWith([cut(0, 1), cut(2, 1), cut(10, 1)]);
      s = s.copyWith(selectionIds: {s.clips[0].id, s.clips[1].id});

      final afterState = moveSelection(s, 3, beats: const [], snap: false);

      expect(afterState.clips[0].atS, 3.0);
      expect(afterState.clips[1].atS, 5.0);
      expect(
        afterState.clips[2].atS,
        10.0,
        reason: 'whoever was not in the selection stayed',
      );
    });

    test('moves together or not at all: a collision cancels the whole move', () {
      // moving half of a selection would undo an arrangement already made
      var s = stateWith([cut(0, 1), cut(2, 1), cut(4, 1)]);
      s = s.copyWith(selectionIds: {s.clips[0].id, s.clips[1].id});

      final afterState = moveSelection(s, 2.5, beats: const [], snap: false);

      expect(afterState.clips.map((c) => c.atS), [0.0, 2.0, 4.0]);
    });

    test('does not push the group before the first frame', () {
      var s = stateWith([cut(1, 1), cut(3, 1)]);
      s = s.copyWith(selectionIds: {for (final c in s.clips) c.id});

      expect(
        moveSelection(s, -2, beats: const [], snap: false).clips[0].atS,
        1.0,
      );
    });

    test('with the magnet, the group snaps by the edge of the first one', () {
      var s = stateWith([cut(0, 1), cut(2, 1)]);
      s = s.copyWith(selectionIds: {for (final c in s.clips) c.id});

      final afterState = moveSelection(
        s,
        1.04,
        beats: const [0, 1, 2, 3, 4],
        snap: true,
      );

      expect(afterState.clips[0].atS, 1.0);
      expect(afterState.clips[1].atS, 3.0, reason: 'the distance was kept');
    });
  });

  group('duplicating and pasting', () {
    test('the copies go after the end, with a new identity', () {
      var s = stateWith([cut(0, 1), cut(2, 1)]);
      final ids = {for (final c in s.clips) c.id};

      s = duplicate(s, ids);

      expect(s.clips, hasLength(4));
      expect(s.clips[2].atS, 3.0);
      expect(s.clips[3].atS, 5.0, reason: 'the internal arrangement was kept');
      expect(
        ids.intersection({for (final c in s.clips.skip(2)) c.id}),
        isEmpty,
      );
      expect(s.selectionIds, {s.clips[2].id, s.clips[3].id});
    });

    test('pasting at the cursor keeps the arrangement', () {
      final s = stateWith([cut(0, 1)]);
      final area = [cut(10, 1), cut(12, 2)];

      final afterState = paste(s, area, 4);

      expect(afterState.clips[1].atS, 4.0);
      expect(afterState.clips[2].atS, 6.0);
    });

    test('if it does not fit at the cursor, the whole group goes to the end', () {
      // spreading the copies through the gaps would be less predictable
      final s = stateWith([cut(0, 5)]);
      final afterState = paste(s, [cut(0, 1), cut(2, 1)], 1);

      expect(afterState.clips[1].atS, 5.0);
      expect(afterState.clips[2].atS, 7.0);
    });

    test('pasting nothing changes nothing', () {
      final s = stateWith([cut(0, 1)]);
      expect(paste(s, const [], 3).clips, hasLength(1));
    });
  });

  group('history', () {
    test('undo goes back to the previous state; redo brings it back', () {
      final h = MontageHistory(stateWith([cut(0, 1)]));
      final id = h.present.clips.first.id;

      h.apply(moveBlock(h.present, id, 5, beats: const [], snap: false));
      expect(h.present.clips.first.atS, 5);

      expect(h.undo().clips.first.atS, 0);
      expect(h.redo().clips.first.atS, 5);
    });

    test('with nothing to undo, it neither blows up nor invents', () {
      final h = MontageHistory(MontageState.blank());
      expect(h.canUndo, isFalse);
      expect(h.undo().clips, isEmpty);
      expect(h.redo().clips, isEmpty);
    });

    test('a whole drag counts as a single step', () {
      // without grouping, undo would go one pixel at a time
      final h = MontageHistory(stateWith([cut(0, 1)]));
      final id = h.present.clips.first.id;

      h.startGesture();
      for (final at in [1.0, 2.0, 3.0, 4.0]) {
        h.apply(moveBlock(h.present, id, at, beats: const [], snap: false));
      }
      h.endGesture();

      expect(h.present.clips.first.atS, 4);
      expect(h.undo().clips.first.atS, 0);
      expect(h.canUndo, isFalse);
    });

    test('two drags are two steps', () {
      final h = MontageHistory(stateWith([cut(0, 1)]));
      final id = h.present.clips.first.id;

      for (final at in [2.0, 4.0]) {
        h.startGesture();
        h.apply(moveBlock(h.present, id, at, beats: const [], snap: false));
        h.endGesture();
      }

      expect(h.undo().clips.first.atS, 2);
      expect(h.undo().clips.first.atS, 0);
    });

    test('editing after undoing discards the redo', () {
      final h = MontageHistory(stateWith([cut(0, 1)]));
      final id = h.present.clips.first.id;

      h.apply(moveBlock(h.present, id, 5, beats: const [], snap: false));
      h.undo();
      h.apply(moveBlock(h.present, id, 9, beats: const [], snap: false));

      expect(h.canRedo, isFalse);
      expect(h.present.clips.first.atS, 9);
    });

    test('selecting does not become an undo step', () {
      // undo has to go back one *edit*, not a focus change
      final h = MontageHistory(stateWith([cut(0, 1)]));
      h.replace(h.present.copyWith(selectionIds: {h.present.clips.first.id}));

      expect(h.canUndo, isFalse);
      expect(h.present.selectionIds, hasLength(1));
    });

    test('applying the same state does not create a step', () {
      final h = MontageHistory(stateWith([cut(0, 1)]));
      h.apply(h.present);
      expect(h.canUndo, isFalse);
    });

    test('the history has a ceiling', () {
      final h = MontageHistory(stateWith([cut(0, 1)]));
      final id = h.present.clips.first.id;
      for (var i = 0; i < MontageHistory.maxSteps + 40; i++) {
        h.apply(
          moveBlock(
            h.present,
            id,
            i.toDouble() + 1,
            beats: const [],
            snap: false,
          ),
        );
      }
      var steps = 0;
      while (h.canUndo) {
        h.undo();
        steps++;
      }
      expect(steps, MontageHistory.maxSteps);
    });
  });

  group('dropping a dragged clip', () {
    MontageState drop(
      MontageState s,
      TimelineClip c, {
      required double atS,
      int? layer,
    }) => dropClip(
      s,
      c.id,
      fromS: c.atS,
      atS: atS,
      destination: layer ?? s.locate(c.id)!.$1,
      beats: const [],
      snap: false,
    );

    List<double> starts(MontageState s, int layer) => [
      for (final c in [...s.layers[layer].clips]
        ..sort((a, b) => a.atS.compareTo(b.atS)))
        c.atS,
    ];

    test('a free spot takes it as it is', () {
      final s = stateWith([cut(0, 2), cut(5, 2)]);
      final a = s.layers[0].clips[0];
      final after = drop(s, a, atS: 8);
      expect(after.layers[0].clips.firstWhere((c) => c.id == a.id).atS, 8);
    });

    test('dropped on the next clip, the two swap and the gap stays', () {
      final s = stateWith([cut(0, 2), cut(3, 2), cut(6, 2)]);
      final [a, b, c] = s.layers[0].clips;
      final after = drop(s, a, atS: 3);
      final at = {for (final x in after.layers[0].clips) x.id: x.atS};
      expect(at[b.id], 0);
      expect(at[a.id], 3);
      expect(at[c.id], 6, reason: 'outside the span nothing moves');
    });

    test('dragged over two clips, both slide back', () {
      final s = stateWith([cut(0, 2), cut(2, 2), cut(4, 2)]);
      final [a, b, c] = s.layers[0].clips;
      final after = drop(s, a, atS: 4);
      final at = {for (final x in after.layers[0].clips) x.id: x.atS};
      expect([at[b.id], at[c.id], at[a.id]], [0, 2, 4]);
    });

    test('dragged to the left, the clips jumped over slide right', () {
      final s = stateWith([cut(0, 2), cut(2, 2), cut(4, 3)]);
      final [a, b, c] = s.layers[0].clips;
      final after = drop(s, c, atS: 0);
      final at = {for (final x in after.layers[0].clips) x.id: x.atS};
      expect([at[c.id], at[a.id], at[b.id]], [0, 3, 5]);
      expect(starts(after, 0).last + 2, 7, reason: 'same end as before');
    });

    test('a near miss on a neighbour changes nothing', () {
      // the centre does not reach the neighbour: that is not a swap
      final s = stateWith([cut(0, 2), cut(3, 2)]);
      expect(drop(s, s.layers[0].clips[0], atS: 1.5), same(s));
    });

    test('on another layer, the two trade places', () {
      final s = layeredState([cut(0, 2)], [cut(4, 3)]);
      final a = s.layers[0].clips.single;
      final b = s.layers[1].clips.single;
      final after = drop(s, a, atS: 4, layer: 1);
      expect(after.layers[1].clips.single.id, a.id);
      expect(after.layers[1].clips.single.atS, 4);
      expect(after.layers[0].clips.single.id, b.id);
      expect(after.layers[0].clips.single.atS, 0);
    });

    test('a swap the lengths do not allow is refused', () {
      // the other clip is longer and would cover the neighbour left behind
      final s = layeredState([cut(0, 2), cut(2, 2)], [cut(5, 3)]);
      expect(drop(s, s.layers[0].clips[0], atS: 5, layer: 1), same(s));
    });

    test('a free spot on another layer takes it at the new instant', () {
      final s = layeredState([cut(0, 2)], [cut(0, 2)]);
      final a = s.layers[0].clips.single;
      final after = drop(s, a, atS: 6, layer: 1);
      expect(after.layers[0].clips, isEmpty);
      expect(starts(after, 1), [0, 6]);
    });
  });

  group('music on the timeline', () {
    Track music({
      String id = 'm1',
      String displayName = 'track.mp3',
      double durationValue = 90,
      String status = 'ready',
    }) => Track(
      id: id,
      status: status,
      name: displayName,
      durationS: durationValue,
      bpm: 120,
      beats: const [],
      peaks: const [],
      audioUrl: '',
    );

    test('the sound layer draws nothing', () {
      // it is the difference that justifies the kind: a music block on the top
      // layer would erase the video if the visual stacking took it into account
      final s = putMusic(
        addMusicLayer(stateWith([cut(0, 2)])),
        music(),
        atS: 0,
      );

      expect(s.layers.last.isAudio, isTrue);
      expect(s.layers.last.clips, hasLength(1));
      expect(s.visibleClips, hasLength(1));
      expect(s.visibleClips.single.source, isNot('media'));
    });

    test('opening the sound layer moves the focus to it', () {
      final s = addMusicLayer(stateWith([cut(0, 2)]));
      expect(s.activeLayer, s.layers.length - 1);
      expect(s.selectionIds, isEmpty);
    });

    test('adding music without a sound layer opens one', () {
      // nobody should have to prepare the ground before asking for the music
      final s = putMusic(stateWith([cut(0, 2)]), music(), atS: 0);

      expect(s.layers, hasLength(2));
      expect(s.layers.last.isAudio, isTrue);
      expect(s.layers.last.clips.single.mediaId, 'm1');
      expect(s.selectionIds, {s.layers.last.clips.single.id});
    });

    test('the second song goes to the same sound layer', () {
      var s = putMusic(stateWith([cut(0, 2)]), music(), atS: 0);
      s = putMusic(s, music(id: 'm2'), atS: 200, durationS: 10);

      expect(s.layers, hasLength(2), reason: 'it did not open another layer');
      expect(s.layers.last.clips, hasLength(2));
      expect(s.layers.last.clips.last.mediaId, 'm2');
    });

    test('without a requested duration, what is left of the track goes in', () {
      final s = putMusic(
        stateWith([cut(0, 2)]),
        music(durationValue: 90),
        atS: 0,
        startS: 20,
      );

      expect(s.layers.last.clips.single.durationS, 70);
      expect(s.layers.last.clips.single.startS, 20);
    });

    test('the requested duration does not exceed what the track has', () {
      final s = putMusic(
        stateWith([cut(0, 2)]),
        music(durationValue: 30),
        atS: 0,
        durationS: 500,
      );

      expect(s.layers.last.clips.single.durationS, 30);
    });

    test('where there is already music, the new one goes after — it pushes no one', () {
      // pushing would misalign the one already fitted to the beat
      var s = putMusic(
        stateWith([cut(0, 2)]),
        music(),
        atS: 0,
        durationS: 10,
      );
      s = putMusic(s, music(id: 'm2'), atS: 5, durationS: 10);

      final blocks = s.layers.last.clips;
      expect(blocks.map((c) => c.atS), [0, 10]);
      expect(blocks.last.mediaId, 'm2');
    });

    test('a song not yet listened to does not go in', () {
      final s = stateWith([cut(0, 2)]);
      expect(putMusic(s, music(status: 'pending'), atS: 0), same(s));
    });

    test('the continuous track of an old montage becomes a block on open', () {
      // there were two ways of having music and one was left. Whoever converts the
      // old format is the reading code -- and the server reads by the same rule
      final s = montageFromDraft(
        Montage(
          trackId: 'm1',
          musicStartS: 12,
          layers: [
            Layer(clips: [cut(0, 2), cut(2, 3)]),
          ],
        ),
      );

      expect(s.layers, hasLength(2));
      final block = s.layers.last.clips.single;
      expect(s.layers.last.isAudio, isTrue);
      expect(block.mediaId, 'm1');
      expect(block.atS, 0, reason: 'the music came in with the video');
      expect(block.durationS, 5, reason: 'and covered the whole video');
      expect(block.startS, 12, reason: 'from the same point of the song');
    });

    test('without cuts there is no video to cover, and the old track is lost', () {
      // a music block alone is no montage at all: what it would cover
      final s = montageFromDraft(
        const Montage(trackId: 'm1', musicStartS: 3),
      );
      expect(s.layers.any((l) => l.isAudio), isFalse);
    });

    test('the converted montage does not send the track back', () {
      // sending it would create a second song: it already became a block
      final s = montageFromDraft(
        Montage(
          trackId: 'm1',
          musicStartS: 4,
          layers: [
            Layer(clips: [cut(0, 2)]),
          ],
        ),
      );
      expect(s.toPayload().toJson().containsKey('track_id'), isFalse);
    });

    test('sound does not go up to a picture layer', () {
      // the two things do not mix: the server would refuse, and refusing here
      // explains it better
      final s = putMusic(stateWith([cut(0, 2)]), music(), atS: 0);
      final block = s.layers.last.clips.single.id;
      final video = s.clips.first.id;

      expect(moveToLayer(s, block, 0), same(s));
      expect(moveToLayer(s, video, 1), same(s));
    });

    test('a moment added while the sound layer is active lands on a picture '
        'layer', () {
      // putting music makes the sound layer the active one; the next moment
      // clicked used to go right into it
      final s = putMusic(stateWith([cut(0, 2)]), music(), atS: 0);
      expect(s.layers[s.activeLayer].isAudio, isTrue);

      final after = addClip(s, cut(0, 2), beats: const [], snap: false);
      expect(after.layers.last.clips, hasLength(1), reason: 'only the music');
      expect(after.layers.first.clips, hasLength(2));
    });

    test('with no picture layer at all, adding a clip opens one', () {
      final s = MontageState(layers: const [Layer(kind: 'audio')]);
      final after = addClip(s, cut(0, 2), beats: const [], snap: false);
      expect(after.layers, hasLength(2));
      expect(after.layers.last.isAudio, isFalse);
      expect(after.layers.last.clips, hasLength(1));
    });

    test('pasting goes to a layer of the clip kind', () {
      final s = putMusic(stateWith([cut(0, 2)]), music(), atS: 0);
      final video = s.layers.first.clips.single;
      final song = s.layers.last.clips.single;

      // the sound layer is active: the picture must not land there
      final pictures = paste(s, [video], 10);
      expect(pictures.layers.first.clips, hasLength(2));
      expect(pictures.layers.last.clips, hasLength(1));

      // and music does not land on a picture layer, whichever is active
      final sounds = paste(
        s.copyWith(activeLayer: 0),
        [song],
        100,
        audio: true,
      );
      expect(sounds.layers.first.clips, hasLength(1));
      expect(sounds.layers.last.clips, hasLength(2));
    });

    test('duplicating a mixed selection keeps each clip on its kind', () {
      final s = putMusic(stateWith([cut(0, 2)]), music(), atS: 0);
      final ids = {for (final c in s.clips) c.id};

      final after = duplicate(s, ids);
      expect(after.layers.first.clips, hasLength(2));
      expect(after.layers.last.clips, hasLength(2));
      expect(after.selectionIds, hasLength(2), reason: 'both copies chosen');
      expect(after.selectionIds.intersection(ids), isEmpty);
    });

    test('the music block moves and trims like any other', () {
      // that is the point of the phase: once placed, it is a regular clip
      final s = putMusic(
        stateWith([cut(0, 20)]),
        music(),
        atS: 0,
        durationS: 10,
      );
      final id = s.layers.last.clips.single.id;

      final movedClip = moveBlock(s, id, 4, beats: const [], snap: false);
      expect(movedClip.layers.last.clips.single.atS, 4);

      final trimmed = trimBlock(movedClip, id, 9, beats: const [], snap: false);
      expect(trimmed.layers.last.clips.single.durationS, 5);
    });

    test('undo removes the music from the timeline', () {
      final h = MontageHistory(stateWith([cut(0, 2)]));
      h.apply(putMusic(h.present, music(), atS: 0));
      expect(h.present.layers.last.clips, hasLength(1));

      h.undo();
      expect(h.present.layers.any((l) => l.isAudio), isFalse);
    });
  });

  group('position in the frame', () {
    test('moving the text changes the transform, and nothing else', () {
      // that is what dragging on the monitor does: the same maths as the server, as
      // a fraction of half the frame
      final s = stateWith([cut(0, 2)]);
      final id = s.clips.first.id;

      final afterState = positionOnFrame(s, id, x: 0.5, y: -0.25);

      expect(afterState.clips.first.transform.x, 0.5);
      expect(afterState.clips.first.transform.y, -0.25);
      expect(afterState.clips.first.transform.scale, 1.0);
      expect(afterState.clips.first.atS, 0, reason: 'the position on the timeline does not change');
      expect(s.clips.first.transform.x, 0, reason: 'the previous state stayed');
    });

    test('does not let the content leave the frame', () {
      // a clip that does not show is indistinguishable from one that vanished
      final s = stateWith([cut(0, 2)]);
      final id = s.clips.first.id;

      final afterState = positionOnFrame(s, id, x: 9, y: -9);

      expect(afterState.clips.first.transform.x, 1.0);
      expect(afterState.clips.first.transform.y, -1.0);
    });

    test('moving a clip that no longer exists does not blow up', () {
      final s = stateWith([cut(0, 2)]);
      expect(positionOnFrame(s, 'ghost', x: 0.5), same(s));
    });
  });

  group('layer order', () {
    test('reordering swaps who stays on top', () {
      // the list order is the order the server draws in: the last one wins
      final s = layeredState([cut(0, 2)], [cut(0, 2)]);
      final lowerId = s.layers[0].clips.first.id;

      final afterState = reorderLayers(s, 0, 1);

      expect(afterState.layers[1].clips.first.id, lowerId);
      expect(afterState.activeLayer, 1, reason: 'the focus follows the moved layer');
      expect(s.layers[0].clips.first.id, lowerId, reason: 'the previous one stayed');
    });

    test('what the monitor shows follows the new order', () {
      // two clips at the same instant: what shows is the top layer's
      final s = layeredState([cut(0, 2)], [cut(0, 2)]);
      final upperId = s.layers[1].clips.first.id;
      expect(s.visibleClips.single.id, upperId);

      final afterState = reorderLayers(s, 1, 0);
      expect(afterState.visibleClips.single.id, isNot(upperId));
    });

    test('an index outside the list does nothing', () {
      final s = layeredState([cut(0, 2)], [cut(0, 2)]);
      expect(reorderLayers(s, 0, 5), same(s));
      expect(reorderLayers(s, -1, 0), same(s));
      expect(reorderLayers(s, 1, 1), same(s));
    });

    test('reordering goes into undo', () {
      final h = MontageHistory(layeredState([cut(0, 2)], [cut(4, 2)]));
      final lowerId = h.present.layers[0].clips.first.id;

      h.apply(reorderLayers(h.present, 0, 1));
      expect(h.present.layers[1].clips.first.id, lowerId);

      h.undo();
      expect(h.present.layers[0].clips.first.id, lowerId);
    });
  });

  group('aligning the play', () {
    /// Aligns and returns the state — the recording is long, and there is room to slide.
    MontageState align(MontageState s, String id, double target) =>
        alignMoment(s, id, target, sourceDurationS: 600)!.state;

    test('the block moves to put the play at the requested point', () {
      // it is the reason it exists: the cut starts before the play, and moving by
      // the edge would leave the impact half a second after the beat
      final s = stateWith([cut(0, 2, t: 90)]); // play 1.4s from the start
      final id = s.clips.first.id;

      final afterState = align(s, id, 5);

      expect(momentInVideo(afterState.clips.first), closeTo(5, 1e-9));
      expect(afterState.clips.first.atS, closeTo(3.6, 1e-9));
      expect(afterState.clips.first.durationS, 2, reason: 'neither stretches nor trims');
      expect(s.clips.first.atS, 0, reason: 'the previous state stayed');
    });

    test('against the first frame, it is the span that slides', () {
      // asking for the play at 0.5s would take the block start to -0.9; instead of
      // stopping at the edge and aligning nothing, the span moves inside the block
      final s = stateWith([cut(0, 2, t: 90)]);
      final done = alignMoment(
        s,
        s.clips.first.id,
        0.5,
        sourceDurationS: 600,
      )!;

      expect(done.didSlide, isTrue);
      expect(done.state.clips.first.atS, 0);
      expect(momentInVideo(done.state.clips.first), closeTo(0.5, 1e-9));
    });

    test('with the neighbour in the way, the span slides inside the block', () {
      // in a montage of back-to-back blocks the block has nowhere to go; what is
      // left is changing *which* piece of the recording shows there, and the play
      // comes to the cursor without touching any neighbour
      final s = stateWith([cut(0, 2, t: 90), cut(2, 2, t: 200)]);
      final id = s.clips.first.id;

      final done = alignMoment(s, id, 0.5, sourceDurationS: 600)!;

      expect(done.didSlide, isTrue);
      expect(done.state.clips.first.atS, 0, reason: 'the block stayed');
      expect(momentInVideo(done.state.clips.first), closeTo(0.5, 1e-9));
      expect(done.state.clips.first.startS, closeTo(89.5, 1e-9));
      expect(done.state.clips[1].atS, 2, reason: 'the neighbour did not move');
    });

    test('moving the block is the preferred path', () {
      // it keeps the run-up: the same span of the recording, at another instant
      final s = stateWith([cut(0, 2, t: 90)]);
      final done = alignMoment(
        s,
        s.clips.first.id,
        5,
        sourceDurationS: 600,
      )!;

      expect(done.didSlide, isFalse);
      expect(done.state.clips.first.startS, s.clips.first.startS);
    });

    test('without recording to slide, there is no alignment to do', () {
      // the play is 1.4s from the block start and the recording ends right there
      final s = stateWith([cut(0, 2, t: 1.4), cut(2, 2, t: 200)]);
      expect(
        alignMoment(s, s.clips.first.id, 1.9, sourceDurationS: 2.0),
        isNull,
      );
    });

    test('a block without a play is not aligned', () {
      final s = putMusic(
        stateWith([cut(0, 2)]),
        Track(
          id: 'm1',
          status: 'ready',
          name: 'track.mp3',
          durationS: 60,
          bpm: 120,
          beats: const [],
          peaks: const [],
          audioUrl: '',
        ),
        atS: 0,
      );
      final block = s.layers.last.clips.single.id;
      expect(alignMoment(s, block, 3, sourceDurationS: 600), isNull);
    });

    test('aligning goes into undo', () {
      final h = MontageHistory(stateWith([cut(0, 2, t: 90)]));
      final id = h.present.clips.first.id;

      h.apply(align(h.present, id, 5));
      expect(h.present.clips.first.atS, closeTo(3.6, 1e-9));

      h.undo();
      expect(h.present.clips.first.atS, 0);
    });
  });

  group('transitions', () {
    const dissolve = ClipTransition(kind: 'dissolve', durationS: 0.5);

    test('applying sets the entrance on the given clips, and only them', () {
      final s = stateWith([cut(0, 2), cut(2, 2, t: 40)]);
      final [a, b] = s.clips;

      final after = applyTransition(s, [b.id], dissolve);

      expect(after.clipItem(b.id)!.transition, dissolve);
      expect(after.clipItem(a.id)!.transition, isNull);
      expect(s.clipItem(b.id)!.transition, isNull, reason: 'the old state stays');
    });

    test('null clears it', () {
      var s = stateWith([cut(0, 2)]);
      final id = s.clips.single.id;
      s = applyTransition(s, [id], dissolve);

      expect(applyTransition(s, [id], null).clipItem(id)!.transition, isNull);
    });

    test('a locked layer does not change', () {
      var s = stateWith([cut(0, 2)]);
      final id = s.clips.single.id;
      s = adjustLayer(s, 0, locked: true);

      expect(applyTransition(s, [id], dissolve), same(s));
    });

    test('splitting keeps the entrance on the left half only', () {
      // the right half carries on where the other stopped: a transition there
      // would show up mid-scene
      var s = stateWith([cut(0, 4)]);
      final id = s.clips.single.id;
      s = applyTransition(s, [id], dissolve);

      final [left, right] = split(s, id, 2).clips;
      expect(left.transition, dissolve);
      expect(right.transition, isNull);
    });
  });
}
