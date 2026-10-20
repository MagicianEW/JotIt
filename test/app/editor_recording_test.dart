import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/app/providers.dart';
import 'package:jotit/app/vault_session.dart';
import 'package:jotit/app/voice_recorder.dart';
import 'package:jotit/ui/editor_page.dart';
import 'package:path/path.dart' as p;

/// Recording a voice memo, from the editor.
///
/// The microphone is a platform channel, so the flow is driven through
/// [VoiceRecorder] — the same seam the app uses — and the recording itself
/// is a file on disk, which is what the vault ultimately cares about.
///
/// Everything that touches the disk runs inside `runAsync`: `testWidgets`
/// drives a fake clock, so a plain `await` on a file write never completes
/// and the test stops rather than fails.
class _FixedNote extends OpenNote {
  _FixedNote(this.path);

  final String path;

  @override
  String? build() => path;
}

/// A recorder that writes a file instead of talking to a microphone.
class _FakeRecorder implements VoiceRecorder {
  bool permitted = true;
  int starts = 0;
  int stops = 0;
  int cancels = 0;
  String? lastPath;

  final List<int> bytes = <int>[0x49, 0x44, 0x33, 0x04, 0x00, 0xFF, 0xFB];

  @override
  Future<bool> requestPermission() async => permitted;

  @override
  Future<void> start({required String path}) async {
    starts++;
    lastPath = path;
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
  }

  @override
  Future<String?> stop() async {
    stops++;
    return lastPath;
  }

  @override
  Future<void> cancel() async {
    cancels++;
    final path = lastPath;
    if (path == null) return;
    final file = File(path);
    if (file.existsSync()) file.deleteSync();
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  late Directory root;
  late VaultSession vault;
  late _FakeRecorder recorder;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jotit_editor_rec_');
    vault = await VaultSession.open(root.path);
    recorder = _FakeRecorder();
    await vault.writeRaw(
      'notes/a.md',
      utf8.encode('---\nuid: u-a\ntitle: A\n---\n\n第一段\n\n第二段\n'),
    );
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

  /// Taps something and lets the whole flow it starts finish.
  ///
  /// The tap has to happen inside `runAsync` as well: the handler it invokes
  /// is asynchronous and its first real step — creating the temporary
  /// directory the recording goes into — is a disk operation.
  Future<void> tapAndSettle(WidgetTester tester, Finder finder) async {
    await tester.runAsync(() async {
      await tester.tap(finder);
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
            voiceRecorderProvider.overrideWithValue(recorder),
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
    await tester.tap(find.text('源码'));
    await settle(tester);
    return state;
  }

  String bodyOf(WidgetTester tester) => tester
      .widget<TextField>(find.byKey(const ValueKey('editor-body')))
      .controller!
      .text;

  testWidgets('a recording lands in the vault as an attachment and the link '
      'goes into the note', (tester) async {
    await openEditor(tester);

    await tapAndSettle(tester, find.byKey(const ValueKey('editor-record')));
    expect(recorder.starts, 1);
    expect(find.textContaining('录音中'), findsOneWidget,
        reason: 'the user has to be able to see that the microphone is open');

    await tapAndSettle(tester, find.byKey(const ValueKey('editor-record')));
    expect(recorder.stops, 1);

    final attachments =
        Directory(p.join(root.path, 'notes', 'attachments'));
    expect(attachments.existsSync(), isTrue,
        reason: 'a recording is an attachment: it lives beside the note, and '
            'that is what makes it syncable');

    final files = attachments.listSync().whereType<File>().toList();
    expect(files, hasLength(1));
    expect(files.single.path, endsWith('.m4a'),
        reason: 'the extension is what tells the vault and the sync engine '
            'what the file is');
    expect(files.single.readAsBytesSync(), recorder.bytes,
        reason: 'the bytes must arrive unchanged — a re-encoded recording is '
            'a different recording');

    final text = bodyOf(tester);
    expect(text, contains('![[attachments/'));
    expect(text, contains('.m4a]]'),
        reason: 'the link has to name the file that was actually written');
    expect(text, contains('第一段'));
    expect(text, contains('第二段'),
        reason: 'inserting a recording must not eat the rest of the note');
  });

  testWidgets('the link points at the file that was really written',
      (tester) async {
    await openEditor(tester);

    await tapAndSettle(tester, find.byKey(const ValueKey('editor-record')));
    await tapAndSettle(tester, find.byKey(const ValueKey('editor-record')));

    final text = bodyOf(tester);
    final target = RegExp(r'!\[\[(.+?)\]\]').firstMatch(text)!.group(1)!;
    final resolved = File(p.join(root.path, 'notes', target));
    expect(resolved.existsSync(), isTrue,
        reason: 'link "$target" has to resolve to the file that was copied');
  });

  testWidgets('the recording is inserted where the caret is, not at the end',
      (tester) async {
    await openEditor(tester);

    // The caret goes into the middle of the second paragraph.
    final controller = tester
        .widget<TextField>(find.byKey(const ValueKey('editor-body')))
        .controller!;
    final at = controller.text.indexOf('第二段');
    await tester.tap(find.byKey(const ValueKey('editor-body')));
    await settle(tester);
    controller.selection = TextSelection.collapsed(offset: at);
    await settle(tester);

    await tapAndSettle(tester, find.byKey(const ValueKey('editor-record')));
    await tapAndSettle(tester, find.byKey(const ValueKey('editor-record')));

    final text = controller.text;
    final linkAt = text.indexOf('![[attachments/');
    expect(linkAt, isNot(-1));
    expect(linkAt, lessThan(text.indexOf('第二段')),
        reason: 'the recording belongs where the user was writing, not at the '
            'bottom of the note');
  });

  testWidgets('a refused microphone says so and inserts nothing',
      (tester) async {
    recorder.permitted = false;
    await openEditor(tester);

    await tapAndSettle(tester, find.byKey(const ValueKey('editor-record')));

    expect(recorder.starts, 0, reason: 'nothing may be recorded');
    expect(find.textContaining('麦克风权限'), findsOneWidget,
        reason: 'a button that does nothing is indistinguishable from a '
            'broken app');
    expect(bodyOf(tester), isNot(contains('![[attachments/')),
        reason: 'a refused recording must not leave a link behind');
  });

  testWidgets('cancelling a recording leaves neither a link nor a file',
      (tester) async {
    await openEditor(tester);

    await tapAndSettle(tester, find.byKey(const ValueKey('editor-record')));
    expect(recorder.starts, 1);

    await tapAndSettle(
        tester, find.byKey(const ValueKey('editor-cancel-recording')));

    expect(recorder.cancels, 1);
    expect(bodyOf(tester), isNot(contains('![[attachments/')),
        reason: 'a cancelled recording was never wanted');
    expect(
        Directory(p.join(root.path, 'notes', 'attachments')).existsSync(),
        isFalse,
        reason: 'a cancelled recording must not leave a file in the vault');
  });

  testWidgets('the recording is syncable once the note is saved',
      (tester) async {
    // The chain the sync engine depends on: it only pushes files a note
    // **references**, so the row cannot appear while the link exists solely
    // in the editor's buffer.
    await openEditor(tester);

    await tapAndSettle(tester, find.byKey(const ValueKey('editor-record')));
    await tapAndSettle(tester, find.byKey(const ValueKey('editor-record')));

    final beforeSave = await tester.runAsync(() => vault.notes.attachmentPaths());
    expect(beforeSave, isEmpty,
        reason: 'the link has not been written to disk yet');

    final text = bodyOf(tester);
    await tester.runAsync(() => vault.save('notes/a.md', text));
    await settle(tester);

    final afterSave = await tester.runAsync(() => vault.notes.attachmentPaths());
    expect(afterSave, hasLength(1),
        reason: 'after saving, the note references the recording and it can '
            'sync to the other devices');
  });
}
