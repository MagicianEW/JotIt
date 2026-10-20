import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/app/photo_service.dart';
import 'package:jotit/app/providers.dart';
import 'package:jotit/app/vault_session.dart';
import 'package:jotit/ui/editor_page.dart';
import 'package:path/path.dart' as p;

/// Taking a picture — or picking one — and getting it into the note.
///
/// The camera is a platform channel, so the flow is driven through
/// [PhotoService] — the same seam the app uses — and the picture itself is a
/// file on disk, which is what the vault ultimately cares about.
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

/// A photo service that hands back a file instead of talking to a camera.
class _FakePhotoService implements PhotoService {
  int captures = 0;
  int picks = 0;

  /// What the camera hands back. Null means the user backed out.
  String? captureResult;

  /// What the album hands back. Null means the user backed out.
  String? pickResult;

  /// Thrown instead of answering, to stand in for a platform that refuses.
  Object? failure;

  @override
  Future<String?> capturePhoto(BuildContext context) async {
    captures++;
    final f = failure;
    if (f != null) throw f;
    return captureResult;
  }

  @override
  Future<String?> pickPhoto() async {
    picks++;
    final f = failure;
    if (f != null) throw f;
    return pickResult;
  }
}

void main() {
  late Directory root;
  late Directory staging;
  late VaultSession vault;
  late _FakePhotoService photos;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jotit_editor_photo_');
    staging = await Directory.systemTemp.createTemp('jotit_editor_photo_src_');
    vault = await VaultSession.open(root.path);
    photos = _FakePhotoService();
    await vault.writeRaw(
      'notes/a.md',
      utf8.encode('---\nuid: u-a\ntitle: A\n---\n\n第一段\n\n第二段\n'),
    );
  });

  tearDown(() async {
    await vault.close();
    if (root.existsSync()) await root.delete(recursive: true);
    if (staging.existsSync()) await staging.delete(recursive: true);
  });

  /// Writes a file that stands in for a photo the camera or album produced.
  ///
  /// Synchronous on purpose: a `testWidgets` body runs on a fake clock, and
  /// an `await` on a real disk write there never completes — the test stops
  /// instead of failing. The same reason the file operations below live
  /// inside `runAsync`.
  String stagePhoto(String name) {
    final file = File(p.join(staging.path, name));
    file.writeAsBytesSync(<int>[0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]);
    return file.path;
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
  }

  Future<void> choose(WidgetTester tester, String label) async {
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('editor-photo-menu')));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.runAsync(() async {
      await tester.tap(find.text(label));
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
            photoServiceProvider.overrideWithValue(photos),
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

  testWidgets('a photo taken with the camera lands in the vault and the link '
      'goes into the note', (tester) async {
    photos.captureResult = stagePhoto('shot.jpg');
    await openEditor(tester);

    await choose(tester, '拍照');

    expect(photos.captures, 1);
    expect(photos.picks, 0);

    final attachments =
        Directory(p.join(root.path, 'notes', 'attachments'));
    expect(attachments.existsSync(), isTrue,
        reason: 'a photo is an attachment: it lives beside the note, and that '
            'is what makes it syncable');

    final files = attachments.listSync().whereType<File>().toList();
    expect(files, hasLength(1));
    expect(files.single.path, endsWith('.jpg'),
        reason: 'the extension is what tells the vault and the sync engine '
            'what the file is');

    final text = bodyOf(tester);
    expect(text, contains('![[attachments/'));
    expect(text, contains('.jpg]]'),
        reason: 'the link has to name the file that was actually written');
    expect(text, contains('第一段'));
    expect(text, contains('第二段'),
        reason: 'inserting a photo must not eat the rest of the note');
  });

  testWidgets('a photo picked from the album lands in the vault too',
      (tester) async {
    photos.pickResult = stagePhoto('album.png');
    await openEditor(tester);

    await choose(tester, '从相册选择');

    expect(photos.picks, 1);
    expect(photos.captures, 0);

    final attachments =
        Directory(p.join(root.path, 'notes', 'attachments'));
    final files = attachments.listSync().whereType<File>().toList();
    expect(files, hasLength(1));
    expect(files.single.path, endsWith('.png'));
    expect(bodyOf(tester), contains('.png]]'));
  });

  testWidgets('the link points at the file that was really written',
      (tester) async {
    photos.captureResult = stagePhoto('shot.jpg');
    await openEditor(tester);

    await choose(tester, '拍照');

    final text = bodyOf(tester);
    final target = RegExp(r'!\[\[(.+?)\]\]').firstMatch(text)!.group(1)!;
    final resolved = File(p.join(root.path, 'notes', target));
    expect(resolved.existsSync(), isTrue,
        reason: 'link "$target" has to resolve to the file that was copied');
  });

  testWidgets('the photo is inserted where the caret is, not at the end',
      (tester) async {
    photos.captureResult = stagePhoto('shot.jpg');
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

    await choose(tester, '拍照');

    final text = controller.text;
    final linkAt = text.indexOf('![[attachments/');
    expect(linkAt, isNot(-1));
    expect(linkAt, lessThan(text.indexOf('第二段')),
        reason: 'the photo belongs where the user was writing, not at the '
            'bottom of the note');
  });

  testWidgets('a picture the user backed out of inserts nothing',
      (tester) async {
    photos.captureResult = null;
    photos.pickResult = null;
    await openEditor(tester);

    await choose(tester, '拍照');

    expect(photos.captures, 1);
    expect(bodyOf(tester), isNot(contains('![[attachments/')),
        reason: 'a cancelled capture was never wanted');
    expect(
        Directory(p.join(root.path, 'notes', 'attachments')).existsSync(),
        isFalse,
        reason: 'a cancelled capture must not leave a file in the vault');
    expect(find.textContaining('取照片失败'), findsNothing,
        reason: 'backing out is not a failure, and saying it is would make '
            'every cancelled camera look broken');
  });

  testWidgets('a camera that refuses says so and inserts nothing',
      (tester) async {
    photos.failure = const PhotoUnsupported('这台机器上没有找到可用的相机');
    await openEditor(tester);

    await choose(tester, '拍照');

    expect(bodyOf(tester), isNot(contains('![[attachments/')),
        reason: 'a failed capture must not leave a link behind');
    expect(find.textContaining('取照片失败'), findsOneWidget,
        reason: 'a button that does nothing is indistinguishable from a '
            'broken app');
    expect(find.textContaining('没有找到可用的相机'), findsOneWidget,
        reason: 'the user has to be told *why*, not just that it went wrong');
  });

  testWidgets('a photo the album hands over keeps its own extension',
      (tester) async {
    // HEIC is what a phone hands over by default. The preview has to know
    // how to show it, and the sync engine has to know how to send it.
    photos.pickResult = stagePhoto('iphone.heic');
    await openEditor(tester);

    await choose(tester, '从相册选择');

    final attachments =
        Directory(p.join(root.path, 'notes', 'attachments'));
    final files = attachments.listSync().whereType<File>().toList();
    expect(files, hasLength(1));
    expect(files.single.path, endsWith('.heic'));
    expect(bodyOf(tester), contains('.heic]]'));
  });

  testWidgets('the photo is syncable once the note is saved', (tester) async {
    // The chain the sync engine depends on: it only pushes files a note
    // **references**, so the row cannot appear while the link exists solely
    // in the editor's buffer.
    photos.captureResult = stagePhoto('shot.jpg');
    await openEditor(tester);

    await choose(tester, '拍照');

    final beforeSave = await tester.runAsync(() => vault.notes.attachmentPaths());
    expect(beforeSave, isEmpty,
        reason: 'the link has not been written to disk yet');

    final text = bodyOf(tester);
    await tester.runAsync(() => vault.save('notes/a.md', text));
    await settle(tester);

    final afterSave = await tester.runAsync(() => vault.notes.attachmentPaths());
    expect(afterSave, hasLength(1),
        reason: 'after saving, the note references the photo and it can sync '
            'to the other devices');
  });
}
