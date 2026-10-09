import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/app/vault_session.dart';

import '../support/boot_app.dart';

/// The loop a user performs a hundred times a day: open, edit, save, leave,
/// open again. The second opening must show what the save wrote.
///
/// The save always reached the disk — the reported failure was display-only,
/// and a full restart made the new text appear, which is the signature of a
/// stale cache rather than a lost write. The suspect is the provider that
/// caches the editable text: it watched only the open-note signal, and
/// reopening the *same* path assigns the same value, so nothing ever told it
/// that the file had changed under it.
void main() {
  late Directory root;
  late VaultSession vault;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jotit_editor_reopen_');
    vault = await VaultSession.open(root.path);
    await vault.writeRaw(
      'notes/a.md',
      utf8.encode('---\nuid: u-a\ntitle: A\n---\n\n第一版正文\n'),
    );
    // open() indexed the (empty) vault before the seed file existed; without
    // this the derived index stays empty and the list shows an empty vault.
    await vault.reindex();
  });

  tearDown(() async {
    await vault.close();
    if (root.existsSync()) await root.delete(recursive: true);
  });

  Future<void> act(WidgetTester tester, Future<void> Function() body,
      {int pumps = 20}) async {
    await tester.runAsync(() async {
      await body();
      for (var i = 0; i < pumps; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
  }

  /// Pumps on the real clock until [finder] matches or [seconds] run out.
  Future<void> waitFor(WidgetTester tester, Finder finder,
      {int seconds = 15}) async {
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(Duration(seconds: seconds));
      while (finder.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
  }

  Future<void> openNoteByTitle(WidgetTester tester, String title) async {
    await waitFor(tester, find.text(title));
    final probe = await tester.runAsync(() async {
      final list = await vault.notes.allActive(limit: 500);
      return 'dbRows=${list.length} paths=${list.map((e) => e.path).toList()}';
    });
    expect(
      tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .join(' | '),
      contains(title),
      reason: 'before tapping the tile, the home list must show it; the '
          'actual value shows every Text on screen. DB PROBE: $probe',
    );
    await act(tester, () async {
      await tester.tap(find.text(title));
      // The editor opens in preview by default; this test drives the raw
      // text field, so switch to source mode first. Each round: open the
      // menu, let the popup fully build (a single pump is not enough —
      // looking for the item too early finds nothing), tap the item, then
      // wait for the field. Re-tapping the menu while it is open closes it,
      // so every round starts by checking whether the switch already
      // happened.
      for (var i = 0;
          i < 10 &&
              find.byKey(const ValueKey('editor-body')).evaluate().isEmpty;
          i++) {
        for (var j = 0; j < 20; j++) {
          final menus = tester
              .widgetList<PopupMenuButton<dynamic>>(
                  find.byKey(const ValueKey('editor-view-menu')))
              .toList();
          if (menus.isNotEmpty && menus.first.enabled != false) break;
          await tester.pump(const Duration(milliseconds: 50));
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        if (find.byKey(const ValueKey('editor-body')).evaluate().isNotEmpty) {
          break;
        }
        await tester.tap(find.byKey(const ValueKey('editor-view-menu')),
            warnIfMissed: false);
        for (var j = 0; j < 10; j++) {
          await tester.pump(const Duration(milliseconds: 50));
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        if (find.text('源码').evaluate().isNotEmpty) {
          await tester.tap(find.text('源码'), warnIfMissed: false);
        }
        for (var j = 0; j < 10; j++) {
          await tester.pump(const Duration(milliseconds: 50));
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }
      for (var i = 0;
          i < 40 &&
              find.byKey(const ValueKey('editor-body')).evaluate().isEmpty;
          i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }, pumps: 10);
  }

  Future<String> editorText(WidgetTester tester) async {
    late String out;
    await tester.runAsync(() async {
      out = tester
          .widget<TextField>(find.byKey(const ValueKey('editor-body')))
          .controller!
          .text;
    });
    return out;
  }

  testWidgets('save, leave, reopen: the editor shows the saved text',
      (tester) async {
    await act(tester, () async {
      await tester.pumpWidget(bootApp(vault: vault, root: root));
      for (var i = 0; i < 30 && find.text('A').evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }, pumps: 10);

    // First opening: the note as it was seeded.
    await openNoteByTitle(tester, 'A');
    final original = await editorText(tester);
    expect(original, contains('第一版正文'));

    // Edit the way the user would — a text change through the field, which
    // fires onChanged and marks the editor dirty.
    await act(tester, () async {
      await tester.enterText(find.byKey(const ValueKey('editor-body')),
          '$original\n新增的一行');
    }, pumps: 5);

    await act(tester, () => tester.tap(find.byIcon(Icons.save_outlined)),
        pumps: 5);
    await waitFor(tester, find.text('已保存'));

    // Sanity, not the point of the test: the save itself must have landed.
    final onDisk = File('${root.path}/notes/a.md').readAsStringSync();
    expect(onDisk, contains('新增的一行'),
        reason: 'sanity: if this fails the save path is broken, and the '
            'display complaint is the smaller problem');

    // Leave. After a successful save the editor is clean, so no discard
    // dialog stands in the way.
    await act(tester, () async {
      await tester.pageBack();
    }, pumps: 20);
    final indexed = await tester.runAsync(() async {
      final list = await vault.notes.allActive(limit: 500);
      return list.map((e) => e.path).toList();
    });
    expect(indexed, contains('notes/a.md'),
        reason: 'the index must survive the save-and-leave round trip');

    // Reopen the same note from the list.
    await openNoteByTitle(tester, 'A');

    final reopened = await editorText(tester);
    expect(reopened, contains('新增的一行'),
        reason: 'the save reached the disk; a reopened editor must show the '
            'saved text, not the bytes from before the save');
  });
}
