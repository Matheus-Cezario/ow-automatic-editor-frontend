import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart';
import 'package:ow_editor/levels.dart';
import 'package:ow_editor/montage_state.dart';
import 'package:ow_editor/screens/timeline_screen.dart';
import 'package:ow_editor/widgets/music_timeline.dart';
import 'package:ow_editor/widgets/sound_shelf.dart';

import 'timeline_screen_test.dart' show jobJson;

/// The sound effects library: browsing it, and an effect landing on the
/// ruler over the music — not after it, as a second song would.
void main() {
  Map<String, dynamic> effectJson(
    String id,
    String name,
    String category,
    double durationS,
  ) => {
    'id': id,
    'name': name,
    'category': category,
    'duration_s': durationS,
    'peaks': [for (var i = 0; i < 64; i++) (i % 8) / 8],
    'audio_url': '/api/sfx/$id/audio',
  };

  final libraryJson = {
    'categories': ['transition', 'impact', 'ui', 'meme'],
    'effects': [
      effectJson('whoosh', 'Whoosh', 'transition', 0.7),
      effectJson('hit', 'Hit', 'impact', 0.5),
      effectJson('ding', 'Ding', 'ui', 1.2),
    ],
  };

  Track sound(String id, double durationS) => Track(
    id: id,
    status: 'ready',
    name: id,
    durationS: durationS,
    bpm: 0,
    beats: const [],
    peaks: const [],
    audioUrl: '',
  );

  Track song() => Track(
    id: 'song',
    status: 'ready',
    name: 'song.mp3',
    durationS: 120,
    bpm: 120,
    beats: [for (var i = 0; i < 240; i++) i * 0.5],
    peaks: const [],
    audioUrl: '',
  );

  group('the wire', () {
    test('the library reads with its groups in order', () {
      final lib = SoundLibrary.fromJson(libraryJson);
      expect(lib.categories, ['transition', 'impact', 'ui', 'meme']);
      expect(lib.effects.map((e) => e.id), ['whoosh', 'hit', 'ding']);
      final whoosh = lib.effects.first;
      expect(whoosh.name, 'Whoosh');
      expect(whoosh.durationS, 0.7);
      expect(whoosh.peaks, hasLength(64));
      expect(whoosh.audioUrl, endsWith('/api/sfx/whoosh/audio'));
    });

    test('a library item made from an effect says so', () {
      final fx = Media.fromJson({
        'id': 'x',
        'kind': 'audio',
        'status': 'ready',
        'name': 'Boom',
        'duration_s': 1.6,
        'sfx_id': 'boom',
        'audio_url': '/api/media/x/file',
      });
      expect(fx.isSoundEffect, isTrue);
      expect(fx.isAudio, isTrue);
      final upload = Media.fromJson({
        'id': 'y',
        'kind': 'audio',
        'sfx_id': null,
      });
      expect(upload.isSoundEffect, isFalse);
    });

    test('an effect block goes to the server as one', () {
      final s = putSoundEffect(MontageState.blank(), sound('fx', 0.7), atS: 1);
      final clip = s.layers.last.clips.single;
      expect(clip.isSoundEffect, isTrue);
      expect(clip.toJson()['kind'], 'sfx');
    });
  });

  group('putSoundEffect', () {
    MontageState withSong() =>
        putMusic(MontageState.blank(), song(), atS: 0, durationS: 10);

    test('goes over the music, at the instant asked, on an effects layer', () {
      final base = withSong();
      final s = putSoundEffect(base, sound('fx', 0.7), atS: 2.5);

      expect(s.layers, hasLength(base.layers.length + 1));
      final effects = s.layers.last;
      expect(effects.isAudio, isTrue);
      expect(effects.name, kEffectsLayerName);
      final clip = effects.clips.single;
      expect(clip.atS, 2.5);
      expect(clip.durationS, 0.7);
      expect(clip.mediaId, 'fx');
      expect(clip.kind, kSoundEffectKind);
      expect(s.selectionIds, {clip.id});
      // the song did not move
      expect(s.layers[s.layers.length - 2].clips.single.atS, 0);
    });

    test('the next effect reuses the effects layer when it is free', () {
      var s = putSoundEffect(withSong(), sound('fx', 0.7), atS: 2.5);
      final layers = s.layers.length;
      // the selection moved to the effects layer; put it back on the song's
      s = s.copyWith(activeLayer: 1);
      s = putSoundEffect(s, sound('hit', 0.5), atS: 5);
      expect(s.layers, hasLength(layers));
      expect(s.layers.last.clips.map((c) => c.atS), [2.5, 5]);
    });

    test('two at the same instant open a second effects layer', () {
      var s = putSoundEffect(withSong(), sound('fx', 0.7), atS: 2.5);
      s = putSoundEffect(s, sound('hit', 0.5), atS: 2.8);
      expect(s.layers.last.name, '$kEffectsLayerName 2');
      expect(s.layers.last.clips.single.atS, 2.8);
      expect(s.layers[s.layers.length - 2].clips.single.atS, 2.5);
    });

    test('a free spot on the chosen sound layer is used', () {
      final base = withSong().copyWith(activeLayer: 1);
      // the song is on layer 1 and ends at 10s
      final s = putSoundEffect(base, sound('fx', 0.7), atS: 12);
      expect(s.layers, hasLength(base.layers.length));
      expect(s.layers[1].clips.map((c) => c.atS), [0, 12]);
    });

    test('a locked effects layer is left alone', () {
      var s = putSoundEffect(withSong(), sound('fx', 0.7), atS: 2.5);
      final i = s.layers.length - 1;
      s = adjustLayer(s, i, locked: true);
      s = putSoundEffect(s, sound('hit', 0.5), atS: 8);
      expect(s.layers[i].clips, hasLength(1));
      expect(s.layers.last.clips.single.atS, 8);
    });

    test('a sound shorter than a block is refused, not stretched', () {
      final base = withSong();
      expect(
        identical(putSoundEffect(base, sound('fx', 0.05), atS: 1), base),
        isTrue,
      );
    });
  });

  group('the mix', () {
    test('an effect alone does not turn the game down', () {
      // with music and the game at 0 the song replaces the game; an effect
      // must not do the same to a montage without a song
      final match = [for (var i = 0; i < 600; i++) 1.0];
      final s = putSoundEffect(
        montageFromDraft(
          const Montage(
            layers: [
              Layer(
                clips: [
                  TimelineClip(atS: 0, durationS: 4, startS: 10, kind: 'kill'),
                ],
              ),
            ],
          ),
        ),
        sound('fx', 0.7),
        atS: 3,
      );
      final level = mixLevelAt(
        s,
        1,
        tracks: {'fx': sound('fx', 0.7)},
        matchWave: match,
        matchDurationS: 600,
      );
      expect(level, greaterThan(0.5));
    });
  });

  group('the shelf', () {
    Future<List<SoundEffect>> pumpShelf(
      WidgetTester tester, {
      SoundLibrary? library,
      String? error,
      VoidCallback? onRetry,
    }) async {
      final added = <SoundEffect>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SoundShelf(
                library: library,
                error: error,
                enabled: true,
                onAdd: added.add,
                onRetry: onRetry,
              ),
            ),
          ),
        ),
      );
      return added;
    }

    testWidgets('lists the effects and filters them by group', (tester) async {
      await pumpShelf(tester, library: SoundLibrary.fromJson(libraryJson));
      expect(find.text('Whoosh'), findsOneWidget);
      expect(find.text('Hit'), findsOneWidget);
      expect(find.text('Ding'), findsOneWidget);
      expect(find.text('0.7 s'), findsOneWidget);

      await tester.tap(find.byKey(const Key('sfx-category-impact')));
      await tester.pump();
      expect(find.text('Whoosh'), findsNothing);
      expect(find.text('Hit'), findsOneWidget);

      await tester.tap(find.byKey(const Key('sfx-category-all')));
      await tester.pump();
      expect(find.text('Whoosh'), findsOneWidget);
    });

    testWidgets('clicking an effect adds it', (tester) async {
      final added = await pumpShelf(
        tester,
        library: SoundLibrary.fromJson(libraryJson),
      );
      await tester.tap(find.text('Hit'));
      await tester.pump();
      expect(added.map((e) => e.id), ['hit']);
    });

    testWidgets('an effect can be dragged onto the ruler', (tester) async {
      await pumpShelf(tester, library: SoundLibrary.fromJson(libraryJson));
      final drag = tester.widget<Draggable<RulerDrop>>(
        find.descendant(
          of: find.byKey(const ValueKey('sfx-whoosh')),
          matching: find.byType(Draggable<RulerDrop>),
        ),
      );
      expect(drag.data!.effect!.id, 'whoosh');
      expect(drag.data!.isSound, isTrue);
      // the ghost under the finger is the size the block will be
      expect(drag.data!.durationSecs, 0.7);
      expect(drag.data!.blockLabel, 'Whoosh');
    });

    testWidgets('a library that did not load can be asked again', (
      tester,
    ) async {
      var retried = 0;
      await pumpShelf(tester, error: 'offline', onRetry: () => retried++);
      expect(find.text('Could not load the sound effects.'), findsOneWidget);
      await tester.tap(find.text('Try again'));
      expect(retried, 1);
    });
  });

  group('the screen', () {
    testWidgets(
      'an effect from the Library lands at the playhead, over the music',
      (tester) async {
        final api = _FakeApi(SoundLibrary.fromJson(libraryJson));
        await tester.binding.setSurfaceSize(const Size(1000, 2400));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            home: TimelineScreen(
              job: Job.fromJson(jobJson(withMusic: true)),
              api: api,
            ),
          ),
        );
        await tester.pump();

        Future<void> tab(String name) async {
          await tester.tap(find.text(name));
          for (var i = 0; i < 5; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
        }

        List<Layer> layers() =>
            tester.widget<MusicTimeline>(find.byType(MusicTimeline)).layers;

        await tab('Library');
        // the song first, as the user would
        await tester.tap(find.byKey(const ValueKey('media-m1')));
        await tester.pump();
        final before = layers().length;

        await tester.ensureVisible(find.text('Whoosh'));
        await tester.pump();
        await tester.tap(find.text('Whoosh'));
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }

        expect(api.added, ['whoosh']);
        final after = layers();
        expect(after, hasLength(before + 1));
        final effect = after.firstWhere((l) => l.name == kEffectsLayerName);
        final clip = effect.clips.single;
        expect(clip.mediaId, 'fx-whoosh');
        expect(clip.kind, 'sfx');
        expect(clip.atS, 0, reason: 'at the playhead, which has not moved');
        expect(clip.durationS, 0.7);
        // the song is where it was
        expect(
          after
              .where((l) => l.isAudio && l.name != kEffectsLayerName)
              .single
              .clips
              .single
              .atS,
          0,
        );
        // and the effect is in the match library now
        expect(find.byKey(const ValueKey('media-fx-whoosh')), findsOneWidget);
      },
    );
  });
}

class _FakeApi extends ApiClient {
  _FakeApi(this.sounds);

  final SoundLibrary sounds;
  final added = <String>[];

  @override
  Future<SoundLibrary> listSoundEffects() async => sounds;

  @override
  Future<Media> addSoundEffect({
    required String jobId,
    required String sfxId,
  }) async {
    added.add(sfxId);
    final e = sounds.effects.firstWhere((e) => e.id == sfxId);
    return Media(
      id: 'fx-$sfxId',
      kind: 'audio',
      status: 'ready',
      name: e.name,
      durationS: e.durationS,
      sfxId: sfxId,
      audioUrl: 'http://localhost/api/media/fx-$sfxId/file',
    );
  }

  @override
  Future<void> requestFrames(String jobId) async {}
}
