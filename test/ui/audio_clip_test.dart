import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/app/clip_player.dart';
import 'package:jotit/app/providers.dart';
import 'package:jotit/app/vault_session.dart';
import 'package:jotit/ui/editor_page.dart';
import 'package:path/path.dart' as p;

/// A recorded clip, as the preview shows it.
///
/// The clip arrives in the note through the same `![[…]]` embed syntax a
/// picture uses, so the only thing that separates "a picture" from "a voice
/// memo" is what the preview does with it. Get that wrong and a recording
/// shows up as a broken-image placeholder — a file the app can play perfectly
/// well, described to the user as something it cannot show.
class _FixedNote extends OpenNote {
  _FixedNote(this.path);

  final String path;

  @override
  String? build() => path;
}

/// A player that records what it was asked to do instead of making a sound.
class _FakeClipPlayer implements ClipPlayer {
  final _playback = StreamController<ClipPlayback>.broadcast();
  final _progress = StreamController<ClipProgress>.broadcast();

  String? opened;
  int plays = 0;
  int pauses = 0;

  @override
  Stream<ClipPlayback> get playback => _playback.stream;

  @override
  Stream<ClipProgress> get progress => _progress.stream;

  @override
  Future<void> open(String path) async {
    opened = path;
    _progress.add(const ClipProgress(
      position: Duration.zero,
      duration: Duration(seconds: 42),
    ));
  }

  @override
  Future<void> play() async {
    plays++;
    _playback.add(ClipPlayback.playing);
  }

  @override
  Future<void> pause() async {
    pauses++;
    _playback.add(ClipPlayback.paused);
  }

  @override
  Future<void> seek(Duration to) async {}

  @override
  Future<void> dispose() async {
    await _playback.close();
    await _progress.close();
  }
}

void main() {
  late Directory root;
  late VaultSession vault;
  late _FakeClipPlayer player;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jotit_clip_');
    vault = await VaultSession.open(root.path);
    player = _FakeClipPlayer();

    await vault.writeRaw(
      'notes/a.md',
      utf8.encode(
        '---\nuid: u-a\ntitle: A\n---\n\n'
        '说一段话：\n\n'
        '![[attachments/clip.m4a]]\n\n'
        '然后继续写。\n',
      ),
    );
    final clip = File(p.join(root.path, 'notes', 'attachments', 'clip.m4a'));
    clip.parent.createSync(recursive: true);
    clip.writeAsBytesSync(<int>[0x00, 0x01, 0x02]);
    await vault.reindex();
  });

  tearDown(() async {
    await vault.close();
    if (root.existsSync()) await root.delete(recursive: true);
  });

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
  }

  Future<void> openPreview(WidgetTester tester, {String path = 'notes/a.md'}) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            vaultProvider.overrideWith((ref) async => vault),
            openNoteProvider.overrideWith(() => _FixedNote(path)),
            clipPlayerFactoryProvider.overrideWithValue(() => player),
          ],
          child: const MaterialApp(home: EditorPage()),
        ),
      );
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await settle(tester);
  }

  testWidgets('a recording shows as a playable clip, not a broken picture',
      (tester) async {
    await openPreview(tester);

    expect(find.byKey(const ValueKey('audio-clip-play')), findsOneWidget,
        reason: 'the clip has to be playable where it is referenced');
    expect(find.text('无法显示的图片'), findsNothing,
        reason: 'a recording the app can play is not a picture it cannot '
            'show');
    expect(find.text('录音'), findsOneWidget);
  });

  testWidgets('the clip is opened from the file that is really in the vault',
      (tester) async {
    await openPreview(tester);

    expect(player.opened,
        p.join(root.path, 'notes', 'attachments', 'clip.m4a'),
        reason: 'the player has to be pointed at the real file — a path built '
            'without the vault root plays silence');
  });

  testWidgets('the play button starts and stops the clip', (tester) async {
    await openPreview(tester);

    await tester.tap(find.byKey(const ValueKey('audio-clip-play')));
    await settle(tester);
    expect(player.plays, 1);

    await tester.tap(find.byKey(const ValueKey('audio-clip-play')));
    await settle(tester);
    expect(player.pauses, 1,
        reason: 'a clip that cannot be paused is a clip that runs to the end '
            'whether the user wants it to or not');
  });

  testWidgets('the clip shows its length', (tester) async {
    await openPreview(tester);

    expect(find.text('0:00 / 0:42'), findsOneWidget,
        reason: 'a voice memo whose length is unknown cannot be judged '
            'before it is played');
  });

  testWidgets('a clip the user named shows that name, not the file name',
      (tester) async {
    // The label of a wiki embed is the target unless the user wrote one, so
    // an unnamed clip must not be labelled with its own path — and a named
    // one must keep the name.
    //
    // The writes go through `runAsync`: inside `testWidgets` the clock is
    // fake, and a plain `await` on a file write never completes — the test
    // stops rather than fails.
    await tester.runAsync(() async {
      await vault.writeRaw(
        'notes/named.md',
        utf8.encode(
          '---\nuid: u-n\ntitle: N\n---\n\n'
          '![[attachments/clip.m4a|周五的想法]]\n',
        ),
      );
      await vault.reindex();
    });

    await openPreview(tester, path: 'notes/named.md');

    expect(find.text('周五的想法'), findsOneWidget,
        reason: 'a name the user wrote is the one thing worth showing');
    expect(find.text('attachments/clip.m4a'), findsNothing,
        reason: 'the file name is not a name anybody gave anything');
  });
}
