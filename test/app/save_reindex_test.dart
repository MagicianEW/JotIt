import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/app/vault_session.dart';

/// Isolates the reported "reopened note shows old text" report from the UI:
/// does the note survive its own save in the **index**? The file demonstrably
/// survives (the bytes are on disk after a restart); if the derived index
/// loses the row on save, the list goes empty and every downstream view —
/// including a reopened editor — is reading from a lie.
void main() {
  late Directory root;
  late VaultSession vault;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jotit_save_reindex_');
    vault = await VaultSession.open(root.path);
  });

  tearDown(() async {
    await vault.close();
    if (root.existsSync()) await root.delete(recursive: true);
  });

  test('create → save → the note stays indexed', () async {
    final path = await vault.createNote(title: '123');
    expect(await vault.notes.allActive(limit: 500), hasLength(1),
        reason: 'right after creation the note is indexed');

    final note = await vault.readForEdit(path);
    expect(note, isNotNull);
    final saved = await vault.save(path, '${note!.text}\n新增的一行\n');
    expect(saved, isNotNull, reason: 'the text changed, so bytes were written');

    final list = await vault.notes.allActive(limit: 500);
    expect(list, hasLength(1),
        reason: 'the note must survive its own save in the derived index');
    expect(list.single.path, path);
  });

  test('seeded → edited through save → still indexed', () async {
    await vault.writeRaw('notes/a.md',
        utf8.encode('---\nuid: u-a\ntitle: A\n---\n\n第一版正文\n'));
    await vault.reindex();

    final saved =
        await vault.save('notes/a.md', '---\nuid: u-a\ntitle: A\n---\n\n第一版正文\n\n新增的一行\n');
    expect(saved, isNotNull);

    final list = await vault.notes.allActive(limit: 500);
    expect(list, hasLength(1),
        reason: 'an edit through save must not evict the note from the index');
  });
}

