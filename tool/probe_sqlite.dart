// Capability probe: verifies ADR-4 (SQLite >= 3.34 + FTS5 + trigram) actually
// holds on this machine with the bundled SQLite. Run: dart run tool/probe_sqlite.dart
//
// 这是一个命令行探针脚本，输出就是它唯一的产品，故豁免 avoid_print。
// ignore_for_file: avoid_print
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> main() async {
  sqfliteFfiInit();
  final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);

  Future<String> scalar(String sql) async =>
      (await db.rawQuery(sql)).first.values.first.toString();

  final version = await scalar('SELECT sqlite_version()');
  print('sqlite_version() = $version');

  final versionOk = (() {
    final parts = version.split('.').map(int.parse).toList();
    return parts[0] > 3 || (parts[0] == 3 && parts[1] >= 34);
  })();
  print('  >= 3.34 (trigram requires): ${versionOk ? "YES" : "NO  <-- BLOCKER"}');

  // FTS5 availability
  try {
    await db.execute(
      'CREATE VIRTUAL TABLE _probe_fts USING fts5(x, tokenize = \'trigram\')',
    );
    print('FTS5 + trigram: AVAILABLE');
    await db.execute('DROP TABLE _probe_fts');
  } catch (e) {
    print('FTS5 + trigram: FAILED -> $e');
    print('  <-- Chinese search would be broken; need fallback tokenizer path');
  }

  // Realistic CJK search check (this is what P0-1 was about)
  try {
    await db.execute(
      "CREATE VIRTUAL TABLE t USING fts5(id UNINDEXED, body, tokenize = 'trigram')",
    );
    await db.insert('t', {
      'id': 'n1',
      'body': '同步引擎的状态机包含六个状态和十三个决策分支',
    });
    for (final q in ['同步引擎', '状态机', '决策', '引擎的状态']) {
      final rows = await db.rawQuery(
        "SELECT count(*) c FROM t WHERE t MATCH ?",
        [q],
      );
      final hits = rows.first['c'];
      print('  MATCH "$q" -> $hits  ${(hits as int) > 0 ? "OK" : "MISS"}');
    }
    await db.execute('DROP TABLE t');
  } catch (e) {
    print('CJK search check failed: $e');
  }

  // Triggers + PRAGMAs that ADR/schema depends on
  try {
    await db.execute('CREATE TABLE a(id TEXT PRIMARY KEY, b TEXT NOT NULL)');
    await db.execute('CREATE TABLE ax(id TEXT PRIMARY KEY, x TEXT)');
    await db.execute(
      'CREATE TRIGGER ax_i AFTER INSERT ON a BEGIN '
      'INSERT INTO ax(id,x) VALUES(new.id,new.b); END',
    );
    await db.insert('a', {'id': 'x1', 'b': 'v'});
    final r = await db.rawQuery('SELECT x FROM ax WHERE id=?', ['x1']);
    print('triggers: ${r.isEmpty ? "BROKEN" : "OK"}');
  } catch (e) {
    print('trigger check failed: $e');
  }

  for (final p in [
    'PRAGMA journal_mode=WAL',
    'PRAGMA foreign_keys=ON',
    'PRAGMA user_version=7',
  ]) {
    try {
      await db.execute(p);
      print('$p -> OK');
    } catch (e) {
      print('$p -> FAILED $e');
    }
  }
  print('user_version now = ${await scalar('PRAGMA user_version')}');

  await db.close();
}