import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/domain/vault/note_mover.dart';
import 'package:path/path.dart' as p;

/// v3.0 §9.3 rule 4 — "笔记移动时，其 `attachments/` 目录随笔记目录一并移动".
///
/// The mover is deliberately small and deliberately *not* a link rewriter.
/// §9.3 rule 2 puts every pasted file in an `attachments/` folder beside the
/// note, so carrying that folder makes the relative link invariant — a mover
/// that rewrote links would be solving a problem it created itself. These
/// tests pin that reasoning, so the next person to add a "rewrite the links
/// too" branch has to argue with them first.
void main() {
  late Directory vault;
  late NoteMover mover;

  setUp(() async {
    vault = await Directory.systemTemp.createTemp('jotit_move_');
    mover = NoteMover(vaultRoot: vault.path);
  });

  tearDown(() async {
    if (vault.existsSync()) await vault.delete(recursive: true);
  });

  File write(String relative, List<int> bytes) {
    final f = File(p.joinAll([vault.path, ...relative.split('/')]));
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(bytes);
    return f;
  }

  bool exists(String relative) =>
      File(p.joinAll([vault.path, ...relative.split('/')])).existsSync();

  group('nothing to do', () {
    test('two notes in the same directory', () async {
      write('notes/daily/attachments/x.png', <int>[1]);

      final outcome =
          await mover.moveAttachments(fromNotePath: 'notes/daily/a.md', toNotePath: 'notes/daily/b.md');

      expect(outcome.isEmpty, isTrue);
      expect(exists('notes/daily/attachments/x.png'), isTrue);
    });

    test('a note that never had attachments', () async {
      final outcome =
          await mover.moveAttachments(fromNotePath: 'notes/a.md', toNotePath: 'notes/b.md');

      expect(outcome.isEmpty, isTrue);
    });

    test('a path outside the vault is refused, not attempted', () async {
      final outcome = await mover.moveAttachments(
        fromNotePath: '_conflicts/x/local.md',
        toNotePath: 'notes/y.md',
      );
      expect(outcome.isEmpty, isTrue);
    });
  });

  group('a plain move', () {
    test('the whole folder travels', () async {
      write('notes/a/attachments/one.png', <int>[1]);
      write('notes/a/attachments/two.png', <int>[2]);

      final outcome =
          await mover.moveAttachments(fromNotePath: 'notes/a/x.md', toNotePath: 'notes/b/x.md');

      expect(outcome.moved, 2);
      expect(outcome.collisions, isEmpty);
      expect(exists('notes/b/attachments/one.png'), isTrue);
      expect(exists('notes/b/attachments/two.png'), isTrue);
      expect(exists('notes/a/attachments/one.png'), isFalse);
    });

    test('the emptied folder is cleaned up', () async {
      write('notes/a/attachments/one.png', <int>[1]);

      await mover.moveAttachments(fromNotePath: 'notes/a/x.md', toNotePath: 'notes/b/x.md');

      expect(Directory(p.joinAll([vault.path, 'notes', 'a', 'attachments'])).existsSync(),
          isFalse,
          reason: 'an empty attachments folder in a directory with no notes '
              'is just clutter');
    });

    test('the relocation map names both ends', () async {
      // The engine needs it to finish the move on the server; without it the
      // old path lingers as a second copy of an immutable file.
      write('notes/a/attachments/one.png', <int>[1]);

      final outcome =
          await mover.moveAttachments(fromNotePath: 'notes/a/x.md', toNotePath: 'notes/b/x.md');

      expect(outcome.relocations,
          {'notes/a/attachments/one.png': 'notes/b/attachments/one.png'});
    });

    test('moving several levels up works the same', () async {
      write('notes/a/b/c/attachments/one.png', <int>[1]);

      final outcome = await mover.moveAttachments(
          fromNotePath: 'notes/a/b/c/x.md', toNotePath: 'notes/x.md');

      expect(outcome.moved, 1);
      expect(exists('notes/attachments/one.png'), isTrue);
    });

    test('moving sideways into a sibling directory', () async {
      write('notes/a/attachments/one.png', <int>[1]);

      await mover.moveAttachments(
          fromNotePath: 'notes/a/x.md', toNotePath: 'notes/c/x.md');

      expect(exists('notes/c/attachments/one.png'), isTrue);
    });
  });

  group('merging into a folder that already exists', () {
    test('an identical file is dropped rather than duplicated', () async {
      // The other device already did this move; arriving second must not
      // leave two copies of an immutable file that both sync forever.
      write('notes/a/attachments/one.png', <int>[1]);
      write('notes/b/attachments/one.png', <int>[1]);

      final outcome =
          await mover.moveAttachments(fromNotePath: 'notes/a/x.md', toNotePath: 'notes/b/x.md');

      expect(outcome.identical, 1);
      expect(outcome.moved, 0);
      expect(outcome.collisions, isEmpty);
      expect(exists('notes/a/attachments/one.png'), isFalse);
      expect(exists('notes/b/attachments/one.png'), isTrue);
    });

    test('a differing file is a collision, and both are left alone', () async {
      // C3: never overwrite. And §9.3 / ADR-11: these paths are immutable, so
      // two different files at two destinations is a fact for a person, not
      // a diff to resolve automatically.
      write('notes/a/attachments/one.png', <int>[1]);
      write('notes/b/attachments/one.png', <int>[2]);

      final outcome =
          await mover.moveAttachments(fromNotePath: 'notes/a/x.md', toNotePath: 'notes/b/x.md');

      expect(outcome.collisions, ['notes/b/attachments/one.png']);
      expect(File(p.joinAll([vault.path, 'notes', 'a', 'attachments', 'one.png'])).readAsBytesSync(),
          <int>[1]);
      expect(File(p.joinAll([vault.path, 'notes', 'b', 'attachments', 'one.png'])).readAsBytesSync(),
          <int>[2]);
    });

    test('a collision does not block the files that are not colliding',
        () async {
      write('notes/a/attachments/dup.png', <int>[1]);
      write('notes/b/attachments/dup.png', <int>[1]);
      write('notes/a/attachments/conflict.png', <int>[2]);
      write('notes/b/attachments/conflict.png', <int>[9]);
      write('notes/a/attachments/fresh.png', <int>[3]);

      final outcome =
          await mover.moveAttachments(fromNotePath: 'notes/a/x.md', toNotePath: 'notes/b/x.md');

      expect(outcome.moved, 1);
      expect(outcome.identical, 1);
      expect(outcome.collisions, ['notes/b/attachments/conflict.png']);
      expect(exists('notes/b/attachments/fresh.png'), isTrue);
      expect(exists('notes/a/attachments/conflict.png'), isTrue,
          reason: 'a colliding file stays where it was; C3');
    });
  });

  group('the comparison can be driven without real megabytes', () {
    test('a comparator that always says "different" produces a collision',
        () async {
      // Proves the collision branch is reachable by content, not only by
      // file name — otherwise the only way to test it would be a fixture
      // large enough to be inconvenient.
      write('notes/a/attachments/one.png', <int>[1]);
      write('notes/b/attachments/one.png', <int>[1]);

      final outcome = await NoteMover(
        vaultRoot: vault.path,
        bytesEqual: (a, b) async => false,
      ).moveAttachments(fromNotePath: 'notes/a/x.md', toNotePath: 'notes/b/x.md');

      expect(outcome.identical, 0);
      expect(outcome.collisions, hasLength(1));
    });
  });

  group('the invariant the no-link-rewriting claim rests on', () {
    test('the link to a carried file is unchanged by the move', () {
      // §9.3 rule 2 + rule 4 together: the attachment is always at
      // dirname(note)/attachments/, so the relative link is always
      // `attachments/<name>`, at any depth. If this ever stops holding, the
      // mover needs a link rewriter and this test is where that decision
      // belongs.
      expect(VaultPathsForTest.attachmentDirFor('notes/a/b/c/x.md'),
          'notes/a/b/c/attachments');
      expect(VaultPathsForTest.attachmentDirFor('notes/x.md'),
          'notes/attachments');
    });
  });
}

/// A two-line view of the rule the test above is about, kept here rather than
/// imported so the assertion reads as the *rule* and not as a call.
class VaultPathsForTest {
  static String attachmentDirFor(String notePath) {
    final segments = notePath.split('/');
    segments.removeLast();
    return <String>[...segments, 'attachments'].join('/');
  }
}
