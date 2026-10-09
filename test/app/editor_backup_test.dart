import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/app/vault_session.dart';
import 'package:path/path.dart' as p;

/// The rolling backup behind rich-text saves.
///
/// The boss's rule: the backup always holds the *previous* save — one file,
/// overwritten on each rich save, never accumulating. A source-mode save
/// (pure text, byte-faithful by construction) does not create one.
void main() {
  late Directory root;
  late VaultSession vault;

  File bakFile(String notePath) {
    final rel = notePath.startsWith('notes/')
        ? notePath.substring('notes/'.length)
        : notePath;
    return File(p.join(root.path, '.jotit', 'backups', '$rel.bak'));
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jotit_backup_');
    vault = await VaultSession.open(root.path);
    // Seeded with a uid so the setUp reindex does not rewrite the file
    // behind the test's back.
    await vault.writeRaw(
      'notes/a.md',
      utf8.encode('---\nuid: u-a\n---\n\nv1\n'),
    );
    await vault.reindex();
  });

  tearDown(() async {
    await vault.close();
    if (root.existsSync()) await root.delete(recursive: true);
  });

  test('first rich save backs up the version from before it', () async {
    await vault.saveRich('notes/a.md', '---\nuid: u-a\n---\n\nv2\n');

    expect(bakFile('notes/a.md').readAsStringSync(), contains('v1'),
        reason: 'the backup must hold the previous save, not the new one');
  });

  test('each rich save rolls the backup forward, never accumulating',
      () async {
    await vault.saveRich('notes/a.md', '---\nuid: u-a\n---\n\nv2\n');
    await vault.saveRich('notes/a.md', '---\nuid: u-a\n---\n\nv3\n');

    final dir = Directory(p.join(root.path, '.jotit', 'backups'));
    final baks = dir.listSync(recursive: true).whereType<File>().toList();
    expect(baks, hasLength(1),
        reason: 'one rolling backup, not a history');
    expect(baks.single.readAsStringSync(), contains('v2'),
        reason: 'after saving v3, the backup is v2 — the previous save');
    expect(baks.single.readAsStringSync(), isNot(contains('v3')),
        reason: 'the new content must never end up in its own backup');
  });

  test('source-mode saves do not create or roll the backup', () async {
    await vault.saveRich('notes/a.md', '---\nuid: u-a\n---\n\nv2\n');
    await vault.save('notes/a.md', '---\nuid: u-a\n---\n\nv3-source\n');

    expect(bakFile('notes/a.md').readAsStringSync(), contains('v1'),
        reason: 'the backup tracks rich saves only');
  });

  test('saving identical content does not touch the backup', () async {
    await vault.saveRich('notes/a.md', 'v2\n');
    final before = bakFile('notes/a.md').readAsStringSync();

    await vault.saveRich('notes/a.md', 'v2\n'); // no-op save

    expect(bakFile('notes/a.md').readAsStringSync(), before);
  });
}
