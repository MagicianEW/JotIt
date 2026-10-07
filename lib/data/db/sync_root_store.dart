import 'dart:convert';

import 'package:sqflite_common/sqlite_api.dart';

import '../../domain/sync/sync_session.dart';

/// One configured remote (v3.0 §3.2 `sync_roots`).
class SyncRootRecord {
  const SyncRootRecord({
    required this.id,
    required this.name,
    required this.baseUrl,
    this.collectionCtag,
    this.username,
    this.capabilities = const <String, Object?>{},
    this.enabled = true,
    this.lastSyncAt,
    this.nextAttemptAt = 0,
    this.lastError,
  });

  final String id;
  final String name;
  final String baseUrl;

  /// Collection-level change token from the last successful round. Kept apart
  /// from the per-path `sync_meta` rows on purpose — one CTag covers the whole
  /// collection, and mixing the two is how a partial listing ends up looking
  /// like a complete one.
  final String? collectionCtag;

  final String? username;

  /// Persisted capability negotiation result (§6.2). Survives a restart so the
  /// engine stops asking a Synology box for a CTag it will never send.
  final Map<String, Object?> capabilities;

  final bool enabled;
  final int? lastSyncAt;

  /// Epoch ms. A session that is still inside its backoff window must not be
  /// started by a fresh trigger.
  final int nextAttemptAt;

  final String? lastError;

  bool isReadyAt(int nowMs) => enabled && nextAttemptAt <= nowMs;

  static SyncRootRecord fromRow(Map<String, Object?> row) => SyncRootRecord(
        id: row['id']! as String,
        name: row['name'] as String,
        baseUrl: row['base_url'] as String,
        collectionCtag: row['collection_ctag'] as String?,
        username: row['username'] as String?,
        enabled: (row['enabled'] as int? ?? 1) == 1,
        lastSyncAt: row['last_sync_at'] as int?,
        nextAttemptAt: (row['next_attempt_at'] as int?) ?? 0,
        lastError: row['last_error'] as String?,
      );
}

/// Reads and writes `sync_roots`.
///
/// The backoff deadline is the reason this is not just a config table: §5.2
/// requires `next_attempt_at` to survive a restart, because a process that
/// dies mid-backoff and comes back immediately will hammer a server that is
/// already refusing it.
class SyncRootStore {
  SyncRootStore(DatabaseExecutor executor) : _root = executor;

  final DatabaseExecutor _root;

  Future<SyncRootRecord?> byId(String id) async {
    final rows = await _root
        .query('sync_roots', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : SyncRootRecord.fromRow(rows.first);
  }

  Future<List<SyncRootRecord>> enabled() async {
    final rows = await _root.query(
      'sync_roots',
      where: 'enabled = 1',
      orderBy: 'created_at',
    );
    return [for (final r in rows) SyncRootRecord.fromRow(r)];
  }

  Future<void> upsert(SyncRootRecord record) => _root.insert(
        'sync_roots',
        {
          'id': record.id,
          'name': record.name,
          'base_url': record.baseUrl,
          'collection_ctag': record.collectionCtag,
          'username': record.username,
          'capabilities': _encodeCapabilities(record.capabilities),
          'enabled': record.enabled ? 1 : 0,
          'last_sync_at': record.lastSyncAt,
          'next_attempt_at': record.nextAttemptAt,
          'last_error': record.lastError,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  /// Stores the CTag from a completed round. Only written when the server
  /// actually sent one — overwriting a good token with null would silently
  /// downgrade the next round to a full walk.
  Future<void> saveCollectionCtag(String id, String? ctag) async {
    if (ctag == null) return;
    await _root.update('sync_roots', {'collection_ctag': ctag},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> saveCapabilities(String id, Map<String, Object?> caps) =>
      _root.update('sync_roots', {'capabilities': _encodeCapabilities(caps)},
          where: 'id = ?', whereArgs: [id]);

  /// Clears the backoff after a good round so the next trigger is immediate.
  Future<void> markSuccess(String id, int nowMs) => _root.update(
        'sync_roots',
        {'last_sync_at': nowMs, 'next_attempt_at': 0, 'last_error': null},
        where: 'id = ?',
        whereArgs: [id],
      );

  /// Arms the next attempt. The window is computed by [SyncBackoff] so the
  /// formula lives in exactly one place.
  Future<void> markFailure({
    required String id,
    required int nowMs,
    required int retryCount,
    required String error,
    required double jitterFactor,
  }) =>
      _root.update(
        'sync_roots',
        {
          'last_error': error,
          'next_attempt_at':
              SyncBackoff.nextAttemptAt(nowMs, retryCount, jitterFactor: jitterFactor),
        },
        where: 'id = ?',
        whereArgs: [id],
      );

  static String _encodeCapabilities(Map<String, Object?> caps) =>
      caps.isEmpty ? '{}' : jsonEncode(caps);
}