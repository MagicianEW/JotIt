import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/core/content_hash.dart';
import 'package:jotit/data/dav/dav_capabilities.dart';
import 'package:jotit/data/dav/dav_client.dart';
import 'package:jotit/data/db/jotit_database.dart';
import 'package:jotit/data/db/note_dao.dart';
import 'package:jotit/data/db/sync_meta_store.dart';
import 'package:jotit/data/db/sync_root_store.dart';
import 'package:jotit/data/sync/sync_engine.dart';
import 'package:jotit/data/vault/note_file_store.dart';
import 'package:jotit/domain/sync/attachment_policy.dart';
import 'package:jotit/domain/vault/vault_scanner.dart';

/// §5.5 against the only server we have that disagrees with us on purpose.
///
/// The local harness is written to agree with this client. Synology DSM over
/// Apache mod_dav is not, and §5.5 singles out exactly that class of server:
/// *"同步判据用 checksum（SHA-256）而非 ETag，因为部分服务端对二进制资源的
/// ETag 实现不一致"*. Every claim in this file is therefore a claim about the
/// real server's behaviour on a **binary** resource, which no test double can
/// stand in for.
///
/// Skipped unless `JOTIT_DAV_URL` is set:
///
///   $env:JOTIT_DAV_URL='http://192.168.1.100:35115/webDAV/JotIt/'
///   $env:JOTIT_DAV_USER='testuser'
///   $env:JOTIT_DAV_PASS='...'
///   flutter test test/integration/nas_attachment_sync_test.dart
void main() {
  final baseUrl = Platform.environment['JOTIT_DAV_URL'];
  final user = Platform.environment['JOTIT_DAV_USER'] ?? 'testuser';
  final pass = Platform.environment['JOTIT_DAV_PASS'] ?? '';

  if (baseUrl == null || baseUrl.isEmpty) {
    test('live NAS attachment sync', () {},
        skip: 'JOTIT_DAV_URL is not set');
    return;
  }

  late Directory vault;
  late NoteFileStore files;
  late JotItDatabase db;
  late SyncEngine engine;
  late String rootId;
  var now = 2000000;

  // One scratch collection per run, so a half-finished test cannot scatter
  // files across the user's real `notes/`. Recreated per test rather than per
  // run: a leftover file from the previous test makes the next one's
  // `If-None-Match: *` fail with 412, and a 412 here looks exactly like the
  // "two devices generated the same uuid" case the engine is meant to report.
  late String scratch;
  var scratchSeq = 0;

  /// A real 1×1 PNG. Not arbitrary bytes: the point is that it is a binary
  /// file whose content type the server has to carry, and a PNG is the case
  /// §5.5 was written about.
  final png = Uint8List.fromList(<int>[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
    0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
    0x54, 0x78, 0x9C, 0x63, 0xFC, 0xCF, 0xC0, 0x50,
    0x0F, 0x00, 0x04, 0x85, 0x01, 0x80, 0x84, 0xA9,
    0x8C, 0x21, 0x33, 0x2C, 0x1D, 0x00, 0x00, 0x00,
    0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60,
    0x82,
  ]);

  setUp(() async {
    vault = await Directory.systemTemp.createTemp('jotit_nas_att_');
    await NoteFileStore.ensureLayout(vault.path);
    files = NoteFileStore(vaultRoot: vault.path);
    db = await JotItDatabase.openInMemory();
    rootId = 'att-root';
    scratch = '_att-${DateTime.now().millisecondsSinceEpoch}-${scratchSeq++}';

    // Sweep the previous run's leftovers **before** making a new one.
    //
    // The teardown below cleans up after a run that finishes. It does not run
    // at all when `flutter test` kills a test at its timeout, which is
    // exactly when a scratch collection is most expensive to leave behind —
    // and it lands in the user's real library directory, not in %TEMP%.
    // Three such directories were found there, all from the run that timed
    // out on the 11 MB upload, which is why this sweeps on the way in.
    //
    // The prefix is what makes it safe: nothing a user creates starts with
    // `_att-`, and this only ever deletes collections carrying it.
    await _sweepScratch(Uri.parse(baseUrl), user, pass);

    // The scratch collection has to exist before the engine starts. mod_dav
    // does not create intermediate collections for a deep MKCOL, which the
    // engine relies on being true — it walks down one segment at a time
    // instead — so a test that skipped this would be testing the engine
    // against a server that is not the one being deployed to.
    await _raw('MKCOL', Uri.parse(baseUrl).resolve('$scratch/'), user, pass);

    final meta = SyncMetaStore(db.db);
    await SyncRootStore(db.db).upsert(SyncRootRecord(
      id: rootId,
      name: 'nas',
      // A sub-collection so the run cleans up after itself.
      baseUrl: '$baseUrl${baseUrl.endsWith('/') ? '' : '/'}$scratch/',
      username: user,
    ));

    engine = SyncEngine(
      dav: DavClient(
        baseUri: Uri.parse(
            '$baseUrl${baseUrl.endsWith('/') ? '' : '/'}$scratch/'),
        username: user,
        password: pass,
        // What DSM actually advertises: no collection CTag, but it does
        // evaluate both conditional headers.
        capabilities: DavCapabilities(
          supportsCtag: false,
          supportsIfMatch: true,
          supportsIfNoneMatch: true,
        ),
      ),
      files: files,
      notes: NoteDao(db.db),
      meta: meta,
      roots: SyncRootStore(db.db),
      vaultRoot: vault.path,
    );
    await VaultScanner(database: db.db, fileStore: files).reindex();
  });

  tearDown(() async {
    await db.close();
    if (vault.existsSync()) {
      try {
        await vault.delete(recursive: true);
      } on FileSystemException {
        // A handle left open by a timed-out transfer must not turn the next
        // test into a cascade of unrelated failures.
      }
    }
    await _rmtree(Uri.parse(baseUrl), scratch, user, pass);
  });

  Future<SyncBatchResult> run() async {
    now += 1000;
    final result = await engine.run(syncRootId: rootId, nowMs: now);
    await engine.recordSuccess(syncRootId: rootId, nowMs: now);
    // The engine reads local state through the derived index, and a round
    // that downloaded a note changes what the next round should see.
    await VaultScanner(database: db.db, fileStore: files).reindex();
    return result;
  }

  Future<void> writeNote(String path, String body, {String? uid}) async {
    final fm = StringBuffer('---');
    if (uid != null) fm.write('\nuid: $uid');
    fm.write('\n---');
    await files.writeAtomic(path, utf8.encode('$fm\n\n$body\n'));
    await VaultScanner(database: db.db, fileStore: files).reindex();
  }

  Future<void> writeAttachment(String path, List<int> bytes) async {
    await files.writeAtomic(path, bytes);
    await VaultScanner(database: db.db, fileStore: files).reindex();
  }

  const attachment = 'notes/attachments/6f1a.png';
  const embed = '---\nuid: u-a\n---\n\n![[attachments/6f1a.png]]\n';

  test('a binary attachment survives the round trip byte for byte',
      () async {
    await writeNote('notes/a.md', embed, uid: 'u-a');
    await writeAttachment(attachment, png);

    final result = await run();

    expect(result.error, isNull);
    expect(result.uploaded, contains(attachment));

    // Read it back through the client rather than trusting the upload: this
    // is the only assertion that proves the server stored a *picture* and not
    // a text file that happens to start with the same bytes.
    final back = await engine.dav.get(attachment);
    expect(back, isNotNull);
    expect(ContentHash.ofBytes(back!), ContentHash.ofBytes(png));
  });

  test('the server keeps the content type we sent', () async {
    await writeNote('notes/a.md', embed, uid: 'u-a');
    await writeAttachment(attachment, png);
    await run();

    final stat = await engine.dav.stat(attachment);
    expect(stat, isNotNull);
    expect(stat!.contentType, isNotNull);
    expect(
      stat.contentType!.toLowerCase(),
      anyOf(contains('image/png'), contains('application/octet-stream')),
      reason: 'DSM may normalise the type, but it must not report markdown: '
          'that would mean it stored this as text',
    );
  });

  test('a second round moves nothing, on a server with its own ETag shape',
      () async {
    // The pre-filter trusts the server's length and ETag to avoid re-reading
    // bytes it already has. If DSM's token for a binary resource behaved
    // differently from its token for a note, this is where it would show up:
    // an attachment that re-downloads itself on every round forever.
    await writeNote('notes/a.md', embed, uid: 'u-a');
    await writeAttachment(attachment, png);
    await run();

    final second = await run();

    expect(second.touched, 0,
        reason: 'unchanged attachments must cost a checksum, not a transfer');
    expect(second.error, isNull);
  });

  test('deleting the file here removes it there', () async {
    await writeNote('notes/a.md', embed, uid: 'u-a');
    await writeAttachment(attachment, png);
    await run();

    await (files.fileFor(attachment)!).delete();
    final result = await run();

    expect(result.deleted, contains(attachment));
    expect(await engine.dav.get(attachment), isNull,
        reason: 'ADR-11 makes deletion part of replacing an image; if it did '
            'not propagate, the old picture would return on every round');
  });

  test('bytes rewritten on the far side are reported and left alone',
      () async {
    // mod_dav will happily overwrite an existing resource, which is exactly
    // why this case is reachable at all — and why the engine must refuse to
    // be the thing that does it.
    await writeNote('notes/a.md', embed, uid: 'u-a');
    await writeAttachment(attachment, png);
    await run();

    final other = Uint8List.fromList(png);
    other[other.length - 1] = other.last ^ 0xFF;
    await engine.dav.put(attachment, other);

    final result = await run();

    expect(result.attachmentViolations, contains(attachment),
        reason: 'a rewritten immutable path has to be visible, not silently '
            'resolved in either direction');
    expect(result.conflicts, isEmpty);
    expect(ContentHash.ofBytes((await engine.dav.get(attachment))!),
        ContentHash.ofBytes(other),
        reason: 'the remote copy is left exactly as found');
    expect(ContentHash.ofBytes((await files.readBytesIfPresent(attachment))!),
        ContentHash.ofBytes(png),
        reason: 'and so is the local one');
  });

  test('a file past the 10 MB threshold streams up intact', () async {
    // §5.5's large-file rule, against the only server that matters. A
    // streamed `PUT` declares its `Content-Length` up front rather than
    // chunking, and there is no test double for how mod_dav treats a body
    // that arrives in many pieces: it can accept it and store a short file,
    // which is the failure nobody notices until someone tries to open the
    // attachment.
    const note = 'notes/big.md';
    const big = 'notes/attachments/big.bin';
    final payload = List<int>.generate(kLargeAttachmentBytes + 250000,
        (i) => (i * 31 + (i >> 8)) & 0x7F);

    await writeNote(note, '---\nuid: u-big\n---\n\n![[attachments/big.bin]]\n',
        uid: 'u-big');
    await writeAttachment(big, payload);

    final result = await run();

    expect(result.error, isNull);
    expect(result.uploaded, contains(big));
    final back = await engine.dav.get(big);
    expect(back, isNotNull);
    expect(back!.length, payload.length,
        reason: 'a short upload is the failure this test exists to rule out');
    expect(ContentHash.ofBytes(back), ContentHash.ofBytes(payload));
  },
      // Measured, not guessed: `curl` to this server sustained ~56 KB/s on the
      // way up (500 KB in 9 s, 2 MB in 30 s), so an 11.5 MB body takes about
      // 3 minutes 25. The five minutes here is that plus the download and the
      // surrounding round trips.
      //
      // This bound is also what caught the client-side bug this file now
      // guards: at 140 s the client gave up on a transfer the server was
      // still accepting, and the symptom was a bare timeout with no hint that
      // the two sides disagreed about how long eleven megabytes takes.
      timeout: const Timeout(Duration(minutes: 12)));

  test('a fresh device receives the picture along with the note', () async {    // The direction this whole feature exists for. Device A writes both; a
    // second vault syncs against the same collection and must come away with
    // the note *and* the image, or the note arrives broken with nothing in
    // the UI saying so.
    await writeNote('notes/a.md', embed, uid: 'u-a');
    await writeAttachment(attachment, png);
    await run();

    final otherVault = await Directory.systemTemp.createTemp('jotit_nas_b_');
    addTearDown(() async {
      if (otherVault.existsSync()) await otherVault.delete(recursive: true);
    });
    await NoteFileStore.ensureLayout(otherVault.path);
    final otherDb = await JotItDatabase.openInMemory();
    addTearDown(otherDb.close);
    final otherFiles = NoteFileStore(vaultRoot: otherVault.path);
    final otherMeta = SyncMetaStore(otherDb.db);
    final otherRoots = SyncRootStore(otherDb.db);
    await otherRoots.upsert(SyncRootRecord(
      id: 'b',
      name: 'nas',
      baseUrl: engine.dav.baseUri.toString(),
      username: user,
    ));
    await VaultScanner(database: otherDb.db, fileStore: otherFiles).reindex();

    final deviceB = SyncEngine(
      dav: DavClient(
        baseUri: engine.dav.baseUri,
        username: user,
        password: pass,
        capabilities: const DavCapabilities(
          supportsCtag: false,
          supportsIfMatch: true,
          supportsIfNoneMatch: true,
        ),
      ),
      files: otherFiles,
      notes: NoteDao(otherDb.db),
      meta: otherMeta,
      roots: otherRoots,
      vaultRoot: otherVault.path,
    );

    final result = await deviceB.run(syncRootId: 'b', nowMs: now + 5000);
    await VaultScanner(database: otherDb.db, fileStore: otherFiles).reindex();

    expect(result.error, isNull);
    expect(result.downloaded, contains('notes/a.md'));
    expect(result.downloaded, contains(attachment),
        reason: 'the note arrived; without its picture it is a broken note');
    expect(ContentHash.ofBytes((await otherFiles.readBytesIfPresent(attachment))!),
        ContentHash.ofBytes(png));
  });
}

/// Minimal MKCOL, spoken directly rather than through [DavClient].
///
/// The client under test has no `MKCOL` of its own beyond `ensureCollection`,
/// which deliberately walks one segment at a time because that is the only
/// thing mod_dav honours. Creating the scratch collection is test scaffolding,
/// not app behaviour, so it goes around the client.
Future<void> _raw(String method, Uri uri, String user, String pass) async {
  final client = HttpClient();
  try {
    final req = await client.openUrl(method, uri);
    req.headers.set(
      HttpHeaders.authorizationHeader,
      'Basic ${base64Encode(utf8.encode('$user:$pass'))}',
    );
    final resp = await req.close();
    await resp.drain<void>();
  } finally {
    client.close(force: true);
  }
}

/// Removes [scratch] and everything under it, over the raw protocol.
Future<void> _rmtree(Uri base, String scratch, String user, String pass) async {
  final client = HttpClient()
    ..badCertificateCallback = (_, _, _) => true;
  try {
    final uri = Uri.parse(
        '${base.toString()}${base.toString().endsWith('/') ? '' : '/'}$scratch/');
    final req = await client.getUrl(uri);
    req.headers.set(HttpHeaders.authorizationHeader,
        'Basic ${base64Encode(utf8.encode('$user:$pass'))}');
    req.headers.set('Depth', 'infinity');
    final res = await req.close();
    await res.drain<void>();

    final del = await client.deleteUrl(uri);
    del.headers.set(HttpHeaders.authorizationHeader,
        'Basic ${base64Encode(utf8.encode('$user:$pass'))}');
    final res2 = await del.close();
    await res2.drain<void>();
  } on Object catch (e) {
    // Leaving a scratch collection behind is untidy, not dangerous.
    // ignore: avoid_print
    print('could not remove $scratch: $e');
  } finally {
    client.close(force: true);
  }
}

/// Deletes every leftover `_att-*` collection directly under [base].
///
/// Runs before each test so that a run killed at its timeout does not leave
/// its scratch collections in the user's real library forever. A teardown is
/// the wrong place for this: `flutter test` does not run teardowns for a test
/// it terminates at the timeout, which is precisely the run most likely to
/// have been interrupted part-way through a large transfer.
///
/// Deliberately prefix-scoped. This runs against a directory a person owns,
/// and the only thing standing between a sweeping cleanup and someone's data
/// is that it will not touch a name that does not begin `_att-`.
Future<void> _sweepScratch(Uri base, String user, String pass) async {
  final client = HttpClient()
    ..badCertificateCallback = (_, _, _) => true;
  final auth = 'Basic ${base64Encode(utf8.encode('$user:$pass'))}';
  final root = Uri.parse(
      '${base.toString()}${base.toString().endsWith('/') ? '' : '/'}');
  try {
    final req = await client.openUrl('PROPFIND', root);
    req.headers.set(HttpHeaders.authorizationHeader, auth);
    req.headers.set('Depth', '1');
    final res = await req.close();
    if (res.statusCode != 207) return;
    final body = await res.transform(utf8.decoder).join();

    for (final m in RegExp(r'<[^>]*:?href>([^<]+)</').allMatches(body)) {
      // Every `<D:href>` in a collection listing ends in a slash, and
      // `'a/b/'.split('/').last` is the empty string — so the first version
      // of this swept nothing at all while looking like it worked. `basename`
      // on a trailing-slash path has the same trap.
      final href = Uri.decodeComponent(m.group(1) ?? '');
      final name = href.replaceFirst(RegExp(r'/+$'), '').split('/').last;
      if (name.isEmpty || !name.startsWith('_att-')) continue;
      await _rmtree(root, name, user, pass);
    }
  } on Object catch (e) {
    // Not being able to sweep is a tidiness problem, and must never be the
    // reason a test fails to start.
    // ignore: avoid_print
    print('could not sweep scratch collections: $e');
  } finally {
    client.close(force: true);
  }
}
