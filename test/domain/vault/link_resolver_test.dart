import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/domain/entities/parsed_note.dart';
import 'package:jotit/domain/vault/link_resolver.dart';

/// Uids as they really appear in front matter (ADR-2): a uuid. Short readable
/// stand-ins would slip past the resolver's own shape check and test nothing.
const uidIndex = '00000000-0000-4000-8000-000000000001';
const uidRootNotes = '00000000-0000-4000-8000-000000000002';
const uidProjNotes = '00000000-0000-4000-8000-000000000003';
const uidD1 = '00000000-0000-4000-8000-000000000004';
const uidD2 = '00000000-0000-4000-8000-000000000005';
const uidDupeA = '00000000-0000-4000-8000-000000000006';
const uidDupeB = '00000000-0000-4000-8000-000000000007';
const uidTwin1 = '00000000-0000-4000-8000-000000000008';
const uidTwin2 = '00000000-0000-4000-8000-000000000009';
const uidSameMd = '00000000-0000-4000-8000-00000000000a';
const uidSameMarkdown = '00000000-0000-4000-8000-00000000000b';
const uidSpace = '00000000-0000-4000-8000-00000000000c';
const uidPct = '00000000-0000-4000-8000-00000000000d';
const uidNoteInDaily = '00000000-0000-4000-8000-00000000000e';

/// Resolution priority tests (v3.0 §8.1).
///
/// Every branch here answers "which note did the human mean", and the whole
/// conflict-safety story rests on those answers. The resolver is pure, so it is
/// tested as a table against a hand-built [LinkIndex] rather than through a
/// database — a fixture that silently gained or lost a row would be a fixture
/// bug, not a resolver bug, and `expect(index.byStem.length, 10)` guards that.
void main() {
  late LinkIndex index;

  LinkResolution resolve(String source, String target, {bool embed = false}) =>
      LinkResolver.resolve(index, source, link(target, embed: embed));

  setUp(() {
    index = LinkIndex(
      uidToPath: const {
        uidIndex: 'notes/index.md',
        uidRootNotes: 'notes/notes.md',
        uidProjNotes: 'notes/projects/notes.md',
        uidD1: 'notes/daily/2024-01-01.md',
        uidD2: 'notes/daily/2024-01-02.md',
        uidDupeA: 'notes/a/dup.md',
        uidDupeB: 'notes/b/dup.md',
        uidTwin1: 'notes/twin/one.md',
        uidTwin2: 'notes/twin/two.md',
        uidSameMd: 'notes/twin/same.md',
        uidSameMarkdown: 'notes/twin/same.markdown',
        uidSpace: 'notes/my note.md',
        uidPct: 'notes/100%.md',
        uidNoteInDaily: 'notes/daily/here.md',
      },
      pathToUid: const {
        'notes/index.md': uidIndex,
        'notes/notes.md': uidRootNotes,
        'notes/projects/notes.md': uidProjNotes,
        'notes/daily/2024-01-01.md': uidD1,
        'notes/daily/2024-01-02.md': uidD2,
        'notes/a/dup.md': uidDupeA,
        'notes/b/dup.md': uidDupeB,
        'notes/twin/one.md': uidTwin1,
        'notes/twin/two.md': uidTwin2,
        'notes/twin/same.md': uidSameMd,
        'notes/twin/same.markdown': uidSameMarkdown,
        'notes/my note.md': uidSpace,
        'notes/100%.md': uidPct,
        'notes/daily/here.md': uidNoteInDaily,
      },
      byStem: const {
        'index': ['notes/index.md'],
        'notes': ['notes/notes.md', 'notes/projects/notes.md'],
        '2024-01-01': ['notes/daily/2024-01-01.md'],
        '2024-01-02': ['notes/daily/2024-01-02.md'],
        'dup': ['notes/a/dup.md', 'notes/b/dup.md'],
        'one': ['notes/twin/one.md'],
        'two': ['notes/twin/two.md'],
        'same': ['notes/twin/same.md', 'notes/twin/same.markdown'],
        'my note': ['notes/my note.md'],
        '100%': ['notes/100%.md'],
        'here': ['notes/daily/here.md'],
      },
      aliases: <String, String>{},
    );
  });

  group('fixture sanity', () {
    // Guards the tests below: a fixture that lost a row turns "byUniqueName"
    // into "dangling" and the suite still passes while proving nothing.
    test('index has every note', () {
      expect(index.uidToPath.length, 14);
      expect(index.pathToUid.length, 14);
      expect(index.byStem.length, 11);
      for (final entry in index.uidToPath.entries) {
        expect(index.pathToUid[entry.value], entry.key,
            reason: 'uidToPath and pathToUid must be inverse');
      }
    });
  });

  group('tier 1 — explicit uid', () {
    test('resolves a known uid', () {
      final r = resolve('notes/index.md', 'uid:$uidD2');
      expect(r.method, LinkMethod.byUid);
      expect(r.targetNoteId, uidD2);
      expect(r.targetPath, 'notes/daily/2024-01-02.md');
    });

    test('is case-insensitive on both the scheme and the uid', () {
      expect(resolve('notes/index.md', 'UID:${uidD2.toUpperCase()}')
          .targetNoteId, uidD2);
    });

    test('survives surrounding whitespace', () {
      expect(resolve('notes/index.md', ' uid:$uidD2 ').targetNoteId, uidD2);
    });

    test('a well-formed but absent uuid is dangling', () {
      const missing = 'uid:00000000-0000-4000-8000-000000000000';
      final r = resolve('notes/index.md', missing);
      expect(r.method, LinkMethod.dangling);
      expect(r.targetNoteId, isNull);
    });

    test('a malformed uid is dangling, never a URL and never a name guess', () {
      // `uid:typo` is a broken internal link. It must not reach the browser,
      // and it must not fall through to name matching and invent a target.
      for (final bad in ['uid:nope', 'uid:u-d2', 'uid:', 'uid:zz-9999']) {
        final r = resolve('notes/index.md', bad);
        expect(r.method, LinkMethod.dangling, reason: bad);
        expect(r.targetNoteId, isNull, reason: bad);
      }
    });

    test('the reserved namespace shadows a note that shares the prefix', () {
      // A note literally named `uid:weird.md` cannot be linked by name: the
      // prefix is ours. Documented rather than desired, but stable.
      final i2 = LinkIndex(
        pathToUid: const {'notes/index.md': uidIndex},
        byStem: const {
          'uid:weird': ['notes/index.md'],
          'index': ['notes/index.md'],
        },
      );
      expect(
        LinkResolver.resolve(i2, 'notes/index.md', link('uid:weird')).method,
        LinkMethod.dangling,
      );
    });
  });

  group('tier 1.5 — stored disambiguation wins over inference', () {
    test('an alias is honoured before full-path and name matching', () {
      index.aliases[LinkIndex.aliasKey('notes/index.md', 'notes')] =
          'notes/projects/notes.md';
      final r = resolve('notes/index.md', 'notes');
      expect(r.method, LinkMethod.byUid);
      expect(r.targetPath, 'notes/projects/notes.md');
    });

    test('alias lookup is case-insensitive on the alias text', () {
      index.aliases[LinkIndex.aliasKey('notes/index.md', 'Notes')] =
          'notes/projects/notes.md';
      expect(resolve('notes/index.md', 'NOTES').targetPath,
          'notes/projects/notes.md');
    });

    test('an alias to a vanished note falls through instead of crashing', () {
      index.aliases[LinkIndex.aliasKey('notes/index.md', 'gone')] =
          'notes/deleted.md';
      expect(resolve('notes/index.md', 'gone').method, LinkMethod.dangling);
    });
  });

  group('tier 2 — full path', () {
    test('path relative to the note', () {
      final r = resolve('notes/daily/2024-01-01.md', '2024-01-02.md');
      expect(r.method, LinkMethod.byFullPath);
      expect(r.targetPath, 'notes/daily/2024-01-02.md');
    });

    test('path written from the vault root', () {
      final r = resolve('notes/daily/2024-01-01.md', 'notes/index.md');
      expect(r.method, LinkMethod.byFullPath);
      expect(r.targetPath, 'notes/index.md');
    });

    test('bare path from the vault root gains the notes/ prefix', () {
      final r = resolve('notes/index.md', 'projects/notes.md');
      expect(r.method, LinkMethod.byFullPath);
      expect(r.targetPath, 'notes/projects/notes.md');
    });

    test('a deliberate path is never shadowed by a same-named note', () {
      // Both `notes/notes.md` and `notes/projects/notes.md` exist. A bare
      // `[[notes]]` from the root prefers the sibling; the explicit path
      // overrides that preference outright.
      final bare = resolve('notes/index.md', 'notes');
      expect(bare.method, LinkMethod.bySiblingName);
      expect(bare.targetPath, 'notes/notes.md');

      final r = resolve('notes/index.md', 'projects/notes.md');
      expect(r.method, LinkMethod.byFullPath);
      expect(r.targetPath, 'notes/projects/notes.md');
    });

    test('`./` and `..` inside the notes tree are normalised', () {
      final r = resolve('notes/daily/2024-01-01.md', '../index.md');
      expect(r.method, LinkMethod.byFullPath);
      expect(r.targetPath, 'notes/index.md');
    });
  });

  group('tier 3 — sibling name', () {
    test('one candidate in the same directory', () {
      final r = resolve('notes/daily/2024-01-01.md', '2024-01-02');
      expect(r.method, LinkMethod.bySiblingName);
      expect(r.targetNoteId, uidD2);
    });

    test('a stem that is ambiguous globally resolves to the sibling', () {
      // `notes` exists twice globally, once next to the source note.
      final r = resolve('notes/projects/2024-01-01.md', 'notes');
      expect(r.method, LinkMethod.bySiblingName);
      expect(r.targetPath, 'notes/projects/notes.md');
    });
  });

  group('tier 4 — unique name anywhere', () {
    test('one candidate in a different directory', () {
      final r = resolve('notes/index.md', '2024-01-01');
      expect(r.method, LinkMethod.byUniqueName);
      expect(r.targetNoteId, uidD1);
    });

    test('name matching ignores case and the .md suffix', () {
      expect(resolve('notes/index.md', 'INDEX').targetNoteId, uidIndex);
      final r = resolve('notes/a/note.md', 'dup.md');
      expect(r.method, LinkMethod.byFullPath,
          reason: 'with .md it is a path match, resolved one tier earlier');
    });
  });

  group('tier 5 — ambiguous', () {
    test('two candidates, neither in the source directory', () {
      final r = resolve('notes/index.md', 'dup');
      expect(r.method, LinkMethod.ambiguous);
      expect(r.isAmbiguous, isTrue);
      expect(r.targetNoteId, isNull);
      expect(r.candidates, ['notes/a/dup.md', 'notes/b/dup.md']);
    });

    test('two candidates in the *same* directory stay ambiguous', () {
      // `same.md` and `same.markdown` share a stem *and* a directory. There
      // is no sibling preference left to break the tie, so guessing would
      // make the link graph a fiction.
      final r = resolve('notes/twin/sheet.md', 'same');
      expect(r.method, LinkMethod.ambiguous);
      expect(r.targetNoteId, isNull);
      expect(r.candidates,
          ['notes/twin/same.md', 'notes/twin/same.markdown']);
    });

    test('two same-named notes in one directory keep both candidates', () {
      final r = resolve('notes/twin/sheet.md', 'same');
      expect(r.candidates.length, 2);
      expect(r.isResolved, isFalse);
    });

    test('a globally unique name next door is still bySiblingName', () {
      final r = resolve('notes/twin/sheet.md', 'two');
      expect(r.method, LinkMethod.bySiblingName);
      expect(r.targetPath, 'notes/twin/two.md');
    });

    test('candidates are offered for the UI to present', () {
      final r = resolve('notes/daily/2024-01-01.md', 'dup');
      expect(r.candidates.length, 2);
      expect(r.isResolved, isFalse);
    });
  });

  group('tier 6 — external', () {
    test('https URL', () {
      final r = resolve('notes/index.md', 'https://example.com/a?b=c');
      expect(r.method, LinkMethod.external);
      expect(r.targetPath, 'https://example.com/a?b=c');
      expect(r.targetNoteId, isNull);
    });

    test('mailto and other schemes', () {
      expect(resolve('notes/index.md', 'mailto:a@b.c').method,
          LinkMethod.external);
      expect(resolve('notes/index.md', 'obsidian://open?vault=x').method,
          LinkMethod.external);
    });

    test('protocol-relative URL', () {
      expect(resolve('notes/index.md', '//cdn.example.com/x.png').method,
          LinkMethod.external);
    });

    test('an embed of a non-note file', () {
      final r = resolve('notes/daily/2024-01-01.md', 'diagram.png',
          embed: true);
      expect(r.method, LinkMethod.external);
      expect(r.targetPath, 'notes/daily/diagram.png');
    });

    test('a bare non-note filename is a file reference, not a note hunt', () {
      final r = resolve('notes/index.md', 'diagram.png');
      expect(r.method, LinkMethod.external);
      expect(r.targetPath, 'notes/diagram.png');
    });

    test('an extensionless bare name is NOT treated as a file', () {
      // No note and no extension: the file branch must not invent
      // `notes/diagram`, which would render as a broken image embed.
      expect(resolve('notes/index.md', 'diagram').method, LinkMethod.dangling);
    });

    test('a .md file that is not a note resolves as a file', () {
      final r = resolve('notes/index.md', 'readme.md');
      expect(r.method, LinkMethod.external);
      expect(r.targetPath, 'notes/readme.md');
    });

    test('a real .md note wins over the file branch', () {
      final r = resolve('notes/daily/2024-01-01.md', 'here.md');
      expect(r.method, LinkMethod.byFullPath);
      expect(r.targetNoteId, uidNoteInDaily);
    });
  });

  group('tier 7 — dangling', () {
    test('no match anywhere', () {
      final r = resolve('notes/index.md', 'nothing-here');
      expect(r.method, LinkMethod.dangling);
      expect(r.isResolved, isFalse);
      expect(r.candidates, isEmpty);
    });

    test('empty link text', () {
      final r = resolve('notes/index.md', '   ');
      expect(r.method, LinkMethod.dangling);
      expect(r.targetNoteId, isNull);
    });

    test('a link that climbs out of notes/ never resolves', () {
      final r =
          resolve('notes/daily/2024-01-01.md', '../../../../etc/passwd');
      expect(r.method, LinkMethod.dangling);
      expect(r.targetPath, isNull);
    });

    test('an absolute path is never resolved', () {
      expect(resolve('notes/index.md', '/etc/passwd').method,
          LinkMethod.dangling);
      expect(resolve('notes/index.md', r'C:\Windows\System32\config').method,
          LinkMethod.dangling);
    });
  });

  group('percent-encoded targets', () {
    test('a space decodes to a real note', () {
      final r = resolve('notes/a/other.md', 'my%20note');
      expect(r.method, LinkMethod.byUniqueName);
      expect(r.targetPath, 'notes/my note.md');
    });

    test('a malformed escape falls back to the literal text', () {
      // `100%` alone is not a valid escape; it must not throw the link away.
      final r = resolve('notes/a/other.md', '100%');
      expect(r.method, LinkMethod.byUniqueName);
      expect(r.targetPath, 'notes/100%.md');
    });
  });

  group('LinkIndex helpers', () {
    test('stemOf strips only the final extension', () {
      expect(LinkIndex.stemOf('notes/a/archive.tar.gz.md'), 'archive.tar.gz');
      expect(LinkIndex.stemOf('notes/a/noext'), 'noext');
      expect(LinkIndex.stemOf('notes/a/Mixed.Case.md'), 'mixed.case');
    });

    test('displayNameOf keeps the case', () {
      expect(LinkIndex.displayNameOf('notes/a/Mixed.Case.md'), 'Mixed.Case');
      expect(LinkIndex.displayNameOf('notes/a/noext'), 'noext');
    });

    test('aliasKey is stable and lower-cased', () {
      expect(LinkIndex.aliasKey('notes/a.md', 'Target'),
          LinkIndex.aliasKey('notes/a.md', 'target'));
      expect(LinkIndex.aliasKey('notes/a.md', 'x'),
          isNot(LinkIndex.aliasKey('notes/ab.md', 'x')));
    });

    test('candidatesFor is case-insensitive and empty-safe', () {
      expect(index.candidatesFor('DUP').length, 2);
      expect(index.candidatesFor('absent'), isEmpty);
    });

    test('dirOf returns the notes-prefixed directory', () {
      expect(LinkResolver.dirOf('notes/a/b.md'), 'notes/a');
      expect(LinkResolver.dirOf('notes/b.md'), 'notes');
    });
  });
}

/// Builds a link with the parser's guarantees already applied: the resolver
/// only ever sees the target text, never the anchor, block id, or alias.
WikiLink link(String target, {bool embed = false, String? anchor}) =>
    WikiLink(
      target: target,
      isEmbed: embed,
      anchor: anchor,
      blockId: null,
      alias: null,
      start: 0,
      end: target.length + 2,
    );