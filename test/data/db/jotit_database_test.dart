import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/data/db/jotit_database.dart';
import 'package:jotit/data/db/note_dao.dart';
import 'package:jotit/data/db/schema.dart';
import 'package:jotit/data/search/note_search.dart';
import 'package:sqflite_common/sqlite_api.dart';

void main() {
  late JotItDatabase jdb;
  late NoteDao notes;
  late NoteSearch search;

  setUp(() async {
    jdb = await JotItDatabase.openInMemory();
    notes = NoteDao(jdb.db);
    search = NoteSearch(jdb.db);
  });

  tearDown(() async => jdb.close());

  NoteRecord note(String uid, String path, String title, String body,
          {int at = 1000}) =>
      NoteRecord(
          uid: uid, path: path, title: title, body: body, updatedAt: at);

  group('migration', () {
    test('lands on the declared version and records it', () async {
      expect(await jdb.schemaVersion(), kSchemaVersion);
    });

    test('reopening an up-to-date vault is a no-op', () async {
      await notes.upsert(note('u1', 'a.md', 'A', 'B'));
      final reopened = JotItDatabase.wrap(jdb.db);
      await reopened.ensureSchema();
      expect(await reopened.schemaVersion(), kSchemaVersion);
      expect(await jdb.db.query('notes'), hasLength(1),
          reason: 'a second run must not recreate the schema over live rows');
    });

    test('nothing is pending at the current version', () {
      expect(migrationsFrom(0), hasLength(kSchemaVersion));
      expect(migrationsFrom(kSchemaVersion), isEmpty);
    });

    test('refuses to open a newer schema than it understands', () async {
      await jdb.db.execute('PRAGMA user_version = ${kSchemaVersion + 5}');
      final reopened = JotItDatabase.wrap(jdb.db);
      await expectLater(reopened.ensureSchema(), throwsStateError);
    });
  });

  group('capabilities (ADR-4)', () {
    test('bundled SQLite is new enough for trigram', () async {
      final v = await jdb.sqliteVersion();
      expect(v, isNotNull);
      await expectLater(jdb.assertSearchCapabilities(), completes);
    });
  });

  group('schema guarantees', () {
    test('is_deleted cannot be NULL', () async {
      // A nullable flag is how a note silently disappears from every view
      // filtered by `WHERE is_deleted = 0`.
      await expectLater(
        jdb.db.execute(
          "INSERT INTO notes (id, path, is_deleted, updated_at) VALUES ('a','a.md',NULL,0)",
        ),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('conflict_state is constrained', () async {
      await jdb.db.insert('sync_roots', {'id': 'r', 'name': 'r', 'base_url': 'u'});
      await expectLater(
        jdb.db.insert('sync_meta', {
          'sync_root_id': 'r',
          'path': 'a.md',
          'conflict_state': 'whatever',
        }),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('foreign keys are enforced', () async {
      // v2.0 declared REFERENCES everywhere with foreign_keys left off, so
      // every constraint was decorative.
      await expectLater(
        jdb.db.insert('links', {
          'source_note_id': 'ghost',
          'raw_target': 'x',
          'link_type': 'wiki',
        }),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('links accept a null target for a not-yet-created note', () async {
      await notes.upsert(note('u1', 'a.md', 'A', 'body'));
      await jdb.db.insert('links', {
        'source_note_id': 'u1',
        'target_note_id': null,
        'target_path': 'missing.md',
        'raw_target': 'missing',
        'link_type': 'wiki',
      });
      final rows = await jdb.db.query('links');
      expect(rows.single['target_note_id'], isNull);
      expect(rows.single['target_path'], 'missing.md');
    });
  });

  group('FTS5 triggers (ADR-3)', () {
    test('insert indexes the note', () async {
      await notes.upsert(note('u1', 'a.md', '同步引擎', '状态机设计'));
      final rows = await jdb.db.rawQuery('SELECT count(*) c FROM notes_fts');
      expect(rows.first['c'], 1);
    });

    test('update reindexes', () async {
      await notes.upsert(note('u1', 'a.md', 'old', 'old body'));
      await notes.upsert(note('u1', 'a.md', 'new', 'new body'));
      final rows = await jdb.db.rawQuery('SELECT count(*) c FROM notes_fts');
      expect(rows.first['c'], 1, reason: 'one row per note, not two');
      final hits = await search.search('new body');
      expect(hits.single.uid, 'u1');
    });

    test('delete removes the index row', () async {
      await notes.upsert(note('u1', 'a.md', 'A', 'B'));
      await notes.purge('a.md');
      final rows = await jdb.db.rawQuery('SELECT count(*) c FROM notes_fts');
      expect(rows.first['c'], 0);
    });

    test('upsert preserves the row so links survive', () async {
      await notes.upsert(note('u1', 'a.md', 'A', 'B'));
      await jdb.db.insert('links', {
        'source_note_id': 'u1',
        'raw_target': 'other',
        'link_type': 'wiki',
      });
      await notes.upsert(note('u1', 'a.md', 'A', 'B changed'));
      final links = await jdb.db.query('links');
      expect(links, hasLength(1),
          reason: 'INSERT OR REPLACE would have cascaded this away');
    });

    test('a uid change at the same path replaces the row', () async {
      await notes.upsert(note('u1', 'a.md', 'A', 'B'));
      await notes.upsert(note('u2', 'a.md', 'A', 'B'));
      expect(await jdb.db.query('notes'), hasLength(1));
      expect((await notes.byPath('a.md'))!.uid, 'u2');
    });
  });

  group('search', () {
    setUp(() async {
      await notes.upsert(note('u1', 'a.md', '同步引擎', '状态机与决策矩阵'));
      await notes.upsert(note('u2', 'b.md', '数据库', 'FTS5 与 trigram 分词'));
      await notes.upsert(note('u3', 'c.md', '图谱', 'ForceAtlas2 布局'));
    });

    test('finds a CJK substring that unicode61 would miss', () async {
      final hits = await search.search('引擎');
      expect(hits.map((h) => h.uid), contains('u1'));
    });

    test('finds a longer CJK phrase', () async {
      final hits = await search.search('状态机');
      expect(hits.map((h) => h.uid), contains('u1'));
    });

    test('matches a latin substring', () async {
      final hits = await search.search('atla');
      expect(hits.map((h) => h.uid), contains('u3'));
    });

    test('is case-insensitive', () async {
      expect((await search.search('ATLA')).map((h) => h.uid), contains('u3'));
      expect((await search.search('atla')).map((h) => h.uid), contains('u3'));
    });

    test('two-character queries still work via the LIKE floor', () async {
      // The trigram tokenizer cannot express this; the fallback must.
      final hits = await search.search('数据库');
      expect(hits.map((h) => h.uid), contains('u2'));
    });

    test('single-character queries work', () async {
      final hits = await search.search('图');
      expect(hits.map((h) => h.uid), contains('u3'));
    });

    test('accepts a pasted wiki link', () async {
      expect((await search.search('[[同步引擎]]')).map((h) => h.uid),
          contains('u1'));
      expect((await search.search('![[同步引擎]]')).map((h) => h.uid),
          contains('u1'));
    });

    test('boolean syntax in user input is treated as text', () async {
      // Unquoted this would become an FTS5 OR query.
      final hits = await search.search('图谱 OR 引擎');
      expect(hits, isEmpty);
    });

    test('wildcards in user input are not wildcards', () async {
      final hits = await search.search('%');
      expect(hits, isEmpty);
    });

    test('deleted notes are excluded from the LIKE floor', () async {
      await notes.softDelete('a.md', at: 5);
      final hits = await search.search('数据库');
      expect(hits.map((h) => h.uid), contains('u2'));
      final short = await search.search('状态');
      expect(short, isEmpty);
    });

    test('empty query returns nothing rather than everything', () async {
      expect(await search.search('   '), isEmpty);
      expect(await search.search('[[]]'), isEmpty);
    });
  });

  group('NoteDao', () {
    test('filters soft-deleted by default', () async {
      await notes.upsert(note('u1', 'a.md', 'A', 'B'));
      await notes.softDelete('a.md', at: 7);
      expect(await notes.byPath('a.md'), isNull);
      expect(await notes.byPath('a.md', includeDeleted: true), isNotNull);
      expect(await notes.countActive(), 0);
    });

    test('byUid finds the note regardless of path', () async {
      await notes.upsert(note('u1', 'a.md', 'A', 'B'));
      expect((await notes.byUid('u1'))!.path, 'a.md');
      expect(await notes.byUid('nope'), isNull);
    });

    test('restore brings a note back', () async {
      await notes.upsert(note('u1', 'a.md', 'A', 'B'));
      await notes.softDelete('a.md', at: 7);
      await notes.restore('a.md');
      expect(await notes.byPath('a.md'), isNotNull);
    });
  });
}