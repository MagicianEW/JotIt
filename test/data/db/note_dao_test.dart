import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/data/db/jotit_database.dart';
import 'package:jotit/data/db/note_dao.dart';

/// The `notes` table is a derived index with two unique constraints — `id`
/// (the front-matter uid, ADR-2) and `path` — and every write has to keep both
/// true. These tests pin the two directions a row can go stale.
void main() {
  late JotItDatabase jdb;
  late NoteDao dao;

  setUp(() async {
    jdb = await JotItDatabase.openInMemory();
    dao = NoteDao(jdb.db);
  });

  tearDown(() async => jdb.close());

  NoteRecord record(String uid, String path) => NoteRecord(
        uid: uid,
        path: path,
        title: 'T-$path',
        body: 'B-$path',
        updatedAt: 1,
      );

  test('a note moved to a new path keeps its uid and loses the old row',
      () async {
    // P0-2: 另一设备把已同步笔记改名，本机同步采纳后重建索引。旧行
    // (id=U, path=old.md) 不删的话，INSERT OR IGNORE 主键冲突 + UPDATE 按
    // 新路径影响 0 行 —— 新路径永远插不进去，笔记在应用内永久消失。
    await dao.upsert(record('u-1', 'notes/old.md'));
    expect(await dao.byPath('notes/old.md'), isNotNull);

    await dao.upsert(record('u-1', 'notes/new.md'));

    final moved = await dao.byPath('notes/new.md');
    expect(moved, isNotNull,
        reason: 'the new path must be queryable after the move');
    expect(moved!.uid, 'u-1');
    expect(moved.title, 'T-notes/new.md',
        reason: 'the row must describe the note at its new path');
    expect(await dao.byPath('notes/old.md'), isNull,
        reason: 'the stale row at the old path must be gone');
    expect(await dao.byUid('u-1'), isNotNull);
    expect(await dao.countActive(), 1,
        reason: 'one note, one row — not a ghost at the old path');
  });

  test('a move keeps the disambiguations the user made for the note',
      () async {
    // P1-6: the aliases are the user's own decisions, and they hang off the
    // note's id. Deleting the row to re-create it at the new path cascades
    // the aliases away — silent, permanent loss, caused by nothing more than
    // moving a file in the file manager.
    await dao.upsert(record('u-1', 'notes/a.md'));
    await dao.upsert(record('u-2', 'notes/b.md'));
    await jdb.db.insert('link_aliases', <String, Object?>{
      'source_note_id': 'u-1',
      'alias': '同名',
      'target_note_id': 'u-2',
    });

    await dao.upsert(record('u-1', 'notes/new.md'));

    final aliases = await jdb.db.query('link_aliases');
    expect(aliases, hasLength(1),
        reason: 'the disambiguation must survive the move');
    expect(aliases.single['source_note_id'], 'u-1');
    expect(aliases.single['target_note_id'], 'u-2');
  });

  test('a row whose uid changed under the same path is replaced', () async {
    await dao.upsert(record('u-1', 'notes/a.md'));
    await dao.upsert(record('u-2', 'notes/a.md'));

    final row = await dao.byPath('notes/a.md');
    expect(row!.uid, 'u-2');
    expect(await dao.byUid('u-1'), isNull);
    expect(await dao.countActive(), 1);
  });

  test('upserting the same row twice is idempotent', () async {
    await dao.upsert(record('u-1', 'notes/a.md'));
    await dao.upsert(record('u-1', 'notes/a.md'));

    expect(await dao.countActive(), 1);
    expect((await dao.byPath('notes/a.md'))!.uid, 'u-1');
  });

  test('a move does not disturb unrelated notes', () async {
    await dao.upsert(record('u-1', 'notes/a.md'));
    await dao.upsert(record('u-2', 'notes/b.md'));
    await dao.upsert(record('u-1', 'notes/a-moved.md'));

    expect((await dao.byPath('notes/a-moved.md'))!.uid, 'u-1');
    expect((await dao.byPath('notes/b.md'))!.uid, 'u-2');
    expect(await dao.countActive(), 2);
  });

  test('softDelete hides the row from active reads but keeps it', () async {
    await dao.upsert(record('u-1', 'notes/a.md'));
    await dao.softDelete('notes/a.md', at: 100);

    expect(await dao.byPath('notes/a.md'), isNull);
    expect((await dao.byPath('notes/a.md', includeDeleted: true))!.isDeleted,
        isTrue);
    expect(await dao.countActive(), 0);

    await dao.restore('notes/a.md');
    expect(await dao.byPath('notes/a.md'), isNotNull);
  });

  test('purge removes the row entirely', () async {
    await dao.upsert(record('u-1', 'notes/a.md'));
    await dao.purge('notes/a.md');
    expect(await dao.byPath('notes/a.md', includeDeleted: true), isNull);
  });
}
