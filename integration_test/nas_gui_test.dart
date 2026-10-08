import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:jotit/app/providers.dart';
import 'package:jotit/app/vault_locator.dart';
import 'package:jotit/domain/sync/attachment_policy.dart';
import 'package:jotit/main.dart';
import 'package:jotit/ui/editor_page.dart';
import 'package:path/path.dart' as p;

/// The whole program, on a real machine, against a real WebDAV server.
///
/// Everything below [testWidgets] in the ordinary suite runs in a fake world:
/// a clock that does not move, a `path_provider` with no platform behind it.
/// That world is good for proving decisions and useless for proving the
/// program works. This runs the shipped shell — location gate, home page,
/// editor, settings, the sync controller — inside the real application on a
/// desktop, pointed at a real NAS, and then reads the result back over HTTP to
/// confirm the bytes actually landed there.
///
/// Nothing here is mocked except *where the vault lives*, which is redirected
/// at a temp directory so a test run cannot eat the author's notes.
///
/// Needs `JOTIT_DAV_URL`, `JOTIT_DAV_USER` and `JOTIT_DAV_PASS`. Without them
/// it skips rather than fails: the server is a LAN address that will not be
/// there on somebody else's desk.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final url = Platform.environment['JOTIT_DAV_URL'];
  final user = Platform.environment['JOTIT_DAV_USER'];
  final pass = Platform.environment['JOTIT_DAV_PASS'];
  final configured = url != null && user != null && pass != null;

  if (!configured) {
    stderr.writeln(
      'JOTIT_DAV_URL / JOTIT_DAV_USER / JOTIT_DAV_PASS are not all set — the '
      'desktop GUI test will be skipped. It needs a WebDAV server that answers '
      'PROPFIND, which is a LAN address that will not be there on somebody '
      "else's desk.");
  }

  late Directory sandbox;
  late Directory vaultRoot;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('jotit_guids_');
    // `Documents/JotIt` does not exist inside the sandbox, so the location
    // gate adopts it — the same as a first run on a fresh machine.
    vaultRoot = Directory(p.join(sandbox.path, 'docs', 'JotIt'));
    await vaultRoot.create(recursive: true);
  });

  tearDown(() async {
    // The vault keeps `jotit.db` open for as long as the app is mounted, and
    // Windows will not delete a file somebody else is holding. The test body
    // unmounts the app first; this retries briefly anyway, and never fails
    // the run over a temp directory — the OS will collect it eventually, and
    // a leaked `%TEMP%` folder is not a reason to report a green test red.
    for (var i = 0; i < 10 && sandbox.existsSync(); i++) {
      try {
        await sandbox.delete(recursive: true);
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
  });

  testWidgets(
    'a note written on the desktop reaches the server byte for byte',
    (tester) async {
      final davUrl = url!;
      final davUser = user!;
      final davPass = pass!;
      final noteName = 'guids-${DateTime.now().millisecondsSinceEpoch}';
      final body = '第一行 中文\r\n第二行 with "quotes" & <angles>\r\n第三行';

      await tester.pumpWidget(ProviderScope(
        overrides: [
          vaultLocatorProvider.overrideWith(
            (ref) async => VaultLocator(
              Directory(p.join(sandbox.path, 'support')),
              documentsDir: Directory(p.dirname(vaultRoot.path)),
            ),
          ),
        ],
        child: const JotItApp(),
      ));

      await _settle(tester, find.text('库里还没有笔记'));
      await tester.tap(find.text('新建'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('new-note-title')), findsOneWidget);

      await tester.enterText(
          find.byKey(const ValueKey('new-note-title')), noteName);
      await tester.tap(find.text('创建'));

      // The editor opens on the new note, and the dialog has to be fully
      // dismissed before anything touches a text field. Interrupting the
      // route transition puts the overlay in a state where Flutter reports
      // duplicate global keys, and the save that follows silently does
      // nothing.
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('editor-body')), findsOneWidget);
      expect(find.byKey(const ValueKey('new-note-title')), findsNothing);

      final notePath = p.join(vaultRoot.path, 'notes', '$noteName.md');
      expect(File(notePath).existsSync(), isTrue,
          reason: 'the file on disk is the whole promise of the app');

      // What the file looked like before anybody typed in it, so the
      // preservation of its conventions can be checked afterwards.
      final before = await File(notePath).readAsString();
      final wasCrlf = before.contains('\r\n');

      await tester.enterText(find.byKey(const ValueKey('editor-body')), body);

      // The shortcut the tooltip promises, not the button beside it. Using
      // the keyboard here means the test fails if Ctrl+S is ever removed
      // again, and it is the path a user actually takes.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

      // Whatever the save ended up saying, say it. Asserting only on
      // '已保存' turns a real defect into "could not find a widget", which
      // is a sentence that helps nobody.
      await _settleAny(tester,
          ['已保存', '内容没有变化', '保存失败'], seconds: 30);
      final said = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .whereType<String>()
          .toList();
      // ignore: avoid_print
      print('editor status bar: $said');
      expect(find.text('已保存'), findsOneWidget,
          reason: 'the editor said: $said');

      final local = await File(notePath).readAsBytes();
      final written = utf8.decode(local);
      expect(written, contains('第一行 中文'));

      // The editor keeps the line endings the file already had. ADR-1 is not
      // "write back what the user typed" — it is "do not re-serialise
      // Markdown", and a note somebody keeps in CRLF must not silently become
      // LF because Windows was where it got edited. This note was created
      // with LF, so LF is what has to come back; the rule is the preservation,
      // not the particular convention.
      expect(written.contains('\r\n'), wasCrlf,
          reason: 'the editor changed the file’s line endings');
      // And no BOM was invented for a file that had none.
      expect(local.take(3).toList(), isNot([0xEF, 0xBB, 0xBF]));

      // Out through the UI, not by calling the engine directly.
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('新建'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();
      expect(find.text('尚未配置远端'), findsOneWidget);

      await tester.tap(find.text('添加远端'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('root-pass')), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('root-name')), '测试 NAS');
      await tester.enterText(
          find.byKey(const ValueKey('root-url')), '$davUrl/JotIt/');
      await tester.enterText(find.byKey(const ValueKey('root-user')), davUser);
      await tester.enterText(find.byKey(const ValueKey('root-pass')), davPass);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.sync), findsOneWidget);

      await tester.tap(find.byIcon(Icons.sync));
      await _settle(tester, find.textContaining('上次同步'), seconds: 60);

      // No error line: the report is where a refused write would show up.
      expect(find.textContaining('同步失败'), findsNothing);
      expect(find.textContaining('服务器拒绝了这些写入'), findsNothing);
      // Scoped to the report's own wording. A bare `冲突` matches the settings
      // page's standing labels — "冲突副本" and "没有未解决的冲突" — and fails
      // on a run where nothing whatsoever went wrong.
      expect(find.textContaining('冲突，两份都留在'), findsNothing);
      expect(find.text('没有未解决的冲突'), findsOneWidget);

      // And the server really has the bytes, read back over HTTP.
      final target = Uri.parse(
          '$davUrl/JotIt/notes/${Uri.encodeComponent('$noteName.md')}');
      final auth = 'Basic ${base64Encode(utf8.encode('$davUser:$davPass'))}';

      // Registered before the assertions, not after them. A run that fails
      // halfway through used to leave its note sitting on the author's NAS,
      // and the next run then had a file from the last run to reason about —
      // which is precisely the kind of state a sync test must not inherit.
      addTearDown(() async {
        try {
          await http.delete(target, headers: {'Authorization': auth});
        } on Object {
          // A failed cleanup must not replace the real failure with a
          // confusing one; the note is named after the test that made it.
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });

      final response = await http.get(target, headers: {'Authorization': auth});
      expect(response.statusCode, 200,
          reason: 'GET $target returned ${response.statusCode}');

      expect(response.bodyBytes, local,
          reason: 'what came back is not what was written — ADR-1 says the '
              'file is the truth, so a lossy round trip is data loss');
    },
    skip: !configured,
  );

  testWidgets(
    'an attachment reaches the server byte for byte',
    (tester) async {
      // This is the case the note test above cannot reach. §5.5 sends
      // attachments as a *stream* with a scaled timeout, and every one of
      // those decisions only matters on a real socket to a real server: the
      // buffered path and the streamed path look identical in a unit test
      // that writes to an in-process fake.
      //
      // On the NAS this project actually syncs against, an 11.5 MB body takes
      // about 205 s at roughly 56 KB/s. The budget that permits that
      // (`DavClient.timeoutOverrideFor`) is exactly the thing that used to be
      // too small, so this test is what would have caught it.
      final davUrl = url!;
      final davUser = user!;
      final davPass = pass!;
      final noteName = 'guatt-${DateTime.now().millisecondsSinceEpoch}';

      // Deterministic pseudo-random bytes. A repeating pattern would let a
      // length check pass while the content was subtly wrong.
      final size = kLargeAttachmentBytes + 400000;
      final source = File(p.join(sandbox.path, 'picture.png'));
      final payload = Uint8List(size);
      var x = 987654321;
      for (var i = 0; i < size; i++) {
        x = (1103515245 * x + 12345) & 0x7FFFFFFF;
        payload[i] = (x >> 16) & 0xFF;
      }
      await source.writeAsBytes(payload, flush: true);

      await tester.pumpWidget(ProviderScope(
        overrides: [
          vaultLocatorProvider.overrideWith(
            (ref) async => VaultLocator(
              Directory(p.join(sandbox.path, 'support')),
              documentsDir: Directory(p.dirname(vaultRoot.path)),
            ),
          ),
        ],
        child: const JotItApp(),
      ));

      await _settle(tester, find.text('库里还没有笔记'));
      await tester.tap(find.text('新建'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('new-note-title')), noteName);
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('editor-body')), findsOneWidget);

      // The picker is the only part that needs a platform channel, and its
      // body is empty of anything to get wrong — everything after it is what
      // this test is for.
      final state = tester.state<EditorPageState>(find.byType(EditorPage));
      await state.attachForTesting(source.path);
      await tester.pumpAndSettle();

      final attachmentsDir =
          Directory(p.join(vaultRoot.path, 'notes', 'attachments'));
      final copied = attachmentsDir.listSync().whereType<File>();
      expect(copied, hasLength(1),
          reason: 'the attachment belongs in the vault, not in the temp '
              'directory it was picked from');
      final stored = copied.single;
      expect(await stored.readAsBytes(), payload,
          reason: 'the copy that landed on disk has to be the whole file');

      // Inserting an attachment marks the note dirty, so `PopScope` will not let
      // the route close and `pageBack` raises the discard dialog. Save first —
      // which is what the status line already told the user to do ("保存后同步"),
      // and which the sync step below depends on anyway: an unsaved link never
      // reaches the file, let alone the server.
      //
      // The button, not Ctrl+S. `CallbackShortcuts` wraps the `Scaffold`, so
      // the shortcut only fires while focus is somewhere inside it, and
      // calling the attach seam directly — as this test must — leaves focus
      // where the test framework put it. Waiting on a shortcut that cannot
      // arrive is how a test spends thirty seconds proving nothing.
      await tester.tap(find.byIcon(Icons.save_outlined));
      await _settleAny(tester, ['已保存', '内容没有变化', '保存失败'], seconds: 30);
      expect(find.text('已保存'), findsOneWidget,
          reason: 'the attachment was inserted but never written to disk, so '
              'there would be nothing for the server to receive');

      await tester.pageBack();
      await tester.pumpAndSettle();
      // Assert the way home rather than tapping a button and finding out
      // where we were. The settings icon is on the list page, and
      // "could not find icon" says nothing about why the page underneath was
      // not the list page — it is what a dialog left open looks like.
      expect(find.text('新建'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加远端'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('root-name')), '测试 NAS');
      await tester.enterText(
          find.byKey(const ValueKey('root-url')), '$davUrl/JotIt/');
      await tester.enterText(find.byKey(const ValueKey('root-user')), davUser);
      await tester.enterText(find.byKey(const ValueKey('root-pass')), davPass);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      final storedName = p.basename(stored.path);
      final remote = Uri.parse(
          '$davUrl/JotIt/notes/attachments/${Uri.encodeComponent(storedName)}');
      final noteRemote = Uri.parse(
          '$davUrl/JotIt/notes/${Uri.encodeComponent('$noteName.md')}');
      final auth = 'Basic ${base64Encode(utf8.encode('$davUser:$davPass'))}';

      addTearDown(() async {
        for (final u in <Uri>[remote, noteRemote]) {
          try {
            await http.delete(u, headers: {'Authorization': auth});
          } on Object {
            // A failed cleanup must not replace the real failure.
          }
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });

      await tester.tap(find.byIcon(Icons.sync));
      // Generous, and honestly so: the measured upload is ~205 s, and this
      // waits for the UI to say the round finished rather than for a fixed
      // count. A ceiling that is too tight here would report a slow server as
      // a broken one — the very mistake this file's sibling made.
      await _settle(tester, find.textContaining('上次同步'), seconds: 900);

      expect(find.textContaining('同步失败'), findsNothing);
      expect(find.textContaining('服务器拒绝了这些写入'), findsNothing);

      final response = await http.get(remote, headers: {'Authorization': auth});
      expect(response.statusCode, 200,
          reason: 'GET $remote returned ${response.statusCode}');
      expect(response.bodyBytes.length, payload.length,
          reason: 'a short upload is the failure this test exists to rule out');
      expect(response.bodyBytes, payload,
          reason: '§5.5 judges attachments by SHA-256; a transfer that lands '
              'the right length and the wrong bytes is still data loss');
    },
    // The whole point is that this takes minutes on a real server, which the
    // integration binding's own default timeout will not allow.
    timeout: const Timeout(Duration(minutes: 20)),
    skip: !configured,
  );
}

/// Pumps until any one of [needles] appears as the text of some widget.
Future<void> _settleAny(WidgetTester tester, List<String> needles,
    {int seconds = 20}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  bool seen() => tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data)
      .whereType<String>()
      .any((s) => needles.any((n) => s.startsWith(n)));

  while (!seen() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(seen(), isTrue,
      reason: 'timed out after ${seconds}s waiting for any of $needles');
}

/// Pumps until [finder] matches, or gives up after [seconds].
///
/// `pumpAndSettle` is no use here: a `CircularProgressIndicator` is on screen
/// while a round runs and it animates forever. Nothing is faked in this test,
/// so the waits are honest wall-clock waits.
///
/// The assertion at the end is the point of the helper. An earlier version
/// phrased it as "empty means it expects findsNothing", which passes whether
/// or not the widget ever appeared — and then a dialog that had not finished
/// dismissing stayed in the tree and every later `find.byType(TextField)`
/// matched two widgets instead of one.
Future<void> _settle(WidgetTester tester, Finder finder,
    {int seconds = 20}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (finder.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(finder, findsWidgets,
      reason: 'timed out after ${seconds}s waiting for $finder');
}
