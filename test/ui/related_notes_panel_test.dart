import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/app/providers.dart';
import 'package:jotit/app/vault_session.dart';
import 'package:jotit/ui/editor_page.dart';

/// 「提到本篇的笔记」面板。
///
/// 这个面板回答的是一个具体的问题：**别的笔记里，哪些提到了我**。
///
/// 它和预览里的自动提及是同一套规则的两个方向，所以两件事都必须成立：
///
///  * 预览里把「录音」渲染成链接，那篇笔记就该出现在这个面板里；
///  * 面板里列出来的笔记，点进去跳到的就是它。
///
/// 少了任何一半，用户看到的关联关系就是断的。
class _FixedNote extends OpenNote {
  _FixedNote(this.path);

  final String path;

  @override
  String? build() => path;
}

void main() {
  group('相关笔记面板（widget，真实库）', () {
    late Directory root;
    late VaultSession vault;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('jotit_related_');
      vault = await VaultSession.open(root.path);
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

    Future<void> openEditor(WidgetTester tester, String path) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              vaultProvider.overrideWith((ref) async => vault),
              openNoteProvider.overrideWith(() => _FixedNote(path)),
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

    Future<void> writeNotes() async {
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
    }

    testWidgets('面板列出提到本篇的笔记', (tester) async {
      await tester.runAsync(writeNotes);

      await openEditor(tester, 'notes/录音.md');

      await tester.tap(find.byKey(const ValueKey('editor-related-notes')));
      await settle(tester);

      expect(find.text('A'), findsOneWidget,
          reason: '提到了「录音」的那篇笔记要列出来');
      expect(find.textContaining('这里提到了录音这个功能'), findsOneWidget,
          reason: '要能看出它是在哪儿提到我的');
    });

    testWidgets('面板里点一条就跳到那篇笔记', (tester) async {
      await tester.runAsync(writeNotes);

      await openEditor(tester, 'notes/录音.md');
      await tester.tap(find.byKey(const ValueKey('editor-related-notes')));
      await settle(tester);

      await tester.tap(find.byKey(const ValueKey('related-note-notes/a.md')));
      await settle(tester);

      expect(find.widgetWithText(AppBar, 'A'), findsOneWidget,
          reason: '点面板里的一条要跳到那篇笔记');
    });

    testWidgets('没人提到本篇时，面板说清楚是空的', (tester) async {
      await tester.runAsync(() async {
        await vault.writeRaw(
          'notes/独苗.md',
          utf8.encode('---\nuid: u-solo\ntitle: 独苗\n---\n\n没人提到我。\n'),
        );
        await vault.reindex();
      });

      await openEditor(tester, 'notes/独苗.md');
      await tester.tap(find.byKey(const ValueKey('editor-related-notes')));
      await settle(tester);

      expect(find.text('还没有笔记提到这一篇'), findsOneWidget);
    });
  });
}
