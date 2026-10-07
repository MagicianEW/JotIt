import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/core/content_hash.dart';
import 'package:jotit/data/db/jotit_database.dart';
import 'package:jotit/data/db/note_dao.dart';
import 'package:jotit/data/db/sync_meta_store.dart';
import 'package:jotit/data/db/sync_root_store.dart';
import 'package:jotit/data/sync/sync_engine.dart';
import 'package:jotit/data/vault/note_file_store.dart';
import 'package:jotit/domain/vault/vault_scanner.dart';

import '../../support/dav_harness.dart';

/// v3.0 §5.5 — attachments.
///
/// The rules are short enough to state in full, which is exactly why it is
/// worth testing them against a real socket:
///
///  * attachments are **immutable** (ADR-11): `{uuid}.{ext}`, content never
///    changes after it is written, so "replace the image" means a new uuid
///    file plus a new link plus deleting the old one. **There is no such thing
///    as an attachment content conflict**,
///  * the judgement is the SHA-256 **checksum**, never the ETag, because
///    several servers implement ETag for binary resources inconsistently,
///  * a failed upload is retried as a **whole file**, never resumed by range.
void main() {
  late DavHarness dav;
  late Directory vault;
  late NoteFileStore files;
  late JotItDatabase db;
  late NoteDao notes;
  late SyncMetaStore meta;
  late SyncRootStore roots;
  late SyncEngine engine;

  const rootId = 'root-1';
  var now = 1000000;

  Future<void> rescan() async {
    await VaultScanner(database: db.db, fileStore: files).reindex();
  }

  setUp(() async {
    dav = await DavHarness.start();
    vault = await Directory.systemTemp.createTemp('jotit_attach_');
    await NoteFileStore.ensureLayout(vault.path);

    files = NoteFileStore(vaultRoot: vault.path);
    db = await JotItDatabase.openInMemory();
    notes = NoteDao(db.db);
    meta = SyncMetaStore(db.db);
    roots = SyncRootStore(db.db);

    await roots.upsert(SyncRootRecord(
      id: rootId,
      name: 'test',
      baseUrl: dav.baseUri().toString(),
      username: 'testuser',
    ));

    engine = SyncEngine(
      dav: dav.client(),
      files: files,
      notes: notes,
      meta: meta,
      roots: roots,
      vaultRoot: vault.path,
    );
    await rescan();
  });

  tearDown(() async {
    await db.close();
    if (vault.existsSync()) await vault.delete(recursive: true);
    await dav.dispose();
  });

  /// A real PNG: 1×1 transparent. Bytes matter here — an attachment that
  /// happens to be valid UTF-8 would take the note path through the parser and
  /// hide the bug this file exists to pin down.
  final png = Uint8List.fromList(<int>[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
    0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
    0x54, 0x78, 0x9C, 0x63, 0xFC, 0xCF, 0xC0, 0x50,
    0x0F, 0x00, 0x04, 0x85, 0x01, 0x80, 0x84, 0xA9,
    0x8C, 0x21, 0x33, 0x2C, 0x1D, 0x00, 0x00, 0x00,
    0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60,
    0x82,
  ]);

  Future<void> writeNote(
    String notePath,
    String body, {
    String? uid,
  }) async {
    final fm = StringBuffer('---');
    if (uid != null) fm.write('\nuid: $uid');
    fm.write('\n---');
    await files.writeAtomic(notePath, utf8.encode('$fm\n\n$body\n'));
    await rescan();
  }

  Future<void> writeAttachment(String path, List<int> bytes) async {
    await files.writeAtomic(path, bytes);
    await rescan();
  }

  Future<SyncBatchResult> run() async {
    now += 1000;
    final result = await engine.run(syncRootId: rootId, nowMs: now);
    await engine.recordSuccess(syncRootId: rootId, nowMs: now);
    return result;
  }

  const attachmentPath = 'notes/attachments/6f1a.png';

  /// §9.3: the link is relative to the note's own directory, and the file
  /// lives in an `attachments/` folder beside it. A note at `notes/a.md`
  /// linking `![[6f1a.png]]` is asking for `notes/6f1a.png` — writing
  /// `![[attachments/6f1a.png]]` is not a style preference, it is the only
  /// spelling that resolves. Getting this wrong makes the fixture test a
  /// dangling link, and a dangling link is an orphan, and orphans are left
  /// alone on purpose.
  const embeddedNote = '---\nuid: u-a\n---\n\n![[attachments/6f1a.png]]\n';

  test('a note with an image uploads the image too', () async {
    await writeNote('notes/a.md', embeddedNote, uid: 'u-a');
    await writeAttachment(attachmentPath, png);

    final result = await run();

    expect(result.error, isNull);
    expect(result.uploaded, contains('notes/a.md'));
    expect(result.uploaded, contains(attachmentPath),
        reason: 'a note whose picture never reaches the other device is a '
            'note that arrives broken, and nothing in the UI says so');
    expect(await dav.readRemote(attachmentPath), png);
  });

  test('an attachment is never filed as a conflict', () async {
    // The regression this whole file exists for. Attachments were being fed
    // through the note decision matrix, where a binary file has no `uid` on
    // either side — which lands on the matrix's "remote file has no uid;
    // refusing to overwrite without identity" row. Every attachment in a
    // synced vault became a `trueConflict` and a pair of copies in
    // `_conflicts/`, forever, while the note above it synced cleanly.
    await writeNote('notes/a.md', embeddedNote, uid: 'u-a');
    await writeAttachment(attachmentPath, png);

    final result = await run();

    expect(result.conflicts, isEmpty,
        reason: 'ADR-11 makes attachment content conflicts impossible by '
            'construction; §5.5 says so outright');
    expect(await dav.readRemote(attachmentPath), png,
        reason: 'a conflict copy is not a sync — the real path has to be '
            'written');
  });

  test('a second round with nothing changed transfers nothing', () async {
    await writeNote('notes/a.md', embeddedNote, uid: 'u-a');
    await writeAttachment(attachmentPath, png);
    await run();

    final second = await run();

    expect(second.touched, 0,
        reason: '§5.5 judges by checksum, so an unchanged attachment costs '
            'one hash and no bytes');
    expect(second.error, isNull);
  });

  test('an image added on the other device is downloaded', () async {
    await dav.seedRemote(attachmentPath, png);
    await dav.seedRemote(
      'notes/a.md',
      utf8.encode('---\nuid: u-a\n---\n\n![[attachments/6f1a.png]]\n'),
    );
    await run();

    final fetched = await files.readBytesIfPresent(attachmentPath);

    expect(fetched, isNotNull);
    // Compared by hash rather than by `equals(png)`: a transport that
    // rewrites a single byte has produced an image the user will see as
    // corrupt, and `expect` on two 67-byte lists hides *which* byte.
    expect(ContentHash.ofBytes(fetched!), ContentHash.ofBytes(png));
  });

  test('deleting an attachment locally removes it remotely', () async {
    await writeNote('notes/a.md', embeddedNote, uid: 'u-a');
    await writeAttachment(attachmentPath, png);
    await run();
    expect(await dav.remoteExists(attachmentPath), isTrue);

    await files.fileFor(attachmentPath)?.delete();
    final result = await run();

    expect(result.deleted, contains(attachmentPath));
    expect(await dav.remoteExists(attachmentPath), isFalse);
  });

  test('an attachment arrives with its own content type, not markdown',
      () async {
    await writeNote('notes/a.md', embeddedNote, uid: 'u-a');
    await writeAttachment(attachmentPath, png);

    await run();

    final listing = await dav.client().stat(attachmentPath);
    expect(listing?.contentType, isNotNull);
    expect(listing!.contentType, isNot(contains('markdown')),
        reason: 'uploading a PNG as text/markdown makes every other tool on '
            'the server treat it as a text file');
  });

  test('a file no note references is left where it is', () async {
    // Someone copied a screenshot into `attachments/` and has not embedded it
    // yet. Pushing it would put a file on every other device that nothing on
    // them refers to; deleting it would throw away work in progress. Both
    // directions are refused.
    await writeAttachment(attachmentPath, png);

    final result = await run();

    expect(await dav.remoteExists(attachmentPath), isFalse);
    expect(result.uploaded, isEmpty);
    expect(await files.readBytesIfPresent(attachmentPath), isNotNull);
  });

  test('bytes rewritten on the far side are reported, not overwritten',
      () async {
    await writeNote('notes/a.md', embeddedNote, uid: 'u-a');
    await writeAttachment(attachmentPath, png);
    await run();
    expect(await dav.remoteExists(attachmentPath), isTrue);

    // Something outside this app rewrote the same immutable path. Picking a
    // winner here is the silent overwrite C3 forbids.
    final other = Uint8List.fromList(png);
    other[other.length - 1] = other.last ^ 0xFF;
    await dav.seedRemote(attachmentPath, other);

    final result = await run();

    expect(result.attachmentViolations, contains(attachmentPath));
    expect(result.conflicts, isEmpty,
        reason: 'a `_conflicts/` pair of binaries is not a resolution');
    expect(await dav.readRemote(attachmentPath), other,
        reason: 'the remote copy is left exactly as it was found');
    expect(await files.readBytesIfPresent(attachmentPath), png,
        reason: 'and so is the local one');
  });
}
