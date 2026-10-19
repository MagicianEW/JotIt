import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/app/providers.dart';
import 'package:jotit/app/sync_controller.dart';
import 'package:jotit/app/vault_session.dart';
import 'package:jotit/data/db/sync_root_store.dart';
import 'package:path/path.dart' as p;

import '../support/dav_harness.dart';

/// P1-3: the round moves files on disk; the derived index has to follow.
///
/// The engine's `downloadRemote` writes the file and moves the merge base,
/// but never touches the `notes` table — so a round that downloads ten notes
/// leaves the home page showing none of them until a restart happens to
/// reindex. The controller is the one place that knows a round just finished,
/// so that is where the reindex lives.
void main() {
  late Directory root;
  late Directory priv;
  late VaultSession vault;
  late DavHarness dav;
  late ProviderContainer container;

  const rootId = 'root-1';

  setUp(() async {
    // `flutter_test` installs an HttpOverrides that answers every request
    // with 400; a round that never leaves the machine is not a round.
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = null);

    dav = await DavHarness.start();
    // The engine's first move is an OPTIONS on the collection; a server that
    // answers 400 for a folder it has never heard of fails the round early.
    Directory(p.join(dav.root.path, 'notes')).createSync(recursive: true);

    root = await Directory.systemTemp.createTemp('jotit_sync_ctrl_');
    priv = await Directory.systemTemp.createTemp('jotit_sync_ctrl_priv_');
    vault = await VaultSession.open(root.path, appDataDir: priv);

    await vault.roots.upsert(SyncRootRecord(
      id: rootId,
      name: 'test',
      baseUrl: dav.baseUri().toString(),
      username: 'testuser',
    ));
    final record = (await vault.roots.byId(rootId))!;
    await vault.setPassword(record, 'test');

    container = ProviderContainer(overrides: [
      vaultProvider.overrideWith((ref) async => vault),
    ]);
  });

  tearDown(() async {
    container.dispose();
    await vault.close();
    if (root.existsSync()) await root.delete(recursive: true);
    if (priv.existsSync()) await priv.delete(recursive: true);
    await dav.dispose();
  });

  Future<SyncRunReport?> runRound() =>
      container.read(syncControllerProvider.notifier).run(rootId);

  test('a download round indexes what it downloaded', () async {
    await dav.seedRemote(
        'notes/downloaded.md',
        utf8.encode(
            '---\nuid: u-d\ntitle: Downloaded\n---\n\nfrom the remote\n'));

    expect(await vault.notes.byPath('notes/downloaded.md'), isNull,
        reason: 'nothing has been fetched yet');

    final report = await runRound();

    expect(report, isNotNull);
    expect(report!.result.downloaded, contains('notes/downloaded.md'));

    final row = await vault.notes.byPath('notes/downloaded.md');
    expect(row, isNotNull,
        reason: 'P1-3: 下载的笔记必须进索引，否则首页一篇没有，重启才出现');
    expect(row!.uid, 'u-d');
    expect(row.title, 'Downloaded');
  });

  test('an idle round leaves the index standing', () async {
    await vault.writeRaw(
        'notes/a.md', utf8.encode('---\nuid: u-a\n---\n\nbody\n'));
    await vault.reindex();

    final first = await runRound();
    expect(first!.result.uploaded, contains('notes/a.md'));

    final second = await runRound();
    expect(second!.result.isEmpty, isTrue,
        reason: 'nothing moved, so nothing to report');
    expect(await vault.notes.byPath('notes/a.md'), isNotNull,
        reason: 'the row must survive an idle round');
  });
}
