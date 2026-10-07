import 'package:sqflite_common/sqlite_api.dart';

/// What one queued row asks the server to do.
enum PendingOpType {
  create('create'),
  update('update'),
  delete('delete'),
  rename('rename'),

  /// §7.3 — the user picked a side or merged by hand.
  conflictResolve('conflict_resolve');

  const PendingOpType(this.wire);

  final String wire;

  static PendingOpType parse(String raw) => PendingOpType.values.firstWhere(
        (t) => t.wire == raw,
        orElse: () => PendingOpType.update,
      );
}

enum PendingOpState {
  pending('pending'),
  inFlight('in_flight'),
  done('done'),

  /// Out of retries. Never auto-cleared — §5.4 puts these in front of the user
  /// with retry / discard / open, because a silently abandoned upload looks
  /// identical to "this device is in sync".
  dead('dead');

  const PendingOpState(this.wire);

  final String wire;

  static PendingOpState parse(String raw) => PendingOpState.values.firstWhere(
        (s) => s.wire == raw,
        orElse: () => PendingOpState.pending,
      );
}

/// One queued operation.
class PendingOp {
  const PendingOp({
    required this.id,
    required this.syncRootId,
    required this.opType,
    required this.targetPath,
    this.prevPath,
    this.payload,
    this.payloadVersion = 1,
    this.state = PendingOpState.pending,
    this.lastError,
    this.retryCount = 0,
    this.nextAttemptAt = 0,
    required this.createdAt,
    required this.updatedAt,
  });

  final int id;
  final String syncRootId;
  final PendingOpType opType;

  /// Vault-relative POSIX path this op acts on.
  final String targetPath;

  /// Set for [PendingOpType.rename]: where the file came from.
  final String? prevPath;

  /// Opaque to the queue — it never inspects this, only carries it forward.
  final String? payload;
  final int payloadVersion;

  final PendingOpState state;
  final String? lastError;
  final int retryCount;
  final int nextAttemptAt;
  final int createdAt;
  final int updatedAt;

  Map<String, Object?> toMap() => {
        'id': id,
        'sync_root_id': syncRootId,
        'op_type': opType.wire,
        'target_path': targetPath,
        'prev_path': prevPath,
        'payload': payload,
        'payload_version': payloadVersion,
        'state': state.wire,
        'last_error': lastError,
        'retry_count': retryCount,
        'next_attempt_at': nextAttemptAt,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  static PendingOp fromRow(Map<String, Object?> row) => PendingOp(
        id: row['id']! as int,
        syncRootId: row['sync_root_id']! as String,
        opType: PendingOpType.parse(row['op_type']! as String),
        targetPath: row['target_path']! as String,
        prevPath: row['prev_path'] as String?,
        payload: row['payload'] as String?,
        payloadVersion: (row['payload_version'] as int?) ?? 1,
        state: PendingOpState.parse(row['state']! as String),
        lastError: row['last_error'] as String?,
        retryCount: (row['retry_count'] as int?) ?? 0,
        nextAttemptAt: (row['next_attempt_at'] as int?) ?? 0,
        createdAt: (row['created_at'] as int?) ?? 0,
        updatedAt: (row['updated_at'] as int?) ?? 0,
      );
}

/// The outcome of an enqueue, for logging and for the "pending operations"
/// settings list.
enum EnqueueOutcome {
  /// A brand new row.
  inserted,

  /// Folded into an existing row per one of the five merge rules.
  coalesced,

  /// Appended without merging, because order carries meaning.
  appended,
}

/// The offline operation queue of §5.4.
///
/// Its whole reason to exist is coalescing. A user who edits ten notes on the
/// train should produce one upload each, not one per keystroke-save, and the
/// merge rules are what stop the queue from growing without bound while
/// offline.
/// Takes a [DatabaseExecutor] rather than a `Database`: every method here is a
/// single statement, and coalescing must be evaluated inside whatever
/// transaction the caller already owns — merging outside it would let two
/// concurrent enqueues both read "no existing row" and both insert.
class PendingQueue {
  PendingQueue(DatabaseExecutor executor) : _root = executor;

  /// §5.4 — attempts before an op is parked as `dead`, not before it is
  /// abandoned. Named so nobody re-introduces the old `999` sentinel.
  static const int maxRetries = 3;

  final DatabaseExecutor _root;

  Future<EnqueueOutcome> enqueue({
    required String syncRootId,
    required PendingOpType opType,
    required String targetPath,
    String? prevPath,
    String? payload,
    required int now,
  }) async {
    final existing = await _pendingFor(syncRootId, targetPath);
    if (existing == null) {
      await _insert(
          syncRootId: syncRootId,
          opType: opType,
          targetPath: targetPath,
          prevPath: prevPath,
          payload: payload,
          now: now);
      return EnqueueOutcome.inserted;
    }

    final merged = _coalesce(existing, opType,
        prevPath: prevPath, payload: payload);
    if (merged == null) {
      // Order carries meaning, so this becomes a second row rather than a
      // rewrite of the first. Appending is not optional: dropping it here
      // would silently swallow every rename-then-edit.
      await _insert(
          syncRootId: syncRootId,
          opType: opType,
          targetPath: targetPath,
          prevPath: prevPath,
          payload: payload,
          now: now);
      return EnqueueOutcome.appended;
    }

    await _root.update(
      'pending_ops',
      {
        'op_type': merged.type.wire,
        'prev_path': merged.clearPrevPath ? null : merged.prevPath,
        'payload': merged.clearPayload ? null : merged.payload,
        'updated_at': now,
        // A new intent clears a parked failure: the user edited the file again,
        // so the previous error describes a version that no longer exists.
        'state': PendingOpState.pending.wire,
        'last_error': null,
        'retry_count': 0,
        'next_attempt_at': 0,
      },
      where: 'id = ?',
      whereArgs: [existing.id],
    );
    return EnqueueOutcome.coalesced;
  }

  Future<void> _insert({
    required String syncRootId,
    required PendingOpType opType,
    required String targetPath,
    required String? prevPath,
    required String? payload,
    required int now,
  }) =>
      _root.insert('pending_ops', {
        'sync_root_id': syncRootId,
        'op_type': opType.wire,
        'target_path': targetPath,
        'prev_path': prevPath,
        'payload': payload,
        'payload_version': 1,
        'state': PendingOpState.pending.wire,
        'retry_count': 0,
        'next_attempt_at': 0,
        'created_at': now,
        'updated_at': now,
      });

  /// The five rules of §5.4, in one pure function so they can be tested
  /// without a database and read as a table.
  ///
  /// Returns null to mean "append as a second row".
  static _Merge? _coalesce(
    PendingOp existing,
    PendingOpType incoming, {
    String? prevPath,
    String? payload,
  }) {
    switch (existing.opType) {
      // create + anything -> create. Nothing has reached the server yet, so
      // the upload only ever needs the latest bytes.
      case PendingOpType.create:
        if (incoming == PendingOpType.delete) {
          return const _Merge(PendingOpType.create, clearPayload: true);
        }
        return _Merge(PendingOpType.create,
            prevPath: existing.prevPath, payload: payload);

      // update + update -> one update.
      case PendingOpType.update:
        if (incoming == PendingOpType.update) {
          return _Merge(PendingOpType.update,
              prevPath: existing.prevPath, payload: payload);
        }
        // update then delete: uploading only to delete it again is wasted
        // traffic, and the delete alone reaches the same end state. The
        // payload goes too — nothing is going to be uploaded.
        if (incoming == PendingOpType.delete) {
          return const _Merge(PendingOpType.delete,
              clearPayload: true, clearPrevPath: true);
        }
        return null;

      // rename + rename -> one rename, retargeted from the *original* origin.
      case PendingOpType.rename:
        if (incoming == PendingOpType.rename) {
          return _Merge(PendingOpType.rename,
              prevPath: existing.prevPath, payload: existing.payload);
        }
        // rename then update stays two rows. Merging them would upload bytes
        // to a path the server has not been told about yet.
        return null;

      case PendingOpType.delete:
        // A delete is terminal: anything queued after it is about a file the
        // user already asked to remove. Still appended rather than dropped —
        // silently discarding an operation is never the queue's call.
        return null;

      case PendingOpType.conflictResolve:
        return null;
    }
  }

  Future<PendingOp?> _pendingFor(String syncRootId, String path) async {
    final rows = await _root.query(
      'pending_ops',
      where: "sync_root_id = ? AND target_path = ? AND state IN ('pending','in_flight')",
      whereArgs: [syncRootId, path],
      orderBy: 'id',
      limit: 1,
    );
    return rows.isEmpty ? null : PendingOp.fromRow(rows.first);
  }

  /// Replay order: `created_at`, then `id`. Deterministic ordering matters
  /// because a rename queued after an update only makes sense in one sequence.
  Future<List<PendingOp>> ready(String syncRootId, {required int now}) async {
    final rows = await _root.query(
      'pending_ops',
      where: "sync_root_id = ? AND state = 'pending' AND next_attempt_at <= ?",
      whereArgs: [syncRootId, now],
      orderBy: 'created_at ASC, id ASC',
    );
    return [for (final r in rows) PendingOp.fromRow(r)];
  }

  Future<void> markInFlight(int id, {required int now}) async {
    await _root.update(
      'pending_ops',
      {'state': PendingOpState.inFlight.wire, 'updated_at': now},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> markDone(int id, {required int now}) async {
    await _root.delete('pending_ops', where: 'id = ?', whereArgs: [id]);
  }

  /// Backs a failed op off and, past the limit, parks it for the user.
  ///
  /// Returns true when the op reached `dead`.
  Future<bool> markFailed(
    int id, {
    required String error,
    required int now,
    required int nextAttemptAt,
  }) async {
    final rows = await _root.query('pending_ops',
        columns: ['retry_count'], where: 'id = ?', whereArgs: [id], limit: 1);
    final retries = (rows.isEmpty ? 0 : rows.first['retry_count'] as int? ?? 0) + 1;
    final dead = retries > maxRetries;

    await _root.update(
      'pending_ops',
      {
        'state': (dead ? PendingOpState.dead : PendingOpState.pending).wire,
        'retry_count': retries,
        'last_error': error,
        'next_attempt_at': nextAttemptAt,
        'updated_at': now,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    return dead;
  }

  /// Puts a parked op back in line for the user's "retry" action.
  Future<void> revive(int id, {required int now}) async {
    await _root.update(
      'pending_ops',
      {
        'state': PendingOpState.pending.wire,
        'retry_count': 0,
        'last_error': null,
        'next_attempt_at': 0,
        'updated_at': now,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> discard(int id) =>
      _root.delete('pending_ops', where: 'id = ?', whereArgs: [id]);

  /// §5.4 — what the settings page lists for manual intervention.
  Future<List<PendingOp>> deadLetters(String syncRootId) async {
    final rows = await _root.query(
      'pending_ops',
      where: "sync_root_id = ? AND state = 'dead'",
      whereArgs: [syncRootId],
      orderBy: 'created_at ASC, id ASC',
    );
    return [for (final r in rows) PendingOp.fromRow(r)];
  }

  Future<int> countPending(String syncRootId) async {
    final rows = await _root.rawQuery(
      "SELECT COUNT(*) AS c FROM pending_ops "
      "WHERE sync_root_id = ? AND state IN ('pending','in_flight')",
      [syncRootId],
    );
    return (rows.first['c'] as int?) ?? 0;
  }
}

class _Merge {
  const _Merge(
    this.type, {
    this.prevPath,
    this.payload,
    this.clearPayload = false,
    this.clearPrevPath = false,
  });

  final PendingOpType type;
  final String? prevPath;
  final String? payload;

  /// A null column value is ambiguous between "leave it alone" and "empty it".
  /// These flags say which, so folding `update` into `delete` can actually
  /// drop the payload instead of silently uploading stale bytes.
  final bool clearPayload;
  final bool clearPrevPath;
}