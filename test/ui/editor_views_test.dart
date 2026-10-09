import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/app/providers.dart';
import 'package:jotit/app/vault_session.dart';
import 'package:jotit/ui/editor_page.dart';
import 'package:jotit/ui/note_preview.dart';
import 'package:super_editor/super_editor.dart';

/// The three view modes: preview, rich (WYSIWYG), source.
///
/// Stage 1 of the rich editor: the mode switch works, the rich pane only
/// accepts notes it can round-trip, and unsupported notes fall back with an
/// explanation instead of a silently mangled save.
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
    root = await Directory.systemTemp.createTemp('jotit_views_');
    vault = await VaultSession.open(root.path);
    await vault.writeRaw(
      'notes/plain.md',
      utf8.encode('---\nuid: u-p\ntitle: 平凡笔记\n---\n\n普通正文。\n'),
    );
    await vault.writeRaw(
      'notes/wiki.md',
      utf8.encode('---\nuid: u-w\ntitle: 带双链\n---\n\n跳到[[other]]。\n'),
    );
    await vault.reindex();
  });

  tearDown(() async {
    await vault.close();
    if (root.existsSync()) await root.delete(recursive: true);
  });

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
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
  }

  Future<void> pickView(WidgetTester tester, String label) async {
    await tester.tap(find.byKey(const ValueKey('editor-view-menu')));
    await settle(tester);
    await tester.tap(find.text(label));
    await settle(tester);
  }

  testWidgets('defaults to preview; source switch keeps the old editor',
      (tester) async {
    await openEditor(tester, 'notes/plain.md');

    expect(find.byKey(const ValueKey('editor-body')), findsNothing);
    await pickView(tester, '源码');
    expect(find.byKey(const ValueKey('editor-body')), findsOneWidget);
  });

  testWidgets('a plain note can enter the rich editor', (tester) async {
    await openEditor(tester, 'notes/plain.md');

    await pickView(tester, '富文本编辑');

    expect(find.byType(SuperEditor), findsOneWidget,
        reason: 'the WYSIWYG pane renders an editable document');
    expect(find.byKey(const ValueKey('editor-body')), findsNothing,
        reason: 'rich mode replaces the raw text field');
  });

  testWidgets('a note with wiki links refuses rich mode with an explanation',
      (tester) async {
    await openEditor(tester, 'notes/wiki.md');

    await pickView(tester, '富文本编辑（含不支持语法）');

    expect(find.byType(SuperEditor), findsNothing,
        reason: 'a serializer that mangles [[links]] must never run');
    expect(find.textContaining('不支持'), findsOneWidget,
        reason: 'the fallback must say why, not just refuse');
    // The menu item is disabled, so the view did not change.
    expect(find.byKey(const ValueKey('editor-body')), findsNothing);
    expect(find.byType(NotePreview), findsOneWidget);
  });

  testWidgets('the preview-tap positioning still lands in source mode',
      (tester) async {
    await openEditor(tester, 'notes/plain.md');
    await settle(tester);

    await tester.tap(find.textContaining('普通正文'));
    await settle(tester);

    expect(find.byKey(const ValueKey('editor-body')), findsOneWidget);
  });
}
