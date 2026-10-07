import 'dart:io';

import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'schema.dart';

/// Opens and maintains the derived index for one vault (ADR-1).
///
/// The database is disposable: [rebuildFromNotes] must be able to repopulate
/// every table from the files on disk. Nothing in here is allowed to become
/// the only copy of anything.
class JotItDatabase {
  JotItDatabase._(this.db);

  /// Adopts an already-open handle. Lets tests exercise [ensureSchema]
  /// against the same connection the real code path builds.
  static JotItDatabase wrap(Database db) => JotItDatabase._(db);

  final Database db;

  static const int _busyTimeoutMs = 5000;

  /// Minimum SQLite version that ships the `trigram` tokenizer (ADR-4).
  static const String minimumSqliteVersion = '3.34.0';

  static Future<JotItDatabase> open({required String filePath}) async {
    final factory = _factory();
    final db = await factory.openDatabase(
      filePath,
      options: OpenDatabaseOptions(
        singleInstance: true,
        onConfigure: (d) => _applyPragmas(d),
      ),
    );
    final instance = JotItDatabase._(db);
    await instance.ensureSchema();
    return instance;
  }

  /// In-memory instance for tests. Pragmas still apply — `foreign_keys` in
  /// particular is exactly the setting v2.0 relied on without ever turning on,
  /// so a test that skipped it would not be testing the real configuration.
  static Future<JotItDatabase> openInMemory() async {
    _factory();
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        singleInstance: false,
        onConfigure: (d) => _applyPragmas(d),
      ),
    );
    final instance = JotItDatabase._(db);
    await instance.ensureSchema();
    return instance;
  }

  /// Desktop platforms get the bundled FFI build, which is the only way to
  /// guarantee the trigram tokenizer. Android's system SQLite has lagged far
  /// enough behind that relying on it would silently disable CJK search.
  static DatabaseFactory _factory() {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      return databaseFactoryFfi;
    }
    return sqflite.databaseFactory;
  }

  Future<void> close() => db.close();

  Future<String> sqliteVersion() async {
    final rows = await db.rawQuery('SELECT sqlite_version() AS v');
    return rows.first['v'] as String;
  }

  Future<int> schemaVersion() async {
    final rows = await db.rawQuery('PRAGMA user_version');
    return (rows.first.values.first as int?) ?? 0;
  }

  /// Throws with an actionable message rather than letting a missing trigram
  /// tokenizer surface later as "search returns nothing".
  Future<void> assertSearchCapabilities() async {
    final version = await sqliteVersion();
    if (_compareVersions(version, minimumSqliteVersion) < 0) {
      throw StateError(
        'SQLite $version is older than $minimumSqliteVersion, which is the '
        'first release with the trigram tokenizer (ADR-4). CJK search needs it. '
        'Use a build that bundles its own SQLite.',
      );
    }
    await db.rawQuery("SELECT 1 FROM notes_fts WHERE notes_fts MATCH 'x'");
  }

  static Future<void> _applyPragmas(DatabaseExecutor db) async {
    // WAL survives across connections, so re-issuing it is harmless and makes
    // a freshly attached database behave the same as the first one.
    await db.execute('PRAGMA journal_mode = WAL');
    await db.execute('PRAGMA synchronous = NORMAL');
    await db.execute('PRAGMA foreign_keys = ON');
    await db.execute('PRAGMA temp_store = MEMORY');
    await db.execute('PRAGMA busy_timeout = $_busyTimeoutMs');
  }

  Future<void> ensureSchema() async {
    var version = await schemaVersion();
    if (version > kSchemaVersion) {
      throw StateError(
        'this vault was written by a newer JotIt (schema v$version); '
        'refusing to downgrade',
      );
    }
    while (version < kSchemaVersion) {
      final step = migrationsFrom(version).first;
      // ADR-10: one transaction per migration, so a failure leaves the
      // database at the last good version instead of half-populated.
      await db.execute('BEGIN');
      try {
        step(db);
        version++;
        await db.execute('PRAGMA user_version = $version');
        await db.execute('COMMIT');
      } catch (_) {
        await db.execute('ROLLBACK');
        rethrow;
      }
    }
  }

  static int _compareVersions(String a, String b) {
    final pa = a.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    final pb = b.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    for (var i = 0; i < 3; i++) {
      final d = (i < pa.length ? pa[i] : 0) - (i < pb.length ? pb[i] : 0);
      if (d != 0) return d;
    }
    return 0;
  }
}