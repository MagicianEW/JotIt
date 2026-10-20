import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
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

  /// Opens the vault's database.
  ///
  /// [factory] overrides the SQLite implementation. Tests pass
  /// [testFactory] so the SQL runs on the calling isolate — see [testFactory]
  /// for why that matters.
  static Future<JotItDatabase> open({
    required String filePath,
    DatabaseFactory? factory,
  }) async {
    final db = await (factory ?? _factory()).openDatabase(
      filePath,
      options: OpenDatabaseOptions(
        singleInstance: true,
        onConfigure: (d) => applyPragmas(d),
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
        onConfigure: (d) => applyPragmas(d),
      ),
    );
    final instance = JotItDatabase._(db);
    await instance.ensureSchema();
    return instance;
  }

  /// Every platform gets the bundled FFI build.
  ///
  /// Android was the exception once, and it was the wrong exception: the
  /// system SQLite on a phone has no FTS5 module, and the vault's search
  /// table is built on it. The symptom was not a degraded search — it was a
  /// vault that would not open at all, because creating the table failed
  /// with "no such module: fts5" while the schema was being written.
  ///
  /// The bundled build is the one that has FTS5 and the trigram tokenizer
  /// (ADR-4), and it is now the same build on every platform — so a vault
  /// written on a phone is readable on a desktop, and the other way round.
  ///
  /// **The SQL runs on the calling isolate**, not on a background one. The
  /// isolate-based factory is a trap in a test: the app is driven by a
  /// harness whose fake async zone never lets that isolate's callbacks land,
  /// so the first `pump()` after the database is opened waits for a future
  /// that will not complete, and the test hangs instead of failing. Running
  /// the SQL inline is also simply faster for a local file — the whole point
  /// of the library is that it *is* SQLite, running it in-process.
  static DatabaseFactory _factory() {
    sqfliteFfiInit();
    return databaseFactoryFfiNoIsolate;
  }

  /// The factory the tests use, for the same reason as [_factory].
  static DatabaseFactory get testFactory {
    sqfliteFfiInit();
    return databaseFactoryFfiNoIsolate;
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

  /// Applies the pragmas the vault relies on.
  ///
  /// Two rules, both learned the hard way on a phone:
  ///
  ///  * `journal_mode` is the one pragma that *answers with a row*, and
  ///    Android's SQLite driver refuses to run a query through `execute` — it
  ///    throws "Queries can be performed using SQLiteDatabase query or
  ///    rawQuery methods only". Because this runs while the database is
  ///    opening, that one line does not merely lose WAL: the whole vault
  ///    fails to open and the app sits on a spinner forever. Ask for it the
  ///    way it has to be asked.
  ///  * None of these is worth failing an open over. They are tuning knobs
  ///    and safety belts, and a database that cannot be tuned is still a
  ///    database. A pragma that cannot be applied is reported and stepped
  ///    over, never allowed to take the vault down with it.
  @visibleForTesting
  static Future<void> applyPragmas(DatabaseExecutor db) async {
    // WAL survives across connections, so re-issuing it is harmless and makes
    // a freshly attached database behave the same as the first one.
    try {
      await db.rawQuery('PRAGMA journal_mode = WAL');
    } on Object catch (e) {
      _reportPragma('journal_mode = WAL', e);
    }

    // The rest answer with nothing, so `execute` is the right call for them.
    for (final String pragma in <String>[
      'PRAGMA synchronous = NORMAL',
      'PRAGMA foreign_keys = ON',
      'PRAGMA temp_store = MEMORY',
      'PRAGMA busy_timeout = $_busyTimeoutMs',
    ]) {
      try {
        await db.execute(pragma);
      } on Object catch (e) {
        _reportPragma(pragma, e);
      }
    }
  }

  /// Says out loud that a pragma did not take.
  ///
  /// Not swallowed: a database running without `foreign_keys` is still a
  /// database, but it is one whose guarantees differ, and whoever is looking
  /// at a bug report later needs to know that.
  static void _reportPragma(String pragma, Object error) {
    stderr.writeln('JotIt: could not apply "$pragma": $error');
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