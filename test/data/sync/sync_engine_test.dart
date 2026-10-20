import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/core/content_hash.dart';
import 'package:jotit/core/vault_paths.dart';
import 'package:jotit/data/dav/dav_capabilities.dart';
import 'package:jotit/data/dav/dav_client.dart';
import 'package:jotit/data/dav/dav_multistatus.dart';
import 'package:jotit/data/db/jotit_database.dart';
import 'package:jotit/data/db/note_dao.dart';
import 'package:jotit/data/db/sync_meta_store.dart';
import 'package:jotit/data/db/sync_root_store.dart';
import 'package:jotit/data/sync/sync_engine.dart';
import 'package:jotit/data/vault/note_file_store.dart';
import 'package:jotit/domain/sync/conflict_writer.dart';
import 'package:jotit/domain/sync/sync_session.dart';
import 'package:jotit/domain/vault/vault_scanner.dart';
import 'package:path/path.dart' as p;

import '../../support/dav_harness.dart';

/// The whole chain, against a real WebDAV server: local vault on disk, index
/// in SQLite, remote over HTTP.
///
/// The units are all tested in isolation elsewhere — the matrix as a table,
/// the diff as a pure function, the state machine as a graph. What only shows
/// up when the pieces are wired is whether the *base* actually moves, because
/// a sync engine that transfers correctly but never records a new merge base
/// re-downloads the entire vault on every single run and looks, from the logs,
/// exactly like one that is working.
void main() {
  late DavHarness dav;
  late Directory vault;
  late NoteFileStore files;
  late JotItDatabase db;
  late NoteDao notes;
  late SyncMetaStore meta;
  late SyncRootStore roots;
  late SyncEngine engine;
  late _CountingClient counter;

  const rootId = 'root-1';
  var now = 1000000;

  /// Rebuilds the derived index. The engine reads local state through it, so
  /// after every write the index has to catch up or the engine will keep
  /// seeing the previous version of the vault.
  Future<void> rescan() =>
      VaultScanner(database: db.db, fileStore: files).reindex().then((_) {});

  setUp(() async {
    dav = await DavHarness.start();
    vault = await Directory.systemTemp.createTemp('jotit_sync_');
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

    counter = _CountingClient(inner: dav.client());
    engine = SyncEngine(
      dav: counter,
      files: files,
      notes: notes,
      meta: meta,
      roots: roots,
      vaultRoot: vault.path,
    );

    // The index is what the engine reads for local state; an empty one means
    // every local file looks like "never seen" and the first round uploads
    // the whole vault, which is correct but not what most of these tests are
    // about.
    await rescan();
  });

  tearDown(() async {
    await db.close();
    if (vault.existsSync()) await vault.delete(recursive: true);
    await dav.dispose();
  });

  Future<void> writeLocal(
    String notePath,
    String body, {
    String? uid,
    String? title,
  }) async {
    final fm = StringBuffer('---');
    if (uid != null) fm.write('\nuid: $uid');
    if (title != null) fm.write('\ntitle: $title');
    fm.write('\n---');
    await files.writeAtomic(notePath, utf8.encode('$fm\n\n$body\n'));
    await rescan();
  }

  Future<String> readLocal(String notePath) async =>
      utf8.decode((await files.readBytesIfPresent(notePath))!);

  Future<SyncBatchResult> run() async {
    now += 1000;
    final result = await engine.run(syncRootId: rootId, nowMs: now);
    await engine.recordSuccess(syncRootId: rootId, nowMs: now);
    return result;
  }

  String note(String uid, String title, String body) =>
      '---\nuid: $uid\ntitle: $title\n---\n\n$body\n';

  /// Rebuilds the engine with a client that rewrites [path] the first time a
  /// note body is fetched.
  ///
  /// This is the only seam that lands the "other device" inside the exact
  /// window §5.3 row 10 describes: the PROPFIND walk has already recorded an
  /// ETag, and the PUT is about to be sent against it. Seeding the change
  /// *before* `run()` does not produce a 412 at all — the snapshot sees it and
  /// the note is classified as a genuine divergence (row 9), which is a
  /// different code path with a different, and correct, answer.
  SyncEngine engineThatMutatesOnRead({
    required String path,
    required List<int> bytes,
  }) {
    late final DavClient racer = _MutateOnFirstGet(
      inner: dav.client(),
      onFirstGet: () => dav.seedRemote(path, bytes),
    );
    return SyncEngine(
      dav: racer,
      files: files,
      notes: notes,
      meta: meta,
      roots: roots,
      vaultRoot: vault.path,
    );
  }

  group('first round', () {
    test('uploads a local note the server has never seen', () async {
      await writeLocal('notes/a.md', 'local body',
          uid: 'u-a', title: 'A');

      final result = await run();

      expect(result.uploaded, contains('notes/a.md'));
      expect(result.error, isNull);
      expect(
        utf8.decode((await dav.readRemote('notes/a.md'))!),
        contains('local body'),
      );
    });

    test('records a merge base so a second round is a no-op', () async {
      await writeLocal('notes/a.md', 'body', uid: 'u-a', title: 'A');
      await run();

      final record = await meta.byPath(rootId, 'notes/a.md');
      expect(record, isNotNull);
      expect(record!.baseEtag, isNotNull,
          reason: 'no base_etag means every round re-uploads everything');
      expect(record.baseContentHash, isNotNull);
      expect(record.uid, 'u-a');
      expect(record.conflictState, ConflictState.none);
    });

    test('a second round touches nothing', () async {
      await writeLocal('notes/a.md', 'body', uid: 'u-a', title: 'A');
      await run();

      final second = await run();
      expect(second.uploaded, isEmpty);
      expect(second.downloaded, isEmpty);
      expect(second.isEmpty, isTrue);
    });

  group('the idle round (P1-5)', () {
    // The short-circuit has to mean "there is genuinely nothing to do". The
    // condition it used was "is there work left?" — used un-negated, which
    // got both directions wrong at once: an idle vault never took the fast
    // path (every round asked the server for every file again), and a vault
    // holding one unuploaded attachment took it (the attachment was shelved
    // forever, which is exactly the state a freshly pasted image is in).

    test('an idle vault does not read the files again', () async {
      await writeLocal('notes/a.md', 'body', uid: 'u-a', title: 'A');
      await run();

      counter.gets = 0;
      final second = await run();

      expect(second.error, isNull);
      expect(counter.gets, 0,
          reason: 'nothing moved, so the round must not fetch every file to '
              'learn what it already knew');
    });

    test('an attachment that has never been synced is not shelved', () async {
      // The state a freshly pasted image sits in: every note is in sync and
      // one attachment has no base row yet. The round used to read that as
      // "there is nothing to do" — the very thing it was checking for.
      await writeLocal('notes/a.md', '![[attachments/pic.png]]',
          uid: 'u-a', title: 'A');
      await run();
      expect(await dav.remoteExists('notes/attachments/pic.png'), isFalse);

      // The picture arrives on disk.
      final pic = File(p.join(vault.path, 'notes', 'attachments', 'pic.png'));
      pic.parent.createSync(recursive: true);
      pic.writeAsBytesSync(_png);
      await rescan();

      final result = await run();

      expect(result.error, isNull);
      expect(await dav.remoteExists('notes/attachments/pic.png'), isTrue,
          reason: 'the attachment is the only thing with work to do, and the '
              'short-circuit must not swallow it');
    });
  });

    test('pulls a remote note this device has never seen', () async {
      await dav.seedRemote('notes/remote.md',
          utf8.encode(note('u-r', 'Remote', 'from another device')));

      final result = await run();

      expect(result.downloaded, contains('notes/remote.md'));
      expect(await readLocal('notes/remote.md'), contains('from another device'));
      final record = await meta.byPath(rootId, 'notes/remote.md');
      expect(record!.baseEtag, isNotNull);
    });

    test('walks nested directories', () async {
      await dav.seedRemote(
          'notes/daily/deep/x.md', utf8.encode(note('u-x', 'X', 'nested')));
      await run();
      expect(await readLocal('notes/daily/deep/x.md'), contains('nested'));
    });

    test('never syncs anything outside notes/', () async {
      await dav.seedRemote('_conflicts/20260101-000000-1-a/local.md',
          utf8.encode('conflict copy'));
      await dav.seedRemote('.jotit/jotit.db', utf8.encode('private'));
      await dav.seedRemote('notes/real.md', utf8.encode(note('u-r', 'R', 'x')));

      await run();

      expect(await files.readBytesIfPresent('_conflicts/20260101-000000-1-a/local.md'),
          isNull);
      expect(await files.readBytesIfPresent('.jotit/jotit.db'), isNull);
      expect(await readLocal('notes/real.md'), contains('x'));
    });
  });

  group('a server that will not create folders for you', () {
    // The whole group runs against `--strict-collections`, which makes a PUT
    // into a missing folder answer 409 the way Apache mod_dav — Synology DSM's
    // WebDAV — actually does. Found by running the Windows app against a real
    // NAS: every note was refused forever, and the Settings page blamed a
    // stale base that had never existed.
    late DavHarness strict;
    late Directory strictVault;
    late JotItDatabase strictDb;
    late NoteFileStore strictFiles;
    late NoteDao strictNotes;
    late SyncMetaStore strictMeta;
    late SyncRootStore strictRoots;
    late SyncEngine strictEngine;

    setUp(() async {
      strict = await DavHarness.start(extraArgs: ['--strict-collections']);
      strictVault = await Directory.systemTemp.createTemp('jotit_strict_');
      strictFiles = NoteFileStore(vaultRoot: strictVault.path);
      await NoteFileStore.ensureLayout(strictVault.path);
      strictDb = await JotItDatabase.open(
        filePath: p.join(VaultPaths.appRoot(strictVault.path), 'jotit.db'),
      );
      strictNotes = NoteDao(strictDb.db);
      strictMeta = SyncMetaStore(strictDb.db);
      strictRoots = SyncRootStore(strictDb.db);
      // `sync_meta` has a foreign key onto `sync_roots`, so a round without a
      // registered root fails before it ever reaches the server.
      await strictRoots.upsert(SyncRootRecord(
        id: rootId,
        name: 'strict',
        baseUrl: strict.baseUri().toString(),
        username: 'testuser',
      ));
      strictEngine = SyncEngine(
        dav: strict.client(),
        files: strictFiles,
        notes: strictNotes,
        meta: strictMeta,
        roots: strictRoots,
        vaultRoot: strictVault.path,
      );
    });

    tearDown(() async {
      await strictDb.close();
      if (strictVault.existsSync()) await strictVault.delete(recursive: true);
      await strict.dispose();
    });

    test('a brand new vault uploads its first note', () async {
      // The server has never seen `notes/`, and this is the very first round
      // of a vault that has never synced anywhere.
      expect(await strict.remoteExists('notes'), isFalse);

      await strictFiles.writeAtomic('notes/a.md', utf8.encode(note('u-a', 'A', 'body')));
      await VaultScanner(database: strictDb.db, fileStore: strictFiles).reindex();

      now += 1000;
      final result = await strictEngine.run(syncRootId: rootId, nowMs: now);

      expect(result.error, isNull);
      expect(result.preconditionFailed, isEmpty,
          reason: 'a missing folder is not a stale base');
      expect(result.uploaded, contains('notes/a.md'));
      expect(utf8.decode((await strict.readRemote('notes/a.md'))!),
          contains('body'));
    });

    test('a note in a subfolder creates the whole chain', () async {
      // MKCOL of a deep path does not create the levels above it either, so a
      // single-level fix would work for `notes/a.md` and fail for
      // `notes/sub/a.md`.
      await strictFiles.writeAtomic('notes/sub/a.md',
          utf8.encode(note('u-a', 'A', 'body')));
      await VaultScanner(database: strictDb.db, fileStore: strictFiles).reindex();

      now += 1000;
      final result = await strictEngine.run(syncRootId: rootId, nowMs: now);

      expect(result.error, isNull);
      expect(result.uploaded, contains('notes/sub/a.md'));
      expect(await strict.remoteExists('notes/sub/a.md'), isTrue);
    });

    test('the second round is still a no-op', () async {
      await strictFiles.writeAtomic('notes/a.md', utf8.encode(note('u-a', 'A', 'body')));
      await VaultScanner(database: strictDb.db, fileStore: strictFiles).reindex();
      now += 1000;
      await strictEngine.run(syncRootId: rootId, nowMs: now);

      now += 1000;
      final second = await strictEngine.run(syncRootId: rootId, nowMs: now);

      expect(second.uploaded, isEmpty);
      expect(second.downloaded, isEmpty);
      expect(second.preconditionFailed, isEmpty);
    });
  });

  group('remote edits', () {
    test('an untouched local note adopts the remote version', () async {
      await dav.seedRemote('notes/a.md', utf8.encode(note('u-a', 'A', 'v1')));
      await run();

      await dav.seedRemote('notes/a.md', utf8.encode(note('u-a', 'A', 'v2')));
      final result = await run();

      expect(result.downloaded, contains('notes/a.md'));
      expect(await readLocal('notes/a.md'), contains('v2'));
    });

    test('a local note with no edit does not clobber the remote', () async {
      await dav.seedRemote('notes/a.md', utf8.encode(note('u-a', 'A', 'v1')));
      await run();
      await dav.seedRemote('notes/a.md', utf8.encode(note('u-a', 'A', 'v2')));
      await run();

      expect(utf8.decode((await dav.readRemote('notes/a.md'))!), contains('v2'),
          reason: 'downloading must not push the stale local copy back up');
    });

    test('the base advances after a download', () async {
      await dav.seedRemote('notes/a.md', utf8.encode(note('u-a', 'A', 'v1')));
      await run();
      final first = (await meta.byPath(rootId, 'notes/a.md'))!.baseEtag;

      await dav.seedRemote('notes/a.md', utf8.encode(note('u-a', 'A', 'v2')));
      await run();
      final second = (await meta.byPath(rootId, 'notes/a.md'))!.baseEtag;

      expect(second, isNotNull);
      expect(second == first, false,
          reason: 'an unchanged base re-downloads the same bytes forever');
    });
  });

  group('local edits', () {
    test('an untouched remote accepts the local version', () async {
      await dav.seedRemote('notes/a.md', utf8.encode(note('u-a', 'A', 'v1')));
      await run();

      await writeLocal('notes/a.md', 'local edit', uid: 'u-a', title: 'A');
      final result = await run();

      expect(result.uploaded, contains('notes/a.md'));
      expect(utf8.decode((await dav.readRemote('notes/a.md'))!),
          contains('local edit'));
    });

    test('a conditional upload is rejected when the server moved on', () async {
      await dav.seedRemote('notes/a.md', utf8.encode(note('u-a', 'A', 'v1')));
      await run();

      // The other device wins the race between our base and our upload.
      await dav.seedRemote('notes/a.md', utf8.encode(note('u-a', 'A', 'remote won')));
      await writeLocal('notes/a.md', 'local edit', uid: 'u-a', title: 'A');

      final result = await run();

      expect(result.conflicts, contains('notes/a.md'),
          reason: 'ADR-8: the server refuses the stale write, so this is a '
              'divergence, not an upload');
      expect(utf8.decode((await dav.readRemote('notes/a.md'))!),
          contains('remote won'),
          reason: 'the server content must survive untouched');
    });
  });

  group('precondition failure (matrix row 10)', () {
    test('a 412 is reclassified next round instead of being retried blind',
        () async {
      await dav.seedRemote('notes/a.md', utf8.encode(note('u-a', 'A', 'v1')));
      await run();

      await writeLocal('notes/a.md', 'local edit', uid: 'u-a', title: 'A');

      // The remote moves *after* the walk recorded its ETag.
      engine = engineThatMutatesOnRead(
        path: 'notes/a.md',
        bytes: utf8.encode(note('u-a', 'A', 'other device won')),
      );
      final result = await run();

      expect(result.preconditionFailed, contains('notes/a.md'),
          reason: 'the server refused our If-Match, so this path was not '
              'uploaded and must be reported as refused');
      expect(result.uploaded, isNot(contains('notes/a.md')));
      expect(utf8.decode((await dav.readRemote('notes/a.md'))!),
          contains('other device won'),
          reason: 'the refused write must not have landed');
    });

    test('the refusal is counted on the path, not swallowed', () async {
      await dav.seedRemote('notes/a.md', utf8.encode(note('u-a', 'A', 'v1')));
      await run();
      await writeLocal('notes/a.md', 'local edit', uid: 'u-a', title: 'A');

      engine = engineThatMutatesOnRead(
        path: 'notes/a.md',
        bytes: utf8.encode(note('u-a', 'A', 'other device won')),
      );
      await run();

      final record = await meta.byPath(rootId, 'notes/a.md');
      expect(record, isNotNull);
      expect(record!.retryCount, 1);
      expect(record.lastError, contains('412'));
    });

    test('one refused path does not abandon the rest of the round', () async {
      await dav.seedRemote('notes/a.md', utf8.encode(note('u-a', 'A', 'v1')));
      await dav.seedRemote('notes/b.md', utf8.encode(note('u-b', 'B', 'v1')));
      await run();

      await writeLocal('notes/a.md', 'local edit', uid: 'u-a', title: 'A');
      await writeLocal('notes/b.md', 'local edit', uid: 'u-b', title: 'B');

      // Only notes/a.md is raced. Before the transport layer was taught to
      // return 412 instead of throwing it, this single refusal escaped as a
      // DavException and abandoned the whole batch — notes/b.md stayed
      // un-uploaded and the round reported an error rather than a result.
      engine = SyncEngine(
        dav: _MutateOnFirstGet(
          inner: dav.client(),
          onFirstGet: () async {
            final listing = await dav.client().propfind('notes/', depth: 1);
            if (listing.resources.any((r) => r.path.endsWith('b.md'))) {
              await dav.seedRemote(
                  'notes/a.md', utf8.encode(note('u-a', 'A', 'other device won')));
            }
          },
        ),
        files: files,
        notes: notes,
        meta: meta,
        roots: roots,
        vaultRoot: vault.path,
      );
      final result = await run();

      expect(result.preconditionFailed, contains('notes/a.md'));
      expect(result.uploaded, contains('notes/b.md'),
          reason: 'a refusal on one path must not stop the others');
      expect(result.error, isNull);
      expect(utf8.decode((await dav.readRemote('notes/b.md'))!),
          contains('local edit'));
    });

    test('the refusal count survives a restart', () async {
      await dav.seedRemote('notes/a.md', utf8.encode(note('u-a', 'A', 'v1')));
      await run();
      await writeLocal('notes/a.md', 'local edit', uid: 'u-a', title: 'A');

      engine = engineThatMutatesOnRead(
        path: 'notes/a.md',
        bytes: utf8.encode(note('u-a', 'A', 'other device won')),
      );
      await run();
      expect((await meta.byPath(rootId, 'notes/a.md'))!.retryCount, 1);

      // A count that lives in the engine instance resets on restart, which is
      // the same shape of bug as the PIN backoff P2-18 was about.
      final afterRestart = SyncMetaStore(db.db);
      expect((await afterRestart.byPath(rootId, 'notes/a.md'))!.retryCount, 1);
      expect(await afterRestart.failing(rootId), hasLength(1));
      expect((await afterRestart.failing(rootId)).single.path, 'notes/a.md');
    });

    test('the stale base is not overwritten by the rejected ETag', () async {
      await dav.seedRemote('notes/a.md', utf8.encode(note('u-a', 'A', 'v1')));
      await run();
      final goodBase = (await meta.byPath(rootId, 'notes/a.md'))!.baseEtag;

      await writeLocal('notes/a.md', 'local edit', uid: 'u-a', title: 'A');
      engine = engineThatMutatesOnRead(
        path: 'notes/a.md',
        bytes: utf8.encode(note('u-a', 'A', 'other device won')),
      );
      await run();

      // Writing the refused ETag into base_etag would make the next pass see
      // "local changed, remote unchanged" and PUT into the same 412 forever —
      // and it would bless a body this device has never merged.
      expect((await meta.byPath(rootId, 'notes/a.md'))!.baseEtag, goodBase);
    });

    test('a path that syncs again clears its refusal', () async {
      await dav.seedRemote('notes/a.md', utf8.encode(note('u-a', 'A', 'v1')));
      await run();
      await writeLocal('notes/a.md', 'local edit', uid: 'u-a', title: 'A');

      engine = engineThatMutatesOnRead(
        path: 'notes/a.md',
        bytes: utf8.encode(note('u-a', 'A', 'other device won')),
      );
      await run();
      expect((await meta.byPath(rootId, 'notes/a.md'))!.retryCount, 1);

      // The real divergence surfaces on the next round, which is exactly what
      // row 10 is asking for, and it resolves into a conflict.
      engine = SyncEngine(
        dav: dav.client(),
        files: files,
        notes: notes,
        meta: meta,
        roots: roots,
        vaultRoot: vault.path,
      );
      final resolved = await run();

      expect(resolved.conflicts, contains('notes/a.md'),
          reason: 'reclassifying next round must actually reach row 9');
      expect((await meta.byPath(rootId, 'notes/a.md'))!.lastError, isNull,
          reason: 'a path that exchanged successfully carries no stale refusal');
    });
  });

  group('divergence', () {
    test('both sides edited: both copies are kept, neither is overwritten',
        () async {
      await dav.seedRemote('notes/a.md', utf8.encode(note('u-a', 'A', 'remote v1')));
      await run();

      // Local edit and remote edit land on opposite sides of a base that both
      // agree existed.
      await writeLocal('notes/a.md', 'local v2', uid: 'u-a', title: 'A');
      await dav.seedRemote('notes/a.md', utf8.encode(note('u-a', 'A', 'remote v2')));

      final result = await run();

      expect(result.conflicts, isNotEmpty);
      final dirs = ConflictWriter.pending(vault.path);
      expect(dirs, isNotEmpty);

      final local = await _side(vault.path, dirs.single, 'local.md');
      final remote = await _side(vault.path, dirs.single, 'remote.md');
      expect(local, isNotNull);
      expect(remote, isNotNull);
      expect(utf8.decode(local!), contains('local v2'));
      expect(utf8.decode(remote!), contains('remote v2'));

      // The user's own file is not annotated either.
      expect(await readLocal('notes/a.md'), isNot(contains('CONFLICT')));
    });

    test('a new conflict on top of a pending one still keeps the bytes',
        () async {
      // P1-7: a conflict that is already waiting on a person does not earn
      // a second copy directory every round — but the bytes still have to be
      // written. The divergence moves on while the first copy waits: the
      // remote deletes the note and the local edit changes again. The
      // branch that follows deletes the local file, so the newest edit has
      // nowhere else to be — the copy that is already on disk describes a
      // round that has been superseded.
      await dav.seedRemote('notes/a.md', utf8.encode(note('u-a', 'A', 'remote v1')));
      await run();

      // A genuine conflict: both sides changed.
      await writeLocal('notes/a.md', 'local v2', uid: 'u-a', title: 'A');
      await dav.seedRemote('notes/a.md', utf8.encode(note('u-a', 'A', 'remote v2')));
      await run();
      final dirs = ConflictWriter.pending(vault.path);
      expect(dirs, hasLength(1));
      expect(
        utf8.decode((await _side(vault.path, dirs.single, 'local.md'))!),
        contains('local v2'),
      );

      // The divergence moves on: the remote deletes the note, and the local
      // edit changes again.
      await writeLocal('notes/a.md', 'local v3', uid: 'u-a', title: 'A');
      await dav.removeRemote('notes/a.md');

      await run();

      final after = ConflictWriter.pending(vault.path);
      expect(after, hasLength(1),
          reason: 'a conflict waiting on a person does not earn a new copy '
              'directory every round');
      final local = await _side(vault.path, after.single, 'local.md');
      expect(local, isNotNull);
      expect(utf8.decode(local!), contains('local v3'),
          reason: 'the newest edit has to be in the copy — the local file is '
              'about to be deleted, and the earlier copy is a round old');
    });

    test('the conflict is flagged for the user, not auto-resolved', () async {
      await dav.seedRemote('notes/a.md', utf8.encode(note('u-a', 'A', 'remote v1')));
      await run();
      await writeLocal('notes/a.md', 'local v2', uid: 'u-a', title: 'A');
      await dav.seedRemote('notes/a.md', utf8.encode(note('u-a', 'A', 'remote v2')));
      await run();

      final open = await meta.unresolved(rootId);
      expect(open, isNotEmpty,
          reason: 'a conflict the UI cannot see is a conflict nobody resolves');
      expect(open.first.conflictState.isUnresolved, isTrue);
      expect(open.first.conflictCopyDir, isNotNull);
    });

    test('two devices creating the same path keep both', () async {
      // Same path, different identities: the P0-6 collision.
      await dav.seedRemote('notes/daily/2024-01-01.md',
          utf8.encode(note('u-remote', 'Remote', 'remote side')));
      await writeLocal('notes/daily/2024-01-01.md', 'local side',
          uid: 'u-local', title: 'Local');

      final result = await run();

      expect(result.conflicts, contains('notes/daily/2024-01-01.md'));
      expect(utf8.decode((await dav.readRemote('notes/daily/2024-01-01.md'))!),
          contains('remote side'),
          reason: 'the remote copy stays exactly as the other device wrote it');
    });
  });

  group('renames (matrix row 3)', () {
    // The other device moved a file. Identity travels in the front matter,
    // so the uid is the only reliable way to see this as a rename rather than
    // as one deletion plus one unrelated new file.
    Future<void> renameRemote(String from, String to, String uid) async {
      final bytes = (await dav.readRemote(from))!;
      await dav.seedRemote(to, bytes);
      final f = File(p.join(dav.root.path, p.joinAll(from.split('/'))));
      if (f.existsSync()) await f.delete();
    }

    test('a remote rename moves the local file and keeps the identity',
        () async {
      await dav.seedRemote('notes/old.md', utf8.encode(note('u-a', 'A', 'v1')));
      await run();
      expect(await readLocal('notes/old.md'), contains('v1'));

      await renameRemote('notes/old.md', 'notes/new.md', 'u-a');
      await run();

      expect(await files.readBytesIfPresent('notes/new.md'), isNotNull,
          reason: 'the note should follow the file to its new home');
      expect(await readLocal('notes/new.md'), contains('v1'));
      expect(await files.readBytesIfPresent('notes/old.md'), isNull,
          reason: 'leaving the old copy behind means the same note exists '
              'twice, under two paths, forever');
    });

    test('a rename does not produce a conflict', () async {
      await dav.seedRemote('notes/old.md', utf8.encode(note('u-a', 'A', 'v1')));
      await run();
      await renameRemote('notes/old.md', 'notes/new.md', 'u-a');

      final result = await run();

      expect(result.conflicts, isEmpty,
          reason: 'a rename is not a divergence');
      expect(ConflictWriter.pending(vault.path), isEmpty);
    });

    test('the base follows the rename and keeps the uid', () async {
      await dav.seedRemote('notes/old.md', utf8.encode(note('u-a', 'A', 'v1')));
      await run();
      await renameRemote('notes/old.md', 'notes/new.md', 'u-a');
      await run();

      final moved = await meta.byPath(rootId, 'notes/new.md');
      expect(moved, isNotNull);
      expect(moved!.uid, 'u-a',
          reason: 'losing the uid here is what makes the next round see a '
              'rename and a delete instead');
      expect(moved.baseEtag, isNotNull);
    });

    test('a remote rename adopts the remote content, not the stale local copy',
        () async {
      // P0-1: the old branch renamed the local file and committed a base
      // built from the remote ETag plus the *local* hash, having never
      // fetched the body. This device then sat on v1 believing it was in
      // sync, and its next upload silently overwrote the other device's
      // edit with that stale content.
      await dav.seedRemote('notes/old.md', utf8.encode(note('u-a', 'A', 'v1')));
      await run();

      await renameRemote('notes/old.md', 'notes/new.md', 'u-a');
      await dav.seedRemote(
          'notes/new.md', utf8.encode(note('u-a', 'A', 'v2 edited remotely')));

      final result = await run();

      expect(result.error, isNull);
      expect(await readLocal('notes/new.md'), contains('v2 edited remotely'));
      // The base must describe the bytes actually on disk.
      final onDisk = (await files.readBytesIfPresent('notes/new.md'))!;
      final record = await meta.byPath(rootId, 'notes/new.md');
      expect(record!.baseContentHash, ContentHash.ofBytes(onDisk));
      expect(record.baseEtag, isNotNull);

      // And the round that follows must agree it has nothing left to do.
      final second = await run();
      expect(second.downloaded, isEmpty);
      expect(second.uploaded, isEmpty);
    });

    test('a rename with an unsynced local edit keeps the edit in _conflicts/',
        () async {
      // P0-1 + C3: the rename is adopted (the uid proves it is the same
      // note), but the local edit cannot be accounted for, so its bytes are
      // preserved before the remote content replaces the file.
      await dav.seedRemote('notes/old.md', utf8.encode(note('u-a', 'A', 'v1')));
      await run();

      await renameRemote('notes/old.md', 'notes/new.md', 'u-a');
      await dav.seedRemote(
          'notes/new.md', utf8.encode(note('u-a', 'A', 'v2 remote')));
      await writeLocal('notes/old.md', 'my unsynced edit', uid: 'u-a', title: 'A');

      await run();

      expect(await readLocal('notes/new.md'), contains('v2 remote'),
          reason: 'the rename is still adopted');
      final dirs = ConflictWriter.pending(vault.path);
      expect(dirs, isNotEmpty);
      final preserved = await _side(vault.path, dirs.single, 'local.md');
      expect(preserved, isNotNull);
      expect(utf8.decode(preserved!), contains('my unsynced edit'),
          reason: 'the edit survives somewhere, or it is simply gone');

      final record = await meta.byPath(rootId, 'notes/new.md');
      expect(record!.conflictState.isUnresolved, isTrue);
      expect(record.conflictCopyDir, isNotNull);
      // The base still matches the bytes on disk.
      final onDisk = (await files.readBytesIfPresent('notes/new.md'))!;
      expect(record.baseContentHash, ContentHash.ofBytes(onDisk));
    });

    test('a rename onto a local file with a different uid keeps both',
        () async {
      // P0-3: the target path already holds another device's note. Row 3
      // used to fire anyway, and the engine deleted the local file without
      // a copy — an unsynced note destroyed by a rename it had no part in.
      await dav.seedRemote('notes/old.md', utf8.encode(note('u-a', 'A', 'v1')));
      await run();

      await writeLocal('notes/new.md', 'local side', uid: 'u-local',
          title: 'Local');
      await renameRemote('notes/old.md', 'notes/new.md', 'u-a');

      final result = await run();

      expect(result.conflicts, contains('notes/new.md'));
      expect(await readLocal('notes/new.md'), contains('local side'),
          reason: 'the local note at the target path is not destroyed');
      final dirs = ConflictWriter.pending(vault.path);
      expect(dirs, isNotEmpty);
      final remote = await _side(vault.path, dirs.single, 'remote.md');
      expect(remote, isNotNull);
      expect(utf8.decode(remote!), contains('v1'),
          reason: 'and the remote copy is preserved too');
    });
    test('a remote deletion propagates to a note nobody edited', () async {
      await dav.seedRemote('notes/a.md', utf8.encode(note('u-a', 'A', 'v1')));
      await run();
      expect(await dav.remoteExists('notes/a.md'), isTrue);

      final file = File(p.join(dav.root.path, 'notes', 'a.md'));
      await file.delete();
      await run();

      expect(await files.readBytesIfPresent('notes/a.md'), isNull);
    });

    test('a remote deletion never silently discards a local edit', () async {
      // The P0-5 case. Losing someone's edit because a file vanished is the
      // single worst thing a sync engine can do.
      await dav.seedRemote('notes/a.md', utf8.encode(note('u-a', 'A', 'v1')));
      await run();

      await writeLocal('notes/a.md', 'my unsynced edit', uid: 'u-a', title: 'A');
      final file = File(p.join(dav.root.path, 'notes', 'a.md'));
      await file.delete();

      await run();

      final dirs = ConflictWriter.pending(vault.path);
      expect(dirs, isNotEmpty,
          reason: 'the local edit must be preserved somewhere');
      final preserved =
          await _side(vault.path, dirs.single, 'local.md');
      expect(preserved, isNotNull);
      expect(utf8.decode(preserved!), contains('my unsynced edit'));
    });
  });

  group('a rename made outside the app (P1-6)', () {
    // The file manager is the only rename path this app has: there is no
    // rename entry point, so a note that is moved on disk is a note that
    // changed path and kept its identity.
    //
    // The bug this pins down: the reindex used to delete the old index row
    // outright. The sync round then read "the server has this file and this
    // device does not" and downloaded the server's old copy back over the
    // moved note — the rename silently reverted, the note went back to the
    // content it had before the move, and the edited version was not
    // visible in the app any more.

    /// Moves a file the way a file manager does: the bytes go with it.
    Future<void> moveOnDisk(String from, String to) async {
      final source = File(p.join(vault.path, p.joinAll(from.split('/'))));
      final target = File(p.join(vault.path, p.joinAll(to.split('/'))));
      await target.parent.create(recursive: true);
      await source.rename(target.path);
    }

    test('the moved note reaches the server and the old copy is not restored',
        () async {
      await dav.seedRemote('notes/old.md', utf8.encode(note('u-a', 'A', 'v1')));
      await run();
      expect(await readLocal('notes/old.md'), contains('v1'));
      // The index has to know the note before it moves: the engine's
      // download writes the file and the base, and the index follows on the
      // next pass — which is exactly when the app is running.
      await rescan();

      // The user moves the file in the file manager and edits it there.
      await moveOnDisk('notes/old.md', 'notes/new.md');
      await files.writeAtomic(
          'notes/new.md', utf8.encode(note('u-a', 'A', 'v2 edited locally')));
      await rescan();

      final result = await run();

      expect(result.error, isNull);
      expect(await files.readBytesIfPresent('notes/old.md'), isNull,
          reason: 'the server copy must not be downloaded back over the moved '
              'note — that is what silently undid the rename');
      expect(await readLocal('notes/new.md'), contains('v2 edited locally'),
          reason: 'the edit made after the move is the note');
      expect(await dav.remoteExists('notes/old.md'), isFalse,
          reason: 'the rename has to reach the server, not just this device');
      final remote = await dav.readRemote('notes/new.md');
      expect(remote, isNotNull);
      expect(utf8.decode(remote!), contains('v2 edited locally'));
    });

    test('a moved note keeps its identity in the index', () async {
      await dav.seedRemote('notes/old.md', utf8.encode(note('u-a', 'A', 'v1')));
      await run();
      await rescan();

      await moveOnDisk('notes/old.md', 'notes/new.md');
      await rescan();

      final moved = await notes.byUid('u-a');
      expect(moved, isNotNull);
      expect(moved!.path, 'notes/new.md',
          reason: 'the identity lives in the front matter, the path does not');
      expect(moved.isDeleted, isFalse);
      expect(await notes.byPath('notes/old.md'), isNull,
          reason: 'the old path is not the note any more');
    });

    test('the old path is remembered as vacated, so the server copy goes',
        () async {
      await dav.seedRemote('notes/old.md', utf8.encode(note('u-a', 'A', 'v1')));
      await run();
      await rescan();

      await moveOnDisk('notes/old.md', 'notes/new.md');
      await rescan();

      // The tombstone is what the sync engine reads as "this device no
      // longer has a note here". Without it the round sees a file the
      // server has and the device does not, and downloads it back.
      final tombstone = await notes.byPath('notes/old.md', includeDeleted: true);
      expect(tombstone, isNotNull);
      expect(tombstone!.isDeleted, isTrue);
    });
  });

  group('an unreachable remote (P0-4)', () {
    test('a 404 on the synced root aborts the round instead of deleting the '
        'vault', () async {
      await writeLocal('notes/a.md', 'body', uid: 'u-a', title: 'A');
      await writeLocal('notes/b.md', 'body', uid: 'u-b', title: 'B');
      await run();
      expect(await dav.remoteExists('notes/a.md'), isTrue);

      // The whole subtree disappears from the server — a mistyped baseUrl,
      // a renamed share, a box mid-restart. Reading the 404 as "an empty
      // collection" used to delete every note in the vault.
      await Directory(p.join(dav.root.path, 'notes')).delete(recursive: true);

      now += 1000;
      final result = await engine.run(syncRootId: rootId, nowMs: now);

      expect(result.error, isNotNull);
      expect(result.error, contains('远端状态不明'));
      expect(result.deleted, isEmpty);
      expect(await files.readBytesIfPresent('notes/a.md'), isNotNull,
          reason: 'an unreachable server is not a deletion');
      expect(await files.readBytesIfPresent('notes/b.md'), isNotNull);
    });

    test('a first round against an empty server still uploads', () async {
      // The other half of the same check: with no base at all, a missing
      // synced root is a legitimate first round, not an abort.
      await dav.dispose();
      dav = await DavHarness.start(extraArgs: ['--strict-collections']);
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

      await writeLocal('notes/a.md', 'body', uid: 'u-a', title: 'A');
      final result = await run();

      expect(result.error, isNull);
      expect(result.uploaded, contains('notes/a.md'));
    });

    test('a 404 on a subfolder is unknown, not a deletion', () async {
      await dav.seedRemote('notes/sub/a.md', utf8.encode(note('u-a', 'A', 'v1')));
      await run();
      expect(await readLocal('notes/sub/a.md'), contains('v1'));

      // The parent still lists the collection, but listing the collection
      // itself 404s — the shape a raced deletion or a sulking server
      // produces. The server never said the note was gone.
      engine = SyncEngine(
        dav: _SubfolderVanishes(
          inner: dav.client(),
          path: 'notes/sub',
        ),
        files: files,
        notes: notes,
        meta: meta,
        roots: roots,
        vaultRoot: vault.path,
      );

      final result = await run();

      expect(result.deleted, isNot(contains('notes/sub/a.md')));
      expect(result.downloaded, isEmpty);
      expect(await readLocal('notes/sub/a.md'), contains('v1'),
          reason: 'the server never said this note was gone');
      expect(await dav.remoteExists('notes/sub/a.md'), isTrue,
          reason: 'and nothing was deleted from the server either');
    });
  });

  group('session bookkeeping', () {
    test('a successful round stores the CTag', () async {
      await writeLocal('notes/a.md', 'body', uid: 'u-a', title: 'A');
      now += 1000;
      await engine.run(syncRootId: rootId, nowMs: now);
      await engine.recordSuccess(
          syncRootId: rootId, nowMs: now, collectionCtag: '"ctag-1"');

      final root = await roots.byId(rootId);
      expect(root!.collectionCtag, '"ctag-1"');
      expect(root.lastSyncAt, now);
      expect(root.nextAttemptAt, 0);
      expect(root.lastError, isNull);
    });

    test('a failure arms a backoff that survives a restart', () async {
      final failing = SyncEngine(
        dav: DavClient(
          baseUri: dav.baseUri(),
          username: 'testuser',
          password: 'wrong-password',
        ),
        files: files,
        notes: notes,
        meta: meta,
        roots: roots,
        vaultRoot: vault.path,
      );

      final result = await failing.run(syncRootId: rootId, nowMs: now);
      expect(result.error, isNotNull);
      // P1-4: the round ends at idle, not wedged in `backoff`. The machine
      // only tracks whether a session is in flight; the deadline that
      // actually guards the retry is the one persisted on `sync_roots`
      // below. A machine left in `backoff` refuses every future trigger,
      // which is a single-flight lock that never unlocks.
      expect(failing.state, SyncState.idle);
      expect(failing.isRunning, isFalse);

      await failing.recordFailure(
          syncRootId: rootId, nowMs: now, retryCount: 2, error: result.error!);

      final root = await roots.byId(rootId);
      expect(root!.nextAttemptAt, greaterThan(now));
      expect(root.lastError, isNotNull);
      expect(root.isReadyAt(now), isFalse,
          reason: 'a root still inside its backoff must refuse a fresh start');
    });

    test('a failed round does not wedge the instance for the next one',
        () async {
      // P1-4: the second `run()` used to be answered by the single-flight
      // guard with an empty result — the machine never left `backoff`, so
      // the same instance could never sync again for the life of the
      // process.
      final failing = SyncEngine(
        dav: DavClient(
          baseUri: dav.baseUri(),
          username: 'testuser',
          password: 'wrong-password',
        ),
        files: files,
        notes: notes,
        meta: meta,
        roots: roots,
        vaultRoot: vault.path,
      );

      final first = await failing.run(syncRootId: rootId, nowMs: now);
      expect(first.error, isNotNull);
      final second = await failing.run(syncRootId: rootId, nowMs: now);
      expect(second.error, isNotNull,
          reason: 'a refused single-flight round returns no error; a real '
              'attempt that fails again does');
    });

    test('a nothing-to-do round still leaves the machine able to run',
        () async {
      // P1-4: the "nothing to do" early return used to leave the machine in
      // `diffBuild`, so the third round below was refused as "already
      // running" and the remote note was never downloaded.
      await writeLocal('notes/a.md', 'body', uid: 'u-a', title: 'A');
      await run();

      final quiet = await run();
      expect(quiet.isEmpty, isTrue);

      await dav.seedRemote('notes/b.md', utf8.encode(note('u-b', 'B', 'x')));
      final third = await run();
      expect(third.downloaded, contains('notes/b.md'));
      expect(engine.state, SyncState.idle);
    });

    test('a second concurrent session is refused, not run in parallel',
        () async {
      await writeLocal('notes/a.md', 'body', uid: 'u-a', title: 'A');
      final first = engine.run(syncRootId: rootId, nowMs: now);
      final second = await engine.run(syncRootId: rootId, nowMs: now);
      expect(second.isEmpty, isTrue,
          reason: 'single-flight: the second caller gets the running state');
      await first;
    });

    test('the machine is back at idle when a round finishes', () async {
      await writeLocal('notes/a.md', 'body', uid: 'u-a', title: 'A');
      await run();
      expect(engine.state, SyncState.idle);
      expect(engine.isRunning, isFalse);
    });
  });

  group('capability profiles', () {
    test('a server with no CTag still syncs by full scan', () async {
      await dav.dispose();
      dav = await DavHarness.start(extraArgs: ['--no-ctag']);
      await roots.upsert(SyncRootRecord(
        id: rootId,
        name: 'test',
        baseUrl: dav.baseUri().toString(),
      ));
      engine = SyncEngine(
        dav: dav.client(capabilities: noCtagProfile()),
        files: files,
        notes: notes,
        meta: meta,
        roots: roots,
        vaultRoot: vault.path,
      );

      await writeLocal('notes/a.md', 'body', uid: 'u-a', title: 'A');
      final first = await run();
      expect(first.uploaded, contains('notes/a.md'));

      await dav.seedRemote('notes/b.md', utf8.encode(note('u-b', 'B', 'x')));
      final second = await run();
      expect(second.downloaded, contains('notes/b.md'),
          reason: 'without a CTag every round must walk; skipping here is the '
              'v2.0 bug where a device reports itself in sync forever');
    });

    // Synology DSM's WebDAV is Apache mod_dav, and it returns `W/"31-..."` for
    // every file. Found against the real box, not guessed: with a weak-etag
    // profile the unguarded engine sent If-Match, DavClient refused to send it,
    // and the ArgumentError unwound out of the whole round.
    group('a server with weak ETags', () {
      DavCapabilities weakProfile() => const DavCapabilities(
            supportsCtag: false,
            etagIsWeak: true,
            supportsIfMatch: true,
            supportsIfNoneMatch: true,
          );

      SyncEngine weakEngine() => SyncEngine(
            dav: dav.client(capabilities: weakProfile()),
            files: files,
            notes: notes,
            meta: meta,
            roots: roots,
            vaultRoot: vault.path,
          );

      test('an edit still reaches the server instead of throwing', () async {
        await dav.seedRemote('notes/a.md', utf8.encode(note('u-a', 'A', 'v1')));
        engine = weakEngine();
        await run();

        await writeLocal('notes/a.md', 'local edit', uid: 'u-a', title: 'A');
        engine = weakEngine();
        final result = await run();

        expect(result.error, isNull);
        expect(result.uploaded, contains('notes/a.md'));
        expect(utf8.decode((await dav.readRemote('notes/a.md'))!),
            contains('local edit'));
      });

      test('an update is never sent as a create', () async {
        // `If-None-Match: *` on an existing path is a phantom 412. A server
        // that hands back no ETag on PUT leaves the base empty, and a naive
        // fallback turns every later update into a refused create.
        await dav.seedRemote('notes/a.md', utf8.encode(note('u-a', 'A', 'v1')));
        engine = weakEngine();
        await run();

        await writeLocal('notes/a.md', 'local edit', uid: 'u-a', title: 'A');
        engine = weakEngine();
        final result = await run();

        expect(result.preconditionFailed, isEmpty);
        expect(result.error, isNull);
        expect(result.uploaded, contains('notes/a.md'));
      });

      test('the base is still learned, so the next round converges', () async {
        await dav.seedRemote('notes/a.md', utf8.encode(note('u-a', 'A', 'v1')));
        engine = weakEngine();
        await run();

        await writeLocal('notes/a.md', 'local edit', uid: 'u-a', title: 'A');
        engine = weakEngine();
        await run();

        expect((await meta.byPath(rootId, 'notes/a.md'))!.baseEtag, isNotNull,
            reason: 'the tag is recovered with a stat when PUT returns none');

        engine = weakEngine();
        final settled = await run();
        expect(settled.uploaded, isEmpty);
        expect(settled.downloaded, isEmpty,
            reason: 'a note that just synced must not be re-downloaded');
      });
    });
  });
}

/// Synology DSM's profile: no CTag, but conditional writes still work.
DavCapabilities noCtagProfile() => const DavCapabilities(
      supportsCtag: false,
      supportsIfMatch: true,
      supportsIfNoneMatch: true,
    );

/// Runs [onFirstGet] the first time a note body is read, then behaves exactly
/// like the client it wraps.
///
/// The engine reads every candidate body through `get` while classifying, so
/// that is the narrowest place where "the remote changed after our snapshot"
/// can be staged without a sleep, a timer, or a race the test does not
/// control.
class _MutateOnFirstGet extends DavClient {
  _MutateOnFirstGet({required DavClient inner, required this.onFirstGet})
      : _inner = inner,
        super(
          baseUri: inner.baseUri,
          username: inner.username,
          password: inner.password,
          capabilities: inner.capabilities,
        );

  final DavClient _inner;
  final Future<void> Function() onFirstGet;
  bool _fired = false;

  @override
  Future<List<int>?> get(String path, {int? expectedLength}) async {
    if (!_fired) {
      _fired = true;
      await onFirstGet();
    }
    return _inner.get(path, expectedLength: expectedLength);
  }

  @override
  Future<DavListing> propfind(String path, {int depth = 1}) =>
      _inner.propfind(path, depth: depth);

  @override
  Future<DavResource?> stat(String path) => _inner.stat(path);

  @override
  Future<DavListing?> listCollection(String path) =>
      _inner.listCollection(path);

  @override
  Future<DavPutResult> put(
    String path,
    List<int> bytes, {
    DavCondition condition = const DavUnconditional(),
    String contentType = 'text/markdown; charset=utf-8',
  }) =>
      _inner.put(path, bytes, condition: condition, contentType: contentType);

  @override
  Future<void> ensureCollection(String collectionPath) =>
      _inner.ensureCollection(collectionPath);

  @override
  Future<bool> delete(String path, {String? ifMatch}) =>
      _inner.delete(path, ifMatch: ifMatch);

  @override
  Future<DavCapabilities> probe() => _inner.probe();

  @override
  Future<void> close() => _inner.close();
}

/// A client whose listing of one subfolder 404s while the parent still lists
/// it — the shape a raced deletion or a sulking server produces.
///
/// Everything else is delegated, so the round is otherwise a normal one
/// against the real server.
class _SubfolderVanishes extends DavClient {
  _SubfolderVanishes({required DavClient inner, required this.path})
      : _inner = inner,
        super(
          baseUri: inner.baseUri,
          username: inner.username,
          password: inner.password,
          capabilities: inner.capabilities,
        );

  final DavClient _inner;
  final String path;

  @override
  Future<DavListing?> listCollection(String collectionPath) {
    if (collectionPath == path) return Future<DavListing?>.value(null);
    return _inner.listCollection(collectionPath);
  }

  @override
  Future<DavListing> propfind(String p, {int depth = 1}) =>
      _inner.propfind(p, depth: depth);

  @override
  Future<DavResource?> stat(String p) => _inner.stat(p);

  @override
  Future<List<int>?> get(String p, {int? expectedLength}) =>
      _inner.get(p, expectedLength: expectedLength);

  @override
  Future<DavPutResult> put(
    String p,
    List<int> bytes, {
    DavCondition condition = const DavUnconditional(),
    String contentType = 'text/markdown; charset=utf-8',
  }) =>
      _inner.put(p, bytes, condition: condition, contentType: contentType);

  @override
  Future<DavPutResult> putStream(
    String p,
    Stream<List<int>> content, {
    required int contentLength,
    String contentType = 'application/octet-stream',
    DavCondition condition = const DavUnconditional(),
    void Function(int sent)? onProgress,
    Duration? timeoutOverride,
  }) =>
      _inner.putStream(
        p,
        content,
        contentLength: contentLength,
        contentType: contentType,
        condition: condition,
        onProgress: onProgress,
        timeoutOverride: timeoutOverride,
      );

  @override
  Future<void> ensureCollection(String collectionPath) =>
      _inner.ensureCollection(collectionPath);

  @override
  Future<bool> delete(String p, {String? ifMatch}) =>
      _inner.delete(p, ifMatch: ifMatch);

  @override
  Future<void> move(String fromPath, String toPath, {bool overwrite = false}) =>
      _inner.move(fromPath, toPath, overwrite: overwrite);

  @override
  Future<DavCapabilities> probe() => _inner.probe();

  @override
  Future<void> close() => _inner.close();
}

Future<List<int>?> _side(String vaultRoot, String dir, String name) async {
  final f = File(p.join(VaultPaths.conflictsRoot(vaultRoot), dir, name));
  return await f.exists() ? f.readAsBytes() : null;
}

/// Counts the file reads the engine makes.
///
/// The idle round is a *cost* question as much as a correctness one: a
/// vault where nothing changed should not ask the server for every file
/// again. The number of GETs is the only honest witness.
class _CountingClient extends DavClient {
  _CountingClient({required DavClient inner})
      : _inner = inner,
        super(
          baseUri: inner.baseUri,
          username: inner.username,
          password: inner.password,
          capabilities: inner.capabilities,
        );

  final DavClient _inner;

  /// How many files were read since the counter was last cleared.
  int gets = 0;

  @override
  Future<List<int>?> get(String path, {int? expectedLength}) {
    gets++;
    return _inner.get(path, expectedLength: expectedLength);
  }

  @override
  Future<DavListing> propfind(String path, {int depth = 1}) =>
      _inner.propfind(path, depth: depth);

  @override
  Future<DavResource?> stat(String path) => _inner.stat(path);

  @override
  Future<DavListing?> listCollection(String path) =>
      _inner.listCollection(path);

  @override
  Future<DavPutResult> put(
    String path,
    List<int> bytes, {
    DavCondition condition = const DavUnconditional(),
    String contentType = 'text/markdown; charset=utf-8',
  }) =>
      _inner.put(path, bytes, condition: condition, contentType: contentType);

  @override
  Future<DavPutResult> putStream(
    String path,
    Stream<List<int>> content, {
    required int contentLength,
    String contentType = 'application/octet-stream',
    DavCondition condition = const DavUnconditional(),
    void Function(int sent)? onProgress,
    Duration? timeoutOverride,
  }) =>
      _inner.putStream(
        path,
        content,
        contentLength: contentLength,
        contentType: contentType,
        condition: condition,
        onProgress: onProgress,
        timeoutOverride: timeoutOverride,
      );

  @override
  Future<void> ensureCollection(String collectionPath) =>
      _inner.ensureCollection(collectionPath);

  @override
  Future<bool> delete(String path, {String? ifMatch}) =>
      _inner.delete(path, ifMatch: ifMatch);

  @override
  Future<void> move(String fromPath, String toPath, {bool overwrite = false}) =>
      _inner.move(fromPath, toPath, overwrite: overwrite);

  @override
  Future<DavCapabilities> probe() => _inner.probe();

  @override
  Future<void> close() => _inner.close();
}

/// A real 1×1 PNG. The bytes matter: an attachment that happens to be valid
/// UTF-8 would take the note path through the parser and hide what is being
/// tested here.
const List<int> _png = <int>[
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
];
