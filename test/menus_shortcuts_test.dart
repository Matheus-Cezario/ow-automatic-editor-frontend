import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart';
import 'package:ow_editor/keymap.dart';
import 'package:ow_editor/montage.dart';
import 'package:ow_editor/screens/timeline_screen.dart';
import 'package:ow_editor/widgets/music_timeline.dart';
import 'package:ow_editor/widgets/shortcuts_dialog.dart';

import 'timeline_screen_test.dart' show jobJson, readyMusic;

/// Right-click menus on the library and the moment shelf, and shortcuts the
/// user can change.
void main() {
  group('the keymap', () {
    test('starts on the defaults and finds a command by its key', () {
      const k = Keymap.defaults;
      expect(k.isDefault, isTrue);
      expect(k.keysOf('split'), [const KeyCombo(LogicalKeyboardKey.keyS)]);
      expect(
        k.commandFor(const KeyCombo(LogicalKeyboardKey.keyZ, command: true)),
        'undo',
      );
      // every command has a name and distinct defaults
      final all = [for (final c in kEditorCommands) ...c.defaults];
      expect(all.toSet(), hasLength(all.length));
    });

    test('a key given to one command is taken from the other', () {
      const x = KeyCombo(LogicalKeyboardKey.keyS);
      final k = Keymap.defaults.bind('marker', x);
      expect(k.commandFor(x), 'marker');
      expect(k.keysOf('split'), isEmpty);
      expect(k.keysOf('marker'), [const KeyCombo(LogicalKeyboardKey.keyN), x]);
    });

    test('remove, reset, and Esc is never given away', () {
      var k = Keymap.defaults.unbind(
        'play',
        const KeyCombo(LogicalKeyboardKey.keyK),
      );
      expect(k.keysOf('play'), [const KeyCombo(LogicalKeyboardKey.space)]);
      k = k.reset('play');
      expect(k.isDefault, isTrue, reason: 'back to the default is no change');
      expect(
        Keymap.defaults.bind(
          'split',
          const KeyCombo(LogicalKeyboardKey.escape),
        ),
        same(Keymap.defaults),
      );
    });

    test('is kept as text and read back, and junk gives the defaults', () {
      final k = Keymap.defaults
          .bind('split', const KeyCombo(LogicalKeyboardKey.keyX, shift: true))
          .bind('undo', const KeyCombo(LogicalKeyboardKey.keyU, command: true));
      final back = Keymap.fromJson(k.toJson());
      expect(back.keysOf('split'), k.keysOf('split'));
      expect(back.keysOf('undo'), k.keysOf('undo'));
      expect(Keymap.fromJson('{"gone": ["83"]}').isDefault, isTrue);
      expect(Keymap.fromJson('not json').isDefault, isTrue);
    });
  });

  group('the shortcut list', () {
    testWidgets('+ then a key gives the key to that command', (tester) async {
      Keymap? last;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ShortcutsDialog(
              keymap: Keymap.defaults,
              onChanged: (k) => last = k,
            ),
          ),
        ),
      );
      await tester.ensureVisible(find.byKey(const Key('shortcut-add-marker')));
      await tester.tap(find.byKey(const Key('shortcut-add-marker')));
      await tester.pump();
      expect(find.byKey(const Key('shortcut-listening')), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.pump();
      expect(
        last!.commandFor(const KeyCombo(LogicalKeyboardKey.keyS)),
        'marker',
      );
      expect(
        find.byKey(const Key('shortcut-note')),
        findsOneWidget,
        reason: 'it says S no longer splits',
      );

      await tester.tap(find.byKey(const Key('shortcuts-reset-all')));
      await tester.pump();
      expect(last!.isDefault, isTrue);
    });
  });

  group('the screen', () {
    Future<void> open(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: TimelineScreen(
            job: Job.fromJson(jobJson(withMusic: true)),
            api: _FakeApi(),
          ),
        ),
      );
      await tester.pump();
    }

    List<TimelineClip> clips(WidgetTester tester) => [
      for (final l
          in tester.widget<MusicTimeline>(find.byType(MusicTimeline)).layers)
        ...l.clips,
    ];

    Future<void> menuItem(WidgetTester tester, String key) async {
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key(key)));
      await tester.pumpAndSettle();
    }

    final kill = find.byKey(ValueKey('moment-${momentKey('kill', 30)}'));

    testWidgets('right-click a moment: place it, then find it on the ruler', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(kill, buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('moment-menu-show')),
        findsNothing,
        reason: 'not on the ruler yet',
      );
      await menuItem(tester, 'moment-menu-place');
      final placed = clips(tester).where((c) => c.sourceT == 30).toList();
      expect(placed, hasLength(1));

      await tester.tap(kill, buttons: kSecondaryButton);
      await menuItem(tester, 'moment-menu-show');
      final timeline = tester.widget<MusicTimeline>(find.byType(MusicTimeline));
      expect(timeline.selectionIds, {placed.single.id});
    });

    testWidgets('right-click a library item and place it', (tester) async {
      await open(tester);
      await tester.tap(find.text('Library'));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final music = readyMusic()['id'] as String;
      await tester.tap(
        find.byKey(ValueKey('media-$music')),
        buttons: kSecondaryButton,
      );
      await menuItem(tester, 'media-menu-use');
      expect(clips(tester).where((c) => c.mediaId == music), isNotEmpty);
    });

    testWidgets('a key the user chose does what it was given', (tester) async {
      await open(tester);
      await tester.tap(kill);
      await tester.pump();
      expect(
        clips(tester).where((c) => !c.isMusic || c.source == 'recording'),
        hasLength(1),
      );

      // the list, from the screen's menu: X now splits
      await tester.tap(find.byKey(const Key('screen-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keyboard shortcuts'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('shortcut-add-split')));
      await tester.tap(find.byKey(const Key('shortcut-add-split')));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
      await tester.pump();
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      // the playhead into the block, then X
      final cut = clips(tester).firstWhere((c) => c.source == 'recording');
      final ruler = tester.getRect(find.byType(MusicTimeline));
      await tester.tapAt(
        Offset(
          ruler.left + MusicTimeline.headerWidth + 1 + cut.durationS / 2 * 60,
          ruler.top + 20,
        ),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
      await tester.pump();
      expect(clips(tester).where((c) => c.source == 'recording'), hasLength(2));
    });
  });
}

class _FakeApi extends ApiClient {
  @override
  Future<void> requestFrames(String jobId) async {}
}
