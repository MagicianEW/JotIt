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

/// Taking a picture on the phone with the phone's own camera.
///
/// The camera is another application: JotIt hands the shutter to the system
/// camera app and waits for the photo to come back. A test cannot drive that
/// app, so this test waits for it — and a helper on the host presses the
/// shutter while it waits. What is checked here is the half that belongs to
/// JotIt: that the photo comes back, lands in the vault as an attachment, and
/// is linked into the note where the caret was.
class _FixedNote extends OpenNote {
  _FixedNote(this.path);

  final String path;

  @override
  String? build() => path;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a photo taken with the system camera lands in the vault',
      (tester) async {
    final root = await Directory.systemTemp.createTemp('jotit_device_photo_');
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

    // The source view, because that is where the note's text can be read.
    await tester.tap(find.byKey(const ValueKey('editor-view-menu')));
    await _settle(tester);
    await tester.tap(find.text('源码'));
    await _settle(tester);

    final attachments = Directory(p.join(root.path, 'notes', 'attachments'));

    // The photo menu: the camera and the album are two sources of the same
    // thing, so they live behind one button.
    await tester.tap(find.byKey(const ValueKey('editor-photo-menu')));
    await _settle(tester);
    await tester.tap(find.text('拍照'));

    // The system camera is up now. The helper on the host presses the
    // shutter; this loop waits for the photo to come back.
    File? photo;
    for (var i = 0; i < 150; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      await tester.pump();
      if (attachments.existsSync()) {
        final files = attachments.listSync().whereType<File>().toList();
        if (files.isNotEmpty) {
          photo = files.first;
          break;
        }
      }
    }

    expect(photo, isNotNull,
        reason: 'the camera was asked for a picture and none came back');
    if (photo == null) {
      fail('the camera was asked for a picture and none came back');
    }
    final File shot = photo;

    expect(shot.path, endsWith('.jpg'),
        reason: 'the extension is what tells the vault and the sync engine '
            'what the file is');
    expect(shot.lengthSync(), greaterThan(0),
        reason: 'a picture with no bytes in it is not a picture');

    final text = tester
        .widget<TextField>(find.byKey(const ValueKey('editor-body')))
        .controller!
        .text;
    expect(text, contains('![[attachments/'));
    expect(text, contains('.jpg]]'),
        reason: 'the link has to name the file that was actually written');
    expect(text, contains('第一段'));
    expect(text, contains('第二段'),
        reason: 'inserting a picture must not eat the rest of the note');
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
