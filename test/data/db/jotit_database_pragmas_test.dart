import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/data/db/jotit_database.dart';
import 'package:sqflite_common/sqlite_api.dart';

/// The pragmas the vault applies when it opens.
///
/// These two tests exist because of a bug that only a phone could show: on
/// Android, `PRAGMA journal_mode = WAL` answers with a row, and Android's
/// SQLite driver refuses to run a query through `execute`. The pragma ran
/// while the database was opening, so the whole vault failed to open and the
/// app sat on a spinner forever — on a platform nobody was testing on.
///
/// A desktop SQLite happily accepts the same line, which is exactly why the
/// bug survived every other test.
class _RecordingExecutor implements DatabaseExecutor {
  final List<String> executed = <String>[];
  final List<String> rawQueries = <String>[];

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) async {
    executed.add(sql);
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) async {
    rawQueries.add(sql);
    return <Map<String, Object?>>[];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// An executor that behaves the way Android's SQLite driver does: a pragma
/// that answers with a row is refused when it arrives as a command.
class _AndroidLikeExecutor implements DatabaseExecutor {
  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) async {
    if (sql.toLowerCase().contains('journal_mode')) {
      throw StateError(
        'Queries can be performed using SQLiteDatabase query or rawQuery '
        'methods only.',
      );
    }
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) async {
    return <Map<String, Object?>>[];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('the journal mode is asked for as a query, not as a command',
      () async {
    final executor = _RecordingExecutor();

    await JotItDatabase.applyPragmas(executor);

    expect(
      executor.rawQueries,
      contains('PRAGMA journal_mode = WAL'),
      reason: 'journal_mode answers with a row, so it has to be read as a '
          'query — Android refuses it as a command, and it runs while the '
          'database is opening',
    );
    expect(
      executor.executed.where((String sql) => sql.contains('journal_mode')),
      isEmpty,
      reason: 'asking for it as a command is the bug this test exists for',
    );
  });

  test('a platform that refuses a pragma does not stop the vault opening',
      () async {
    // A pragma is a tuning knob. A database that cannot be tuned is still a
    // database, and one that cannot be opened is not a vault at all.
    await expectLater(
      JotItDatabase.applyPragmas(_AndroidLikeExecutor()),
      completes,
    );
  });

  test('the pragmas that guard correctness are still asked for', () async {
    final executor = _RecordingExecutor();

    await JotItDatabase.applyPragmas(executor);

    // `foreign_keys` is what v2.0 relied on without ever turning on, and
    // `busy_timeout` is what keeps a second writer from failing instantly.
    expect(
      executor.executed,
      containsAll(<String>[
        'PRAGMA foreign_keys = ON',
        'PRAGMA busy_timeout = 5000',
      ]),
    );
  });
}
