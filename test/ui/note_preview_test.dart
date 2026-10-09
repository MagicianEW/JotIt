import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/app/providers.dart';
import 'package:jotit/app/vault_session.dart';
import 'package:jotit/ui/editor_page.dart';
import 'package:jotit/ui/note_preview.dart';
import 'package:path/path.dart' as p;

/// The preview: what renders, what hides, and what is clickable.
///
/// Three guarantees matter here and none of them is cosmetic:
///
///  * front matter is metadata and stays out of the rendered body;
///  * wiki syntax inside a code block stays literal — rendering a fenced
///     example as a real link means the *documentation* navigates the reader;
///  * a resolved wiki link opens the note the link graph resolves to, using
///     the same [LinkResolver] the sync engine's graph is built on.
class _FixedNote extends OpenNote {
  _FixedNote(this.path);

  final String path;

  @override
  String? build() => path;
}

void main() {
  group('renderableBody (pure)', () {
    test('hides the front matter, keeps the body', () {
      final out = renderableBody('---\nuid: u-1\ntitle: T\n---\n\n正文第一行\n');
      expect(out, isNot(contains('uid')));
      expect(out, isNot(contains('---')));
      expect(out, contains('正文第一行'));
    });

    test('rewrites wiki links and embeds to the internal schemes', () {
      final out = renderableBody('看[[a]]和![[img.png]]还有[[b|别名]]');
      expect(out, contains('[a](jotit-note:a)'));
      expect(out, contains('![img.png](jotit-embed:img.png)'));
      expect(out, contains('[别名](jotit-note:b)'));
      expect(out, isNot(contains('[[a]]')));
    });

    test('anchor renders in the label but not the href', () {
      final out = renderableBody('[[note#标题]]');
      expect(out, contains('[note › 标题](jotit-note:note)'));
    });

    test('leaves wiki syntax inside inline code alone', () {
      final out = renderableBody('写法是 `[[a]]` 别弄错');
      expect(out, contains('`[[a]]`'));
      expect(out, isNot(contains('jotit-note')));
    });

    test('leaves wiki syntax inside a fenced block alone', () {
      final out = renderableBody('```md\n[[a]]\n```\n之后[[b]]');
      expect(out, contains('[[a]]'));
      expect(out, contains('jotit-note:b'));
    });

    test('an empty link stays literal, not a dead markdown link', () {
      expect(renderableBody('前[[]]后'), contains('[[]]'));
    });
  });

  group('NotePreview (widget, real vault)', () {
    late Directory root;
    late VaultSession vault;

    final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
        'AAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

    setUp(() async {
      root = await Directory.systemTemp.createTemp('jotit_preview_');
      vault = await VaultSession.open(root.path);
      await vault.writeRaw(
        'notes/a.md',
        utf8.encode(
          '---\nuid: u-a\ntitle: A\n---\n\n# 大标题\n\n'
          '这是**加粗**的一段。\n\n'
          // The link sits in its own paragraph so it renders as a single
          // Text widget — findable and tappable without span coordinates.
          '跳到下面：\n\n[[b|别名]]\n\n'
          '嵌图：![[attachments/pic.png]]\n\n'
          '```md\n[[b]] 是代码\n```\n',
        ),
      );
      await vault.writeRaw('notes/b.md', utf8.encode('B 的内容\n'));
      final pic = File(p.join(root.path, 'notes', 'attachments', 'pic.png'));
      pic.parent.createSync(recursive: true);
      pic.writeAsBytesSync(png);
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

    Future<void> openEditor(WidgetTester tester) async {
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
      // The preview loads its link index after the first frame; the setState
      // that lands it needs one more pump inside runAsync to materialise.
      await settle(tester);
    }

    Future<void> switchToEdit(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('editor-view-menu')));
      await settle(tester);
      await tester.tap(find.text('源码'));
      await settle(tester);
    }

    Future<void> switchToPreview(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('editor-view-menu')));
      await settle(tester);
      await tester.tap(find.text('预览'));
      await settle(tester);
    }

    /// Waits until the preview rebuilt with the loaded link index — the
    /// MarkdownBody key flips once `_load` lands. Tapping a link before that
    /// hits a tree whose recognizers are about to be discarded, so every
    /// link-tap test gates on this instead of hoping the load won a race.
    Future<void> waitForIndexLoaded(WidgetTester tester) async {
      await tester.runAsync(() async {
        for (var i = 0;
            i < 40 &&
                find
                    .byKey(const ValueKey('md-index-true-root-true'))
                    .evaluate()
                    .isEmpty;
            i++) {
          await tester.pump(const Duration(milliseconds: 50));
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
    }

    testWidgets('opens in preview: markdown renders, front matter hides',
        (tester) async {
      await openEditor(tester);

      expect(find.byKey(const ValueKey('editor-body')), findsNothing,
          reason: 'default mode is preview, not the raw editor');
      expect(find.text('大标题'), findsOneWidget);
      expect(find.textContaining('这是加粗的一段'), findsOneWidget);
      expect(find.textContaining('**'), findsNothing,
          reason: 'the asterisks are markdown, not prose');
      expect(find.textContaining('uid: u-a'), findsNothing,
          reason: 'front matter is machine metadata, not prose');
    });

    testWidgets('code block keeps its brackets literal', (tester) async {
      await openEditor(tester);

      expect(find.textContaining('[[b]] 是代码'), findsOneWidget);
    });

    testWidgets('a wiki embed renders as an image from the vault',
        (tester) async {
      await openEditor(tester);

      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('tapping a wiki link jumps to the resolved note',
        (tester) async {
      await openEditor(tester);
      await waitForIndexLoaded(tester);

      await tester.tap(find.text('别名'));
      await settle(tester);

      expect(find.byType(EditorPage), findsOneWidget,
          reason: 'jumping swaps the note in place; the stack must not grow');
      // b.md has no front-matter title and no H1, so the app bar falls back
      // to the filename stem — never the file name itself.
      expect(find.widgetWithText(AppBar, 'b'), findsOneWidget,
          reason: 'the editor now shows the resolved target');
    });

    testWidgets('tapping a dangling link explains instead of navigating',
        (tester) async {
      await openEditor(tester);
      await switchToEdit(tester);

      // Rewrite the buffer so the only link is one that resolves nowhere.
      // Dangling links are normal — that is how "I will write this note
      // later" is written — so the preview must say so, not fail.
      final text = tester
          .widget<TextField>(find.byKey(const ValueKey('editor-body')))
          .controller!
          .text;
      await tester.enterText(
          find.byKey(const ValueKey('editor-body')),
          text.replaceAll('[[b|别名]]', '[[不存在]]'));
      await settle(tester);

      await switchToPreview(tester);
      await tester.tap(find.text('不存在'));
      await settle(tester);
      expect(find.textContaining('未找到笔记'), findsOneWidget);
      expect(find.widgetWithText(AppBar, 'A'), findsOneWidget,
          reason: 'the app bar shows the note title, not "a.md" — a file '
              'name up there reads as "this is my title"');
    });

    testWidgets('tapping a rendered paragraph opens the source at that line',
        (tester) async {
      await openEditor(tester);
      await waitForIndexLoaded(tester);

      await tester.tap(find.textContaining('这是加粗的一段'));
      await settle(tester);

      expect(find.byKey(const ValueKey('editor-body')), findsOneWidget,
          reason: 'a tap on the rendered text lands you in the source view');
      final c = tester
          .widget<TextField>(find.byKey(const ValueKey('editor-body')))
          .controller!;
      expect(c.text, contains('这是**加粗**的一段。'),
          reason: 'the buffer itself is untouched by the tap');
      final sel = c.selection;
      expect(
          c.text.substring(sel.baseOffset, sel.extentOffset),
          '这是**加粗**的一段。',
          reason: 'the source line behind the tapped paragraph is selected, '
              'so the toolbar acts on exactly what was on screen');
    });

    testWidgets('the located line responds to the toolbar', (tester) async {
      await openEditor(tester);
      await waitForIndexLoaded(tester);

      await tester.tap(find.textContaining('这是加粗的一段'));
      await settle(tester);
      await tester.tap(find.byIcon(Icons.title));
      await settle(tester);

      final c = tester
          .widget<TextField>(find.byKey(const ValueKey('editor-body')))
          .controller!;
      expect(c.text, contains('# 这是**加粗**的一段。'),
          reason: 'the toolbar heading button acts on the tapped line');
    });

    testWidgets('tapping a wiki link still navigates instead of repositioning',
        (tester) async {
      await openEditor(tester);
      await waitForIndexLoaded(tester);

      await tester.tap(find.text('别名'));
      await settle(tester);

      expect(find.widgetWithText(AppBar, 'b'), findsOneWidget,
          reason: 'the inline link recognizer wins the gesture arena; a tap '
              'on a link must never fall through to block positioning');
    });

    testWidgets('the format toolbar is present in preview mode too',
        (tester) async {
      await openEditor(tester);

      expect(find.byIcon(Icons.format_bold), findsOneWidget,
          reason: 'the toolbar is the editing surface of the rendered page; '
              'hiding it would force a manual mode switch for every fix');
    });
  });
}
