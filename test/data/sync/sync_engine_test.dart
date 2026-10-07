import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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

    engine = SyncEngine(
      dav: dav.client(),
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
      expect(failing.state, SyncState.backoff);

      await failing.recordFailure(
          syncRootId: rootId, nowMs: now, retryCount: 2, error: result.error!);

      final root = await roots.byId(rootId);
      expect(root!.nextAttemptAt, greaterThan(now));
      expect(root.lastError, isNotNull);
      expect(root.isReadyAt(now), isFalse,
          reason: 'a root still inside its backoff must refuse a fresh start');
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
  Future<List<int>?> get(String path) async {
    if (!_fired) {
      _fired = true;
      await onFirstGet();
    }
    return _inner.get(path);
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
  }) =>
      _inner.put(path, bytes, condition: condition);

  @override
  Future<bool> delete(String path, {String? ifMatch}) =>
      _inner.delete(path, ifMatch: ifMatch);

  @override
  Future<DavCapabilities> probe() => _inner.probe();

  @override
  Future<void> close() => _inner.close();
}

Future<List<int>?> _side(String vaultRoot, String dir, String name) async {
  final f = File(p.join(VaultPaths.conflictsRoot(vaultRoot), dir, name));
  return await f.exists() ? f.readAsBytes() : null;
}
