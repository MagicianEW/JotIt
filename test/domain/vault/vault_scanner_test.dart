import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/core/content_hash.dart';
import 'package:jotit/data/db/jotit_database.dart';
import 'package:jotit/data/vault/note_file_store.dart';
import 'package:jotit/domain/vault/vault_scanner.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Behaviour contract for [VaultScanner].
///
/// This file is the one that has to exist before the sync engine is written.
/// The scanner is the *single source of truth* the engine will read from, and
/// ADR-1 promises the database is disposable. A promise nobody tests is a
/// promise nobody keeps: the first person to lean on "the index can always be
/// rebuilt" will do it without noticing that rebuilding quietly drops a
/// column they added.
void main() {
  late Directory vault;
  late NoteFileStore store;

  setUp(() async {
    vault = await Directory.systemTemp.createTemp('jotit_vault_');
    store = NoteFileStore(vaultRoot: vault.path);
    await NoteFileStore.ensureLayout(vault.path);
  });

  tearDown(() async {
    if (vault.existsSync()) await vault.delete(recursive: true);
  });

  Future<void> writeNote(
    String notePath,
    String body, {
    String? uid,
    String? title,
    List<String> tags = const [],
  }) async {
    final fm = StringBuffer('---');
    if (uid != null) fm.write('\nuid: $uid');
    if (title != null) fm.write('\ntitle: $title');
    if (tags.isNotEmpty) {
      // Bound to a local first: nesting " inside an interpolation inside a
      // double-quoted string closes the string early.
      final joined = tags.join(', ');
      fm.write('\ntags: [$joined]');
    }
    fm.write('\n---');
    final file = File(p.joinAll([vault.path, ...notePath.split('/')]));
    await file.parent.create(recursive: true);
    await file.writeAsString('$fm\n\n$body');
  }

  Future<void> writeBinary(String relPath, List<int> bytes) async {
    final file = File(p.joinAll([vault.path, ...relPath.split('/')]));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
  }

  String dbPath() => p.join(vault.path, '.jotit', 'jotit.db');

  Future<JotItDatabase> openDb() => JotItDatabase.open(filePath: dbPath());

  /// Everything about the index that ADR-1 promises is reproducible.
  ///
  /// Deliberately excludes `updated_at`: the scanner stamps it with "now",
  /// because a file does not record when it was last edited through JotIt.
  /// That column is display-and-sort only — §13's P2-9 note is explicit that
  /// sync decisions must never read a clock — so it is outside the invariant.
  /// Stating that here stops the next person from "fixing" it by trying to
  /// reconstruct an edit time that does not exist anywhere.
  Future<Map<String, Object?>> snapshot(Database db) async {
    final notes = await db.query('notes',
        where: 'is_deleted = 0', orderBy: 'path');
    final links = await db.query('links', orderBy: 'source_note_id, raw_target');
    final tags = await db.query('note_tags', orderBy: 'note_id, tag');
    final tagNames = await db.query('tags', orderBy: 'name');
    final attachments =
        await db.query('attachments', orderBy: 'path');

    return {
      'notes': [
        for (final r in notes)
          <String, Object?>{
            'id': r['id'],
            'path': r['path'],
            'title': r['title'],
            'body': r['body'],
            'content_hash': r['content_hash'],
            'file_size': r['file_size'],
            'is_deleted': r['is_deleted'],
          },
      ],
      'links': [
        for (final r in links)
          <String, Object?>{
            'source': r['source_note_id'],
            'target': r['target_note_id'],
            'target_path': r['target_path'],
            'raw': r['raw_target'],
            'type': r['link_type'],
            'external': r['is_external'],
          },
      ],
      'note_tags': [
        for (final r in tags) '${r['note_id']}#${r['tag']}',
      ],
      'tags': [for (final r in tagNames) r['name']],
      'attachments': [
        for (final r in attachments)
          <String, Object?>{
            'note': r['note_id'],
            'path': r['path'],
            'size': r['size'],
            'hash': r['content_hash'],
          },
      ],
    };
  }

  /// ADR-1 / I1. Delete the database, rebuild from files, get the same index.
  group('invariant I1 — the database is disposable', () {
    test('rebuilding after deleting the database reproduces the index',
        () async {
      await writeNote('notes/a.md', 'Links to [[b]] and embeds ![[attachments/x.png]]',
          uid: 'u-a', title: 'Alpha', tags: ['one', 'two']);
      await writeNote('notes/b.md', 'The second note', uid: 'u-b', title: 'Beta');
      await writeNote('notes/deep/nested/c.md', 'A nested note about [[b]]',
          uid: 'u-c', title: 'Gamma');
      await writeBinary('notes/attachments/x.png', <int>[1, 2, 3, 4, 5]);

      final first = await openDb();
      final r1 = await VaultScanner(database: first.db, fileStore: store).reindex();
      expect(r1.notesIndexed, 3);
      final before = await snapshot(first.db);
      await first.close();

      // The part that matters: throw the database away entirely.
      for (final suffix in ['', '-wal', '-shm']) {
        final f = File('${dbPath()}$suffix');
        if (f.existsSync()) await f.delete();
      }
      expect(File(dbPath()).existsSync(), isFalse);

      final second = await openDb();
      addTearDown(second.close);
      final r2 = await VaultScanner(database: second.db, fileStore: store).reindex();

      expect(r2.notesIndexed, r1.notesIndexed);
      expect(await snapshot(second.db), before,
          reason: 'ADR-1: a rebuilt index must be indistinguishable from the '
              'original, or "just delete the db" stops being a safe recovery '
              'move');
    });

    test('a second reindex over the same files is idempotent', () async {
      await writeNote('notes/a.md', '[[b]]', uid: 'u-a', title: 'Alpha');
      await writeNote('notes/b.md', 'body', uid: 'u-b');

      final db = await openDb();
      addTearDown(db.close);
      final scanner = VaultScanner(database: db.db, fileStore: store);

      await scanner.reindex();
      final first = await snapshot(db.db);
      final second = await scanner.reindex();
      final afterSecond = await snapshot(db.db);

      expect(afterSecond, first);
      // `notesIndexed` counts rows this pass *wrote*. The second pass reads
      // every file, hashes it, finds the bytes identical to what the index
      // already describes, and writes nothing — which is the whole point of
      // the fast path and is what keeps startup inside §11.2's budget.
      expect(second.notesUnchanged, 2);
      expect(second.notesIndexed, 0);
      expect(second.duplicateUids, isEmpty);
    });

    test('a change on disk is never skipped by the fast path', () async {
      // The fast path compares content hashes. A note edited between two
      // passes must be re-indexed, or ADR-1 turns into a lie: the index would
      // describe a version of the file that no longer exists, and nothing
      // would ever notice.
      await writeNote('notes/a.md', 'first body', uid: 'u-a', title: 'Alpha');
      final db = await openDb();
      addTearDown(db.close);
      final scanner = VaultScanner(database: db.db, fileStore: store);
      await scanner.reindex();

      // Same byte length, so a size-based shortcut would miss it too.
      await writeNote('notes/a.md', 'OTHER BODY', uid: 'u-a', title: 'Alpha');

      final result = await scanner.reindex();
      expect(result.notesUnchanged, 0);
      expect(result.notesIndexed, 1);

      final row = await db.db.query('notes',
          where: 'path = ?', whereArgs: ['notes/a.md']);
      expect(row.single['body'], contains('OTHER BODY'));
    });

    test('a file added while the app was closed is still indexed', () async {
      await writeNote('notes/a.md', 'body', uid: 'u-a');
      final db = await openDb();
      addTearDown(db.close);
      final scanner = VaultScanner(database: db.db, fileStore: store);
      await scanner.reindex();

      await writeNote('notes/b.md', 'brand new', uid: 'u-b');
      final result = await scanner.reindex();

      // The fast path is all-or-nothing: one new file means the whole vault
      // goes down the full path, so nothing is reported as unchanged.
      expect(result.notesUnchanged, 0);
      expect(result.notesIndexed, 2);
      final rows = await db.db.query('notes', where: 'is_deleted = 0');
      expect(rows.length, 2);
      expect(rows.map((r) => r['path']), containsAll(['notes/a.md', 'notes/b.md']));
    });

    test('a file deleted while the app was closed is reported missing',
        () async {
      await writeNote('notes/a.md', 'body', uid: 'u-a');
      await writeNote('notes/b.md', 'body', uid: 'u-b');
      final db = await openDb();
      addTearDown(db.close);
      final scanner = VaultScanner(database: db.db, fileStore: store);
      await scanner.reindex();

      File('${store.vaultRoot}${p.separator}notes${p.separator}b.md')
          .deleteSync();
      final result = await scanner.reindex();

      expect(result.missingPaths, ['notes/b.md']);
      expect(result.notesUnchanged, 0);
      expect(result.notesIndexed, 1);
    });
  });

  group('uid backfill (§4.4.1 / ADR-2)', () {
    test('a note with no uid gets one written into the file', () async {
      await writeNote('notes/plain.md', 'no front matter uid here', title: 'Plain');

      final db = await openDb();
      addTearDown(db.close);
      final result =
          await VaultScanner(database: db.db, fileStore: store).reindex();

      expect(result.uidBackfilled, <String>['notes/plain.md']);
      final text = await File(p.join(vault.path, 'notes', 'plain.md'))
          .readAsString();
      expect(text, contains('uid: '),
          reason: 'the uid has to live in the file, or it never reaches another '
              'device (ADR-2)');
      final row = await db.db.query('notes',
          columns: ['id'], where: 'path = ?', whereArgs: ['notes/plain.md']);
      expect(row.single['id'], isNotEmpty);
      expect(
        '${row.single['id']}',
        matches(
            RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')),
        reason: 'a UUID v4, because every other device will compare it as one',
      );
    });

    test('backfilling a uid is not mistaken for a user edit', () async {
      // The subtle one. Writing the uid changes the file's bytes, so a naive
      // implementation either hashes the pre-patch bytes (and the index
      // disagrees with the file forever) or hashes the post-patch bytes twice
      // across two runs (and the sync engine sees a phantom local edit).
      await writeNote('notes/plain.md', 'body', title: 'Plain');

      final db = await openDb();
      addTearDown(db.close);
      final scanner = VaultScanner(database: db.db, fileStore: store);

      await scanner.reindex();
      final hashAfterFirst =
          (await db.db.query('notes', columns: ['content_hash'],
                  where: 'path = ?', whereArgs: ['notes/plain.md']))
              .single['content_hash'];

      final fileBytes =
          await File(p.join(vault.path, 'notes', 'plain.md')).readAsBytes();
      final second = await scanner.reindex();
      final hashAfterSecond =
          (await db.db.query('notes', columns: ['content_hash'],
                  where: 'path = ?', whereArgs: ['notes/plain.md']))
              .single['content_hash'];

      expect(second.uidBackfilled, isEmpty,
          reason: 'the second pass finds a uid already present');
      expect(hashAfterSecond, hashAfterFirst);
      expect(hashAfterSecond, ContentHash.ofBytes(fileBytes),
          reason: 'the index hash must match the file actually on disk');
    });

    test('a note that already declares a uid is left byte-identical', () async {
      await writeNote('notes/kept.md', 'body', uid: 'u-keep', title: 'Kept');
      final before =
          await File(p.join(vault.path, 'notes', 'kept.md')).readAsBytes();

      final db = await openDb();
      addTearDown(db.close);
      final result = await VaultScanner(database: db.db, fileStore: store).reindex();

      expect(result.uidBackfilled, isEmpty);
      expect(await File(p.join(vault.path, 'notes', 'kept.md')).readAsBytes(),
          before,
          reason: 'JotIt must not rewrite a file the user authored');
    });
  });

  group('duplicate identity', () {
    test('two files claiming one uid index only one and report the other',
        () async {
      // A note copied outside JotIt. Indexing both would rewrite the first
      // row's title, body and hash under the same primary key, and the sync
      // engine would then see a note change that nobody made.
      await writeNote('notes/original.md', 'the original', uid: 'u-same', title: 'One');
      await writeNote('notes/copy.md', 'a copy', uid: 'u-same', title: 'Two');

      final db = await openDb();
      addTearDown(db.close);
      final result = await VaultScanner(database: db.db, fileStore: store).reindex();

      expect(result.notesIndexed, 1);
      expect(result.duplicateUids, hasLength(1));
      expect(result.duplicateUids.single, contains('notes/copy.md'));
      final rows = await db.db.query('notes');
      expect(rows, hasLength(1));
    });
  });

  group('attachments (§4.4)', () {
    test('only referenced attachments are indexed', () async {
      await writeNote('notes/a.md', '![[attachments/used.png]]',
          uid: 'u-a', title: 'A');
      await writeBinary('notes/attachments/used.png', <int>[9, 9]);
      await writeBinary('notes/attachments/orphan.png', <int>[8, 8]);

      final db = await openDb();
      addTearDown(db.close);
      await VaultScanner(database: db.db, fileStore: store).reindex();

      final rows = await db.db.query('attachments', columns: ['path']);
      expect(rows.map((r) => r['path']), <String>['notes/attachments/used.png']);
    });

    test('a deleted attachment file keeps its metadata and is reported',
        () async {
      // §4.4: "文件缺失时记录警告，不删除元数据". The row is the only remaining
      // evidence the note ever referenced that file.
      await writeNote('notes/a.md', '![[attachments/gone.png]]',
          uid: 'u-a', title: 'A');
      await writeBinary('notes/attachments/gone.png', <int>[1, 2, 3]);

      final db = await openDb();
      addTearDown(db.close);
      final scanner = VaultScanner(database: db.db, fileStore: store);
      await scanner.reindex();
      expect(await db.db.query('attachments'), hasLength(1));

      await File(p.join(vault.path, 'notes', 'attachments', 'gone.png')).delete();

      final result = await scanner.reindex();
      expect(await db.db.query('attachments'), hasLength(1),
          reason: 'metadata is kept so the note still knows it referenced a file');
      expect(result.missingAttachments, <String>['notes/attachments/gone.png']);
      expect(result.hasProblems, isTrue,
          reason: 'a missing attachment is something the user should be told '
              'about, not something to absorb silently');
    });
  });

  group('soft delete', () {
    test('a note whose file reappears is reported as restored', () async {
      await writeNote('notes/back.md', 'body', uid: 'u-back', title: 'Back');

      final db = await openDb();
      addTearDown(db.close);
      final scanner = VaultScanner(database: db.db, fileStore: store);
      await scanner.reindex();

      await db.db.update('notes', {'is_deleted': 1},
          where: 'path = ?', whereArgs: ['notes/back.md']);
      final File gone = File(p.join(vault.path, 'notes', 'back.md'));
      final saved = await gone.readAsString();
      await gone.delete();
      await scanner.reindex();

      await gone.writeAsString(saved);
      final result = await scanner.reindex();

      expect(result.restoredFromDisk, contains('notes/back.md'));
      final row = await db.db
          .query('notes', columns: ['is_deleted'], where: 'path = ?',
              whereArgs: ['notes/back.md']);
      expect(row.single['is_deleted'], 0,
          reason: 'a file that exists is not deleted, whatever the index said');
    });
  });

  group('missing paths', () {
    test('an index row with no file is reported, never deleted', () async {
      await writeNote('notes/gone.md', 'body', uid: 'u-gone', title: 'Gone');

      final db = await openDb();
      addTearDown(db.close);
      final scanner = VaultScanner(database: db.db, fileStore: store);
      await scanner.reindex();

      await File(p.join(vault.path, 'notes', 'gone.md')).delete();
      final result = await scanner.reindex();

      expect(result.missingPaths, contains('notes/gone.md'));
      expect(await db.db.query('notes'), hasLength(1),
          reason: 'the scanner runs after a sync that may have half-failed, on a '
              'drive that may be disconnected. Turning "I did not see it" into '
              '"it is deleted" here would propagate a deletion to every device.');
    });

    test('knownPaths widens the report with remote-only paths', () async {
      await writeNote('notes/here.md', 'body', uid: 'u-here');

      final db = await openDb();
      addTearDown(db.close);
      final result = await VaultScanner(database: db.db, fileStore: store)
          .reindex(knownPaths: {'notes/here.md', 'notes/only-remote.md'});

      expect(result.missingPaths, contains('notes/only-remote.md'));
      expect(result.missingPaths, isNot(contains('notes/here.md')));
    });
  });

  group('what gets skipped', () {
    test('system, hidden and temporary files are skipped', () async {
      await writeNote('notes/real.md', 'body', uid: 'u-real');
      await writeBinary('notes/.hidden.md', utf8.encode('---\nuid: h\n---\nx'));
      await writeBinary('notes/Thumbs.db', <int>[1]);
      await writeBinary('notes/half-written.md.tmp', <int>[1]);

      final db = await openDb();
      addTearDown(db.close);
      final result = await VaultScanner(database: db.db, fileStore: store).reindex();

      expect(result.notesIndexed, 1);
      expect(result.skipped.join(' '), contains('half-written.md.tmp'));
    });

    test('conflicts and the app directory are outside the synced subtree',
        () async {
      // The quarantine is a *sibling* of notes/, not a child, so the scan
      // cannot reach it even though it holds Markdown files.
      await writeNote('notes/real.md', 'body', uid: 'u-real');
      final quarantine = File(p.join(
          vault.path, '_conflicts', '20260108-142305-1-x', 'local.md'));
      await quarantine.parent.create(recursive: true);
      await quarantine.writeAsString('---\nuid: conflict-1\n---\nlocal copy');

      final db = await openDb();
      addTearDown(db.close);
      final result = await VaultScanner(database: db.db, fileStore: store).reindex();

      expect(result.notesIndexed, 1);
      final uids = (await db.db.query('notes', columns: ['id']))
          .map((r) => r['id'])
          .toList();
      expect(uids, isNot(contains('conflict-1')),
          reason: 'ADR-7: a conflict copy that got indexed would be uploaded '
              'back to the remote and multiply on every device');
    });

    test('a file that is not valid UTF-8 is left alone and reported', () async {
      await writeNote('notes/ok.md', 'body', uid: 'u-ok');
      final binary = File(p.join(vault.path, 'notes', 'binary.md'));
      await binary.writeAsBytes(<int>[0xFF, 0xFE, 0x00, 0x01, 0x80]);

      final db = await openDb();
      addTearDown(db.close);
      final result = await VaultScanner(database: db.db, fileStore: store).reindex();

      expect(result.notesIndexed, 1);
      expect(await binary.readAsBytes(), <int>[0xFF, 0xFE, 0x00, 0x01, 0x80],
          reason: 'round-tripping invalid bytes would replace them with U+FFFD '
              'and ship that damage to every device');
    });
  });

  group('links', () {
    test('links are rebuilt, not accumulated, across passes', () async {
      await writeNote('notes/a.md', 'Links [[b]] and [[b]] twice',
          uid: 'u-a', title: 'A');
      await writeNote('notes/b.md', 'body', uid: 'u-b');

      final db = await openDb();
      addTearDown(db.close);
      final scanner = VaultScanner(database: db.db, fileStore: store);

      await scanner.reindex();
      final first = (await db.db.query('links')).length;
      await scanner.reindex();
      final second = (await db.db.query('links')).length;

      expect(second, first,
          reason: 'a deleted link must disappear; an upsert cannot express that');
    });

    test('a removed link stops being indexed', () async {
      await writeNote('notes/a.md', '[[b]]', uid: 'u-a');
      await writeNote('notes/b.md', 'body', uid: 'u-b');

      final db = await openDb();
      addTearDown(db.close);
      final scanner = VaultScanner(database: db.db, fileStore: store);
      await scanner.reindex();
      expect(await db.db.query('links'), isNotEmpty);

      await writeNote('notes/a.md', 'no links now', uid: 'u-a');
      await scanner.reindex();

      expect(await db.db.query('links'), isEmpty);
    });
  });
}
