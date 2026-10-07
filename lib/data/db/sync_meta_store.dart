import 'package:sqflite_common/sqlite_api.dart';

/// How a path stands relative to the last common ancestor with the server.
enum ConflictState {
  none('none'),
  localWins('local_wins'),
  remoteWins('remote_wins'),

  /// Both sides changed and diverged. The copies are on disk; the user has
  /// not chosen yet.
  conflict('conflict'),

  /// The copies were written but could not be applied (read-only mount, for
  /// example). Never silently cleared.
  pendingResolution('pending_resolution');

  const ConflictState(this.wire);

  final String wire;

  static ConflictState parse(String? raw) => ConflictState.values.firstWhere(
        (s) => s.wire == raw,
        orElse: () => ConflictState.none,
      );

  bool get isUnresolved =>
      this == ConflictState.conflict || this == ConflictState.pendingResolution;
}

/// One row of `sync_meta`: what the server looked like the last time the two
/// sides agreed.
///
/// This row *is* the merge base from §5.3. Without it, "only the local side
/// changed" and "both sides changed" are the same shape in the schema, which
/// is exactly why v2.0 could not detect conflicts.
class SyncMetaRecord {
  const SyncMetaRecord({
    required this.syncRootId,
    required this.path,
    this.uid,
    this.baseEtag,
    this.baseContentHash,
    this.basePath,
    this.lastSyncedAt,
    this.conflictState = ConflictState.none,
    this.conflictCopyDir,
  });

  final String syncRootId;

  /// Vault-relative POSIX path. The transport-layer identity (ADR/C2).
  final String path;

  /// Front-matter uid as of the last sync. The logical-layer identity.
  final String? uid;

  /// Opaque ETag token, stored and returned verbatim.
  ///
  /// Never parsed, never reformatted, never re-quoted. Its only operation is
  /// string equality against a token the same server produced. A build that
  /// "normalises" it will produce conditional requests the server rejects.
  final String? baseEtag;

  /// SHA-256 of the note's bytes at the last sync.
  final String? baseContentHash;

  /// Where the file lived at the last sync, when it no longer lives there.
  /// A remote rename is detected by uid, not by path (matrix row 3).
  final String? basePath;

  final int? lastSyncedAt;
  final ConflictState conflictState;

  /// Directory under `_conflicts/` holding `local.md` / `remote.md`.
  final String? conflictCopyDir;

  SyncMetaRecord copyWith({
    String? uid,
    String? baseEtag,
    String? baseContentHash,
    String? basePath,
    int? lastSyncedAt,
    ConflictState? conflictState,
    String? conflictCopyDir,
  }) =>
      SyncMetaRecord(
        syncRootId: syncRootId,
        path: path,
        uid: uid ?? this.uid,
        baseEtag: baseEtag ?? this.baseEtag,
        baseContentHash: baseContentHash ?? this.baseContentHash,
        basePath: basePath ?? this.basePath,
        lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
        conflictState: conflictState ?? this.conflictState,
        conflictCopyDir: conflictCopyDir ?? this.conflictCopyDir,
      );

  Map<String, Object?> toMap() => {
        'sync_root_id': syncRootId,
        'path': path,
        'uid': uid,
        'base_etag': baseEtag,
        'base_content_hash': baseContentHash,
        'base_path': basePath,
        'last_synced_at': lastSyncedAt,
        'conflict_state': conflictState.wire,
        'conflict_copy_dir': conflictCopyDir,
      };

  static SyncMetaRecord fromRow(Map<String, Object?> row) => SyncMetaRecord(
        syncRootId: row['sync_root_id']! as String,
        path: row['path']! as String,
        uid: row['uid'] as String?,
        baseEtag: row['base_etag'] as String?,
        baseContentHash: row['base_content_hash'] as String?,
        basePath: row['base_path'] as String?,
        lastSyncedAt: row['last_synced_at'] as int?,
        conflictState: ConflictState.parse(row['conflict_state'] as String?),
        conflictCopyDir: row['conflict_copy_dir'] as String?,
      );
}

/// Reads and writes the merge base, per sync root and path.
///
/// Takes a [DatabaseExecutor] rather than a `Database`: every method here is a
/// single statement, so the caller decides the transaction scope. Matrix rows 6
/// and 9 need the file write and the base update inside one transaction, and
/// that transaction belongs to the engine — a DAO opening its own would split
/// exactly the write that must not be split.
class SyncMetaStore {
  SyncMetaStore(DatabaseExecutor executor) : _root = executor;

  final DatabaseExecutor _root;

  Future<SyncMetaRecord?> byPath(String syncRootId, String path) async {
    final rows = await _root.query(
      'sync_meta',
      where: 'sync_root_id = ? AND path = ?',
      whereArgs: [syncRootId, path],
      limit: 1,
    );
    return rows.isEmpty ? null : SyncMetaRecord.fromRow(rows.first);
  }

  /// Looked up by uid to detect a rename (§5.1). Excludes rows already moved
  /// elsewhere, so two renames in one batch cannot chase each other.
  Future<SyncMetaRecord?> byUid(
    String syncRootId,
    String uid, {
    String? excludingPath,
  }) async {
    final rows = await _root.query(
      'sync_meta',
      where: excludingPath == null
          ? 'sync_root_id = ? AND uid = ?'
          : 'sync_root_id = ? AND uid = ? AND path != ?',
      whereArgs: excludingPath == null
          ? [syncRootId, uid]
          : [syncRootId, uid, excludingPath],
      limit: 1,
    );
    return rows.isEmpty ? null : SyncMetaRecord.fromRow(rows.first);
  }

  Future<List<SyncMetaRecord>> allForRoot(String syncRootId) async {
    final rows = await _root.query(
      'sync_meta',
      where: 'sync_root_id = ?',
      whereArgs: [syncRootId],
      orderBy: 'path',
    );
    return [for (final r in rows) SyncMetaRecord.fromRow(r)];
  }

  Future<void> upsert(SyncMetaRecord record) async {
    final map = record.toMap();
    await _root.insert('sync_meta', map,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Moves the base forward after a successful exchange in either direction.
  ///
  /// [basePath] is written only when the file has moved; [baseEtag] is stored
  /// exactly as the server reported it.
  Future<void> commitBase({
    required String syncRootId,
    required String path,
    required String? uid,
    required String? baseEtag,
    required String? baseContentHash,
    int? at,
    String? basePath,
  }) async {
    final map = <String, Object?>{
      'sync_root_id': syncRootId,
      'path': path,
      'uid': uid,
      'base_etag': baseEtag,
      'base_content_hash': baseContentHash,
      'last_synced_at': at,
      'conflict_state': ConflictState.none.wire,
    };
    if (basePath != null) map['base_path'] = basePath;
    await _root.insert('sync_meta', map,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Records that copies were written and the user still has to choose.
  Future<void> markConflict({
    required String syncRootId,
    required String path,
    required ConflictState state,
    required String copyDir,
    int? at,
  }) async {
    await _root.update(
      'sync_meta',
      {
        'conflict_state': state.wire,
        'conflict_copy_dir': copyDir,
        'last_synced_at': at,
      },
      where: 'sync_root_id = ? AND path = ?',
      whereArgs: [syncRootId, path],
    );
  }

  /// Clears the conflict flag after §7.3 resolution. The base is *not* moved
  /// here — the resolution writes one file, and the next pass reconciles it.
  Future<void> clearConflict(String syncRootId, String path) async {
    await _root.update(
      'sync_meta',
      {'conflict_state': ConflictState.none.wire, 'conflict_copy_dir': null},
      where: 'sync_root_id = ? AND path = ?',
      whereArgs: [syncRootId, path],
    );
  }

  Future<void> remove(String syncRootId, String path) async {
    await _root.delete('sync_meta',
        where: 'sync_root_id = ? AND path = ?', whereArgs: [syncRootId, path]);
  }

  /// Paths still awaiting a decision (§7.3). Surfaced in Settings.
  Future<List<SyncMetaRecord>> unresolved(String syncRootId) async {
    final rows = await _root.query(
      'sync_meta',
      where: "sync_root_id = ? AND conflict_state IN ('conflict','pending_resolution')",
      whereArgs: [syncRootId],
      orderBy: 'path',
    );
    return [for (final r in rows) SyncMetaRecord.fromRow(r)];
  }
}