import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart';
import 'package:ow_editor/monitor/frame.dart';
import 'package:ow_editor/montage_state.dart';
import 'package:ow_editor/widgets/highlight_style.dart';

/// Wipes, zoom, spin, glitch — and landing cuts on the beat.
void main() {
  final before = TimelineClip(id: 'a', atS: 0, durationS: 2, startS: 10);
  TimelineClip after(String kind) => TimelineClip(
    id: 'b',
    atS: 2,
    durationS: 2,
    startS: 50,
    transition: ClipTransition(kind: kind, durationS: 1),
  );

  List<FramePiece> at(String kind, double t) => frameAt(
    [Layer(clips: [before, after(kind)])],
    t,
    matchUrl: 'x.mp4',
  ).pieces;

  test('the list offers every kind the server knows', () {
    expect(
      {for (final t in TransitionType.all) t.kind},
      {
        'dissolve', 'fade_black', 'fade_white',
        'slide_left', 'slide_right', 'slide_up', 'slide_down',
        'wipe_left', 'wipe_right', 'wipe_up', 'wipe_down',
        'zoom', 'spin', 'glitch',
      },
    );
  });

  test('a wipe half-way covers half the frame, over the clip before', () {
    final pieces = at('wipe_left', 2.5);
    expect(pieces, hasLength(2), reason: 'the clip before runs on underneath');
    expect(pieces.last.wipe.left, closeTo(0.5, 1e-9));
    expect(at('wipe_down', 2.25).last.wipe.bottom, closeTo(0.75, 1e-9));
    expect(at('wipe_left', 3.5).single.wipe.left, 0, reason: 'done');
  });

  test('zoom and spin come in large or turned, and see-through', () {
    final zoom = at('zoom', 2.2).last;
    expect(zoom.scale, greaterThan(1.2));
    expect(zoom.opacity, closeTo(0.2, 1e-9));
    final spin = at('spin', 2.2).last;
    expect(spin.scale, lessThan(0.6));
    expect(spin.turn, lessThan(-100));
    expect(at('spin', 3.5).single.turn, 0);
  });

  test('the glitch is a hard cut that jolts', () {
    final pieces = at('glitch', 2.1);
    expect(pieces, hasLength(1), reason: 'nothing runs on underneath');
    expect(pieces.single.offsetX, isNot(0));
  });

  test('landing on the beat moves entrances to the nearest beat if there is room', () {
    var s = MontageState(
      layers: [
        Layer(
          clips: [
            TimelineClip(id: 'a', atS: 0.1, durationS: 1, startS: 0),
            TimelineClip(id: 'b', atS: 2.9, durationS: 1, startS: 0),
            TimelineClip(id: 'c', atS: 4.6, durationS: 1, startS: 0),
          ],
        ),
      ],
    );
    final (out, moved) = landOnBeats(s, {'a', 'b', 'c'}, const [0, 2, 3.5, 4]);
    expect(out.clipItem('a')!.atS, 0);
    expect(out.clipItem('b')!.atS, 3.5);
    expect(out.clipItem('c')!.atS, 4.6, reason: 'b now runs until 4.5');
    expect(moved, 2);
    expect(landOnBeats(s, {'a'}, const []).$2, 0);
  });
}
