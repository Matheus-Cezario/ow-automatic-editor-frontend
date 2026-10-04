import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart';
import 'package:ow_editor/montage_state.dart';

/// Copy and paste effects: the look of one clip on others; their cuts stay.
void main() {
  final styled = TimelineClip(
    id: 'src',
    atS: 0,
    durationS: 4,
    startS: 100,
    color: const ClipColor(brightness: 0.2, saturation: 1.5),
    fade: const ClipFade(inS: 1, outS: 1),
    zoom: const [ZoomKey(t: 0), ZoomKey(t: 1, scale: 2)],
    transform: const ClipTransform(scale: 0.5, x: 0.3),
    keys: const [
      ClipKey(prop: KeyProp.opacity, t: 0, value: 0),
      ClipKey(prop: KeyProp.opacity, t: 1, value: 1),
      ClipKey(prop: KeyProp.volume, t: 0, value: 0.5),
    ],
    speed: 1.5,
    transition: const ClipTransition(kind: 'dissolve', durationS: 1),
  );

  MontageState state(
    List<TimelineClip> pictures, [
    List<TimelineClip> music = const [],
  ]) => MontageState(
    layers: [
      Layer(clips: [styled, ...pictures]),
      Layer(kind: 'audio', clips: music),
    ],
  );

  test('a picture clip takes the look and keeps its cut', () {
    final target = TimelineClip(id: 't', atS: 10, durationS: 3, startS: 500);
    final s = pasteEffects(state([target]), {'t'}, styled);
    final t = s.clipItem('t')!;
    expect((t.atS, t.durationS, t.startS), (10.0, 3.0, 500.0));
    expect(t.color.brightness, 0.2);
    expect(t.zoom, hasLength(2));
    expect(t.transform.scale, 0.5);
    expect(t.keys, hasLength(3));
    expect(t.speed, 1.5);
    expect(t.transition?.kind, 'dissolve');
  });

  test('fades and the transition shrink to fit a short clip', () {
    final short = TimelineClip(id: 't', atS: 10, durationS: 1, startS: 500);
    final t = pasteEffects(state([short]), {'t'}, styled).clipItem('t')!;
    expect(t.fade.inS + t.fade.outS, closeTo(1, 1e-9));
    expect(t.transition?.durationS, 0.5);
  });

  test('a music block takes only its sound', () {
    final song = TimelineClip(
      id: 'm',
      atS: 0,
      durationS: 30,
      startS: 0,
      source: 'media',
      mediaId: 'song',
    );
    final m = pasteEffects(state(const [], [song]), {
      'm',
    }, styled).clipItem('m')!;
    expect(m.keys.single.prop, KeyProp.volume);
    expect(m.zoom, isEmpty);
    expect(m.color.isNeutral, isTrue);
  });

  test('a text takes the text style from a text', () {
    TimelineClip text(String id, ClipTextStyle st) => TimelineClip(
      id: id,
      atS: 0,
      durationS: 2,
      startS: 0,
      source: 'text',
      text: 'ACE',
      textStyle: st,
    );
    final from = text(
      'a',
      const ClipTextStyle(font: 'anton', animIn: TextAnim.pop),
    );
    final s = MontageState(
      layers: [
        Layer(clips: [from, text('b', const ClipTextStyle()).copyWith(atS: 5)]),
      ],
    );
    final b = pasteEffects(s, {'b'}, from).clipItem('b')!;
    expect((b.textStyle.font, b.textStyle.animIn), ('anton', TextAnim.pop));
    expect(b.text, 'ACE');
  });

  test("a clip without a transition clears the target's", () {
    final plain = TimelineClip(id: 'p', atS: 20, durationS: 2, startS: 0);
    final t = pasteEffects(state([plain]), {'src'}, plain).clipItem('src')!;
    expect(t.transition, isNull);
  });
}
