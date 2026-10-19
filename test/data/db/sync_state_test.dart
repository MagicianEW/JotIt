import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/data/db/jotit_database.dart';
import 'package:jotit/data/db/pending_queue.dart';
import 'package:jotit/data/db/sync_meta_store.dart';
import 'package:sqflite_common/sqlite_api.dart';

void main() {
  late JotItDatabase jdb;
  late Database db;

  setUp(() async {
    jdb = await JotItDatabase.openInMemory();
    db = jdb.db;
  });

  tearDown(() async => jdb.close());

  // `sync_meta.sync_root_id` and `pending_ops.sync_root_id` are real foreign
  // keys. A test that invents a root id without registering it proves nothing
  // — every write fails on the constraint instead of on the behaviour.
  Future<void> seedRoot(String id) => db.insert('sync_roots', {
        'id': id,
        'name': id,
        'base_url': 'http://example.invalid/dav/',
        'capabilities': '{}',
      });

  group('SyncMetaStore', () {
    late SyncMetaStore store;
    const root = 'root-1';

    setUp(() async {
      await seedRoot(root);
      await seedRoot('root-2');
      store = SyncMetaStore(db);
    });

    Future<SyncMetaRecord> seed(String path,
            {String? uid, String? etag, String? hash}) async =>
        SyncMetaRecord(
          syncRootId: root,
          path: path,
          uid: uid,
          baseEtag: etag,
          baseContentHash: hash,
        );

    test('round-trips a merge base', () async {
      await store.upsert(await seed('notes/a.md',
          uid: 'u1', etag: '"abc"', hash: 'h1'));
      final got = await store.byPath(root, 'notes/a.md');
      expect(got!.uid, 'u1');
      expect(got.baseEtag, '"abc"');
      expect(got.baseContentHash, 'h1');
      expect(got.conflictState, ConflictState.none);
    });

    test('an ETag is stored and returned byte-for-byte', () async {
      // The token is opaque. A build that trims quotes, lower-cases, or
      // re-wraps it produces conditional requests the server rejects.
      const exotic = 'W/"3d1f-65a9b2c4d5e6",  "spaced"  ';
      await store.upsert(await seed('notes/a.md', etag: exotic));
      expect((await store.byPath(root, 'notes/a.md'))!.baseEtag, exotic);
    });

    test('roots are isolated from each other', () async {
      await store.upsert(await seed('notes/a.md', etag: 'r1'));
      await SyncMetaStore(db).upsert(SyncMetaRecord(
        syncRootId: 'root-2',
        path: 'notes/a.md',
        baseEtag: 'r2',
      ));
      expect((await store.byPath(root, 'notes/a.md'))!.baseEtag, 'r1');
      expect((await store.byPath('root-2', 'notes/a.md'))!.baseEtag, 'r2');
    });

    test('commitBase moves the base and clears any conflict', () async {
      await store.upsert(await seed('notes/a.md', etag: '"old"'));
      await store.markConflict(
        syncRootId: root,
        path: 'notes/a.md',
        state: ConflictState.pendingResolution,
        copyDir: '_conflicts/20261007-101500-1-a',
        at: 1,
      );

      await store.commitBase(
        syncRootId: root,
        path: 'notes/a.md',
        uid: 'u1',
        baseEtag: '"new"',
        baseContentHash: 'h2',
        at: 99,
      );

      final got = await store.byPath(root, 'notes/a.md');
      expect(got!.baseEtag, '"new"');
      expect(got.conflictState, ConflictState.none);
      expect(got.lastSyncedAt, 99);
    });

    test('commitBase leaves base_path alone unless a move is given', () async {
      await store.upsert(await seed('notes/a.md', etag: '"e"'));
      await store.commitBase(
          syncRootId: root,
          path: 'notes/a.md',
          uid: 'u1',
          baseEtag: '"e2"',
          baseContentHash: 'h',
          at: 1);
      expect((await store.byPath(root, 'notes/a.md'))!.basePath, isNull);

      await store.commitBase(
          syncRootId: root,
          path: 'notes/b.md',
          uid: 'u2',
          baseEtag: '"e3"',
          baseContentHash: 'h3',
          at: 2,
          basePath: 'notes/a.md');
      expect((await store.byPath(root, 'notes/b.md'))!.basePath, 'notes/a.md');
    });

    test('byUid finds a renamed note, which is how row 3 is detected', () async {
      await store.upsert(await seed('notes/old.md', uid: 'u1'));
      expect((await store.byUid(root, 'u1'))!.path, 'notes/old.md');
      expect(await store.byUid(root, 'nope'), isNull);
    });

    test('byUid can exclude the path being examined', () async {
      await store.upsert(await seed('notes/a.md', uid: 'u1'));
      expect(await store.byUid(root, 'u1', excludingPath: 'notes/a.md'), isNull);
    });

    test('unresolved lists only paths awaiting a decision', () async {
      await store.upsert(await seed('notes/a.md'));
      await store.upsert(await seed('notes/b.md'));
      await store.upsert(await seed('notes/c.md'));
      await store.markConflict(
          syncRootId: root,
          path: 'notes/b.md',
          state: ConflictState.conflict,
          copyDir: 'd1');
      await store.markConflict(
          syncRootId: root,
          path: 'notes/c.md',
          state: ConflictState.pendingResolution,
          copyDir: 'd2');

      final open = await store.unresolved(root);
      expect(open.map((r) => r.path), ['notes/b.md', 'notes/c.md']);
      expect(open.every((r) => r.conflictState.isUnresolved), isTrue);
    });

    test('markConflict records a conflict even with no base row', () async {
      // P1-4a: 纯 UPDATE 对从未同步过的路径影响 0 行 —— 冲突副本落了盘、
      // DB 无记录，Settings 的"需要关注"永远看不到这个冲突。
      await store.markConflict(
        syncRootId: root,
        path: 'notes/never-synced.md',
        state: ConflictState.conflict,
        copyDir: '_conflicts/20261007-101500-1-never',
        at: 42,
      );

      final got = await store.byPath(root, 'notes/never-synced.md');
      expect(got, isNotNull);
      expect(got!.conflictState, ConflictState.conflict);
      expect(got.conflictCopyDir, '_conflicts/20261007-101500-1-never');
      expect(got.lastSyncedAt, 42);
      expect((await store.unresolved(root)).single.path,
          'notes/never-synced.md');
    });

    test('markConflict updates an existing row without touching the base',
        () async {
      await store.upsert(await seed('notes/a.md',
          uid: 'u1', etag: '"e"', hash: 'h'));
      await store.markConflict(
        syncRootId: root,
        path: 'notes/a.md',
        state: ConflictState.pendingResolution,
        copyDir: 'd1',
        at: 7,
      );

      final got = await store.byPath(root, 'notes/a.md');
      expect(got!.conflictState, ConflictState.pendingResolution);
      expect(got.conflictCopyDir, 'd1');
      expect(got.lastSyncedAt, 7);
      expect(got.uid, 'u1',
          reason: 'the conflict write must not rewrite the note identity');
      expect(got.baseEtag, '"e"');
      expect(got.baseContentHash, 'h');
    });

    test('an unknown conflict_state string degrades to none', () async {
      // A row written by a newer build must not crash an older one.
      expect(ConflictState.parse('something_new'), ConflictState.none);
      expect(ConflictState.parse(null), ConflictState.none);
    });

    test('remove drops the base entirely', () async {
      await store.upsert(await seed('notes/a.md'));
      await store.remove(root, 'notes/a.md');
      expect(await store.byPath(root, 'notes/a.md'), isNull);
    });

    test('SyncMetaStore.on joins a caller-owned transaction', () async {
      await db.transaction((txn) async {
        await SyncMetaStore(txn)
            .upsert(await seed('notes/tx.md', uid: 'u9'));
      });
      expect((await store.byPath(root, 'notes/tx.md'))!.uid, 'u9');
    });
  });

  group('PendingQueue coalescing (§5.4)', () {
    late PendingQueue q;
    const root = 'root-1';

    setUp(() async {
      await seedRoot(root);
      await seedRoot('root-2');
      q = PendingQueue(db);
    });

    Future<void> add(PendingOpType t, String path,
            {String? payload, String? prevPath}) =>
        q.enqueue(
          syncRootId: root,
          opType: t,
          targetPath: path,
          prevPath: prevPath,
          payload: payload,
          now: 1000,
        );

    Future<List<PendingOp>> all() => q.ready(root, now: 999999);

    test('create then anything folds into create', () async {
      await add(PendingOpType.create, 'notes/a.md', payload: 'v1');
      await add(PendingOpType.update, 'notes/a.md', payload: 'v2');
      await add(PendingOpType.rename, 'notes/a.md', payload: 'v3');

      final ops = await all();
      expect(ops.length, 1);
      expect(ops.single.opType, PendingOpType.create);
      expect(ops.single.payload, 'v3');
    });

    test('create then delete drops the payload but stays a create', () async {
      // Nothing reached the server, so there is nothing to delete remotely.
      await add(PendingOpType.create, 'notes/a.md', payload: 'v1');
      await add(PendingOpType.delete, 'notes/a.md');

      final ops = await all();
      expect(ops.length, 1);
      expect(ops.single.opType, PendingOpType.create);
      expect(ops.single.payload, isNull);
    });

    test('update + update collapses to one', () async {
      await add(PendingOpType.update, 'notes/a.md', payload: 'v1');
      await add(PendingOpType.update, 'notes/a.md', payload: 'v2');

      final ops = await all();
      expect(ops.length, 1);
      expect(ops.single.opType, PendingOpType.update);
      expect(ops.single.payload, 'v2');
    });

    test('update then delete collapses to a bare delete', () async {
      // Uploading only to delete it again is wasted traffic.
      await add(PendingOpType.update, 'notes/a.md', payload: 'v1');
      await add(PendingOpType.delete, 'notes/a.md');

      final ops = await all();
      expect(ops.length, 1);
      expect(ops.single.opType, PendingOpType.delete);
      expect(ops.single.payload, isNull);
    });

    test('rename + rename collapses to one rename from the original origin',
        () async {
      await add(PendingOpType.rename, 'notes/c.md', prevPath: 'notes/a.md');
      await add(PendingOpType.rename, 'notes/c.md', prevPath: 'notes/b.md');

      final ops = await all();
      expect(ops.length, 1);
      expect(ops.single.opType, PendingOpType.rename);
      expect(ops.single.prevPath, 'notes/a.md',
          reason: 'the server only ever saw notes/a.md');
      expect(ops.single.targetPath, 'notes/c.md');
    });

    test('rename + update stays two rows, in order', () async {
      await add(PendingOpType.rename, 'notes/b.md', prevPath: 'notes/a.md');
      await add(PendingOpType.update, 'notes/b.md', payload: 'v1');

      final ops = await all();
      expect(ops.length, 2);
      expect(ops[0].opType, PendingOpType.rename);
      expect(ops[1].opType, PendingOpType.update);
      expect(ops[0].id < ops[1].id, isTrue,
          reason: 'replay order is creation order');
    });

    test('a delete is terminal', () async {
      await add(PendingOpType.delete, 'notes/a.md');
      await add(PendingOpType.create, 'notes/a.md', payload: 'x');

      final ops = await all();
      expect(ops.length, 2,
          reason: 'the create is a different intent and gets its own row');
      expect(ops.first.opType, PendingOpType.delete);
    });

    test('different paths never merge', () async {
      await add(PendingOpType.update, 'notes/a.md', payload: '1');
      await add(PendingOpType.update, 'notes/b.md', payload: '2');
      expect((await all()).length, 2);
    });

    test('different roots never merge', () async {
      await q.enqueue(
          syncRootId: 'root-1',
          opType: PendingOpType.update,
          targetPath: 'notes/a.md',
          payload: '1',
          now: 1);
      await q.enqueue(
          syncRootId: 'root-2',
          opType: PendingOpType.update,
          targetPath: 'notes/a.md',
          payload: '2',
          now: 1);
      expect((await q.ready('root-1', now: 99)).length, 1);
      expect((await q.ready('root-2', now: 99)).length, 1);
    });

    test('an edit after a parked failure clears the error', () async {
      await add(PendingOpType.update, 'notes/a.md', payload: 'v1');
      final op = (await all()).single;
      await q.markFailed(op.id, error: 'boom', now: 1, nextAttemptAt: 5);
      expect((await q.deadLetters(root)), isEmpty);

      await add(PendingOpType.update, 'notes/a.md', payload: 'v2');
      final revived = (await all()).single;
      expect(revived.retryCount, 0);
      expect(revived.lastError, isNull);
    });
  });

  group('PendingQueue retry policy', () {
    late PendingQueue q;
    const root = 'root-1';

    setUp(() async {
      await seedRoot(root);
      await seedRoot('root-2');
      q = PendingQueue(db);
    });

    Future<int> enqueueOne() async {
      await q.enqueue(
          syncRootId: root,
          opType: PendingOpType.update,
          targetPath: 'notes/a.md',
          payload: 'v1',
          now: 1000);
      return (await q.ready(root, now: 999999)).single.id;
    }

    test('an op is parked as dead only after the limit is exceeded', () async {
      final id = await enqueueOne();

      for (var attempt = 1; attempt <= PendingQueue.maxRetries; attempt++) {
        final dead = await q.markFailed(id,
            error: 'boom $attempt', now: 1, nextAttemptAt: 2);
        expect(dead, isFalse, reason: 'attempt $attempt is still retryable');
      }
      final dead = await q.markFailed(id, error: 'final', now: 1, nextAttemptAt: 2);
      expect(dead, isTrue);
    });

    test('a dead op is never returned for replay', () async {
      final id = await enqueueOne();
      for (var i = 0; i <= PendingQueue.maxRetries; i++) {
        await q.markFailed(id, error: 'boom', now: 1, nextAttemptAt: 0);
      }
      expect(await q.ready(root, now: 999999), isEmpty);
      expect((await q.deadLetters(root)).single.id, id);
      expect((await q.deadLetters(root)).single.lastError, 'boom');
    });

    test('revive puts a dead op back in line with a clean slate', () async {
      final id = await enqueueOne();
      for (var i = 0; i <= PendingQueue.maxRetries; i++) {
        await q.markFailed(id, error: 'boom', now: 1, nextAttemptAt: 0);
      }
      await q.revive(id, now: 5);

      final ready = await q.ready(root, now: 999999);
      expect(ready.single.retryCount, 0);
      expect(ready.single.lastError, isNull);
      expect(await q.deadLetters(root), isEmpty);
    });

    test('backoff keeps an op out of the ready set until it is due', () async {
      await q.enqueue(
          syncRootId: root,
          opType: PendingOpType.update,
          targetPath: 'notes/a.md',
          payload: 'v1',
          now: 1000);
      final id = (await q.ready(root, now: 999999)).single.id;
      await q.markFailed(id, error: 'boom', now: 1, nextAttemptAt: 5000);

      expect(await q.ready(root, now: 4999), isEmpty);
      expect((await q.ready(root, now: 5000)).single.id, id);
    });

    test('markDone removes the row', () async {
      final id = await enqueueOne();
      await q.markDone(id, now: 1);
      expect(await q.ready(root, now: 999999), isEmpty);
      expect(await q.countPending(root), 0);
    });

    test('an in-flight op is not handed out a second time', () async {
      final id = await enqueueOne();
      await q.markInFlight(id, now: 1);
      expect(await q.ready(root, now: 999999), isEmpty);
      expect(await q.countPending(root), 1,
          reason: 'still pending work, just not replayable right now');
    });

    test('countPending covers in-flight but not dead', () async {
      final id = await enqueueOne();
      await q.markInFlight(id, now: 1);
      expect(await q.countPending(root), 1);
      for (var i = 0; i <= PendingQueue.maxRetries; i++) {
        await q.markFailed(id, error: 'x', now: 1, nextAttemptAt: 0);
      }
      expect(await q.countPending(root), 0);
    });
  });

  group('row mapping', () {
    test('an op survives a database round trip', () async {
      await seedRoot('r');
      final q = PendingQueue(db);
      await q.enqueue(
        syncRootId: 'r',
        opType: PendingOpType.rename,
        targetPath: 'notes/b.md',
        prevPath: 'notes/a.md',
        payload: jsonEncode({'k': 'v'}),
        now: 7,
      );
      final op = (await q.ready('r', now: 99)).single;
      expect(op.opType, PendingOpType.rename);
      expect(op.prevPath, 'notes/a.md');
      expect(jsonDecode(op.payload!)['k'], 'v');
      expect(op.createdAt, 7);
    });

    test('unknown wire values fall back instead of throwing', () async {
      expect(PendingOpType.parse('create'), PendingOpType.create);
      expect(PendingOpType.parse('bogus'), PendingOpType.update);
      expect(PendingOpState.parse('pending'), PendingOpState.pending);
      expect(PendingOpState.parse('bogus'), PendingOpState.pending);
    });
  });
}