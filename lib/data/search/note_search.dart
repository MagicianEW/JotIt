import 'package:sqflite_common/sqlite_api.dart';

class SearchHit {
  const SearchHit({
    required this.uid,
    required this.path,
    required this.title,
    required this.snippet,
  });

  final String uid;
  final String path;
  final String title;
  final String snippet;
}

/// Full-text search over the derived index.
///
/// ADR-4 picked the `trigram` tokenizer because `unicode61` treats a whole run
/// of CJK as one token, which makes "搜索引擎" never match a note containing
/// "同步引擎". Trigram fixes that but introduces its own ceiling: **a query
/// shorter than three characters cannot be matched**, because no trigram fits.
/// In Chinese that is not an edge case — "决策", "同步" and "架构" are all two
/// characters, and a search box that silently misses them is worse than no
/// search box.
///
/// So this runs a two-tier strategy: FTS5 for anything long enough to tokenize,
/// and a `LIKE` scan as the floor. `LIKE` cannot use an index, but it is
/// correct for short CJK input and the vault is a personal knowledge base, not
/// a data warehouse.
class NoteSearch {
  const NoteSearch(this._db);

  final DatabaseExecutor _db;

  /// Column index of `body` in the FTS5 table, for [snippet].
  static const int _bodyColumn = 3;
  static const int _minTrigramLength = 3;

  Future<List<SearchHit>> search(String rawQuery, {int limit = 50}) async {
    final query = _normalize(rawQuery);
    if (query.isEmpty) return const [];

    final hits = <String, SearchHit>{};

    if (query.runes.length >= _minTrigramLength) {
      for (final h in await _fts(query, limit)) {
        hits[h.uid] = h;
      }
    }
    // The floor runs whenever FTS could not run, and also when it found
    // nothing: a trigram index can legitimately miss a substring that a scan
    // would catch, and a search that sometimes returns nothing depending on
    // the query length is unpredictable to live with.
    if (hits.isEmpty || query.runes.length < _minTrigramLength) {
      for (final h in await _like(query, limit)) {
        hits.putIfAbsent(h.uid, () => h);
      }
    }

    final out = hits.values.toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    return out.length > limit ? out.sublist(0, limit) : out;
  }

  Future<List<SearchHit>> _fts(String query, int limit) async {
    try {
      final rows = await _db.rawQuery(
        '''
SELECT f.uid AS uid, f.path AS path, f.title AS title,
       snippet(notes_fts, $_bodyColumn, '\u0001', '\u0002', '\u2026', 16) AS snippet
FROM notes_fts f
WHERE notes_fts MATCH ?
ORDER BY rank
LIMIT ?
''',
        [_ftsQuery(query), limit],
      );
      return [for (final r in rows) _hit(r)];
    } on DatabaseException {
      // A malformed MATCH expression must not take the search box down.
      return const [];
    }
  }

  Future<List<SearchHit>> _like(String query, int limit) async {
    final pattern = '%${_escapeLike(query)}%';
    final rows = await _db.rawQuery(
      '''
SELECT id AS uid, path AS path, title AS title,
       '' AS snippet
FROM notes
WHERE is_deleted = 0 AND (title LIKE ? ESCAPE '\\' OR body LIKE ? ESCAPE '\\')
ORDER BY path
LIMIT ?
''',
      [pattern, pattern, limit],
    );
    return [for (final r in rows) _hit(r)];
  }

  SearchHit _hit(Map<String, Object?> r) => SearchHit(
        uid: r['uid']! as String,
        path: r['path']! as String,
        title: (r['title'] as String?) ?? '',
        snippet: (r['snippet'] as String?) ?? '',
      );

  /// Accepts what a user actually pastes: `[[query]]`, `![[query]]` and the
  /// bare word all mean the same search.
  String _normalize(String raw) {
    var q = raw.trim();
    if (q.startsWith('!')) q = q.substring(1).trim();
    if (q.startsWith('[[') && q.endsWith(']]') && q.length >= 4) {
      q = q.substring(2, q.length - 2).trim();
    }
    final bar = q.indexOf('|');
    if (bar >= 0) q = q.substring(0, bar).trim();
    return q;
  }

  /// Wrap the whole query as one FTS5 phrase.
  ///
  /// Quoting is what makes user input safe: an unquoted `engine OR error`
  /// would silently become a boolean query. Double quotes inside are escaped
  /// the FTS5 way, by doubling.
  String _ftsQuery(String query) =>
      '"${query.replaceAll('"', '""')}"';

  String _escapeLike(String value) => value
      .replaceAll('\\', '\\\\')
      .replaceAll('%', '\\%')
      .replaceAll('_', '\\_');
}