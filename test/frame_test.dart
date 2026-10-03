import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart';
import 'package:ow_editor/monitor/frame.dart';

/// The monitor's frame maths, checked against the server's rules
/// (`owcore/compose.py`): what is on screen at an instant, and how.
void main() {
  const match = 'http://x/match-proxy.mp4';

  TimelineClip clip(
    String id,
    double at,
    double dur, {
    double start = 100,
    double speed = 1,
    bool freeze = false,
    bool reverse = false,
    ClipTransition? transition,
    ClipFade fade = const ClipFade(),
    ClipTransform transform = const ClipTransform(),
    List<ZoomKey> zoom = const [],
    String source = 'recording',
    String? mediaId,
  }) => TimelineClip(
    id: id,
    atS: at,
    durationS: dur,
    startS: start,
    speed: speed,
    freeze: freeze,
    reverse: reverse,
    transition: transition,
    fade: fade,
    transform: transform,
    zoom: zoom,
    source: source,
    mediaId: mediaId,
  );

  Frame at(
    List<Layer> layers,
    double t, {
    Map<String, Media> library = const {},
    ExportSpec export = const ExportSpec(),
  }) => frameAt(layers, t, matchUrl: match, library: library, export: export);

  FramePiece only(Frame f) => f.pieces.single;

  group('what is on screen', () {
    test('every visible picture layer, from the bottom up', () {
      final layers = [
        Layer(clips: [clip('a', 0, 4)]),
        Layer(clips: [clip('b', 1, 2)]),
      ];
      expect([for (final p in at(layers, 1.5).pieces) p.clipId], ['a', 'b']);
      expect([for (final p in at(layers, 3.5).pieces) p.clipId], ['a']);
    });

    test('hidden layers, sound layers and text are left out', () {
      final layers = [
        Layer(hidden: true, clips: [clip('hidden', 0, 4)]),
        Layer(kind: 'audio', clips: [clip('song', 0, 4)]),
        Layer(clips: [clip('text', 0, 4, source: 'text')]),
      ];
      expect(at(layers, 1).isBlack, isTrue);
    });

    test('a gap is black', () {
      final layers = [
        Layer(clips: [clip('a', 0, 1), clip('b', 2, 1)]),
      ];
      expect(at(layers, 1.5).isBlack, isTrue);
    });
  });

  group('where in the source', () {
    test('the speed is how much source each second eats', () {
      final p = only(
        at([
          Layer(clips: [clip('a', 2, 4, speed: 2)]),
        ], 3),
      );
      expect(p.sourceT, closeTo(102, 1e-9));
      expect(p.rate, 2);
      expect(p.seekEachFrame, isFalse);
    });

    test('a frozen clip stays on its first frame', () {
      final p = only(
        at([
          Layer(clips: [clip('a', 0, 4, freeze: true)]),
        ], 3),
      );
      expect(p.sourceT, 100);
      expect(p.seekEachFrame, isTrue);
    });

    test('a reversed clip runs from its end back to its start', () {
      final layers = [
        Layer(clips: [clip('a', 0, 4, reverse: true)]),
      ];
      expect(only(at(layers, 0)).sourceT, closeTo(104, 1e-9));
      expect(only(at(layers, 3)).sourceT, closeTo(101, 1e-9));
    });
  });

  group('transitions', () {
    final dissolve = [
      Layer(
        clips: [
          clip('a', 0, 2),
          clip(
            'b',
            2,
            2,
            start: 300,
            transition: const ClipTransition(kind: 'dissolve', durationS: 1),
          ),
        ],
      ),
    ];

    test('under a dissolve the clip before keeps running underneath', () {
      // the server lengthens its picture by the transition: both are on screen
      final f = at(dissolve, 2.5);
      expect([for (final p in f.pieces) p.clipId], ['a', 'b']);
      expect(f.pieces.first.sourceT, closeTo(102.5, 1e-9));
      expect(f.pieces.first.opacity, 1);
      expect(f.pieces.last.opacity, closeTo(0.5, 1e-9));
    });

    test('once the dissolve is over, only the new clip is left', () {
      expect([for (final p in at(dissolve, 3.2).pieces) p.clipId], ['b']);
    });

    test('a dip darkens the way out and clears the way in', () {
      final layers = [
        Layer(
          clips: [
            clip('a', 0, 2),
            clip(
              'b',
              2,
              2,
              transition: const ClipTransition(
                kind: 'fade_black',
                durationS: 1,
              ),
            ),
          ],
        ),
      ];
      final out = only(at(layers, 1.75));
      expect(out.veil, '#000000');
      expect(out.veilOpacity, closeTo(0.5, 1e-9));
      final into = only(at(layers, 2.25));
      expect(into.clipId, 'b');
      expect(into.veilOpacity, closeTo(0.5, 1e-9));
      expect(only(at(layers, 2.6)).veil, isNull);
    });

    test('a slide comes in from the side opposite its movement', () {
      final layers = [
        Layer(
          clips: [
            clip(
              'a',
              0,
              2,
              transition: const ClipTransition(
                kind: 'slide_left',
                durationS: 1,
              ),
            ),
          ],
        ),
      ];
      expect(only(at(layers, 0)).offsetX, closeTo(1, 1e-9));
      expect(only(at(layers, 0.5)).offsetX, closeTo(0.5, 1e-9));
      expect(only(at(layers, 1.5)).offsetX, 0);
    });
  });

  group('alpha, lens and place', () {
    test('fades and the clip opacity multiply', () {
      final layers = [
        Layer(
          clips: [
            clip(
              'a',
              0,
              4,
              fade: const ClipFade(inS: 1, outS: 1),
              transform: const ClipTransform(opacity: 0.5),
            ),
          ],
        ),
      ];
      expect(only(at(layers, 0.5)).opacity, closeTo(0.25, 1e-9));
      expect(only(at(layers, 2)).opacity, closeTo(0.5, 1e-9));
      expect(only(at(layers, 3.5)).opacity, closeTo(0.25, 1e-9));
    });

    test('the zoom follows its keyframes, as fractions of the clip', () {
      final layers = [
        Layer(
          clips: [
            clip(
              'a',
              0,
              4,
              zoom: const [ZoomKey(t: 0), ZoomKey(t: 1, scale: 2, x: 1)],
            ),
          ],
        ),
      ];
      final p = only(at(layers, 2));
      expect(p.zoom, closeTo(1.5, 1e-9));
      // the server's window: (iw - iw/zoom) * (0.5 + x/2)
      expect(p.zoomLeft, closeTo((1 - 1 / 1.5) * (0.5 + 0.25), 1e-9));
      expect(p.zoomTop, closeTo((1 - 1 / 1.5) * 0.5, 1e-9));
    });

    test('the place is measured from the centre in half frames', () {
      final layers = [
        Layer(
          clips: [
            clip(
              'a',
              0,
              4,
              transform: const ClipTransform(scale: 0.4, x: 0.5, y: -1),
            ),
          ],
        ),
      ];
      final p = only(at(layers, 1));
      expect(p.scale, 0.4);
      expect(p.offsetX, 0.25);
      expect(p.offsetY, -0.5);
    });

    test('the fit comes from the export', () {
      final layers = [
        Layer(clips: [clip('a', 0, 4)]),
      ];
      final p = only(at(layers, 1, export: const ExportSpec(fit: 'contain')));
      expect(p.fit, 'contain');
    });
  });

  group('sources', () {
    final library = {
      'v1': Media(
        id: 'v1',
        kind: 'video',
        status: 'ready',
        name: 'intro.mp4',
        durationS: 10,
        proxyUrl: 'http://x/v1-proxy',
        fileUrl: 'http://x/v1-file',
      ),
      'i1': Media(
        id: 'i1',
        kind: 'image',
        status: 'ready',
        name: 'logo.png',
        durationS: 0,
        thumbUrl: 'http://x/i1-thumb',
        fileUrl: 'http://x/i1-file',
      ),
    };

    test('a library video plays its own proxy, not the match', () {
      // the old monitor only knew the match: an imported clip showed the
      // recording at the wrong instant
      final layers = [
        Layer(
          clips: [clip('a', 0, 4, source: 'media', mediaId: 'v1')],
        ),
      ];
      final p = only(at(layers, 1, library: library));
      expect(p.url, 'http://x/v1-proxy');
      expect(p.kind, PieceKind.video);
    });

    test('an image shows its file', () {
      final layers = [
        Layer(
          clips: [clip('a', 0, 4, source: 'media', mediaId: 'i1')],
        ),
      ];
      final p = only(at(layers, 1, library: library));
      expect(p.url, 'http://x/i1-file');
      expect(p.kind, PieceKind.image);
    });

    test('a clip whose media is gone is left out', () {
      final layers = [
        Layer(
          clips: [clip('a', 0, 4, source: 'media', mediaId: 'nope')],
        ),
      ];
      expect(at(layers, 1, library: library).isBlack, isTrue);
    });

    test('the match clips show the match', () {
      expect(
        only(
          at([
            Layer(clips: [clip('a', 0, 4)]),
          ], 1),
        ).url,
        match,
      );
    });

    test('the watermark sits where the server puts it', () {
      final f = at(
        const [],
        0,
        library: library,
        export: const ExportSpec(
          watermarkId: 'i1',
          watermarkX: 1,
          watermarkY: -1,
        ),
      );
      expect(f.watermark?.url, 'http://x/i1-file');
      expect(f.watermark?.centreX, 1);
      expect(f.watermark?.centreY, 0);
    });
  });

  test('the frame takes the export shape, or the recording one', () {
    expect(
      frameAspect(const ExportSpec(width: 1080, height: 1920)),
      1080 / 1920,
    );
    expect(
      frameAspect(const ExportSpec(), width: 1280, height: 720),
      1280 / 720,
    );
    expect(frameAspect(const ExportSpec()), 16 / 9);
  });
}
