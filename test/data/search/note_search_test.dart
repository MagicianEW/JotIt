import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/data/db/jotit_database.dart';
import 'package:jotit/data/db/note_dao.dart';
import 'package:jotit/data/search/note_search.dart';

/// ADR-3 search over the derived index.
///
/// The one property that is easy to break silently: FTS5 rows are maintained
/// by triggers on `notes`, and a soft delete *is* an UPDATE — so the FTS
/// table keeps every deleted note unless the query filters them out.
void main() {
  late JotItDatabase jdb;
  late NoteDao dao;
  late NoteSearch search;

  setUp(() async {
    jdb = await JotItDatabase.openInMemory();
    dao = NoteDao(jdb.db);
    search = NoteSearch(jdb.db);
  });

  tearDown(() async => jdb.close());

  Future<void> seed(String uid, String path, String title, String body) =>
      dao.upsert(NoteRecord(
        uid: uid,
        path: path,
        title: title,
        body: body,
        updatedAt: 1,
      ));

  test('finds an active note by body text', () async {
    await seed('u-1', 'notes/a.md', 'Alpha', 'the quick brown fox');

    final hits = await search.search('brown');
    expect(hits.map((h) => h.path), ['notes/a.md']);
  });

  test('finds an active note by title', () async {
    await seed('u-1', 'notes/a.md', '搜索引擎', 'body text');

    final hits = await search.search('搜索');
    expect(hits.map((h) => h.path), ['notes/a.md']);
  });

  test('a soft-deleted note cannot be searched out', () async {
    // P1-1: notes_fts_au 重插 FTS 行，softDelete 只是一次 UPDATE，≥3 字符
    // 的查询会把已删笔记搜出来。删除状态只在 notes 表里，FTS 查询必须联结
    // 过滤。
    await seed('u-1', 'notes/a.md', 'Alpha', 'deleted body content');
    await seed('u-2', 'notes/b.md', 'Beta', 'kept body content');

    await dao.softDelete('notes/a.md', at: 100);

    final hits = await search.search('body');
    expect(hits.map((h) => h.path), ['notes/b.md'],
        reason: 'the deleted note must not come back through FTS');
  });

  test('a deleted note is invisible to short queries too', () async {
    await seed('u-1', 'notes/a.md', 'Alpha', 'ab');
    await dao.softDelete('notes/a.md', at: 100);

    expect(await search.search('ab'), isEmpty);
  });

  test('a restored note is searchable again', () async {
    await seed('u-1', 'notes/a.md', 'Alpha', 'restored body content');
    await dao.softDelete('notes/a.md', at: 100);
    expect(await search.search('restored'), isEmpty);

    await dao.restore('notes/a.md');
    expect((await search.search('restored')).map((h) => h.path),
        ['notes/a.md']);
  });

  test('a malformed query does not throw', () async {
    await seed('u-1', 'notes/a.md', 'Alpha', 'body');
    expect(await search.search('"unclosed'), isA<List<Object>>());
  });
}
