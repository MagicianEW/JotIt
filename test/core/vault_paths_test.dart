import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/core/vault_paths.dart';
import 'package:jotit/domain/sync/conflict_naming.dart';
import 'package:path/path.dart' as p;

void main() {
  group('normalizeRelative', () {
    test('normalises separators and drops no-op segments', () {
      expect(VaultPaths.normalizeRelative(r'daily\2024-01-01.md'), 'daily/2024-01-01.md');
      expect(VaultPaths.normalizeRelative('./daily//x.md'), 'daily/x.md');
      expect(VaultPaths.normalizeRelative('a/b/../c.md'), 'a/c.md');
    });

    test('rejects anything that escapes the vault', () {
      expect(VaultPaths.normalizeRelative('/etc/passwd'), isNull);
      expect(VaultPaths.normalizeRelative(r'C:\Windows\x.md'), isNull);
      expect(VaultPaths.normalizeRelative('//server/share/x.md'), isNull);
      expect(VaultPaths.normalizeRelative('../../outside.md'), isNull);
      expect(VaultPaths.normalizeRelative('a/../../outside.md'), isNull);
      expect(VaultPaths.normalizeRelative('   '), isNull);
    });
  });

  group('notes subtree boundary', () {
    test('recognises membership', () {
      expect(VaultPaths.isInsideNotes('notes/daily/x.md'), isTrue);
      expect(VaultPaths.isInsideNotes('notes'), isTrue);
      expect(VaultPaths.isInsideNotes('_conflicts/2026/x/local.md'), isFalse);
      expect(VaultPaths.isInsideNotes('.jotit/jotit.db'), isFalse);
      expect(VaultPaths.isInsideNotes('notesfoo/x.md'), isFalse,
          reason: 'a sibling named "notesfoo" must not count as inside');
    });

    test('strips the notes prefix', () {
      expect(VaultPaths.stripNotesPrefix('notes/daily/x.md'), 'daily/x.md');
      expect(VaultPaths.stripNotesPrefix('_conflicts/x/local.md'), isNull);
    });
  });

  group('resolveWithinVault (§9.3)', () {
    const root = r'C:\vault';

    test('resolves a sibling attachment', () {
      final out = VaultPaths.resolveWithinVault(
        vaultRoot: root,
        notePath: 'notes/daily/2024-01-01.md',
        linkTarget: 'attachments/x.png',
      );
      expect(out, isNotNull);
      expect(out, endsWith(p.joinAll(['daily', 'attachments', 'x.png'])));
    });

    test('permits ".." when the result stays inside notes/', () {
      // v2.0 banned "../" outright, which made notes in nested folders unable
      // to reference anything above them. Only the *destination* matters.
      final out = VaultPaths.resolveWithinVault(
        vaultRoot: root,
        notePath: 'notes/projects/jotit/design.md',
        linkTarget: '../../daily/attachments/y.png',
      );
      expect(out, isNotNull);
      expect(out, endsWith(p.joinAll(['daily', 'attachments', 'y.png'])));
    });

    test('rejects links that climb out of the synced subtree', () {
      expect(
        VaultPaths.resolveWithinVault(
          vaultRoot: root,
          notePath: 'notes/daily/2024-01-01.md',
          linkTarget: '../../_conflicts/secret.md',
        ),
        isNull,
      );
      expect(
        VaultPaths.resolveWithinVault(
          vaultRoot: root,
          notePath: 'notes/daily/2024-01-01.md',
          linkTarget: '../../../outside.md',
        ),
        isNull,
      );
    });

    test('rejects Windows reserved device names', () {
      expect(
        VaultPaths.resolveWithinVault(
          vaultRoot: root,
          notePath: 'notes/daily/2024-01-01.md',
          linkTarget: 'attachments/NUL.png',
        ),
        isNull,
      );
      expect(
        VaultPaths.resolveWithinVault(
          vaultRoot: root,
          notePath: 'notes/daily/2024-01-01.md',
          linkTarget: 'attachments/com1.png',
        ),
        isNull,
        reason: 'reserved-name check is case-insensitive',
      );
    });

    test('percent-encoded targets are decoded before validation', () {
      final out = VaultPaths.resolveWithinVault(
        vaultRoot: root,
        notePath: 'notes/daily/2024-01-01.md',
        linkTarget: 'attachments/%E4%B8%AD%E6%96%87.png',
      );
      expect(out, isNotNull);
      expect(out, contains('中文'));
    });
  });

  group('sanitizeSegment (§7.2)', () {
    test('replaces characters illegal on Windows', () {
      expect(VaultPaths.sanitizeSegment(r'a*b?c"d<e>f|g:h'), 'a_b_c_d_e_f_g_h');
    });

    test('truncates on a UTF-8 boundary, never mid-character', () {
      const long = '中文笔记标题';
      final out = VaultPaths.sanitizeSegment(long, maxBytes: 7);
      expect(utf8Length(out), lessThanOrEqualTo(7));
      // Decoding must not have produced replacement characters.
      expect(out.contains('�'), isFalse);
    });

    test('falls back for empty input', () {
      expect(VaultPaths.sanitizeSegment('   '), 'untitled');
      expect(VaultPaths.sanitizeSegment('***'), '___');
    });
  });

  group('ConflictNaming (§7.2)', () {
    final when = DateTime(2026, 1, 8, 14, 23, 5);

    test('formats timestamp-sequence-base', () {
      expect(
        ConflictNaming.directoryName(
          when: when,
          originalPath: 'daily/2024-01-01.md',
          sequence: 1,
        ),
        '20260108-142305-1-2024-01-01',
      );
    });

    test('strips directories and the extension', () {
      expect(
        ConflictNaming.directoryName(
          when: when,
          originalPath: 'projects/jotit/design notes.md',
          sequence: 2,
        ),
        '20260108-142305-2-design notes',
      );
    });

    test('skips taken slots so same-second conflicts cannot overwrite', () {
      final taken = <String>{};
      var seq = 1;
      for (var i = 0; i < 3; i++) {
        seq = ConflictNaming.nextSequence(
          when: when,
          originalPath: 'daily/2024-01-01.md',
          exists: taken.contains,
        );
        taken.add(ConflictNaming.directoryName(
          when: when,
          originalPath: 'daily/2024-01-01.md',
          sequence: seq,
        ));
      }
      expect(seq, 3);
      expect(taken.length, 3);
    });

    test('sanitises a path that would otherwise be illegal', () {
      final name = ConflictNaming.directoryName(
        when: when,
        originalPath: r'daily\we:ird|name.md',
        sequence: 1,
      );
      for (final ch in [':', '|', '*', '?', '"', '<', '>']) {
        expect(name.contains(ch), isFalse, reason: 'illegal char $ch survived');
      }
    });
  });
}

int utf8Length(String s) => s.runes.fold(0, (a, r) => a + (r > 0xFFFF ? 4 : (r > 0x7FF ? 3 : (r > 0xFF ? 2 : 1))));