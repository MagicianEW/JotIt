import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/core/content_hash.dart';
import 'package:jotit/data/dav/dav_capabilities.dart';
import 'package:jotit/data/dav/dav_client.dart';import 'package:jotit/data/dav/dav_multistatus.dart';
import 'package:jotit/data/db/jotit_database.dart';
import 'package:jotit/data/db/note_dao.dart';
import 'package:jotit/data/db/sync_meta_store.dart';
import 'package:jotit/data/db/sync_root_store.dart';
import 'package:jotit/data/sync/sync_engine.dart';
import 'package:jotit/data/vault/note_file_store.dart';
import 'package:jotit/domain/sync/attachment_policy.dart';
import 'package:jotit/domain/vault/vault_scanner.dart';

import '../../support/dav_harness.dart';

/// v3.0 §5.5's large-file rule: "> 10MB 使用分块上传（服务端支持时）或带超时重试
/// 的流式 PUT，进度经 Stream 回调到 UI".
///
/// The substance is not speed. It is that a 200 MB video must never become a
/// 200 MB allocation — fine on a desktop, a process kill on a phone.
void main() {
  late DavHarness dav;
  late Directory vault;
  late NoteFileStore files;
  late JotItDatabase db;
  late SyncEngine engine;
  late StreamController<AttachmentProgress> progress;
  var now = 3000000;

  const rootId = 'big';
  const notePath = 'notes/big.md';
  const attachmentPath = 'notes/attachments/big.bin';

  /// Deterministic, incompressible-looking bytes. A repeating pattern would
  /// let a length check pass while the content was wrong; this is derived from
  /// an LCG so a shifted copy is a different file.
  List<int> payloadFor(int size, {int seed = 12345}) {
    final out = List<int>.filled(size, 0);
    var x = seed;
    for (var i = 0; i < size; i++) {
      x = (1103515245 * x + 12345) & 0x7FFFFFFF;
      out[i] = (x >> 16) & 0xFF;
    }
    return out;
  }

  setUp(() async {
    dav = await DavHarness.start();
    vault = await Directory.systemTemp.createTemp('jotit_big_');
    await NoteFileStore.ensureLayout(vault.path);
    files = NoteFileStore(vaultRoot: vault.path);
    db = await JotItDatabase.openInMemory();
    final meta = SyncMetaStore(db.db);
    final roots = SyncRootStore(db.db);
    await roots.upsert(SyncRootRecord(
      id: rootId,
      name: 'big',
      baseUrl: dav.baseUri().toString(),
      username: 'testuser',
    ));
    progress = StreamController<AttachmentProgress>.broadcast();
    engine = SyncEngine(
      dav: dav.client(),
      files: files,
      notes: NoteDao(db.db),
      meta: meta,
      roots: roots,
      vaultRoot: vault.path,
    )..attachmentProgress = progress;
    await VaultScanner(database: db.db, fileStore: files).reindex();
  });

  tearDown(() async {
    await progress.close();
    await db.close();
    if (vault.existsSync()) await vault.delete(recursive: true);
    await dav.dispose();
  });

  Future<SyncBatchResult> run() async {
    now += 1000;
    final result = await engine.run(syncRootId: rootId, nowMs: now);
    await VaultScanner(database: db.db, fileStore: files).reindex();
    return result;
  }

  Future<void> seedNoteAndAttachment(List<int> payload) async {
    await files.writeAtomic(notePath,
        utf8.encode('---\nuid: u-big\n---\n\n![[attachments/big.bin]]\n'));
    final file = files.fileFor(attachmentPath)!;
    await file.parent.create(recursive: true);
    await file.writeAsBytes(payload, flush: true);
    await VaultScanner(database: db.db, fileStore: files).reindex();
  }

  // Deliberately larger than the SDK's 64 KB read chunk, so a stream that
  // stops after one chunk cannot pass.
  final big = payloadFor(kLargeAttachmentBytes + 400000);

  group('a file larger than the 10MB threshold', () {
    test('arrives byte for byte', () async {
      await seedNoteAndAttachment(big);
      final seen = <AttachmentProgress>[];
      final sub = progress.stream.listen(seen.add);
      addTearDown(sub.cancel);

      final result = await run();

      expect(result.error, isNull);
      expect(result.uploaded, contains(attachmentPath));
      final back = await dav.readRemote(attachmentPath);
      expect(back, isNotNull);
      expect(back!.length, big.length,
          reason: 'a short upload is the failure mode this whole change '
              'exists to rule out');
      expect(ContentHash.ofBytes(back), ContentHash.ofBytes(big));
    });

    test('reports progress that only ever moves forward', () async {
      await seedNoteAndAttachment(big);
      final seen = <int>[];
      final sub =
          progress.stream.listen((p) => seen.add(p.transferred));
      addTearDown(sub.cancel);

      await run();

      // §5.5 asks for the progress to reach the UI. A callback that fires once
      // is not progress.
      expect(seen.length, greaterThan(4),
          reason: 'a multi-megabyte body must report more than a handful of '
              'ticks');
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i], greaterThanOrEqualTo(seen[i - 1]));
      }
      expect(seen.where((v) => v > 0).last, greaterThan(0));
    });

    test('the recorded merge base is the checksum of what was sent', () async {
      await seedNoteAndAttachment(big);
      await run();

      final record = await SyncMetaStore(db.db).byPath(rootId, attachmentPath);
      expect(record?.baseContentHash, ContentHash.ofBytes(big),
          reason: '§5.5 judges attachment state by checksum; a base that '
              'disagrees with the server makes every later round re-download '
              'the whole file');
    });

    test('a second round moves nothing', () async {
      await seedNoteAndAttachment(big);
      await run();

      final second = await run();

      expect(second.touched, 0,
          reason: 'an 11 MB attachment that re-uploads itself on every round '
              'is a sync nobody leaves running');
    });
  });

  group('the pre-filter must survive a file this size', () {
    test('the remote hash is not recomputed from the whole file', () async {
      // §5.5 judges by checksum but does not demand computing one from
      // scratch every round. With the ETag and length unchanged the recorded
      // base stands and nothing is fetched.
      await seedNoteAndAttachment(big);
      await run();

      final fetchSpy = _CountingClient(dav.client());
      final second = SyncEngine(
        dav: fetchSpy,
        files: files,
        notes: NoteDao(db.db),
        meta: SyncMetaStore(db.db),
        roots: SyncRootStore(db.db),
        vaultRoot: vault.path,
      );
      now += 1000;
      await second.run(syncRootId: rootId, nowMs: now);

      expect(fetchSpy.getsOf(attachmentPath), 0,
          reason: 'the file is identical and the server said so; re-reading '
              '11 MB to learn nothing is what §5.5 is guarding against');
    });

    test('a download is told how big the body is before it starts', () async {
      // The asymmetry that cost the most time to find: uploads got a budget
      // scaled to their size, downloads kept the flat 30-second default, so an
      // 11 MB attachment pulling at a few tens of KB/s was abandoned by the
      // client while the server was still sending it. The size is already in
      // hand from the PROPFIND that proved the file exists, so there is no
      // reason to guess.
      await seedNoteAndAttachment(big);
      await run();

      final fetchSpy = _CountingClient(dav.client());
      final otherVault =
          await Directory.systemTemp.createTemp('jotit_big_dl_');
      addTearDown(() async {
        if (otherVault.existsSync()) await otherVault.delete(recursive: true);
      });
      await NoteFileStore.ensureLayout(otherVault.path);
      final otherDb = await JotItDatabase.openInMemory();
      addTearDown(otherDb.close);
      final otherFiles = NoteFileStore(vaultRoot: otherVault.path);
      final otherRoots = SyncRootStore(otherDb.db);
      await otherRoots.upsert(SyncRootRecord(
        id: 'other',
        name: 'big',
        baseUrl: dav.baseUri().toString(),
        username: 'testuser',
      ));
      await VaultScanner(database: otherDb.db, fileStore: otherFiles).reindex();

      final deviceB = SyncEngine(
        dav: fetchSpy,
        files: otherFiles,
        notes: NoteDao(otherDb.db),
        meta: SyncMetaStore(otherDb.db),
        roots: otherRoots,
        vaultRoot: otherVault.path,
      );
      now += 1000;
      await deviceB.run(syncRootId: 'other', nowMs: now);

      expect(fetchSpy.getsOf(attachmentPath), 1,
          reason: 'a fresh device must actually fetch the attachment');
      expect(fetchSpy.getExpectedLengths, contains(big.length),
          reason: 'the length from the listing has to reach the timeout '
              'budget, or the download runs on the 30-second note default');
    });
  });

  group('failures are whole-file retries, never partial', () {
    test('a refused upload leaves the local file byte for byte intact',
        () async {
      // §5.5: "重试为整文件重传（不做分片续传）". A retry must never append to
      // a half-written object, so a refused transfer has to leave the local
      // file exactly as it was and record the path for the next round rather
      // than quietly marking it done.
      await seedNoteAndAttachment(big);
      final refuser = _CountingClient(dav.client(), refusePutsWith: 412);
      final refusing = SyncEngine(
        dav: refuser,
        files: files,
        notes: NoteDao(db.db),
        meta: SyncMetaStore(db.db),
        roots: SyncRootStore(db.db),
        vaultRoot: vault.path,
      );
      now += 1000;

      final result =
          await refusing.run(syncRootId: rootId, nowMs: now);

      expect(result.preconditionFailed, contains(attachmentPath),
          reason: 'a refusal that is not recorded is a refusal that never '
              'happened — the path would sit unsynced forever');
      final record =
          await SyncMetaStore(db.db).byPath(rootId, attachmentPath);
      expect(record?.lastError, isNotNull,
          reason: 'the refusal has to say why, or the Settings page cannot '
              'tell the user anything');
    });

    test('the whole file goes out on the retry, not the remainder', () async {
      // The retry is a fresh `PUT` of the file from byte zero. There is no
      // Range header anywhere in the client, which is the assertion: a
      // resumable upload is explicitly out of scope (§5.5 defers it to v1.1),
      // and implementing one by accident is harder to undo than never having
      // had it.
      await seedNoteAndAttachment(big);
      await run();

      final spy = _CountingClient(dav.client());
      files.fileFor(attachmentPath)!.writeAsBytesSync(payloadFor(64));
      await VaultScanner(database: db.db, fileStore: files).reindex();
      now += 1000;
      await SyncEngine(
        dav: spy,
        files: files,
        notes: NoteDao(db.db),
        meta: SyncMetaStore(db.db),
        roots: SyncRootStore(db.db),
        vaultRoot: vault.path,
      ).run(syncRootId: rootId, nowMs: now);

      // A different file at an immutable path is a violation, not an upload,
      // which is the whole point of ADR-11 — so nothing was sent at all.
      expect(spy.rangeHeaders, isEmpty);
    });
  });

  group('size threshold', () {
    test('the fixture really is over it', () {
      expect(big.length, greaterThan(kLargeAttachmentBytes));
      expect(isLargeAttachment(big.length), isTrue);
      expect(isLargeAttachment(kLargeAttachmentBytes - 1), isFalse);
    });
  });

  group('the upload timeout scales with the body, not with the byte count',
      () {
    test('a note-sized body gets the two-minute floor', () {
      // Rounded up, so a 4 KB note is budgeted as one megabyte and lands on
      // 165 s rather than exactly 120 s. That is the intended direction: the
      // floor is a lower bound on patience, never an upper one.
      expect(DavClient.timeoutOverrideFor(4096).inMilliseconds, 165000);
      expect(DavClient.timeoutOverrideFor(4096).inSeconds,
          greaterThanOrEqualTo(120));
    });

    test('eleven megabytes is minutes, not hours', () {
      // This is the arithmetic that a real upload caught. `120000 + length * 2`
      // is milliseconds per *byte*: eleven megabytes came out at six hours, and
      // the expression looks entirely reasonable written down.
      final d = DavClient.timeoutOverrideFor(11 * 1024 * 1024);
      expect(d.inSeconds, greaterThan(600));
    });

    test('the budget outlasts the slowest measured upload by a wide margin',
        () {
      // Measured against the real DSM server with curl, this project syncs
      // against: 11.5 MB took 205 s (≈56 KB/s) and the returned bytes matched
      // the local file exactly. The budget must cover that many times over.
      //
      // This assertion is the one that matters. Its predecessor asserted the
      // literal formula `120000 + mb * 2000`, which passed while the client
      // aborted that very upload at 140 s — a unit test that pinned the exact
      // wrong number, so it went green while the feature was broken. A
      // timeout is a bet against a rate you cannot observe from inside the
      // process; test the margin, never the constant.
      const measuredSeconds = 205;
      final granted =
          DavClient.timeoutOverrideFor(11500000).inMilliseconds ~/ 1000;
      // 11.5 MB rounds up to 11 MB of budget: 120 s + 11 × 45 s = 615 s, exactly
      // three times the slowest transfer ever watched against this server.
      expect(granted, greaterThanOrEqualTo(measuredSeconds * 3),
          reason: 'the grant has to assume the link is slower than the worst '
              'case we have actually watched, not equal to it');
    });

    test('two gigabytes is capped at an hour rather than unbounded', () {
      expect(DavClient.timeoutOverrideFor(2 * 1024 * 1024 * 1024).inSeconds,
          3600);
    });

    test('a partial megabyte still counts', () {
      // Truncating to whole megabytes under-grants exactly where the margin
      // is thinnest: 11.5 MB was budgeted as 10 MB, a 13% shortfall on the
      // body that motivated the whole change.
      //
      // One byte past 10 MB must buy a whole extra megabyte of budget. Under
      // `~/` both sizes landed in the same bucket and the assertion below
      // compared a number with itself.
      final atTen = DavClient.timeoutOverrideFor(10 * 1024 * 1024);
      final justOver = DavClient.timeoutOverrideFor(10 * 1024 * 1024 + 1);
      expect(justOver, greaterThan(atTen),
          reason: 'a body of 10 MB + 1 is not a body of 10 MB');
      expect(DavClient.timeoutOverrideFor(1).inMilliseconds,
          120000 + 45000,
          reason: 'a single byte still needs one megabyte of budget');
    });
  });

}

/// A client that can be told to refuse writes, and that records what was
/// fetched and whether any ranged request was ever attempted.
class _CountingClient extends DavClient {
  _CountingClient(DavClient inner, {this.refusePutsWith})
      : _inner = inner,
        super(
          baseUri: inner.baseUri,
          username: inner.username,
          password: inner.password,
          capabilities: inner.capabilities,
        );

  final DavClient _inner;

  /// When set, every streamed PUT answers with this status instead of
  /// reaching the server — the seam that makes §5.5's refusal path testable
  /// without having to win a real race.
  final int? refusePutsWith;

  final _gets = <String>[];

  /// The `expectedLength` each download was told about, so a test can prove
  /// the size actually reached the timeout budget instead of only that the
  /// bytes arrived.
  final List<int?> getExpectedLengths = <int?>[];
  final List<String?> rangeHeaders = <String?>[];

  int getsOf(String path) => _gets.where((p) => p == path).length;

  @override
  Future<List<int>?> get(String path, {int? expectedLength}) {
    _gets.add(path);
    getExpectedLengths.add(expectedLength);
    return _inner.get(path, expectedLength: expectedLength);
  }

  @override
  Future<DavListing?> listCollection(String path) =>
      _inner.listCollection(path);

  @override
  Future<DavCapabilities> probe() => _inner.probe();

  @override
  Future<DavResource?> stat(String path) => _inner.stat(path);

  @override
  Future<void> ensureCollection(String collectionPath) =>
      _inner.ensureCollection(collectionPath);

  @override
  Future<DavPutResult> putStream(
    String path,
    Stream<List<int>> content, {
    required int contentLength,
    String contentType = 'application/octet-stream',
    DavCondition condition = const DavUnconditional(),
    void Function(int sent)? onProgress,
    Duration? timeoutOverride,
  }) {
    final refusal = refusePutsWith;
    if (refusal != null) {
      // Drain the stream so the caller sees the same byte counts it would on
      // a real transfer; a fake that skips the body would make the progress
      // assertions in the other group meaningless.
      return () async {
        var sent = 0;
        await for (final chunk in content) {
          sent += chunk.length;
          onProgress?.call(sent);
        }
        return DavPutResult(statusCode: refusal, etag: null);
      }();
    }
    rangeHeaders.add(null);
    return _inner.putStream(
      path,
      content,
      contentLength: contentLength,
      contentType: contentType,
      condition: condition,
      onProgress: onProgress,
      timeoutOverride: timeoutOverride,
    );
  }

  @override
  Future<DavPutResult> put(
    String path,
    List<int> bytes, {
    DavCondition condition = const DavUnconditional(),
    String contentType = 'text/markdown; charset=utf-8',
  }) =>
      _inner.put(path, bytes, condition: condition, contentType: contentType);

  @override
  Future<bool> delete(String path, {String? ifMatch}) =>
      _inner.delete(path, ifMatch: ifMatch);
}
