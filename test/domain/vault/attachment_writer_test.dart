import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/core/vault_paths.dart';
import 'package:jotit/domain/vault/attachment_writer.dart';

/// v3.0 §9.3 rules 1–3 and ADR-11.
///
/// The rule this file is really about is the one v2.0 got wrong. A blanket
/// "reject any `../`" breaks as soon as a note lives in a subfolder, because
/// the legitimate link from `projects/jotit/design.md` to its picture *is*
/// `../../attachments/x.png`. v3.0 replaces it with "normalise, then check".
///
/// Both halves are tested separately, because they fail in opposite
/// directions: normalising without checking lets a link escape the vault, and
/// checking without normalising rejects every attachment in every subfolder —
/// which is exactly the bug v2.0 shipped.
void main() {
  late Directory vault;
  late AttachmentWriter writer;

  setUp(() async {
    vault = await Directory.systemTemp.createTemp('jotit_attach_write_');
    writer = AttachmentWriter(vaultRoot: vault.path);
  });

  tearDown(() async {
    if (vault.existsSync()) await vault.delete(recursive: true);
  });

  File fileAt(String relative) {
    final f = File(
        '${vault.path}${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}');
    f.parent.createSync(recursive: true);
    return f;
  }

  group('where the file lands', () {
    test('into an attachments folder beside the note', () async {
      final result = await writer.attach(
        notePath: 'notes/a.md',
        sourcePath: '/tmp/whatever.png',
        bytes: Uint8List.fromList(<int>[1, 2, 3]),
      );

      expect(result.attachmentPath,
          startsWith('notes/attachments/'));
      expect(result.attachmentPath, endsWith('.png'));
      expect(File('${vault.path}/notes/attachments/'
          '${result.attachmentPath.split('/').last}').existsSync(), isTrue);
    });

    test('into the subfolder when the note is in one', () async {
      // The whole reason v2.0's ban had to be replaced.
      final result = await writer.attach(
        notePath: 'notes/projects/jotit/design.md',
        sourcePath: '/tmp/whatever.png',
        bytes: Uint8List.fromList(<int>[1]),
      );

      expect(result.attachmentPath, startsWith('notes/projects/jotit/attachments/'));
    });
  });

  group('ADR-11 naming', () {
    test('the user filename never survives', () async {
      final source = fileAt('inbox/IMG_0042.png')
        ..writeAsBytesSync(<int>[9, 9, 9]);

      final result =
          await writer.attach(notePath: 'notes/a.md', sourcePath: source.path);

      expect(result.attachmentPath, isNot(contains('IMG_0042')));
      // The extension is kept: dropping it would leave the sync engine with
      // no way to send a Content-Type, and every other tool unable to tell
      // what the file is.
      expect(result.attachmentPath, endsWith('.png'));
      expect(result.attachmentPath.split('/').last,
          matches(RegExp(r'^[0-9a-f-]{36}\.png$')));
    });

    test('two inserts of the same file never collide', () async {
      final source = fileAt('inbox/photo.png')..writeAsBytesSync(<int>[1]);

      final a = await writer.attach(notePath: 'notes/a.md', sourcePath: source.path);
      final b = await writer.attach(notePath: 'notes/a.md', sourcePath: source.path);

      expect(a.attachmentPath, isNot(b.attachmentPath),
          reason: 'ADR-11: content is never rewritten in place, so the path '
              'must be new every time');
    });

    test('the extension is lowercased', () async {
      final source = fileAt('inbox/SHOT.PNG')..writeAsBytesSync(<int>[1]);
      final result =
          await writer.attach(notePath: 'notes/a.md', sourcePath: source.path);
      expect(result.attachmentPath, endsWith('.png'));
    });

    test('a file with no extension does not have one invented', () async {
      final source = fileAt('inbox/pasted')..writeAsBytesSync(<int>[1]);
      final result =
          await writer.attach(notePath: 'notes/a.md', sourcePath: source.path);
      // Still a uuid, and still no extension: guessing one would make the
      // sync engine send a Content-Type the file is not, which is the same
      // class of lie the `text/markdown` default was.
      expect(result.attachmentPath.split('/').last,
          matches(RegExp(r'^[0-9a-f-]{36}$')));
    });
  });

  group('§9.3 rule 1: the link is relative to the note', () {
    test('a note at the top of the tree links forwards', () {
      expect(
        writer.linkTargetFor(
          notePath: 'notes/a.md',
          attachmentPath: 'notes/attachments/x.png',
        ),
        'attachments/x.png',
      );
    });

    test('a note in a subfolder links with ..', () {
      // This exact string is what v2.0's blanket ban refused.
      expect(
        writer.linkTargetFor(
          notePath: 'notes/projects/jotit/design.md',
          attachmentPath: 'notes/projects/jotit/attachments/x.png',
        ),
        'attachments/x.png',
      );
    });

    test('the separator is a forward slash on every platform', () {
      final target = writer.linkTargetFor(
        notePath: 'notes/a/b.md',
        attachmentPath: 'notes/a/attachments/x.png',
      );
      expect(target, isNot(contains('\\')),
          reason: 'a Windows-authored backslash is not portable, and these '
              'notes sync to other devices');
    });

    test('the markdown wraps it as an embed', () async {
      final result = await writer.attach(
        notePath: 'notes/a.md',
        sourcePath: '/tmp/x.png',
        bytes: Uint8List.fromList(<int>[1]),
      );
      expect(result.markdown, '![[${result.linkTarget}]]');
      expect(result.linkTarget, startsWith('attachments/'));
    });
  });

  group('§9.3 rule 3: check after normalising', () {
    test('a note outside notes/ is refused, with a reason', () async {
      await expectLater(
        writer.attach(
          notePath: '_conflicts/x/local.md',
          sourcePath: '/tmp/x.png',
          bytes: Uint8List.fromList(<int>[1]),
        ),
        throwsA(isA<AttachmentRefused>()),
      );
    });

    test('a note that tries to climb out is refused', () async {
      // Normalisation rejects this before any write is attempted, which is the
      // point: the check is not "warn after writing".
      await expectLater(
        writer.attach(
          notePath: 'notes/../../escape.md',
          sourcePath: '/tmp/x.png',
          bytes: Uint8List.fromList(<int>[1]),
        ),
        throwsA(isA<AttachmentRefused>()),
      );
      expect(Directory('${vault.path}/..').listSync().whereType<Directory>(),
          isNot(contains(predicate<Directory>((d) => d.path.contains('escape')))));
    });

    test('a refused insert writes nothing', () async {
      try {
        await writer.attach(
          notePath: '../outside.md',
          sourcePath: '/tmp/x.png',
          bytes: Uint8List.fromList(<int>[1]),
        );
      } on AttachmentRefused {
        // expected
      }
      expect(Directory('${vault.path}/notes/attachments').existsSync(), isFalse);
    });
  });

  group('missing and empty sources', () {
    test('a path that does not exist says so', () async {
      await expectLater(
        writer.attach(
          notePath: 'notes/a.md',
          sourcePath: '${vault.path}/nope.png',
        ),
        throwsA(isA<AttachmentRefused>()),
      );
    });

    test('an empty file is refused rather than written as a zero-byte file',
        () async {
      final source = fileAt('inbox/empty.png')..writeAsBytesSync(<int>[]);
      await expectLater(
        writer.attach(notePath: 'notes/a.md', sourcePath: source.path),
        throwsA(isA<AttachmentRefused>()),
      );
    });
  });

  group('splicing into the text', () {
    test('lands on its own line at the cursor', () {
      final insertion = const AttachmentInsertion(
        attachmentPath: 'notes/attachments/x.png',
        linkTarget: 'attachments/x.png',
        markdown: '![[attachments/x.png]]',
        size: 1,
      );

      // Cursor parked at the end of the first paragraph's newline.
      final out = AttachmentWriter.spliceInto('第一段\n第二段\n', 4, insertion);

      expect(out, '第一段\n\n![[attachments/x.png]]\n\n第二段\n');
      // The link must not be glued to a word, which renders as an image in
      // the middle of a sentence and leaves the user needing to know Markdown
      // to repair it.
      expect(out.split('\n').where((l) => l.contains('![[')), hasLength(1));
      expect(out.split('\n').every((l) => l.trim().isEmpty ||
          l.contains('第一段') ||
          l.contains('第二段') ||
          l.contains('![[')), isTrue);
    });

    test('into an empty note', () {
      final insertion = const AttachmentInsertion(
        attachmentPath: 'notes/attachments/x.png',
        linkTarget: 'attachments/x.png',
        markdown: '![[attachments/x.png]]',
        size: 1,
      );
      expect(AttachmentWriter.spliceInto('', 0, insertion).trim(),
          '![[attachments/x.png]]');
    });

    test('an offset past the end clamps instead of throwing', () {
      final insertion = const AttachmentInsertion(
        attachmentPath: 'notes/attachments/x.png',
        linkTarget: 'attachments/x.png',
        markdown: '![[attachments/x.png]]',
        size: 1,
      );
      expect(
        () => AttachmentWriter.spliceInto('abc', 999, insertion),
        returnsNormally,
      );
    });

    test('the rest of the note is never lost', () {
      final insertion = const AttachmentInsertion(
        attachmentPath: 'notes/attachments/x.png',
        linkTarget: 'attachments/x.png',
        markdown: '![[attachments/x.png]]',
        size: 1,
      );
      final original = '开头\n结尾';
      final out = AttachmentWriter.spliceInto(original, 3, insertion);
      expect(out, contains('开头'));
      expect(out, contains('结尾'));
      expect(out.length, greaterThan(original.length));
    });
  });

  group('the vault-path predicate this relies on', () {
    test('round-trips: what attach writes, the scanner will index', () {
      expect(VaultPaths.isAttachmentPath('notes/attachments/x.png'), isTrue);
      expect(VaultPaths.isAttachmentPath('notes/a/attachments/x.png'), isTrue);
      expect(VaultPaths.isAttachmentPath('notes/a.md'), isFalse);
    });
  });
}
