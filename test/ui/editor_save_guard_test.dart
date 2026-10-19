import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/app/providers.dart';
import 'package:jotit/app/vault_session.dart';
import 'package:jotit/ui/editor_page.dart';

/// P0-5: a save must write the note the text on screen belongs to.
///
/// The save used to take its path from `openNoteProvider`, but the controller
/// and `_loadedPath` are the consistent pair — and the Ctrl+S binding reaches
/// the save without passing the app bar's `editable` gate. Two failure chains
/// followed, both of which destroy data:
///
///  * a note whose bytes are not valid UTF-8 (readForEdit returns null, so the
///    controller stays empty) — Ctrl+S wrote an empty file and turned the note
///    into a uid shell;
///  * a wiki-link jump, where the provider already names the new note while
///    the buffer still holds the old one — Ctrl+S wrote the old note's text
///    under the new note's path.
///
/// Both are asserted here through [EditorPageState.saveForTesting], the
/// guarded method the Ctrl+S binding and the save button share. (A synthesised
/// key press would first have to win a focus-tree fight that has nothing to do
/// with saving; the guard under test is the method, not the binding.)
class _FixedNote extends OpenNote {
  _FixedNote(this.path);

  final String path;

  @override
  String? build() => path;
}

void main() {
  late Directory root;
  late VaultSession vault;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jotit_save_guard_');
    vault = await VaultSession.open(root.path);
    // GBK bytes: a real note a Windows user wrote with another editor. Not
    // valid UTF-8, so the editor refuses to open it — but it is still the
    // user's data and not one byte of it may be rewritten.
    await vault.writeRaw(
        'notes/gbk.md', <int>[0x23, 0x20, 0xD6, 0xD0, 0xCE, 0xC4]);
    await vault.writeRaw(
      'notes/plain.md',
      utf8.encode('---\nuid: u-p\ntitle: 平凡笔记\n---\n\n普通正文。\n'),
    );
    await vault.reindex();
  });

  tearDown(() async {
    await vault.close();
    if (root.existsSync()) await root.delete(recursive: true);
  });

  File noteFile(String name) => File('${root.path}/notes/$name');

  Future<void> openEditor(WidgetTester tester, OpenNote openNote) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            vaultProvider.overrideWith((ref) async => vault),
            openNoteProvider.overrideWith(() => openNote),
          ],
          child: const MaterialApp(home: EditorPage()),
        ),
      );
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
  }

  testWidgets('a note that is not UTF-8 is never written by the save path',
      (tester) async {
    await openEditor(tester, _FixedNote('notes/gbk.md'));

    expect(find.textContaining('不能以 UTF-8'), findsOneWidget,
        reason: 'readForEdit refused the bytes, so the editor shows the '
            'refusal and the controller stays empty');
    final before = noteFile('gbk.md').readAsBytesSync();

    final state = tester.state<EditorPageState>(find.byType(EditorPage));
    await tester.runAsync(() => state.saveForTesting());
    await settle(tester);

    expect(noteFile('gbk.md').readAsBytesSync(), before,
        reason: 'P0-5: saving an undecodable note used to write 0 bytes — '
            'the file was destroyed, with no backup and no uid left');
    expect(find.textContaining('当前笔记不可保存'), findsOneWidget,
        reason: 'a refused save must say so, not look like it worked');
  });

  testWidgets('a save during a jump does not write the old note under the new '
      'path', (tester) async {
    // The dangerous state, held still: the provider already points at
    // notes/missing.md while the buffer still holds notes/plain.md. That is
    // exactly the window `skipLoadingOnReload` produces during a wiki-link
    // jump — the provider re-runs for the new path while `data:` keeps
    // serving the old note. `editableNoteProvider` is pinned here so the
    // window does not have to be raced in real time.
    final openNote = _FixedNote('notes/plain.md');
    // The read goes inside runAsync with everything else that touches the
    // disk: a testWidgets body runs in the binding's fake-async zone, where
    // the real event loop does not spin while the body is suspended, so a
    // bare `await` on file I/O never resumes. (setUp is outside that zone,
    // which is why the writes there complete.)
    await tester.runAsync(() async {
      final plain = await vault.readForEdit('notes/plain.md');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            vaultProvider.overrideWith((ref) async => vault),
            openNoteProvider.overrideWith(() => openNote),
            editableNoteProvider.overrideWith((ref) async => plain),
          ],
          child: const MaterialApp(home: EditorPage()),
        ),
      );
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });

    // The jump happens: the provider moves, the buffer does not.
    openNote.open('notes/missing.md');
    await settle(tester);

    final state = tester.state<EditorPageState>(find.byType(EditorPage));
    await tester.runAsync(() => state.saveForTesting());
    await settle(tester);

    expect(noteFile('missing.md').existsSync(), isFalse,
        reason: 'P0-5: a save taken mid-jump used to create the new note '
            'with the old note\'s whole text inside it');
    expect(find.textContaining('当前笔记不可保存'), findsOneWidget);
  });

  testWidgets('a normal note still saves through the same path', (tester) async {
    // The guard must not over-block: the everyday save has to keep working.
    await openEditor(tester, _FixedNote('notes/plain.md'));

    await tester.tap(find.byKey(const ValueKey('editor-view-menu')));
    await settle(tester);
    await tester.tap(find.text('源码'));
    await settle(tester);

    final state = tester.state<EditorPageState>(find.byType(EditorPage));
    await tester.runAsync(() async {
      await tester.enterText(find.byKey(const ValueKey('editor-body')),
          '---\nuid: u-p\ntitle: 平凡笔记\n---\n\n改过的正文。\n');
    });
    await settle(tester);

    await tester.runAsync(() => state.saveForTesting());
    await settle(tester);

    expect(find.text('已保存'), findsOneWidget);
    expect(noteFile('plain.md').readAsStringSync(), contains('改过的正文。'),
        reason: 'the guard is a gate on *which* note may be written, not on '
            'whether a save may happen');
  });
}
