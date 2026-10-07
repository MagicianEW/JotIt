import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/core/vault_paths.dart';
import 'package:jotit/data/vault/note_file_store.dart';
import 'package:jotit/domain/entities/front_matter_patcher.dart';
import 'package:jotit/domain/vault/placeholder_note.dart';
import 'package:path/path.dart' as p;

/// v3.0 §9.1 step 6 — the note made for a link with no target.
void main() {
  late Directory vault;
  late NoteFileStore store;

  const uid = '00000000-0000-4000-8000-0000000000ff';

  setUp(() async {
    vault = await Directory.systemTemp.createTemp('jotit_ph_');
    store = NoteFileStore(vaultRoot: vault.path);
    await NoteFileStore.ensureLayout(vault.path);
  });

  tearDown(() async {
    if (vault.existsSync()) await vault.delete(recursive: true);
  });

  Future<String> readNote(String notePath) async =>
      utf8.decode((await store.readBytesIfPresent(notePath))!);

  group('plan — where the note goes', () {
    test('a bare name lands beside the linking note', () {
      final p = PlaceholderNoteFactory.plan(
        sourcePath: 'notes/projects/jotit/design.md',
        target: 'roadmap',
      );
      expect(p!.notePath, 'notes/projects/jotit/roadmap.md');
      expect(p.title, 'roadmap');
      expect(p.sanitized, isFalse);
    });

    test('a bare name beside a note in the root stays in the root', () {
      expect(
        PlaceholderNoteFactory.plan(
                sourcePath: 'notes/index.md', target: 'inbox')
            ?.notePath,
        'notes/inbox.md',
      );
    });

    test('an explicit .md is not doubled', () {
      expect(
        PlaceholderNoteFactory.plan(
                sourcePath: 'notes/a.md', target: 'roadmap.md')
            ?.notePath,
        'notes/roadmap.md',
      );
    });

    test('a multi-segment target is vault-rooted, not source-relative', () {
      // `[[projects/jotit/design]]` means what it says. Making it relative to
      // the source would bury a second copy at notes/a/projects/jotit/design.md
      // the first time anyone clicked the link from a different folder.
      final p = PlaceholderNoteFactory.plan(
        sourcePath: 'notes/daily/2024-01-01.md',
        target: 'projects/jotit/design',
      );
      expect(p!.notePath, 'notes/projects/jotit/design.md');
      expect(p.title, 'design', reason: 'the link text, not the full path');
    });

    test('an explicit notes/ prefix is not doubled', () {
      expect(
        PlaceholderNoteFactory.plan(
                sourcePath: 'notes/a.md', target: 'notes/b/c')
            ?.notePath,
        'notes/b/c.md',
      );
    });

    test('a `../` target that stays inside notes/ is honoured', () {
      final p = PlaceholderNoteFactory.plan(
        sourcePath: 'notes/daily/2024-01-01.md',
        target: '../inbox',
      );
      expect(p!.notePath, 'notes/inbox.md');
    });

    test('percent-encoded names are decoded', () {
      expect(
        PlaceholderNoteFactory.plan(
                sourcePath: 'notes/a.md', target: 'my%20note')
            ?.notePath,
        'notes/my note.md',
      );
    });
  });

  group('plan — what must never become a note', () {
    test('URLs, schemes and protocol-relative references', () {
      for (final bad in [
        'https://example.com/a',
        'mailto:a@b.c',
        'obsidian://open?vault=x',
        '//cdn.example.com/x.png',
      ]) {
        expect(
          PlaceholderNoteFactory.plan(sourcePath: 'notes/a.md', target: bad),
          isNull,
          reason: bad,
        );
      }
    });

    test('the reserved uid namespace', () {
      for (final bad in ['uid:$uid', 'uid:anything', 'UID:$uid']) {
        expect(
          PlaceholderNoteFactory.plan(sourcePath: 'notes/a.md', target: bad),
          isNull,
          reason: bad,
        );
      }
    });

    test('attachment targets name bytes, not notes', () {
      for (final bad in ['diagram.png', 'a/b.pdf', 'archive.tar.gz']) {
        expect(
          PlaceholderNoteFactory.plan(sourcePath: 'notes/a.md', target: bad),
          isNull,
          reason: bad,
        );
      }
    });

    test('paths that escape notes/', () {
      for (final bad in [
        '../../etc/passwd',
        '/etc/passwd',
        r'C:\Windows\System32',
        'notes/../../outside',
      ]) {
        expect(
          PlaceholderNoteFactory.plan(sourcePath: 'notes/a/b.md', target: bad),
          isNull,
          reason: bad,
        );
      }
    });

    test('an empty target', () {
      expect(
        PlaceholderNoteFactory.plan(sourcePath: 'notes/a.md', target: '   '),
        isNull,
      );
    });

    test('a source that is not a note', () {
      expect(
        PlaceholderNoteFactory.plan(sourcePath: '_conflicts/x.md', target: 'a'),
        isNull,
      );
    });
  });

  group('plan — name sanitising', () {
    test('illegal characters are refused, not silently renamed', () async {
      // `:` cannot appear in a Windows filename at all, so no note could ever
      // match this link. Creating `a_b_c_d.md` would leave an orphan file and
      // a link that is still broken — the user has to fix the link text.
      for (final bad in ['a:b', 'a*b', 'a?b', 'a<b', 'a>b', 'a|b', 'a"b']) {
        expect(
          PlaceholderNoteFactory.plan(sourcePath: 'notes/a.md', target: bad),
          isNull,
          reason: bad,
        );
      }
    });

    test('an empty name falls back to untitled and says so', () {
      final p = PlaceholderNoteFactory.plan(
        sourcePath: 'notes/a.md',
        target: '...',
      );
      expect(p!.notePath, 'notes/untitled.md');
      expect(p.sanitized, isTrue);
    });

    test('a trailing dot does not alias another note', () {
      // Windows silently strips it: `v1.2.` and `v1.2` are one file, and two
      // links would then fight over a single note.
      expect(
        PlaceholderNoteFactory.plan(sourcePath: 'notes/a.md', target: 'v1.2.')
            ?.notePath,
        'notes/v1.2.md',
      );
      expect(
        PlaceholderNoteFactory.plan(sourcePath: 'notes/a.md', target: 'v1.2 ')
            ?.notePath,
        'notes/v1.2.md',
      );
    });

    test('Windows device names are made creatable', () {
      expect(
        PlaceholderNoteFactory.plan(sourcePath: 'notes/a.md', target: 'CON')
            ?.notePath,
        'notes/CON_.md',
      );
      expect(
        PlaceholderNoteFactory.plan(sourcePath: 'notes/a.md', target: 'nul.md')
            ?.notePath,
        'notes/nul_.md',
      );
    });

    test('a name that sanitises away falls back to untitled', () {
      final p = PlaceholderNoteFactory.plan(
        sourcePath: 'notes/a.md',
        target: '...',
      );
      expect(p!.notePath, 'notes/untitled.md');
      expect(p.sanitized, isTrue);
    });

    test('unicode survives intact', () {
      expect(
        PlaceholderNoteFactory.plan(
                sourcePath: 'notes/a.md', target: '设计 笔记')
            ?.notePath,
        'notes/设计 笔记.md',
      );
    });
  });

  group('create', () {
    test('writes a note that the next index pass can resolve', () async {
      final plan = await PlaceholderNoteFactory.create(
        store: store,
        sourcePath: 'notes/projects/jotit/design.md',
        target: 'roadmap',
        uid: uid,
      );
      expect(plan!.notePath, 'notes/projects/jotit/roadmap.md');

      // The point of the whole feature: after reindex, `[[roadmap]]` from the
      // sibling resolves as a sibling rather than staying dangling.
      final text = await readNote(plan.notePath);
      expect(FrontMatterPatcher.readString(text, 'uid'), uid);
      expect(FrontMatterPatcher.hasUid(text, uid), isTrue);
    });

    test('carries a uid so every device agrees on its identity', () async {
      // ADR-2: identity lives in the file. A placeholder without one would be
      // re-identified differently on each device and fork on the next sync.
      await PlaceholderNoteFactory.create(
          store: store, sourcePath: 'notes/a.md', target: 'b', uid: uid);
      final text = await readNote('notes/b.md');
      expect(text, contains('uid: $uid'));
    });

    test('is marked so the UI can draw it dashed on every device', () async {
      await PlaceholderNoteFactory.create(
          store: store, sourcePath: 'notes/a.md', target: 'b', uid: uid);
      expect(
        FrontMatterPatcher.readString(await readNote('notes/b.md'),
            PlaceholderNoteFactory.markerKey),
        'true',
      );
    });

    test('title comes from the link text, not the filename', () async {
      await PlaceholderNoteFactory.create(
        store: store,
        sourcePath: 'notes/a.md',
        target: 'projects/jotit/design',
        uid: uid,
      );
      expect(
        FrontMatterPatcher.readString(await readNote('notes/projects/jotit/design.md'),
            'title'),
        'design',
      );
    });

    test('an explicit display label wins over the target', () async {
      final plan = await PlaceholderNoteFactory.create(
        store: store,
        sourcePath: 'notes/a.md',
        target: 'projects/jotit/design',
        displayText: 'Q1 路线图',
        uid: uid,
      );
      expect(plan!.title, 'Q1 路线图');
      expect(
        FrontMatterPatcher.readString(
            await readNote('notes/projects/jotit/design.md'), 'title'),
        'Q1 路线图',
      );
    });

    test('never overwrites an existing note', () async {
      // The link resolves by sibling name, so the occupied path is the one
      // beside the source note — not the vault root.
      const existing = '# Mine\n\nreal content\n';
      await store.writeAtomic(
          'notes/projects/jotit/roadmap.md', utf8.encode(existing));

      final plan = await PlaceholderNoteFactory.create(
        store: store,
        sourcePath: 'notes/projects/jotit/design.md',
        target: 'roadmap',
        uid: uid,
      );

      expect(plan, isNull);
      expect(await readNote('notes/projects/jotit/roadmap.md'), existing,
          reason: 'the link resolves to *something*; JotIt does not get to '
              'decide that note is empty enough to be disposable');
    });

    test('does not clobber a placeholder created a moment earlier', () async {
      final first = await PlaceholderNoteFactory.create(
          store: store, sourcePath: 'notes/a.md', target: 'b', uid: uid);
      expect(first, isNotNull);

      final bytesBefore = await store.readBytesIfPresent('notes/b.md');
      final second = await PlaceholderNoteFactory.create(
          store: store, sourcePath: 'notes/a.md', target: 'b', uid: uid);
      expect(second, isNull);
      expect(await store.readBytesIfPresent('notes/b.md'), bytesBefore);
    });

    test('returns null for a target that is not a note', () async {
      expect(
        await PlaceholderNoteFactory.create(
            store: store,
            sourcePath: 'notes/a.md',
            target: 'https://example.com',
            uid: uid),
        isNull,
      );
      expect(
        Directory(VaultPaths.notesRoot(vault.path))
            .listSync()
            .whereType<File>(),
        isEmpty,
      );
    });

    test('writes UTF-8 with LF, since JotIt is the one authoring it', () async {
      await PlaceholderNoteFactory.create(
        store: store,
        sourcePath: 'notes/a.md',
        target: '中文 笔记',
        uid: uid,
      );
      final bytes = (await store.readBytesIfPresent('notes/中文 笔记.md'))!;
      expect(bytes, isNot(contains(0x0D)), reason: 'no stray CR');
      expect(utf8.decode(bytes), contains('中文 笔记'));
    });

    test('creates missing directories', () async {
      final plan = await PlaceholderNoteFactory.create(
        store: store,
        sourcePath: 'notes/a.md',
        target: 'deep/nested/new',
        uid: uid,
      );
      expect(File(p.join(vault.path, 'notes', 'deep', 'nested', 'new.md'))
          .existsSync(), isTrue);
      expect(plan!.notePath, 'notes/deep/nested/new.md');
    });
  });
}