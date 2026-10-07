import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/app/providers.dart';
import 'package:jotit/app/vault_session.dart';
import 'package:jotit/main.dart';
import 'package:path/path.dart' as p;

/// The behaviour that has to hold before any of this is worth looking at on a
/// desktop: opening a vault, creating a note, editing it, and getting the same
/// bytes back out.
/// `pumpAndSettle` never returns once a `CircularProgressIndicator` is on
/// screen, because the spinner animates forever. Pump a bounded number of
/// Pumps until `finder` matches, inside `tester.runAsync`.
///
/// Two traps here, both of which make a widget test hang forever rather than
/// fail: `pumpAndSettle` never returns once a `CircularProgressIndicator` is
/// on screen, because the spinner animates forever; and `testWidgets` drives a
/// fake clock, so the real I/O behind the provider (sqflite over an ffi
/// isolate) never completes. A widget test that "passes" without `runAsync`
/// is not testing anything.
Future<void> pumpUntilFound(WidgetTester tester, Finder finder) async {
  await tester.runAsync(() async {
    for (var i = 0; i < 40 && finder.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  });
}

Widget boot(VaultSession vault) => ProviderScope(
      overrides: [vaultProvider.overrideWith((ref) async => vault)],
      child: const JotItApp(),
    );

void main() {
  late Directory root;
  late VaultSession vault;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jotit_app_');
    vault = await VaultSession.open(root.path);
  });

  tearDown(() async {
    await vault.close();
    if (root.existsSync()) await root.delete(recursive: true);
  });

  Future<void> put(String notePath, List<int> bytes) async {
    final f = File(p.join(root.path, p.joinAll(notePath.split('/'))));
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes, flush: true);
  }

  Future<List<int>> get(String notePath) async =>
      File(p.join(root.path, p.joinAll(notePath.split('/')))).readAsBytes();

  group('opening', () {
    test('creates the vault layout', () {
      for (final dir in ['notes', '_conflicts', '.jotit']) {
        expect(Directory(p.join(root.path, dir)).existsSync(), isTrue,
            reason: dir);
      }
    });

    test('creates the database outside notes/', () {
      // A database inside the synced subtree would be uploaded to every
      // device and would come back changed.
      expect(
        Directory(p.join(root.path, 'notes', '.jotit')).existsSync(),
        isFalse,
      );
      expect(vault.db.isOpen, isTrue);
    });

    test('indexes what is already on disk', () async {
      await put('notes/seed.md',
          utf8.encode('---\nuid: u-seed\ntitle: Seed\n---\n\nbody\n'));
      await vault.reindex();
      final note = await vault.notes.byPath('notes/seed.md');
      expect(note, isNotNull);
      expect(note!.title, 'Seed');
      expect(note.uid, 'u-seed');
    });
  });

  group('creating', () {
    test('a new note exists, is indexed and carries a uid', () async {
      final path = await vault.createNote(title: '路线图');

      expect(path, 'notes/路线图.md');
      final note = await vault.notes.byPath(path);
      expect(note, isNotNull);
      final editable = await vault.readForEdit(path);
      expect(editable!.hasUid, isTrue,
          reason: 'ADR-2: identity must be in the file before any sync');
    });

    test('an untitled note still gets a name', () async {
      expect(await vault.createNote(), 'notes/untitled.md');
    });

    test('a title with path separators cannot escape notes/', () async {
      for (final title in [r'..\..\evil', '../../evil', 'a/b']) {
        final path = await vault.createNote(title: title);
        expect(path.startsWith('notes/'), isTrue, reason: title);
        // The separators become underscores, so the name is a single segment.
        // Checking for the substring `..` would be wrong: `.._.._evil.md`
        // contains it without traversing anywhere.
        final segments = path.split('/');
        expect(segments.skip(1), isNot(contains('..')), reason: title);
        expect(segments.every((s) => !s.contains('/')), isTrue);
        expect(
          File(p.join(root.path, p.joinAll(segments))).existsSync(),
          isTrue,
          reason: 'it landed inside the vault',
        );
      }
    });
  });

  group('editing', () {
    test('a save returns the new hash', () async {
      final path = await vault.createNote(title: 'a');
      final editable = await vault.readForEdit(path);
      final hash = await vault.save(path, '${editable!.text}\nnew line\n');
      expect(hash, isNotNull);
      expect(hash!.length, 64, reason: 'SHA-256 hex');
    });

    test('saving identical text writes nothing', () async {
      final path = await vault.createNote(title: 'a');
      final editable = await vault.readForEdit(path);
      expect(await vault.save(path, editable!.text), isNull,
          reason: 'the sync engine reads a hash change as "the user edited it"');
    });

    test('a BOM survives a save', () async {
      await put('notes/bom.md',
          <int>[0xEF, 0xBB, 0xBF, ...utf8.encode('# t\n\nbody\n')]);
      await vault.reindex();

      final editable = await vault.readForEdit('notes/bom.md');
      expect(editable!.hadBom, isTrue);
      await vault.save('notes/bom.md', '${editable.text}added\n');

      final after = await get('notes/bom.md');
      expect(after.sublist(0, 3), [0xEF, 0xBB, 0xBF]);
      expect(utf8.decode(after.sublist(3)), contains('added'));
    });

    test('CRLF survives a save', () async {
      await put('notes/crlf.md', utf8.encode('# t\r\n\r\nbody\r\n'));
      await vault.reindex();

      final editable = await vault.readForEdit('notes/crlf.md');
      expect(editable!.usedCrlf, isTrue);
      await vault.save('notes/crlf.md', '${editable.text}more\r\n');

      final text = utf8.decode(await get('notes/crlf.md'));
      expect(text, contains('\r\n'));
      expect(text.replaceAll('\r\n', '').contains('\n'), isFalse,
          reason: 'a single LF would show up as a whole-file diff everywhere');
    });

    test('LF line endings are not rewritten to CRLF', () async {
      await put('notes/lf.md', utf8.encode('# t\n\nbody\n'));
      await vault.reindex();

      final editable = await vault.readForEdit('notes/lf.md');
      expect(editable!.usedCrlf, isFalse);
      await vault.save('notes/lf.md', '${editable.text}more\n');

      final bytes = await get('notes/lf.md');
      expect(bytes.contains(0x0D), isFalse);
    });

    test('a non-UTF-8 file refuses to open rather than decoding lossily', () async {
      await put('notes/gbk.md', <int>[0xD6, 0xD0, 0xCE, 0xC4, 0x0A]);
      await vault.reindex();

      expect(await vault.readForEdit('notes/gbk.md'), isNull);
    });

    test('saving reindexes so the list reflects the edit', () async {
      final path = await vault.createNote(title: 'a');
      await vault.save(path, '---\nuid: u-x\ntitle: Renamed\n---\n\nbody\n');

      final note = await vault.notes.byPath(path);
      expect(note!.title, 'Renamed');
      expect(note.contentHash, isNotNull);
    });
  });

  group('widget', () {
    // Seeding happens in setUp, never in the test body: a 	estWidgets body
    // runs inside a fake-async zone where real I/O — sqflite over an ffi
    // isolate — never completes, so the test hangs instead of failing.
    testWidgets('the shell builds', (tester) async {
      await tester.pumpWidget(boot(vault));
      await pumpUntilFound(tester, find.text('JotIt'));
      expect(find.text('JotIt'), findsOneWidget);
    });

    testWidgets('an empty vault says so instead of showing a blank list',
        (tester) async {
      await tester.pumpWidget(boot(vault));
      await pumpUntilFound(tester, find.text('库里还没有笔记'));
      expect(find.text('库里还没有笔记'), findsOneWidget);
    });
  });

  group('widget with notes', () {
    setUp(() async {
      await put('notes/alpha.md',
          utf8.encode('---\nuid: u-a\ntitle: Alpha\n---\n\nbody\n'));
      await vault.reindex();
    });

    testWidgets('the home page lists notes from the vault', (tester) async {
      await tester.pumpWidget(boot(vault));
      await pumpUntilFound(tester, find.text('Alpha'));
      expect(find.text('Alpha'), findsOneWidget);
    });

    testWidgets('search filters the list', (tester) async {
      await tester.pumpWidget(boot(vault));
      await pumpUntilFound(tester, find.text('Alpha'));

      await tester.runAsync(() async {
        await tester.enterText(find.byType(TextField).first, 'Alpha');
        await tester.pump(const Duration(milliseconds: 200));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump(const Duration(milliseconds: 200));
      });

      expect(find.text('Alpha'), findsWidgets);
    });
  });
}