import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jotit/app/providers.dart';
import 'package:jotit/app/vault_session.dart';
import 'package:jotit/ui/editor_page.dart';

/// 反向关联：别的笔记提到了本篇，面板要列出来并能跳过去。
///
/// widget 测试已经证明了逻辑，这一测的是**真机上算得出来、弹层开得了、
/// 点得动**——反链要扫全库正文，它在真机上的表现和在测试环境里不是一回事。
class _FixedNote extends OpenNote {
  _FixedNote(this.path);

  final String path;

  @override
  String? build() => path;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('提到本篇的笔记，面板列得出来也跳得过去', (tester) async {
    final root = await Directory.systemTemp.createTemp('jotit_device_backlink_');
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
          openNoteProvider.overrideWith(() => _FixedNote('notes/录音.md')),
        ],
        child: const MaterialApp(home: EditorPage()),
      ),
    );
    await _settle(tester);

    // 反链是后台算的：等它落地，等应用栏上的角标出现。
    for (var i = 0; i < 60; i++) {
      if (find.byIcon(Icons.hub_outlined).evaluate().isNotEmpty) {
        break;
      }
      await tester.pump(const Duration(milliseconds: 50));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    await tester.tap(find.byKey(const ValueKey('editor-related-notes')));
    await _settle(tester, rounds: 40);

    expect(find.text('A'), findsOneWidget,
        reason: '提到了本篇的那篇笔记要列在面板里');
    expect(find.textContaining('这里提到了录音这个功能'), findsOneWidget,
        reason: '要能看出它是在哪儿提到我的');

    await tester.tap(find.byKey(const ValueKey('related-note-notes/a.md')));
    await _settle(tester, rounds: 40);

    expect(find.widgetWithText(AppBar, 'A'), findsOneWidget,
        reason: '点面板里的一条要跳到那篇笔记');
  });
}

/// Pumps for a while without `pumpAndSettle`.
///
/// The status line ticks once a second while a recording is running, so there
/// is always a frame coming: `pumpAndSettle` would wait for a quiet
/// moment that never arrives.
Future<void> _settle(WidgetTester tester, {int rounds = 25}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
