import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jotit/app/providers.dart';
import 'package:jotit/app/vault_session.dart';
import 'package:jotit/ui/editor_page.dart';

import '../test/support/link_tap.dart';

/// 正文里提到另一篇笔记，那几个字就是链接。
///
/// 词表测试里已经证明了「认得出」，这个测的是另一件事：**点得动**。
/// 提及常常出现在句子中间，位置要靠排版算出来——而真机上的字体度量
/// 和测试环境里的不一样，所以这一条只有在真机上跑才算数。
class _FixedNote extends OpenNote {
  _FixedNote(this.path);

  final String path;

  @override
  String? build() => path;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('正文里提到另一篇笔记的标题，那几个字点得动', (tester) async {
    final root = await Directory.systemTemp.createTemp('jotit_device_mention_');
    final vault = await VaultSession.open(root.path);
    addTearDown(() async {
      await vault.close();
      if (root.existsSync()) await root.delete(recursive: true);
    });

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

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          vaultProvider.overrideWith((ref) async => vault),
          openNoteProvider.overrideWith(() => _FixedNote('notes/a.md')),
        ],
        child: const MaterialApp(home: EditorPage()),
      ),
    );
    await _settle(tester);

    // 等两个索引都落地：链接索引和提及索引。key 变了就说明重建过了。
    for (var i = 0; i < 60; i++) {
      if (find
          .byKey(const ValueKey('md-index-true-mentions-true-root-true'))
          .evaluate()
          .isNotEmpty) {
        break;
      }
      await tester.pump(const Duration(milliseconds: 50));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    final paragraph = find.textContaining('这里提到了');
    expect(paragraph, findsOneWidget);

    final offset = linkOffset(tester, paragraph, '录音');
    expect(offset, isNotNull,
        reason: '「录音」这两个字应该被渲染成可点的链接');

    await tester.tapAt(offset!);
    await _settle(tester, rounds: 40);

    expect(find.widgetWithText(AppBar, '录音'), findsOneWidget,
        reason: '点自动关联出来的词，应该跳到那篇笔记');
  });
}

/// Pumps for a while without `pumpAndSettle`.
///
/// The status line ticks once a second while a recording is running, so
/// there is always a frame coming: `pumpAndSettle` would wait for a quiet
/// moment that never arrives.
Future<void> _settle(WidgetTester tester, {int rounds = 25}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
