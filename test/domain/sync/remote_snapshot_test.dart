import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/data/db/sync_meta_store.dart';
import 'package:jotit/domain/sync/remote_snapshot.dart';

/// §5.3 change detection — the only place a "the remote changed" verdict is
/// produced. Everything downstream trusts it.
void main() {
  const root = 'root-1';

  RemoteEntry file(String path, {String? etag, bool dir = false}) =>
      RemoteEntry(
        path: path,
        etag: etag,
        contentLength: 10,
        lastModified: DateTime.utc(2026, 10, 7),
        isCollection: dir,
      );

  RemoteSnapshot snap(Map<String, RemoteEntry> entries, {String? ctag}) =>
      RemoteSnapshot(entries: entries, collectionCtag: ctag, probedCtag: true);

  SyncMetaRecord base(String path,
          {String? etag, String? hash = 'h', String? uid = 'u1'}) =>
      SyncMetaRecord(
        syncRootId: root,
        path: path,
        uid: uid,
        baseEtag: etag,
        baseContentHash: hash,
      );

  group('classify', () {
    test('identical ETags mean unchanged', () {
      expect(RemoteDiff.classify(file('a.md', etag: '"e1"'), base('a.md', etag: '"e1"')),
          RemoteChange.unchanged);
    });

    test('different ETags mean changed', () {
      expect(RemoteDiff.classify(file('a.md', etag: '"e2"'), base('a.md', etag: '"e1"')),
          RemoteChange.changed);
    });

    test('the comparison is byte-exact', () {
      // Weak and strong tokens are different tokens. Treating them as equal
      // would skip a file the server considers rewritten.
      expect(
        RemoteDiff.classify(file('a.md', etag: 'W/"e1"'), base('a.md', etag: '"e1"')),
        RemoteChange.changed,
      );
    });

    test('surrounding whitespace and case are not normalised away', () {
      expect(
        RemoteDiff.classify(file('a.md', etag: '"e1 "'), base('a.md', etag: '"e1"')),
        RemoteChange.changed,
      );
    });

    test('no ETag anywhere is unknown, never unchanged', () {
      expect(RemoteDiff.classify(file('a.md'), base('a.md', etag: null)),
          RemoteChange.unknown);
      expect(
        RemoteDiff.classify(file('a.md', etag:'"e1"'), base('a.md')),
        RemoteChange.unknown);
    });

    test('size and mtime are never used as a fallback signal', () {
      // Both entries carry identical length and mtime, yet there is no ETag to
      // compare. Guessing "unchanged" is how a server that stopped sending
      // ETags looks silent forever.
      expect(
        RemoteDiff.classify(file('a.md'), base('a.md', etag: null)),
        RemoteChange.unknown,
      );
    });
  });

  group('diff', () {
    test('a path the base has never seen is added', () {
      final changes = RemoteDiff.between(
        snap({'notes/new.md': file('notes/new.md', etag: '"e1"')}),
        const [],
      );
      expect(changes.added, ['notes/new.md']);
      expect(changes.isEmpty, isFalse);
    });

    test('a moved ETag is changed', () {
      final changes = RemoteDiff.between(
        snap({'notes/a.md': file('notes/a.md', etag: '"e2"')}),
        [base('notes/a.md', etag: '"e1"')],
      );
      expect(changes.changed, ['notes/a.md']);
      expect(changes.added, isEmpty);
      expect(changes.deleted, isEmpty);
    });

    test('a path missing from the snapshot is deleted', () {
      final changes = RemoteDiff.between(
        snap(const {}),
        [base('notes/gone.md', etag: '"e1"')],
      );
      expect(changes.deleted, ['notes/gone.md']);
    });

    test('a rename shows up as one delete plus one add', () {
      // The matrix resolves this by uid, not by path — see row 3.
      final changes = RemoteDiff.between(
        snap({'notes/new.md': file('notes/new.md', etag: '"e1"')}),
        [base('notes/old.md', etag: '"e1"', uid: 'u1')],
      );
      expect(changes.added, ['notes/new.md']);
      expect(changes.deleted, ['notes/old.md']);
    });

    test('collections are not files', () {
      final changes = RemoteDiff.between(
        snap({
          'notes/daily': file('notes/daily', etag: '"c1"', dir: true),
          'notes/a.md': file('notes/a.md', etag: '"e1"'),
        }),
        const [],
      );
      expect(changes.added, ['notes/a.md'],
          reason: 'a directory appearing is not a note to fetch');
    });

    test('an unchanged vault produces nothing at all', () {
      final changes = RemoteDiff.between(
        snap({
          'notes/a.md': file('notes/a.md', etag: '"e1"'),
          'notes/b.md': file('notes/b.md', etag: '"e2"'),
        }),
        [base('notes/a.md', etag: '"e1"'), base('notes/b.md', etag: '"e2"')],
      );
      expect(changes.isEmpty, isTrue);
      expect(changes.total, 0);
      expect(changes.toString(), contains('+0'));
    });

    test('every list comes back sorted, so a batch is deterministic', () {
      final changes = RemoteDiff.between(
        snap({
          'notes/z.md': file('notes/z.md', etag: '"e1"'),
          'notes/a.md': file('notes/a.md', etag: '"e1"'),
        }),
        [base('notes/m.md', etag: '"x"'), base('notes/b.md', etag: '"y"')],
      );
      expect(changes.added, ['notes/a.md', 'notes/z.md']);
      expect(changes.deleted, ['notes/b.md', 'notes/m.md']);
    });

    test('unknown entries are listed separately from changed ones', () {
      final changes = RemoteDiff.between(
        snap({'notes/a.md': file('notes/a.md')}),
        [base('notes/a.md', etag: '"e1"')],
      );
      expect(changes.unknown, ['notes/a.md']);
      expect(changes.changed, isEmpty);
      expect(changes.total, 1);
    });

    test('a base row for another path is a delete, never an add', () {
      final changes = RemoteDiff.between(
        snap(const {}),
        [base('notes/a.md'), base('notes/b.md')],
      );
      expect(changes.deleted, ['notes/a.md', 'notes/b.md']);
      expect(changes.added, isEmpty);
    });
  });

  group('CTag fast path', () {
    test('an unchanged CTag lets the walk be skipped', () {
      final snapshot = RemoteSnapshot(
        collectionCtag: '"ctag-5"',
        probedCtag: true,
      );
      expect(RemoteDiff.canSkipWalk(snapshot, '"ctag-5"'), isTrue);
    });

    test('a changed CTag forces a walk', () {
      final snapshot = RemoteSnapshot(
        collectionCtag: '"ctag-6"',
        probedCtag: true,
      );
      expect(RemoteDiff.canSkipWalk(snapshot, '"ctag-5"'), isFalse);
    });

    test('no CTag on the server means the walk is never skipped', () {
      // §6.2: CTag is RFC 3253 and only Nextcloud / ownCloud / SabreDAV have
      // it. Skipping on "no CTag" is the v2.0 bug that reported every device
      // as in sync forever.
      final snapshot = RemoteSnapshot(probedCtag: true);
      expect(RemoteDiff.canSkipWalk(snapshot, '"ctag-5"'), isFalse);
      expect(RemoteDiff.canSkipWalk(snapshot, null), isFalse);
    });

    test('a base with no CTag yet forces the first walk', () {
      final snapshot = RemoteSnapshot(
        collectionCtag: '"ctag-1"',
        probedCtag: true,
      );
      expect(RemoteDiff.canSkipWalk(snapshot, null), isFalse);
    });

    test('an unprobed snapshot never skips, even with a matching token', () {
      final snapshot = RemoteSnapshot(collectionCtag: '"ctag-5"');
      expect(snapshot.probedCtag, isFalse);
      expect(RemoteDiff.canSkipWalk(snapshot, '"ctag-5"'), isFalse,
          reason: 'never asked is not the same as asked and got nothing');
    });
  });

  group('traversal helpers', () {
    final snapshot = snap({
      'notes': file('notes', etag: '"c0"', dir: true),
      'notes/a.md': file('notes/a.md', etag: '"e1"'),
      'notes/daily': file('notes/daily', etag: '"c1"', dir: true),
      'notes/daily/1.md': file('notes/daily/1.md', etag: '"e2"'),
      'notes/daily/deep': file('notes/daily/deep', etag: '"c2"', dir: true),
      'notes/daily/deep/2.md': file('notes/daily/deep/2.md', etag: '"e3"'),
      'notes/archive': file('notes/archive', etag: '"c3"', dir: true),
    });

    test('child collections are exactly the direct ones', () {
      expect(
        snapshot.childCollectionsOf('notes').map((e) => e.path),
        ['notes/archive', 'notes/daily'],
      );
    });

    test('recursion from a child works', () {
      expect(
        snapshot.childCollectionsOf('notes/daily').map((e) => e.path),
        ['notes/daily/deep'],
      );
    });

    test('the root itself is not a child of the root', () {
      expect(snapshot.childCollectionsOf('').map((e) => e.path),
          ['notes'],
      );
    });

    test('a leaf has no child collections', () {
      expect(snapshot.childCollectionsOf('notes/daily/deep'), isEmpty);
    });

    test('files and collections are separated', () {
      expect(snapshot.files.length, 3);
      expect(snapshot.collections.length, 4);
    });
  });
}
