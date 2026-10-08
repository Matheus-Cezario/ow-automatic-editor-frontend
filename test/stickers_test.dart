import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart';
import 'package:ow_editor/monitor/frame.dart';
import 'package:ow_editor/montage.dart';
import 'package:ow_editor/montage_state.dart';
import 'package:ow_editor/screens/timeline_screen.dart';
import 'package:ow_editor/widgets/music_timeline.dart';
import 'package:ow_editor/widgets/sticker_shelf.dart';

import 'timeline_screen_test.dart' show jobJson;

/// The stickers library, and pictures placed whole on the frame: browsing,
/// a sticker landing over the gameplay (never on it), and the monitor
/// drawing it whole as the server does.
void main() {
  final libraryJson = {
    'categories': ['point', 'mark', 'game', 'fun'],
    'colors': [
      {'id': 'red', 'hex': '#ff3b30'},
      {'id': 'blue', 'hex': '#0a84ff'},
    ],
    'stickers': [
      {
        'id': 'arrow',
        'name': 'Arrow',
        'category': 'point',
        'preview_url': '/api/stickers/arrow.png',
      },
      {
        'id': 'skull',
        'name': 'Skull',
        'category': 'game',
        'preview_url': '/api/stickers/skull.png',
      },
    ],
  };

  Media sticker(String id) => Media(
    id: id,
    kind: 'image',
    status: 'ready',
    name: 'Arrow (red)',
    durationS: 0,
    width: 512,
    height: 512,
    fileUrl: 'http://localhost/api/media/$id/file',
    stickerId: 'arrow:red',
  );

  group('the wire', () {
    test('the library reads with its colours and groups in order', () {
      final lib = StickerLibrary.fromJson(libraryJson);
      expect(lib.categories, ['point', 'mark', 'game', 'fun']);
      expect(lib.colors.map((c) => c.id), ['red', 'blue']);
      expect(lib.stickers.map((s) => s.id), ['arrow', 'skull']);
      expect(
        lib.stickers.first.previewIn('blue'),
        endsWith('/api/stickers/arrow.png?color=blue'),
      );
    });

    test('a library item drawn from a sticker says so', () {
      final item = Media.fromJson({
        'id': 'x',
        'kind': 'image',
        'status': 'ready',
        'sticker_id': 'arrow:red',
      });
      expect(item.isSticker, isTrue);
      expect(item.isImage, isTrue);
      final upload = Media.fromJson({'id': 'y', 'kind': 'image'});
      expect(upload.isSticker, isFalse);
    });

    test('a clip placed whole goes to the server, and comes back, as one', () {
      final clip = stickerClip(sticker('s1'), atS: 3);
      final json = clip.toJson();
      expect(json['fit'], 'contain');
      expect(json['media_id'], 's1');
      expect((json['transform'] as Map)['scale'], kStickerScale);
      expect(clip.simple, isFalse);

      final back = TimelineClip.fromJson(json);
      expect(back.fit, 'contain');
      // a clip without one follows the export, and sends nothing
      final plain = back.copyWith(clearFit: true);
      expect(plain.fit, isNull);
      expect(plain.toJson().containsKey('fit'), isFalse);
    });

    test('a sticker comes in small, in the middle, for the image time', () {
      final clip = stickerClip(sticker('s1'), atS: -1);
      expect(clip.atS, 0);
      expect(clip.durationS, sticker('s1').suggestedDuration);
      expect(clip.transform.scale, kStickerScale);
      expect((clip.transform.x, clip.transform.y), (0.0, 0.0));
    });
  });

  group('setFit', () {
    test('turns placing whole on and off', () {
      var s = addClip(
        MontageState.blank(),
        const TimelineClip(
          atS: 0,
          durationS: 2,
          startS: 0,
          source: 'media',
          mediaId: 'logo',
        ),
        beats: const [],
        snap: false,
      );
      final id = s.selectionIds.single;
      s = setFit(s, id, 'contain');
      expect(s.clipItem(id)!.fit, 'contain');
      s = setFit(s, id, null);
      expect(s.clipItem(id)!.fit, isNull);
    });
  });

  group('the monitor', () {
    test('a clip placed whole is drawn whole, whatever the export says', () {
      final layers = [
        Layer(
          clips: [
            const TimelineClip(id: 'a', atS: 0, durationS: 4, startS: 0),
          ],
        ),
        Layer(
          clips: [
            stickerClip(sticker('s1'), atS: 0).copyWith(id: 'st'),
          ],
        ),
      ];
      final frame = frameAt(
        layers,
        1,
        matchUrl: 'http://x/match.mp4',
        library: {'s1': sticker('s1')},
        export: const ExportSpec(fit: 'cover'),
      );
      expect([for (final p in frame.pieces) p.fit], ['cover', 'contain']);
      expect(frame.pieces.last.kind, PieceKind.image);
      expect(frame.pieces.last.scale, kStickerScale);
    });
  });

  group('the shelf', () {
    Future<List<(String, String)>> pumpShelf(
      WidgetTester tester, {
      StickerLibrary? library,
      String? error,
      VoidCallback? onRetry,
    }) async {
      final added = <(String, String)>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: StickerShelf(
                library: library,
                error: error,
                enabled: true,
                onAdd: (s, c) => added.add((s.id, c)),
                onRetry: onRetry,
              ),
            ),
          ),
        ),
      );
      return added;
    }

    testWidgets('adds a sticker in the colour picked', (tester) async {
      final added = await pumpShelf(
        tester,
        library: StickerLibrary.fromJson(libraryJson),
      );
      await tester.tap(find.byKey(const ValueKey('sticker-arrow')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('sticker-colour-blue')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('sticker-skull')));
      await tester.pump();
      expect(added, [('arrow', 'red'), ('skull', 'blue')]);
    });

    testWidgets('filters the stickers by group', (tester) async {
      await pumpShelf(tester, library: StickerLibrary.fromJson(libraryJson));
      expect(find.byKey(const ValueKey('sticker-arrow')), findsOneWidget);
      await tester.tap(find.byKey(const Key('sticker-category-game')));
      await tester.pump();
      expect(find.byKey(const ValueKey('sticker-arrow')), findsNothing);
      expect(find.byKey(const ValueKey('sticker-skull')), findsOneWidget);
    });

    testWidgets('a library that did not load can be asked again', (
      tester,
    ) async {
      var retried = 0;
      await pumpShelf(tester, error: 'offline', onRetry: () => retried++);
      expect(find.text('Could not load the stickers.'), findsOneWidget);
      await tester.tap(find.text('Try again'));
      expect(retried, 1);
    });
  });

  group('the screen', () {
    testWidgets(
      'a sticker lands over the gameplay at the playhead, and can be '
      'switched back to filling the frame',
      (tester) async {
        final api = _FakeApi(StickerLibrary.fromJson(libraryJson));
        await tester.binding.setSurfaceSize(const Size(1000, 2400));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            home: TimelineScreen(job: Job.fromJson(jobJson()), api: api),
          ),
        );
        await tester.pump();

        List<Layer> layers() =>
            tester.widget<MusicTimeline>(find.byType(MusicTimeline)).layers;
        final before = layers();

        await tester.tap(find.text('Library'));
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.ensureVisible(find.byKey(const ValueKey('sticker-skull')));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('sticker-skull')));
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }

        expect(api.added, [('skull', 'red')]);
        final after = layers();
        expect(after, hasLength(before.length + 1));
        final top = after.last;
        expect(top.name, 'Stickers');
        final clip = top.clips.single;
        expect(clip.mediaId, 'st-skull-red');
        expect(clip.fit, 'contain');
        expect(clip.transform.scale, kStickerScale);
        expect(clip.atS, 0, reason: 'at the playhead, which has not moved');
        // the gameplay underneath did not move or change
        expect(after.first.clips.length, before.first.clips.length);
        expect(find.byKey(const ValueKey('media-st-skull-red')), findsOneWidget);

        // the new block is selected: its panel can take it back to filling
        final whole = find.byKey(const Key('clip-fit-whole'));
        await tester.ensureVisible(whole);
        await tester.pump();
        expect(tester.widget<SwitchListTile>(whole).value, isTrue);
        await tester.tap(whole);
        await tester.pump();
        expect(layers().last.clips.single.fit, isNull);
      },
    );
  });
}

class _FakeApi extends ApiClient {
  _FakeApi(this.stickers);

  final StickerLibrary stickers;
  final added = <(String, String)>[];

  @override
  Future<StickerLibrary> listStickers() async => stickers;

  @override
  Future<Media> addSticker({
    required String jobId,
    required String stickerId,
    required String color,
  }) async {
    added.add((stickerId, color));
    return Media(
      id: 'st-$stickerId-$color',
      kind: 'image',
      status: 'ready',
      name: stickerId,
      durationS: 0,
      width: 512,
      height: 512,
      fileUrl: 'http://localhost/api/media/st-$stickerId-$color/file',
      stickerId: '$stickerId:$color',
    );
  }

  @override
  Future<void> requestFrames(String jobId) async {}
}
