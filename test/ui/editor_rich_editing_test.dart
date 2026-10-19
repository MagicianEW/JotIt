import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/app/providers.dart';
import 'package:jotit/app/vault_session.dart';
import 'package:jotit/ui/editor_page.dart';
import 'package:jotit/ui/rich_editor.dart';
import 'package:path/path.dart' as p;
import 'package:super_editor/super_editor.dart';

/// The rich pane's lifecycle inside the editor page.
///
/// Two bugs lived at the seam between the page and the pane, and both are
/// invisible in either half alone:
///
///  * P1-10 — the pane debounces its serialisation by 250 ms and the page used
///    to tear it down (view switch, save, jump) without asking for the pending
///    text, so the last burst of an edit was cancelled with the timer.
///  * P1-11 — the page splices an attachment link into the shared buffer
///    without the pane noticing, and the pane's next serialisation then
///    replaced the buffer wholesale — wiping the link that was just inserted
///    and orphaning the copied file.
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
    root = await Directory.systemTemp.createTemp('jotit_rich_edit_');
    vault = await VaultSession.open(root.path);
    await vault.writeRaw(
      'notes/a.md',
      utf8.encode('---\nuid: u-a\ntitle: A\n---\n\n普通正文。\n'),
    );
    await vault.reindex();
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
    await tester.tap(find.byKey(const ValueKey('editor-view-menu')));
    await settle(tester);
    await tester.tap(find.text('富文本编辑'));
    await settle(tester);
    expect(find.byType(SuperEditor), findsOneWidget,
        reason: 'the plain note may enter rich mode');
    return state;
  }

  /// The editor the way the app opens it: pushed as a route. The root-route
  /// harness above has no back button, and this test needs one — leaving the
  /// editor is what PopScope's discard dialog guards.
  Future<EditorPageState> openPushedEditor(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            vaultProvider.overrideWith((ref) async => vault),
            openNoteProvider.overrideWith(() => _FixedNote('notes/a.md')),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: Builder(
                  builder: (context) => ElevatedButton(
                    key: const ValueKey('launch-editor'),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                          builder: (_) => const EditorPage()),
                    ),
                    child: const Text('打开编辑器'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.tap(find.byKey(const ValueKey('launch-editor')));
    await settle(tester);
    final state = tester.state<EditorPageState>(find.byType(EditorPage));
    await tester.tap(find.byKey(const ValueKey('editor-view-menu')));
    await settle(tester);
    await tester.tap(find.text('富文本编辑'));
    await settle(tester);
    expect(find.byType(SuperEditor), findsOneWidget,
        reason: 'the plain note may enter rich mode');
    return state;
  }

  /// A collapsed caret in the first paragraph — the selection the pane's
  /// toolbar acts on.
  void placeCaret(RichEditorPaneState pane) {
    final node = pane.document.getNodeAt(0)!;
    pane.select(DocumentSelection(
      base: DocumentPosition(
          nodeId: node.id, nodePosition: TextNodePosition(offset: 0)),
      extent: DocumentPosition(
          nodeId: node.id, nodePosition: TextNodePosition(offset: 0)),
    ));
  }

  String bufferText(WidgetTester tester) => tester
      .widget<TextField>(find.byKey(const ValueKey('editor-body')))
      .controller!
      .text;

  testWidgets('a rich edit made moments before switching views is not lost',
      (tester) async {
    await openPushedEditor(tester);

    // Open the view menu first and let its 300 ms transition finish. The menu
    // is opened before the edit because the transition is longer than the
    // pane's 250 ms debounce: waiting for the menu after editing would let the
    // debounce fire on its own and prove nothing. Selecting an item pops the
    // route and completes `showMenu`'s future synchronously, so the flush
    // below happens with no fake-clock time spent at all.
    await tester.tap(find.byKey(const ValueKey('editor-view-menu')));
    await settle(tester);
    expect(find.text('源码'), findsOneWidget, reason: 'the view menu is open');

    final pane = tester.state<RichEditorPaneState>(find.byType(RichEditorPane));
    placeCaret(pane);
    pane.toggleQuote();
    expect(pane.hasPendingChange, isTrue,
        reason: 'the edit is still inside the 250 ms debounce');
    // Land the dirty rebuild before pressing: a press released in the same
    // frame as a setState does not reach the gesture recogniser. The pump is
    // Duration.zero, so the debounce is still pending when the item is hit.
    await tester.pump();

    final gesture = await tester.press(find.text('源码'));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    // The debounce window is long past; if the edit were merely late it would
    // have arrived by now.
    await tester.pump(const Duration(milliseconds: 400));

    expect(bufferText(tester), contains('> '),
        reason: 'P1-10: the last edit must survive the view switch — it used '
            'to be cancelled with the pane\'s timer');
    expect(bufferText(tester), contains('普通正文。'),
        reason: 'the edit must arrive as an edit, not as a replacement');

    // And it must count as an unsaved change: leaving now has to ask first.
    await tester.pageBack();
    await tester.pump();
    await tester.pump();
    expect(find.text('放弃修改？'), findsOneWidget,
        reason: 'an edit the debounce has not serialised yet is still an edit');
    await tester.tap(find.text('继续编辑'));
    await tester.pump();
  });

  testWidgets('a rich edit made moments before saving is not lost',
      (tester) async {
    // The same pending-edit window, reached through the save button instead
    // of the view menu: the save must write the text the user last saw, not
    // the text from before their last burst.
    await openEditor(tester);

    final pane = tester.state<RichEditorPaneState>(find.byType(RichEditorPane));
    placeCaret(pane);
    pane.toggleQuote();
    expect(pane.hasPendingChange, isTrue);
    // Land the dirty rebuild before pressing: a press released in the same
    // frame as a setState does not reach the button's gesture recogniser.
    // Duration.zero, so the debounce is still pending.
    await tester.pump();

    // The real button, not a back door: what is under test is the page
    // flushing the pane's pending serialisation before it writes. The tap
    // runs inside runAsync because the save it starts performs real file
    // I/O, and a future created in the binding's fake-async zone — which is
    // where a gesture-driven callback runs — never resumes there. (The
    // view-switch test above needs no such wrapper: a view switch is pure
    // in-memory work.)
    await tester.runAsync(() async {
      await tester.tap(find.byIcon(Icons.save_outlined));
      // Give the save room to finish: it awaits the vault session, the
      // backup roll and the disk before it reports back.
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await settle(tester);

    expect(find.text('已保存'), findsOneWidget);
    expect(File('${root.path}/notes/a.md').readAsStringSync(), contains('> '),
        reason: 'P1-10: saving inside the debounce window used to write the '
            'pre-edit text and silently drop the last burst');
  });

  testWidgets('an attachment inserted in rich view falls back to source, and '
      'the link survives a save', (tester) async {
    final state = await openEditor(tester);

    // An edit inside the debounce window, then the insert: the splice works on
    // the shared buffer, so the pending text has to be delivered first.
    final pane = tester.state<RichEditorPaneState>(find.byType(RichEditorPane));
    placeCaret(pane);
    pane.toggleQuote();
    final png = makeSource('shot.png', <int>[0x89, 0x50, 0x4E, 0x47, 1, 2, 3]);

    await tester.runAsync(() => state.attachForTesting(png.path));
    await settle(tester);

    expect(find.byType(SuperEditor), findsNothing,
        reason: 'P1-11: `![[...]]` is wiki syntax the rich serialiser cannot '
            'round-trip, so the view must fall back instead of staying');
    expect(find.byKey(const ValueKey('editor-body')), findsOneWidget);
    expect(find.textContaining('已切回源码视图'), findsOneWidget,
        reason: 'the fallback must say why, not silently move the user');

    final text = bufferText(tester);
    expect(text, contains('![[attachments/'),
        reason: 'P1-11: the pane used to wipe the freshly inserted link on '
            'its next serialisation, orphaning the copied file');
    expect(text, contains('> '),
        reason: 'P1-10: the edit pending at insert time must not be rolled '
            'back by the splice');

    await tester.runAsync(() => state.saveForTesting());
    await settle(tester);

    final onDisk = File('${root.path}/notes/a.md').readAsStringSync();
    expect(onDisk, contains('![[attachments/'),
        reason: 'what the user sees on save is what the file must hold');
    expect(onDisk, contains('> '));
  });

  testWidgets('an attachment inserted in source view keeps the pane out of it',
      (tester) async {
    // The everyday path: no rich pane is mounted, so there is nothing to
    // flush and nothing to fall back from — the insert must behave exactly as
    // it did before this batch of fixes.
    await openEditor(tester);
    await tester.tap(find.byKey(const ValueKey('editor-view-menu')));
    await settle(tester);
    await tester.tap(find.text('源码'));
    await settle(tester);
    final state = tester.state<EditorPageState>(find.byType(EditorPage));

    final png = makeSource('plain.png', <int>[1, 2, 3]);
    await tester.runAsync(() => state.attachForTesting(png.path));
    await settle(tester);

    expect(find.textContaining('已插入'), findsOneWidget);
    expect(find.byType(SuperEditor), findsNothing);
    expect(bufferText(tester), contains('![[attachments/'));
  });
}
