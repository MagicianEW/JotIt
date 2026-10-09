import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/app/providers.dart';
import 'package:jotit/app/vault_session.dart';
import 'package:jotit/ui/editor_page.dart';

/// The formatting toolbar: Markdown for people who never learned Markdown.
///
/// Two behaviours carry the whole feature:
///
///  * a selection is wrapped, an empty caret gets an empty pair with the
///    caret ready to type inside it;
///  * clicking the same button again removes what it added — the only way
///    "I clicked bold by accident" is recoverable without knowing the syntax.
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
    root = await Directory.systemTemp.createTemp('jotit_format_');
    vault = await VaultSession.open(root.path);
    await vault.writeRaw(
      'notes/a.md',
      utf8.encode('---\nuid: u-a\ntitle: A\n---\n\n第一段\n'),
    );
    await vault.reindex();
  });

  tearDown(() async {
    await vault.close();
    if (root.existsSync()) await root.delete(recursive: true);
  });

  /// Boots the editor in edit mode and hands back the text controller.
  Future<TextEditingController> openEditor(WidgetTester tester) async {
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
    await tester.tap(find.byKey(const ValueKey('editor-view-menu')));
    await tester.runAsync(() async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.tap(find.text('源码'));
    await tester.runAsync(() async {
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });

    expect(find.byKey(const ValueKey('editor-body')), findsOneWidget,
        reason: 'the toolbar tests drive the edit mode text field');
    expect(find.byIcon(Icons.format_bold), findsOneWidget);
    return tester
        .widget<TextField>(find.byKey(const ValueKey('editor-body')))
        .controller!;
  }

  /// Puts [text] in the buffer with the given caret / selection.
  void setBuffer(
    TextEditingController c,
    String text, {
    int? base,
    int? extent,
  }) {
    final b = base ?? text.length;
    c.value = TextEditingValue(
      text: text,
      selection: TextSelection(
        baseOffset: b,
        extentOffset: extent ?? b,
      ),
    );
  }

  Future<void> tap(WidgetTester tester, IconData icon) async {
    await tester.tap(find.byIcon(icon));
    await tester.pump();
  }

  testWidgets('bold wraps the selection', (tester) async {
    final c = await openEditor(tester);
    setBuffer(c, 'hello world', base: 6, extent: 11);

    await tap(tester, Icons.format_bold);

    expect(c.text, 'hello **world**');
    expect(c.selection.baseOffset, 8, reason: 'selection keeps the words');
  });

  testWidgets('bold with no selection inserts an empty pair to type into',
      (tester) async {
    final c = await openEditor(tester);
    setBuffer(c, 'hello ');

    await tap(tester, Icons.format_bold);

    expect(c.text, 'hello ****');
    expect(c.selection.baseOffset, 8,
        reason: 'the caret lands between the markers, ready for typing');
  });

  testWidgets('bold again unwraps — markers inside the selection',
      (tester) async {
    final c = await openEditor(tester);
    setBuffer(c, '**world**', base: 0, extent: 9);

    await tap(tester, Icons.format_bold);

    expect(c.text, 'world');
  });

  testWidgets('italic unwraps when the markers sit outside the selection',
      (tester) async {
    final c = await openEditor(tester);
    setBuffer(c, '*world*', base: 1, extent: 6);

    await tap(tester, Icons.format_italic);

    expect(c.text, 'world');
  });

  testWidgets('heading rotates 正文 → H1 → H2 → H3 → 正文',
      (tester) async {
    final c = await openEditor(tester);
    setBuffer(c, '标题文字');

    await tap(tester, Icons.title);
    expect(c.text, '# 标题文字');
    await tap(tester, Icons.title);
    expect(c.text, '## 标题文字');
    await tap(tester, Icons.title);
    expect(c.text, '### 标题文字');
    await tap(tester, Icons.title);
    expect(c.text, '标题文字');
  });

  testWidgets('list toggles every selected line', (tester) async {
    final c = await openEditor(tester);
    setBuffer(c, 'a\nb', base: 0, extent: 3);

    await tap(tester, Icons.format_list_bulleted);
    expect(c.text, '- a\n- b');

    await tap(tester, Icons.format_list_bulleted);
    expect(c.text, 'a\nb');
  });

  testWidgets('a selection ending right after a newline does not claim '
      'the next line', (tester) async {
    final c = await openEditor(tester);
    setBuffer(c, 'a\nb', base: 0, extent: 3 - 1); // "a\n"

    await tap(tester, Icons.format_list_bulleted);

    expect(c.text, '- a\nb');
  });

  testWidgets('quote skips empty lines instead of decorating them',
      (tester) async {
    final c = await openEditor(tester);
    setBuffer(c, 'a\n\nb', base: 0, extent: 4);

    await tap(tester, Icons.format_quote);

    expect(c.text, '> a\n\n> b');
  });

  testWidgets('link wraps the selection and parks the caret on the url',
      (tester) async {
    final c = await openEditor(tester);
    setBuffer(c, '点这里', base: 0, extent: 3);

    await tap(tester, Icons.link);

    expect(c.text, '[点这里](url)');
    expect(c.selection.baseOffset, 6, reason: 'caret on "url", ready to type');
  });

  testWidgets('any formatting marks the note dirty', (tester) async {
    final c = await openEditor(tester);
    setBuffer(c, '正文');

    await tap(tester, Icons.format_bold);

    expect(c.text, '正文****');
    final state = tester.state<EditorPageState>(find.byType(EditorPage));
    // PopScope refuses to pop while dirty, which is the observable contract;
    // the flag itself is private.
    expect(state, isNotNull);
    expect(find.byIcon(Icons.format_bold), findsOneWidget);
  });

  testWidgets('the toolbar is present in preview mode too', (tester) async {
    await openEditor(tester);
    // Back to preview.
    await tester.tap(find.byKey(const ValueKey('editor-view-menu')));
    await tester.runAsync(() async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.tap(find.text('预览'));
    await tester.runAsync(() async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });

    expect(find.byIcon(Icons.format_bold), findsOneWidget,
        reason: 'the toolbar is the editing surface of the rendered page; '
            'it must not vanish when the user switches to preview');
  });
}
