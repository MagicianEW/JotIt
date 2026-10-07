import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/core/content_hash.dart';
import 'package:jotit/core/vault_paths.dart';
import 'package:jotit/data/vault/note_file_store.dart';
import 'package:path/path.dart' as p;

/// Byte-level contract for [NoteFileStore].
///
/// Every assertion here is about one thing: a note file must come out of
/// JotIt byte-identical unless the user actually edited it. The sync engine
/// reads `content_hash` to decide "the user edited this" — so a re-encode
/// that changes a BOM or a line ending is not cosmetic, it is an upload to
/// every other device. ADR-6 is the reason these tests exist.
void main() {
  late Directory vault;
  late NoteFileStore store;

  setUp(() async {
    vault = await Directory.systemTemp.createTemp('jotit_store_');
    store = NoteFileStore(vaultRoot: vault.path);
    await NoteFileStore.ensureLayout(vault.path);
  });

  tearDown(() async {
    if (vault.existsSync()) await vault.delete(recursive: true);
  });

  Future<File> writeRaw(String notePath, List<int> bytes) async {
    final f = File(p.join(vault.path, p.joinAll(notePath.split('/'))));
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes, flush: true);
    return f;
  }

  Future<List<int>> readRaw(String notePath) async =>
      (await store.readBytesIfPresent(notePath))!;

  List<String> filesUnderNotes() {
    final root = Directory(VaultPaths.notesRoot(vault.path));
    if (!root.existsSync()) return const [];
    return root
        .listSync(recursive: true)
        .whereType<File>()
        .map((f) => p.relative(f.path, from: root.path).replaceAll('\\', '/'))
        .toList()
      ..sort();
  }

  group('path resolution', () {
    test('resolves under the vault root, never under the process CWD', () {
      // Regression: `p.joinAll(root, parts)` is not a two-argument call. The
      // compile error it caused was "fixed" by dropping `vaultRoot`, which
      // silently made every note resolve relative to wherever the process
      // happened to be running.
      final abs = store.absolutePathFor('notes/a/b.md');
      expect(abs, isNotNull);
      expect(
        p.isWithin(p.normalize(vault.path), p.normalize(abs!)),
        isTrue,
        reason: 'absolute path must stay inside the vault, not the CWD',
      );
      expect(p.basename(abs), 'b.md');
    });

    test('round-trips through notePathFor', () {
      for (final notePath in [
        'notes/a.md',
        'notes/a/b.md',
        'notes/a/b/c/d.md',
        'notes/中文/笔记.md',
      ]) {
        expect(store.notePathFor(store.absolutePathFor(notePath)!), notePath);
      }
    });

    test('refuses every path that escapes notes/', () {
      for (final bad in [
        '../outside.md',
        'notes/../../outside.md',
        'notes/../../../etc/passwd',
        '/etc/passwd',
        r'C:\Windows\System32\config',
        '_conflicts/x.md',
        '.jotit/db.sqlite',
        'attachments/x.png',
      ]) {
        expect(store.absolutePathFor(bad), isNull, reason: bad);
        expect(store.fileFor(bad), isNull, reason: bad);
      }
    });

    test('normalises redundant separators and dot segments', () {
      expect(
        store.absolutePathFor('notes/a/./b/../c.md'),
        store.absolutePathFor('notes/a/c.md'),
      );
      expect(
        store.absolutePathFor(r'notes\a\c.md'),
        store.absolutePathFor('notes/a/c.md'),
      );
    });

    test('notePathFor rejects a file outside the vault', () {
      expect(store.notePathFor(p.join(vault.path, '..', 'elsewhere.md')), isNull);
    });

    test('writeAtomic refuses to escape notes/', () async {
      await expectLater(
        store.writeAtomic('../outside.md', utf8.encode('x')),
        throwsA(isA<ArgumentError>()),
      );

      // Stale files from earlier runs must not decide this: the name is
      // unique per vault and removed before the check, so the assertion is
      // about what *this* call did, not about what happens to be on disk.
      final name = '${p.basename(vault.path)}_write.md';
      final target = File(p.join(vault.parent.path, name));
      if (target.existsSync()) await target.delete();
      addTearDown(() async {
        if (target.existsSync()) await target.delete();
      });

      await expectLater(
        store.writeAtomic('../$name', utf8.encode('x')),
        throwsA(isA<ArgumentError>()),
      );
      expect(target.existsSync(), isFalse,
          reason: 'nothing may be written beside the vault either');
    });
  });

  group('atomic write', () {
    test('creates missing directories', () async {
      await store.writeAtomic('notes/deep/nested/new.md', utf8.encode('hi'));
      expect(await store.readBytesIfPresent('notes/deep/nested/new.md'),
          utf8.encode('hi'));
    });

    test('leaves no temp or backup files behind', () async {
      await store.writeAtomic('notes/a.md', utf8.encode('one'));
      await store.writeAtomic('notes/a.md', utf8.encode('two'));

      expect(filesUnderNotes(), ['a.md']);
      final dir = Directory(VaultPaths.notesRoot(vault.path));
      final litter = dir
          .listSync(recursive: true)
          .map((e) => p.basename(e.path))
          .where((n) => n.contains('.jotit-tmp') || n.contains('.jotit-bak'));
      expect(litter, isEmpty,
          reason: 'a crash between rename steps must not leave debris the '
              'scanner would then index as a note');
    });

    test('an overwrite replaces the content wholesale', () async {
      await store.writeAtomic('notes/a.md', utf8.encode('first'));
      await store.writeAtomic('notes/a.md', utf8.encode('second'));
      expect(utf8.decode(await readRaw('notes/a.md')), 'second');
    });

    test('writes bytes verbatim, with no encoding of its own', () async {
      final bytes = List<int>.generate(256, (i) => i);
      await store.writeAtomic('notes/bin.md', bytes);
      expect(await readRaw('notes/bin.md'), bytes);
    });
  });

  group('readBytesIfPresent', () {
    test('returns null for a missing note', () async {
      expect(await store.readBytesIfPresent('notes/nope.md'), isNull);
    });

    test('returns null for an escaping path rather than reading it', () async {
      // Unique per test: the temp vaults all share one parent, and a name
      // reused across cases would make this pass for the wrong reason.
      final name = '${p.basename(vault.path)}_read.md';
      final outside = File(p.join(vault.parent.path, name));
      await outside.writeAsBytes(utf8.encode('secret'));
      addTearDown(() async {
        if (outside.existsSync()) await outside.delete();
      });

      expect(await store.readBytesIfPresent('../$name'), isNull);
    });

    test('returns the exact bytes on disk', () async {
      final bytes = <int>[0xEF, 0xBB, 0xBF, ...utf8.encode('# 中文\r\n')];
      await writeRaw('notes/bom.md', bytes);
      expect(await readRaw('notes/bom.md'), bytes);
    });
  });

  group('encodeLike', () {
    test('preserves a UTF-8 BOM', () async {
      final original = <int>[0xEF, 0xBB, 0xBF, ...utf8.encode('a\nb\n')];
      final out = await store.encodeLike(
        originalBytes: original,
        text: 'a\nb\nc\n',
      );
      expect(out.sublist(0, 3), [0xEF, 0xBB, 0xBF]);
      expect(utf8.decode(out.sublist(3)), 'a\nb\nc\n');
    });

    test('does not invent a BOM for a file that had none', () async {
      final out = await store.encodeLike(
        originalBytes: utf8.encode('a\n'),
        text: 'a\nb\n',
      );
      expect(out.sublist(0, 3), isNot([0xEF, 0xBB, 0xBF]));
    });

    test('keeps CRLF when the original used CRLF', () async {
      final out = await store.encodeLike(
        originalBytes: utf8.encode('a\r\nb\r\n'),
        text: 'a\nb\nc\n',
      );
      expect(utf8.decode(out), 'a\r\nb\r\nc\r\n');
      expect(utf8.decode(out).contains('\n\n'), isFalse);
    });

    test('keeps LF when the original used LF', () async {
      final out = await store.encodeLike(
        originalBytes: utf8.encode('a\nb\n'),
        text: 'a\r\nb\r\n',
      );
      expect(utf8.decode(out), 'a\nb\n',
          reason: 'a CRLF pasted into an LF note must not rewrite every line');
    });

    test('mixed line endings are normalised to the dominant one', () async {
      final out = await store.encodeLike(
        originalBytes: utf8.encode('a\r\nb\r\nc\n'),
        text: 'a\nb\nc\n',
      );
      expect(utf8.decode(out), 'a\r\nb\r\nc\r\n');
    });

    test('round-tripping an unchanged note reproduces its exact bytes', () async {
      // The property that makes ADR-6 hold: encoding is the identity when the
      // text did not change, so reindex never manufactures a phantom edit.
      for (final original in <List<int>>[
        utf8.encode('a\nb\n'),
        utf8.encode('a\r\nb\r\n'),
        <int>[0xEF, 0xBB, 0xBF, ...utf8.encode('# 中文\r\n正文\r\n')],
      ]) {
        final text = utf8.decode(
          original.length >= 3 && original[0] == 0xEF
              ? original.sublist(3)
              : original,
        );
        final out = await store.encodeLike(originalBytes: original, text: text);
        expect(out, original, reason: 'hash must be stable across a no-op');
      }
    });
  });

  group('isValidUtf8', () {
    test('accepts UTF-8', () {
      expect(NoteFileStore.isValidUtf8(utf8.encode('中文 ok')), isTrue);
      expect(NoteFileStore.isValidUtf8(<int>[]), isTrue);
    });

    test('rejects a lone continuation byte and a truncated sequence', () {
      expect(NoteFileStore.isValidUtf8(<int>[0x80]), isFalse);
      expect(NoteFileStore.isValidUtf8(<int>[0xE4, 0xB8]), isFalse);
    });

    test('rejects GBK-encoded Chinese', () {
      // A note written by a Windows Chinese-locale editor is not UTF-8. JotIt
      // must leave those bytes alone rather than "fixing" them to U+FFFD.
      expect(NoteFileStore.isValidUtf8(<int>[0xD6, 0xD0, 0xCE, 0xC4]), isFalse);
    });
  });

  group('ensureUid', () {
    const uid = '00000000-0000-4000-8000-000000000001';

    test('adds uid to a note that has front matter', () async {
      await writeRaw('notes/a.md', utf8.encode('---\ntitle: A\n---\n# A\n'));
      final text = utf8.decode((await store.ensureUid('notes/a.md', uid))!);
      expect(text, contains('uid: $uid'));
      expect(text, contains('title: A'));
      expect(text, contains('# A'));
    });

    test('adds front matter to a note that has none', () async {
      await writeRaw('notes/a.md', utf8.encode('# A\n\nbody\n'));
      final text = utf8.decode((await store.ensureUid('notes/a.md', uid))!);
      expect(text, contains('uid: $uid'));
      expect(text, startsWith('---\n'));
      expect(text, endsWith('# A\n\nbody\n'));
    });

    test('is a no-op when the uid is already there', () async {
      final bytes = utf8.encode('---\nuid: $uid\ntitle: A\n---\n# A\n');
      await writeRaw('notes/a.md', bytes);
      expect(await store.ensureUid('notes/a.md', uid), isNull);
      expect(await readRaw('notes/a.md'), bytes,
          reason: 'a no-op must not rewrite the file');
    });

    test('a no-op leaves content_hash untouched', () async {
      final bytes = utf8.encode('---\nuid: $uid\n---\n# A\n');
      await writeRaw('notes/a.md', bytes);
      final before = ContentHash.ofBytes(bytes);
      await store.ensureUid('notes/a.md', uid);
      expect(ContentHash.ofBytes(await readRaw('notes/a.md')), before);
    });

    test('preserves CRLF while inserting the uid', () async {
      await writeRaw('notes/a.md', utf8.encode('---\r\ntitle: A\r\n---\r\n'));
      final text = utf8.decode((await store.ensureUid('notes/a.md', uid))!);
      expect(text, contains('uid: $uid\r\n'));
      expect(text, isNot(contains('\n\n')));
    });

    test('preserves a BOM while inserting the uid', () async {
      await writeRaw('notes/a.md',
          <int>[0xEF, 0xBB, 0xBF, ...utf8.encode('---\ntitle: A\n---\n')]);
      final out = await store.ensureUid('notes/a.md', uid);
      expect(out!.sublist(0, 3), [0xEF, 0xBB, 0xBF]);
      expect(utf8.decode(out.sublist(3)), contains('uid: $uid'));
    });

    test('leaves a non-UTF-8 file completely alone', () async {
      // The most important test in this file. Writing front matter into a
      // GBK note would replace every undecodable byte with U+FFFD and ship
      // that corruption to every other device.
      final gbk = <int>[0xD6, 0xD0, 0xCE, 0xC4, 0x0D, 0x0A];
      await writeRaw('notes/gbk.md', gbk);

      expect(await store.ensureUid('notes/gbk.md', uid), isNull);
      expect(await readRaw('notes/gbk.md'), gbk,
          reason: 'the file must be byte-identical afterwards');
    });

    test('refuses an escaping path and leaves the target untouched', () async {
      // Every temp vault shares one parent directory, so a fixed name here
      // would be written by one case and observed by another. The escaping
      // target gets its own name and its bytes are checked afterwards.
      final name = '${p.basename(vault.path)}_escape.md';
      final outside = File(p.join(vault.parent.path, name));
      final original = utf8.encode('# x\n');
      await outside.writeAsBytes(original);
      addTearDown(() async {
        if (outside.existsSync()) await outside.delete();
      });

      expect(await store.ensureUid('../$name', uid), isNull);
      expect(await outside.readAsBytes(), original);
    });
  });

  group('ensureLayout', () {
    test('creates notes, _conflicts and .jotit', () async {
      for (final dir in [
        VaultPaths.notesDirName,
        VaultPaths.conflictsDirName,
        VaultPaths.appDirName,
      ]) {
        expect(Directory(p.join(vault.path, dir)).existsSync(), isTrue,
            reason: dir);
      }
    });

    test('the conflict directory is a sibling of notes/, not a child', () {
      // ADR-7: conflict copies inside notes/ replicate to every device and
      // multiply. The scanner walks notes/, so _conflicts must stay outside.
      expect(VaultPaths.conflictsRoot(vault.path),
          isNot(startsWith(VaultPaths.notesRoot(vault.path))));
    });
  });
}