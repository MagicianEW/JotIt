import 'package:sqflite_common/sqlite_api.dart';

/// One row of the derived `notes` index.
class NoteRecord {
  const NoteRecord({
    required this.uid,
    required this.path,
    this.title = '',
    this.body = '',
    this.contentHash,
    this.fileSize = 0,
    this.fileMtimeMs,
    required this.updatedAt,
    this.syncedAt,
    this.isDeleted = false,
    this.deletedAt,
  });

  /// Front-matter uid — the note's cross-device identity (ADR-2).
  final String uid;

  /// Vault-relative POSIX path. This, not [uid], is what travels over the wire.
  final String path;

  final String title;
  final String body;
  final String? contentHash;
  final int fileSize;
  final int? fileMtimeMs;
  final int updatedAt;
  final int? syncedAt;
  final bool isDeleted;
  final int? deletedAt;

  Map<String, Object?> toMap() => {
        'id': uid,
        'path': path,
        'title': title,
        'body': body,
        'content_hash': contentHash,
        'file_size': fileSize,
        'file_mtime_ms': fileMtimeMs,
        'updated_at': updatedAt,
        'synced_at': syncedAt,
        'is_deleted': isDeleted ? 1 : 0,
        'deleted_at': deletedAt,
      };

  static NoteRecord fromRow(Map<String, Object?> row) => NoteRecord(
        uid: row['id']! as String,
        path: row['path']! as String,
        title: (row['title'] as String?) ?? '',
        body: (row['body'] as String?) ?? '',
        contentHash: row['content_hash'] as String?,
        fileSize: (row['file_size'] as int?) ?? 0,
        fileMtimeMs: row['file_mtime_ms'] as int?,
        updatedAt: (row['updated_at'] as int?) ?? 0,
        syncedAt: row['synced_at'] as int?,
        isDeleted: (row['is_deleted'] as int? ?? 0) == 1,
        deletedAt: row['deleted_at'] as int?,
      );
}

/// Reads and writes the derived note index.
///
/// Constructed either around a [Database] (it opens its own short transaction
/// per write) or around a [DatabaseExecutor] that a caller already owns — a
/// `Transaction`, typically. The second form exists because reindexing touches
/// `notes`, `links`, `note_tags` and `attachments` together: committing some
/// without the others leaves an index describing a vault that does not exist,
/// which is worse than no index at all because it looks authoritative.
class NoteDao {
  NoteDao(Database db) : _db = db, _root = db;

  NoteDao.on(DatabaseExecutor executor) : _db = null, _root = executor;

  /// Non-null only when this DAO owns its transaction.
  final Database? _db;
  final DatabaseExecutor _root;

  /// Vault-relative paths of every attachment a note references.
  ///
  /// This is what §9.3 means by "an attachment": a file inside an
  /// `attachments/` directory that some note links to. A file sitting there
  /// with nothing pointing at it is deliberately not in this list, which is why
  /// the sync engine treats an unreferenced one as untouchable rather than as
  /// something to push or prune.
  ///
  /// Read rather than recomputed so the engine and the scanner cannot disagree
  /// about which files belong to the vault.
  Future<List<String>> attachmentPaths() async {
    final rows = await _root.query('attachments', columns: <String>['path']);
    return rows.map((r) => r['path']! as String).toList(growable: false);
  }

  /// Runs [action] inside a transaction on this DAO's connection.
  ///
  /// Only valid when this DAO owns the connection; a DAO built with
  /// [NoteDao.on] is already inside one and cannot start another.
  Future<void> runInTransaction(
          Future<void> Function(DatabaseExecutor txn) action) async {
    final db = _db;
    if (db == null) {
      throw StateError(
        'runInTransaction on a DAO that is already inside a transaction; '
        'call the action directly instead.',
      );
    }
    await db.transaction((Transaction txn) => action(txn));
  }

  /// Inserts or updates a note, replacing a stale row that occupied the same
  /// path under a different uid.
  ///
  /// 清理是对称的，两个方向都要处理，因为"身份"和"路径"各有一个唯一约束：
  ///
  ///  * 同 path 不同 uid —— 身份被换掉的旧行（先删，避免 UNIQUE(path) 打架）；
  ///  * 同 uid 不同 path —— 笔记被挪走了（另一设备改名后本机同步采纳，
  ///    或用户在文件管理器里移动）。这一方向更重要：索引里已有
  ///    `id=U, path=old.md`、文件已到 new.md 时，`INSERT OR IGNORE` 会因
  ///    主键冲突整行跳过，随后的 `UPDATE ... WHERE path = new.md` 影响 0 行
  ///    —— 新路径永远插不进去，旧行永存，而 purge 没有调用方，笔记就此在
  ///    应用内永久消失（重启也不会好，因为文件确实在，索引却指着旧路径）。
  Future<void> upsert(NoteRecord record) async {
    Future<void> body(DatabaseExecutor txn) async {
      // A note whose uid changed while keeping its path is a rename of
      // identity, not a new note. Drop the stale row first so the unique path
      // constraint does not fight the new one.
      await txn.delete('notes',
          where: 'path = ? AND id != ?', whereArgs: [record.path, record.uid]);

      // The mirror image: the same note (same uid) living at another path.
      // Without this the insert-ignore below swallows the new path forever.
      //
      // The row is *moved*, not deleted and re-created. A delete cascades
      // through `links`, `link_aliases` and `note_tags`, and the aliases are
      // the user's own disambiguation decisions — losing them because a file
      // was moved in the file manager is silent, permanent data loss. The
      // delete above has already freed this path, so the update cannot meet
      // the unique constraint.
      await txn.update('notes', {'path': record.path},
          where: 'id = ? AND path != ?', whereArgs: [record.uid, record.path]);

      // INSERT OR IGNORE + UPDATE rather than INSERT OR REPLACE: replace
      // deletes and re-inserts the row, which cascades through `links` and
      // fires a spurious FTS delete/insert pair.
      await txn.insert('notes', record.toMap(),
          conflictAlgorithm: ConflictAlgorithm.ignore);
      await txn.update('notes', record.toMap(),
          where: 'path = ?', whereArgs: [record.path]);
    }

    final db = _db;
    if (db == null) return body(_root);
    await db.transaction(body);
  }

  /// Moves the row of [uid] to [path].
  ///
  /// The identity stays; only the path changes. Nothing that references the
  /// note by id is touched, which is the whole point: a note that moved
  /// keeps its links, its tags and the disambiguations the user made for
  /// it.
  Future<void> moveTo({required String uid, required String path}) async {
    await _root.update('notes', {'path': path},
        where: 'id = ?', whereArgs: [uid]);
  }

  /// Leaves a tombstone at [path] for the note that used to live there.
  ///
  /// The tombstone is what tells the sync engine that this device no longer
  /// has a note at that path. Without it the engine reads the round as "the
  /// server has this file and this device does not", downloads the server's
  /// copy back over the new note, and the rename silently reverts — the note
  /// goes back to the content it had before the move, and the edited version
  /// is not visible in the app any more.
  ///
  /// The tombstone cannot carry the note's own uid: the live row already
  /// owns it, and `notes.id` is the primary key. It gets an id of its own
  /// instead. Because the row is soft-deleted it stays out of the note list,
  /// the link index, the alias table and the search results — it is a marker
  /// for the sync engine, not a note.
  Future<void> leaveTombstone({
    required String path,
    required String uid,
    required int at,
  }) async {
    await _root.insert(
      'notes',
      <String, Object?>{
        'id': 'moved:$uid@$path',
        'path': path,
        'title': '',
        'body': '',
        'content_hash': null,
        'file_size': 0,
        'file_mtime_ms': null,
        'updated_at': at,
        'synced_at': null,
        'is_deleted': 1,
        'deleted_at': at,
      },
      // Ignored rather than fatal: a tombstone is a marker, and a marker
      // that cannot be placed must not abort the reindex that placed it.
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<void> softDelete(String path, {required int at}) async {
    await _root.update(
      'notes',
      {'is_deleted': 1, 'deleted_at': at},
      where: 'path = ?',
      whereArgs: [path],
    );
  }

  Future<void> restore(String path) async {
    await _root.update(
      'notes',
      {'is_deleted': 0, 'deleted_at': null},
      where: 'path = ?',
      whereArgs: [path],
    );
  }

  Future<void> purge(String path) => _root.delete('notes',
      where: 'path = ?', whereArgs: [path]);

  Future<NoteRecord?> byPath(String path, {bool includeDeleted = false}) async {
    final rows = await _root.query(
      'notes',
      where: includeDeleted ? 'path = ?' : 'path = ? AND is_deleted = 0',
      whereArgs: [path],
      limit: 1,
    );
    return rows.isEmpty ? null : NoteRecord.fromRow(rows.first);
  }

  Future<NoteRecord?> byUid(String uid) async {
    final rows =
        await _root.query('notes', where: 'id = ?', whereArgs: [uid], limit: 1);
    return rows.isEmpty ? null : NoteRecord.fromRow(rows.first);
  }

  Future<List<NoteRecord>> allActive({int limit = 10000, int offset = 0}) async {
    final rows = await _root.query('notes',
        where: 'is_deleted = 0',
        orderBy: 'path',
        limit: limit,
        offset: offset);
    return [for (final r in rows) NoteRecord.fromRow(r)];
  }

  /// The path every indexed identity lives at, by uid.
  ///
  /// One query for the whole table. The reindex asks this for every note it
  /// is about to write, and asking one question per note turns a single scan
  /// into a thousand round trips.
  Future<Map<String, String>> pathsByUid() async {
    final rows = await _root.query('notes', columns: <String>['id', 'path']);
    return <String, String>{
      for (final r in rows) r['id']! as String: r['path']! as String,
    };
  }

  /// The active notes, with their bodies cut short.
  ///
  /// The shelf shows one line of each note, so the list needs a handful of
  /// characters of body and nothing more. Carrying the full text of 500
  /// notes across the platform channel to render 500 one-line excerpts is
  /// the kind of cost that shows up as a slow start, and the whole body is
  /// one query away for anything that really needs it.
  Future<List<NoteRecord>> allActiveExcerpts({
    int limit = 10000,
    int excerptChars = 200,
  }) async {
    final rows = await _root.rawQuery(
      'SELECT id, path, title, SUBSTR(body, 1, ?) AS body, content_hash, '
      'file_size, file_mtime_ms, updated_at, synced_at, is_deleted, '
      'deleted_at FROM notes WHERE is_deleted = 0 ORDER BY path LIMIT ?',
      <Object?>[excerptChars, limit],
    );
    return [for (final r in rows) NoteRecord.fromRow(r)];
  }

  Future<int> countActive() async {
    final rows = await _root
        .rawQuery('SELECT COUNT(*) AS c FROM notes WHERE is_deleted = 0');
    return (rows.first['c'] as int?) ?? 0;
  }
}