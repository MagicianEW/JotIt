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
  Future<void> upsert(NoteRecord record) async {
    Future<void> body(DatabaseExecutor txn) async {
      // A note whose uid changed while keeping its path is a rename of
      // identity, not a new note. Drop the stale row first so the unique path
      // constraint does not fight the new one.
      final existing = await txn.query(
        'notes',
        columns: ['id'],
        where: 'path = ?',
        whereArgs: [record.path],
        limit: 1,
      );
      if (existing.isNotEmpty && existing.first['id'] != record.uid) {
        await txn.delete('notes', where: 'path = ?', whereArgs: [record.path]);
      }

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

  Future<int> countActive() async {
    final rows = await _root
        .rawQuery('SELECT COUNT(*) AS c FROM notes WHERE is_deleted = 0');
    return (rows.first['c'] as int?) ?? 0;
  }
}