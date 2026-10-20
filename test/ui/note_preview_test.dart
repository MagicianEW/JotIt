import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/app/providers.dart';
import 'package:jotit/app/vault_session.dart';
import 'package:jotit/domain/vault/mention_index.dart';
import 'package:jotit/ui/editor_page.dart';
import 'package:jotit/ui/note_preview.dart';

import '../support/link_tap.dart';
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

/// 一篇可以被提到的笔记，和一个只含它的索引。
final MentionIndex _mentions = MentionIndex(const <MentionTarget>[
  MentionTarget(
    path: 'notes/录音.md',
    uid: 'u-rec',
    title: '录音',
    stem: '录音',
  ),
]);

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

    test('正文里提到另一篇笔记的标题，那几个字渲染成链接', () {
      final out = renderableBody(
        '这里提到录音这个功能。',
        mentions: _mentions,
        sourcePath: 'notes/a.md',
      );
      expect(out, contains('[录音](jotit-note:'),
          reason: '显示的是用户写的那两个字，指向的是那篇笔记');
      expect(out, contains(Uri.encodeComponent('notes/录音.md')));
    });

    test('用户自己写的链接不再被当成一次提及', () {
      final out = renderableBody(
        '见 [[录音]] 这篇。',
        mentions: _mentions,
        sourcePath: 'notes/a.md',
      );
      expect('jotit-note:'.allMatches(out).length, 1,
          reason: '同一个字只能链一次，否则用户写的链接里会再套一个链接');
    });

    test('没有索引时正文一个字都不改', () {
      final out = renderableBody('这里提到录音这个功能。');
      expect(out, contains('这里提到录音这个功能。'));
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
                    .byKey(const ValueKey(
                        'md-index-true-mentions-true-root-true'))
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

    testWidgets('a HEIC photo renders as an image, not as a file the app '
        'cannot show', (tester) async {
      // HEIC is what a phone hands over by default, and the attachment
      // policy already knows the type. A preview that refused it would make
      // the app look like it had lost the picture. The bytes are a PNG on
      // purpose: what is under test is the *extension* being recognised as
      // a picture, not the HEIC decoder.
      final heic = File(p.join(root.path, 'notes', 'attachments', 'pic.heic'));
      heic.writeAsBytesSync(png);
      await tester.runAsync(() async {
        await vault.writeRaw(
          'notes/a.md',
          utf8.encode(
              '---\nuid: u-a\ntitle: A\n---\n\n嵌图：![[attachments/pic.heic]]\n'),
        );
        await vault.reindex();
      });

      await openEditor(tester);

      expect(find.byType(Image), findsOneWidget,
          reason: 'a HEIC is a picture: the preview has to try to show it '
              'instead of saying the file cannot be displayed');
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

    testWidgets('正文里提到另一篇笔记的标题，那几个字点得动', (tester) async {
      await tester.runAsync(() async {
        await vault.writeRaw(
          'notes/录音.md',
          utf8.encode('---\nuid: u-rec\ntitle: 录音\n---\n\n录音这篇的内容。\n'),
        );
        await vault.writeRaw(
          'notes/a.md',
          utf8.encode(
              '---\nuid: u-a\ntitle: A\n---\n\n先写第一段。\n\n这里提到了录音这个功能。\n'),
        );
        await vault.reindex();
      });

      await openEditor(tester);
      await waitForIndexLoaded(tester);

      final paragraph = find.textContaining('这里提到了');
      expect(paragraph, findsOneWidget);

      final offset = linkOffset(tester, paragraph, '录音');
      expect(offset, isNotNull,
          reason: '「录音」这两个字应该被渲染成可点的链接');

      await tester.tapAt(offset!);
      await settle(tester);

      expect(find.widgetWithText(AppBar, '录音'), findsOneWidget,
          reason: '点自动关联出来的词，应该跳到那篇笔记');
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

    testWidgets('a long note scrolls, and keeps its ends', (tester) async {
      // P1-1: the reading surface used to be a `MarkdownBody` — a widget
      // that explicitly does not scroll — inside a `Center`, so a note
      // taller than the window was cropped at both ends and could not be
      // read past the middle. The whole point of the preview is to read a
      // long note.
      final long = StringBuffer('---\nuid: u-a\ntitle: A\n---\n\n');
      for (var i = 0; i < 60; i++) {
        long.writeln('第 $i 段\n');
      }
      long.writeln('最后一行\n');
      // A disk write inside a widget test has to happen on the real clock,
      // or the continuation is queued in the fake zone and never arrives.
      await tester.runAsync(() async {
        await vault.writeRaw('notes/a.md', utf8.encode(long.toString()));
        await vault.reindex();
      });

      await openEditor(tester);

      final scroller = find.descendant(
        of: find.byType(NotePreview),
        matching: find.byType(Scrollable),
      );
      expect(scroller, findsOneWidget,
          reason: 'the reading surface has to scroll');
      final state = tester.state<ScrollableState>(scroller);
      expect(state.position.maxScrollExtent, greaterThan(0),
          reason: 'a long note is taller than the window');

      await tester.drag(scroller, const Offset(0, -600));
      await settle(tester);

      expect(state.position.pixels, greaterThan(0),
          reason: 'the note moves under the finger');
      expect(find.text('最后一行'), findsOneWidget,
          reason: 'the end of the note is reachable');
    });

    testWidgets('a format action in preview mode is visible on the page',
        (tester) async {
      // P1-2: the preview has no text field to listen to, and the provider
      // does not move, so a format action that only wrote the controller
      // changed the buffer without anything on screen following. The first
      // action rebuilt the page by accident (it flipped the dirty flag);
      // every action after it did not — so the button looked dead, and the
      // invisible change was still written to disk.
      await openEditor(tester);

      String pageText() =>
          tester.widget<NotePreview>(find.byType(NotePreview)).text;

      final before = pageText();
      await tester.tap(find.byIcon(Icons.format_bold));
      await settle(tester);
      final afterBold = pageText();
      expect(afterBold, isNot(before),
          reason: 'the first action reaches the page');

      await tester.tap(find.byIcon(Icons.format_italic));
      await settle(tester);
      final afterItalic = pageText();
      expect(afterItalic, isNot(afterBold),
          reason: 'and so does the second one — only a rebuild can carry it');
    });
  });
}
