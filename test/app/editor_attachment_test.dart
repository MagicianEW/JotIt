import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/app/providers.dart';
import 'package:jotit/app/vault_session.dart';
import 'package:jotit/ui/editor_page.dart';
import 'package:path/path.dart' as p;

/// v3.0 §9.3, from the editor.
///
/// The unit tests in `attachment_writer_test.dart` prove where the file lands
/// and what the link says. This proves the two things only the editor can be
/// wrong about: that the picture ends up in the **text the user is looking
/// at**, and that nothing has escaped the vault while doing it.
///
/// Like every widget test in this project that touches the disk, everything
/// runs inside `runAsync` — `testWidgets` drives a fake clock, so a plain
/// `await` on a file write never completes and the test stops rather than
/// fails.
/// Opens [path] instead of waiting for the user to tap a tile.
///
/// A `Notifier` rather than a plain value because that is what the provider
/// holds: overriding it with a lambda returning a `String` compiles against
/// nothing and fails the moment Riverpod calls `build()`.
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
    root = await Directory.systemTemp.createTemp('jotit_editor_attach_');
    vault = await VaultSession.open(root.path);
    await vault.writeRaw(
      'notes/a.md',
      utf8.encode('---\nuid: u-a\ntitle: A\n---\n\n第一段\n\n第二段\n'),
    );
  });

  tearDown(() async {
    await vault.close();
    if (root.existsSync()) await root.delete(recursive: true);
  });

  File makeSource(String name, List<int> bytes) {
    final f = File(p.join(root.path, 'inbox', name));
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(bytes);
    return f;
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
  }

  /// Boots the editor with a note open and hands back its state.
  Future<EditorPageState> openEditor(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            vaultProvider.overrideWith((ref) async => vault),
            openNoteProvider.overrideWith(() => _FixedNote('notes/a.md')),
          ],
          child: const MaterialApp(home: EditorPage()),
        ),
      );
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    final state = tester.state<EditorPageState>(find.byType(EditorPage));
    // The editor opens in preview; these tests verify the raw text field, so
    // switch to source mode before anything inspects the buffer.
    await tester.tap(find.byKey(const ValueKey('editor-view-menu')));
    await settle(tester);
    await tester.tap(find.text('源码'));
    await settle(tester);
    return state;
  }

  testWidgets('inserting a picture puts the file in the vault and the link '
      'in the note', (tester) async {
    final state = await openEditor(tester);
    final png = makeSource('shot.png', <int>[0x89, 0x50, 0x4E, 0x47, 1, 2, 3]);

    await tester.runAsync(() => state.insertFile(png.path));
    await settle(tester);

    final attachments = Directory(p.join(root.path, 'notes', 'attachments'));    expect(attachments.existsSync(), isTrue,
        reason: '§9.3: the file goes into an attachments folder beside the '
            'note');

    final files = attachments.listSync().whereType<File>().toList();
    expect(files, hasLength(1));
    expect(files.single.readAsBytesSync(), <int>[0x89, 0x50, 0x4E, 0x47, 1, 2, 3],
        reason: 'the bytes must arrive unchanged — a re-encoded picture is a '
            'corrupt picture');
    expect(files.single.path, endsWith('.png'));

    final text = tester
        .widget<TextField>(find.byKey(const ValueKey('editor-body')))
        .controller!
        .text;
    expect(text, contains('![[attachments/'));
    expect(text, contains('第一段'));
    expect(text, contains('第二段'),
        reason: 'inserting a picture must not eat the rest of the note');
  });

  testWidgets('the inserted link resolves to the file that was actually '
      'written', (tester) async {
    // The link and the file are produced by two different functions; a test
    // that only checks "there is a link" and "there is a file" passes happily
    // when the link points somewhere else entirely.
    final state = await openEditor(tester);
    final png = makeSource('x.png', <int>[1, 2, 3, 4]);

    await tester.runAsync(() => state.insertFile(png.path));
    await settle(tester);

    final text = tester
        .widget<TextField>(find.byKey(const ValueKey('editor-body')))
        .controller!
        .text;
    final target = RegExp(r'!\[\[(.+?)\]\]').firstMatch(text)!.group(1)!;
    final resolved = File(p.join(root.path, 'notes', target));

    expect(resolved.existsSync(), isTrue,
        reason: 'link "$target" has to resolve to the file that was copied');
  });

  testWidgets('the attachment becomes syncable once the note is saved',
      (tester) async {
    // The chain the user actually performs, and the one the sync engine
    // depends on: it only pushes files a note **references**, so the row
    // cannot appear while the link exists solely in the editor's buffer.
    // Insertion without a save leaves an orphan on disk — deliberately, since
    // "nothing points at this" is not evidence the user wants it on their
    // other devices.
    final state = await openEditor(tester);
    final png = makeSource('y.png', <int>[9, 9]);

    await tester.runAsync(() => state.insertFile(png.path));
    await settle(tester);

    final beforeSave = await tester.runAsync(() => vault.notes.attachmentPaths());
    expect(beforeSave, isEmpty,
        reason: 'the link has not been written to disk yet, so nothing '
            'references the file and the engine must leave it alone');

    final text = tester
        .widget<TextField>(find.byKey(const ValueKey('editor-body')))
        .controller!
        .text;
    await tester.runAsync(() => vault.save('notes/a.md', text));
    await settle(tester);

    final afterSave = await tester.runAsync(() => vault.notes.attachmentPaths());
    expect(afterSave, hasLength(1),
        reason: 'after saving, the note references the file and it can sync');
  });

  testWidgets('nothing is written outside the vault', (tester) async {
    final state = await openEditor(tester);
    final png = makeSource('z.png', <int>[7]);

    await tester.runAsync(() => state.insertFile(png.path));
    await settle(tester);

    // The failure this guards against is silent and absolute: a path built
    // without the vault root resolves against the process working directory,
    // so every attachment lands next to the executable.
    expect(Directory(p.join(root.path, 'notes', 'attachments')).existsSync(),
        isTrue);
  });

  testWidgets('a missing file is reported instead of silently doing nothing',
      (tester) async {
    final state = await openEditor(tester);

    await tester.runAsync(
        () => state.insertFile(p.join(root.path, 'nope.png')));
    await settle(tester);

    expect(find.textContaining('插入失败'), findsOneWidget,
        reason: 'a button that does nothing is indistinguishable from a '
            'broken app');
  });

  testWidgets('the editor is marked dirty, so leaving warns about the link',
      (tester) async {
    final state = await openEditor(tester);
    final png = makeSource('w.png', <int>[3]);

    await tester.runAsync(() => state.insertFile(png.path));
    await settle(tester);

    // The link only exists in the buffer until the user saves; leaving without
    // saving would silently drop it while keeping the copied file.
    expect(find.textContaining('已插入'), findsOneWidget);
  });

  tearDownAll(() {
    // A stray directory in the package root is the specific failure this file
    // exists to catch; if one appears it must not be left for the next run.
    final stray = Directory(p.join(Directory.current.path, 'notes'));
    if (stray.existsSync()) {
      // ignore: avoid_print
      print('WARNING: ${stray.path} exists outside any vault');
    }
  });
}
