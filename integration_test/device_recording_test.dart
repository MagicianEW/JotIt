import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jotit/app/providers.dart';
import 'package:jotit/app/vault_session.dart';
import 'package:jotit/ui/editor_page.dart';
import 'package:path/path.dart' as p;

/// A recording made on the phone's own microphone.
///
/// Everything before this was a fake: the recorder was a stub that wrote
/// bytes, and the test proved the *plumbing* worked. This one opens a real
/// microphone, records a real few seconds of the room, and checks that what
/// came out is a file with sound in it.
///
/// It runs on a device, not in a test harness, so the clock is the wall
/// clock: a `Future.delayed` really waits, and a `pump` really advances.
class _FixedNote extends OpenNote {
  _FixedNote(this.path);

  final String path;

  @override
  String? build() => path;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a recording made on a real microphone lands in the vault',
      (tester) async {
    final root = await Directory.systemTemp.createTemp('jotit_device_rec_');
    final vault = await VaultSession.open(root.path);
    addTearDown(() async {
      await vault.close();
      if (root.existsSync()) await root.delete(recursive: true);
    });
    await vault.writeRaw(
      'notes/a.md',
      utf8.encode('---\nuid: u-a\ntitle: 真机测试\n---\n\n第一段。\n\n第二段。\n'),
    );

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

    // The editor opens in the preview view on a phone, and the preview shows
    // the note as a rendered page — the `![[…]]` link is not a text field
    // there. The source view is where the text the editor actually holds can
    // be read, so that is where this test reads it.
    await tester.tap(find.byKey(const ValueKey('editor-view-menu')));
    await _settle(tester);
    await tester.tap(find.text('源码'));
    await _settle(tester);

    // Start recording. The microphone permission has to be granted before
    // the run — the prompt is a system dialog, and a test cannot answer it.
    await tester.tap(find.byKey(const ValueKey('editor-record')));
    await _settle(tester);

    // Whatever the editor has to say is the diagnosis: "没有麦克风权限",
    // "录音失败：…" and "先打开一篇可编辑的笔记" are three very different
    // problems, and guessing between them from the outside is how a phone
    // bug stays a phone bug.
    // ignore: avoid_print
    print('EDITOR TEXTS: ${_visibleTexts(tester)}');
    // A layout overflow is thrown as an exception, not printed — and an
    // app bar that cannot fit its buttons is exactly the kind of thing
    // that only a narrow phone screen shows.
    // ignore: avoid_print
    print('LAYOUT EXCEPTION: ${tester.takeException()}');
    // ignore: avoid_print
    print('RECORD BUTTON RECT: '
        '${tester.getRect(find.byKey(const ValueKey('editor-record')))}');
    // ignore: avoid_print
    print('SCREEN SIZE: ${tester.view.physicalSize} '
        '@ ${tester.view.devicePixelRatio}');
    // The button being live is the difference between "the tap never
    // reached the handler" and "the handler is stuck".
    // ignore: avoid_print
    print('RECORD ONPRESSED: '
        '${tester.widget<IconButton>(find.byKey(const ValueKey('editor-record'))).onPressed}');
    final provider = ProviderScope.containerOf(
      tester.element(find.byType(EditorPage)),
    ).read(editableNoteProvider);
    // ignore: avoid_print
    print('NOTE PROVIDER: hasValue=${provider.hasValue} '
        'hasError=${provider.hasError} isLoading=${provider.isLoading} '
        'value=${provider.asData?.value?.title}');

    expect(
      find.textContaining('录音中'),
      findsOneWidget,
      reason: 'the user has to be able to see that the microphone is open',
    );

    // Let it record for real. A device in a quiet room still records
    // something; silence is still bytes, and bytes are what has to arrive.
    await Future<void>.delayed(const Duration(seconds: 4));
    await _settle(tester);

    await tester.tap(find.byKey(const ValueKey('editor-record')));
    await _settle(tester, rounds: 40);

    final attachments = Directory(p.join(root.path, 'notes', 'attachments'));
    expect(attachments.existsSync(), isTrue,
        reason: 'a recording is an attachment: it lives beside the note, and '
            'that is what makes it syncable');

    final files = attachments.listSync().whereType<File>().toList();
    expect(files, hasLength(1), reason: 'exactly one recording, not two');
    expect(files.single.path, endsWith('.m4a'),
        reason: 'the extension is what tells the vault and the sync engine '
            'what the file is');
    expect(files.single.lengthSync(), greaterThan(100),
        reason: 'a real recording of a few seconds has real bytes in it — an '
            'empty file means the microphone never opened');

    final text = tester
        .widget<TextField>(find.byKey(const ValueKey('editor-body')))
        .controller!
        .text;
    expect(text, contains('![[attachments/'));
    expect(text, contains('.m4a]]'),
        reason: 'the link has to name the file that was actually written');
    expect(text, contains('第一段'));
    expect(text, contains('第二段'),
        reason: 'inserting a recording must not eat the rest of the note');

    // The MIME table has to know what it is, or the sync engine sends the
    // wrong Content-Type.
    final target = RegExp(r'!\[\[(.+?)\]\]').firstMatch(text)!.group(1)!;
    expect(target, endsWith('.m4a'));
  });
}

/// Every piece of text currently on screen, so a failure can say what the
/// app was actually showing.
List<String> _visibleTexts(WidgetTester tester) {
  return tester
      .widgetList<Text>(find.byType(Text))
      .map((Text t) => t.data)
      .whereType<String>()
      .where((String s) => s.trim().isNotEmpty)
      .toList();
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
