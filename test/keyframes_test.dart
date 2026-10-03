import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart';
import 'package:ow_editor/monitor/frame.dart';
import 'package:ow_editor/montage.dart';
import 'package:ow_editor/montage_state.dart';

/// Keyframes and easing: the curve maths (the server's `_curve`), the
/// operations the Motion panel calls, and what reaches the monitor.
void main() {
  TimelineClip clip({List<ClipKey> keys = const [], double dur = 4}) =>
      TimelineClip(id: 'c', atS: 10, durationS: dur, startS: 100, keys: keys);

  MontageState stateWith(TimelineClip c) => MontageState(
    layers: [
      Layer(clips: [c]),
    ],
  );

  TimelineClip only(MontageState s) => s.layers.single.clips.single;

  group('the curve', () {
    const k0 = ClipKey(prop: KeyProp.opacity, t: 0, value: 0);
    const k1 = ClipKey(prop: KeyProp.opacity, t: 1, value: 1);

    test('linear by default, holding the endpoints outside', () {
      final c = clip(keys: [k1, k0]);
      expect(valueAt(c, KeyProp.opacity, -1), 0);
      expect(valueAt(c, KeyProp.opacity, 2), closeTo(0.5, 1e-9));
      expect(valueAt(c, KeyProp.opacity, 9), 1);
    });

    test('each ease bends the stretch that leaves its keyframe', () {
      double half(Ease e) => valueAt(
        clip(
          keys: [
            k0.copyWith(ease: e),
            k1,
          ],
        ),
        KeyProp.opacity,
        2,
      );
      expect(half(Ease.easeIn), closeTo(0.25, 1e-9));
      expect(half(Ease.easeOut), closeTo(0.75, 1e-9));
      expect(half(Ease.easeInOut), closeTo(0.5, 1e-9));
      // smoothstep is slow near the ends
      expect(
        valueAt(
          clip(
            keys: [
              k0.copyWith(ease: Ease.easeInOut),
              k1,
            ],
          ),
          KeyProp.opacity,
          0.4,
        ),
        lessThan(0.1),
      );
    });

    test('a property with no keyframes keeps its static value', () {
      final c = clip().copyWith(
        transform: const ClipTransform(scale: 0.5),
        audio: const ClipAudio(volume: 0.3),
      );
      expect(valueAt(c, KeyProp.scale, 1), 0.5);
      expect(valueAt(c, KeyProp.volume, 1), 0.3);
    });
  });

  group('the Motion operations', () {
    test('a static property sets one value for the whole clip', () {
      final s = setMotion(
        stateWith(clip()),
        'c',
        KeyProp.scale,
        0.4,
        localS: 1,
      );
      expect(only(s).transform.scale, 0.4);
      expect(only(s).keys, isEmpty);
    });

    test(
      'animating starts with a keyframe at the playhead, holding the value',
      () {
        final base = stateWith(
          clip().copyWith(transform: const ClipTransform(opacity: 0.8)),
        );
        final s = animateMotion(
          base,
          'c',
          KeyProp.opacity,
          on: true,
          localS: 1,
        );
        final key = only(s).keysFor(KeyProp.opacity).single;
        expect(key.t, closeTo(0.25, 1e-9));
        expect(key.value, 0.8);
      },
    );

    test('adjusting elsewhere adds a keyframe; on one, it changes it', () {
      var s = animateMotion(
        stateWith(clip()),
        'c',
        KeyProp.x,
        on: true,
        localS: 0,
      );
      s = setMotion(s, 'c', KeyProp.x, 0.6, localS: 4);
      expect(only(s).keysFor(KeyProp.x).map((k) => k.value), [0, 0.6]);

      s = setMotion(s, 'c', KeyProp.x, -0.2, localS: 4.01);
      expect(only(s).keysFor(KeyProp.x).map((k) => k.value), [
        0,
        -0.2,
      ], reason: 'within a frame it is the same keyframe');
    });

    test('turning animation off keeps the value at the playhead', () {
      var s = animateMotion(
        stateWith(clip()),
        'c',
        KeyProp.x,
        on: true,
        localS: 0,
      );
      s = setMotion(s, 'c', KeyProp.x, 1, localS: 4);
      s = animateMotion(s, 'c', KeyProp.x, on: false, localS: 2);
      expect(only(s).keys, isEmpty);
      expect(only(s).transform.x, closeTo(0.5, 1e-9));
    });

    test('removing the last keyframe ends the animation', () {
      var s = animateMotion(
        stateWith(clip()),
        'c',
        KeyProp.volume,
        on: true,
        localS: 1,
      );
      s = setMotion(s, 'c', KeyProp.volume, 0.2, localS: 1);
      s = removeMotionKey(s, 'c', KeyProp.volume, localS: 1);
      expect(only(s).keys, isEmpty);
      expect(only(s).audio.volume, 0.2);
    });

    test('the ease belongs to the keyframe under the playhead', () {
      var s = animateMotion(
        stateWith(clip()),
        'c',
        KeyProp.y,
        on: true,
        localS: 0,
      );
      s = easeMotionKey(s, 'c', KeyProp.y, Ease.easeOut, localS: 0);
      expect(only(s).keys.single.ease, Ease.easeOut);
      expect(
        easeMotionKey(s, 'c', KeyProp.y, Ease.easeIn, localS: 2),
        same(s),
        reason: 'no keyframe there',
      );
    });

    test('values stay in range', () {
      final s = setMotion(
        stateWith(clip()),
        'c',
        KeyProp.opacity,
        3,
        localS: 0,
      );
      expect(only(s).transform.opacity, 1);
    });
  });

  group('on the monitor', () {
    Frame at(TimelineClip c, double t, {List<TimelineClip> after = const []}) =>
        frameAt(
          [
            Layer(clips: [c, ...after]),
          ],
          t,
          matchUrl: 'm',
        );

    test('keyframed opacity, position and scale reach the piece', () {
      final c = clip(
        keys: const [
          ClipKey(prop: KeyProp.opacity, t: 0, value: 0),
          ClipKey(prop: KeyProp.opacity, t: 1, value: 1),
          ClipKey(prop: KeyProp.x, t: 0, value: -1),
          ClipKey(prop: KeyProp.x, t: 1, value: 1),
          ClipKey(prop: KeyProp.scale, t: 0.5, value: 0.5),
        ],
      );
      final p = at(c, 12).pieces.single;
      expect(p.opacity, closeTo(0.5, 1e-9));
      expect(p.offsetX, closeTo(0, 1e-9));
      expect(p.scale, 0.5);
    });

    test('the zoom runs on the clip as placed, not on its dissolve tail', () {
      final c = clip(
        dur: 2,
      ).copyWith(atS: 0, zoom: const [ZoomKey(t: 0), ZoomKey(t: 1, scale: 2)]);
      final next = TimelineClip(
        id: 'n',
        atS: 2,
        durationS: 2,
        startS: 300,
        transition: const ClipTransition(kind: 'dissolve', durationS: 1),
      );
      // at the cut the zoom is complete, though the picture runs on underneath
      expect(at(c, 1.99, after: [next]).pieces.first.zoom, closeTo(2, 0.01));
      expect(at(c, 2.5, after: [next]).pieces.first.zoom, 2);
    });

    test('a smooth zoom eases in and out', () {
      final c = clip(dur: 2).copyWith(
        atS: 0,
        zoom: const [
          ZoomKey(t: 0, ease: Ease.easeInOut),
          ZoomKey(t: 1, scale: 2),
        ],
      );
      expect(at(c, 0.2).pieces.single.zoom, lessThan(1.05));
      expect(at(c, 1).pieces.single.zoom, closeTo(1.5, 1e-9));
    });
  });

  group('on the wire', () {
    test('keyframes and eases go to the server and come back', () {
      final c =
          clip(
            keys: const [
              ClipKey(
                prop: KeyProp.scale,
                t: 0.5,
                value: 0.4,
                ease: Ease.easeIn,
              ),
            ],
          ).copyWith(
            zoom: const [
              ZoomKey(t: 0, ease: Ease.easeOut),
              ZoomKey(t: 1),
            ],
          );
      final json = c.toJson();
      expect(json['keys'], [
        {'prop': 'scale', 't': 0.5, 'value': 0.4, 'ease': 'in'},
      ]);
      expect((json['zoom'] as List).first['ease'], 'out');

      final back = TimelineClip.fromJson(json);
      expect(back.keys.single.ease, Ease.easeIn);
      expect(back.zoom.first.ease, Ease.easeOut);
    });

    test('a property this app does not know is skipped, not a crash', () {
      final back = TimelineClip.fromJson({
        'at_s': 0,
        'duration_s': 1,
        'start_s': 0,
        'keys': [
          {'prop': 'rotation', 't': 0, 'value': 1},
          {'prop': 'x', 't': 0, 'value': 1},
        ],
      });
      expect(back.keys.single.prop, KeyProp.x);
    });
  });
}
