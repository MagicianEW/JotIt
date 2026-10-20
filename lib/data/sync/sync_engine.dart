import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../core/content_hash.dart';
import '../../core/vault_paths.dart';
import '../../data/dav/dav_client.dart';
import '../../data/dav/dav_capabilities.dart';
import '../../data/dav/dav_exception.dart';
import '../../data/db/note_dao.dart';
import '../../data/db/pending_queue.dart';
import '../../data/db/sync_meta_store.dart';
import '../../data/db/sync_root_store.dart';
import '../../domain/entities/front_matter_patcher.dart';
import '../../domain/sync/attachment_policy.dart';
import '../../domain/sync/conflict_writer.dart';
import '../../domain/sync/decision_matrix.dart';
import '../../domain/sync/remote_snapshot.dart';
import '../../domain/sync/sync_session.dart';
import '../../domain/vault/note_mover.dart';
import '../vault/note_file_store.dart';

/// What one session did.
class SyncBatchResult {
  const SyncBatchResult({
    this.downloaded = const <String>[],
    this.uploaded = const <String>[],
    this.deleted = const <String>[],
    this.conflicts = const <String>[],
    this.skipped = const <String>[],
    this.preconditionFailed = const <String>[],
    this.attachmentViolations = const <String>[],
    this.error,
  });

  final List<String> downloaded;
  final List<String> uploaded;
  final List<String> deleted;

  /// Paths whose copies were written to `_conflicts/`. These still need a
  /// person; they are not errors, and they are never auto-cleaned.
  final List<String> conflicts;

  /// Paths deliberately left alone this round.
  final List<String> skipped;

  /// Paths the server refused with 412/409 (§5.3 row 10).
  ///
  /// Reported separately from [skipped] because "left alone on purpose" and
  /// "the server says our base is stale" are opposite situations that happen
  /// to share an empty output list. A path that 412s every round would
  /// otherwise be invisible forever.
  final List<String> preconditionFailed;

  /// Attachments whose bytes differ from the remote copy (§5.5 / ADR-11).
  ///
  /// Separate from [conflicts] because nothing was copied: an immutable path
  /// holding different bytes on the two sides is not a conflict to resolve, it
  /// is an invariant that has been broken by something outside this app. Both
  /// copies are still where they were, and the user is told which path to look
  /// at.
  final List<String> attachmentViolations;

  final String? error;

  bool get isEmpty =>
      downloaded.isEmpty &&
      uploaded.isEmpty &&
      deleted.isEmpty &&
      conflicts.isEmpty;

  int get touched => downloaded.length + uploaded.length + deleted.length;

  @override
  String toString() => 'SyncBatchResult(down ${downloaded.length}, '
      'up ${uploaded.length}, del ${deleted.length}, '
      'conflict ${conflicts.length}, 412 ${preconditionFailed.length}, '
      'attach! ${attachmentViolations.length})';
}

/// One sync session (§5.2).
///
/// The layering the whole design rests on: this class does I/O and *sequence*,
/// `RemoteDiff` decides what changed, `DecisionMatrix` decides what to do about
/// it, and neither of the latter knows what a socket is. A file's verdict is
/// therefore testable without a server, and the engine's job reduces to
/// "gather the values, call the classifier, carry out the answer".
///
/// Invariants enforced here rather than left to the matrix:
///
///  * every conflict action writes its copies **before** anything destructive,
///  * a download and the base move that follows it are committed together,
///  * a path the scanner never saw is never deleted.
class SyncEngine {
  SyncEngine({
    required this.dav,
    required this.files,
    required this.notes,
    required this.meta,
    required this.roots,
    this.queue,
    required this.vaultRoot,
    this.random,
    NoteMover? mover,
  }) : mover = mover ?? NoteMover(vaultRoot: vaultRoot);

  final DavClient dav;
  final NoteFileStore files;
  final NoteDao notes;
  final SyncMetaStore meta;
  final SyncRootStore roots;
  final PendingQueue? queue;
  final String vaultRoot;
  /// Jitter source for the backoff window. Injected so a test can pin both
  /// ends of the range instead of asserting a random number was plausible.
  final Random? random;

  /// Carries `attachments/` folders when a note is renamed by another device
  /// (v3.0 §9.3 rule 4). Injected so a test can drive a collision without
  /// staging megabytes.
  final NoteMover mover;

  /// Where §5.5's progress for a large attachment goes.
  ///
  /// A broadcast controller rather than a callback so the UI can subscribe and
  /// unsubscribe freely — a sync round outlives the screen that started it far
  /// more often than anyone expects, and a callback captured by a disposed
  /// widget is a crash rather than a missing update.
  ///
  /// Null when nobody is listening, which is the common case for a round that
  /// touches no attachment.
  StreamController<AttachmentProgress>? attachmentProgress;

  final SyncStateMachine machine = SyncStateMachine();

  SyncState get state => machine.state;
  bool get isRunning => machine.isRunning;

  /// The subtree that synchronises. Everything else on the server is ignored —
  /// including `_conflicts/`, which is exactly the v2.0 proliferation bug.
  static const String syncedRoot = VaultPaths.notesDirName;

  /// Runs one full session.
  ///
  /// [nowMs] is injected so backoff deadlines and `last_synced_at` are testable
  /// and so a caller can pass a single consistent timestamp for the round.
  Future<SyncBatchResult> run({
    required String syncRootId,
    required int nowMs,
    DavCapabilities? capabilities,
  }) async {
    // Single-flight: if a session is already in flight the second caller gets
    // the running state back rather than starting a concurrent round. Checked
    // before the trigger, because once the first session has left `idle` a
    // trigger is simply an event it does not handle.
    if (machine.isRunning) return const SyncBatchResult();
    machine.apply(SyncEvent.trigger);

    var result = const SyncBatchResult();
    try {
      // Probing updates the client's capability profile, which put consults
      // before it will send an If-Match at all.
      if (capabilities != null) dav.capabilities = capabilities;
      await dav.probe();
      machine.apply(SyncEvent.probed);

      // Read before the walk, not after: the walk needs it to tell "the
      // server will not talk about the synced root" apart from "the synced
      // root is genuinely empty" (P0-4).
      final base = await meta.allForRoot(syncRootId);
      final snapshot = await _walk(syncRootId: syncRootId, base: base);
      if (snapshot.collectionCtag == null) {
        // A server with no CTag stays in `remoteScan` for the full walk and
        // only moves on once the listing is in hand — the §5.2 self-loop.
        machine.apply(SyncEvent.remoteScanDegraded);
      }
      machine.apply(SyncEvent.remoteScanned);
      machine.apply(SyncEvent.localScanned);

      final localPaths = (await notes.allActive()).map((n) => n.path).toList();
      final localAttachments = await _referencedAttachmentPaths();

      final q = queue;
      final backlog = q != null && await q.countPending(syncRootId) > 0;
      if (backlog) {
        // CTag or not, queued work must reach the server. Skipping the drain
        // because the remote looks unchanged is how offline edits were lost.
        machine.apply(SyncEvent.queueReady);
        machine.apply(SyncEvent.queueEmpty);
        machine.apply(SyncEvent.localScanned);
      }

      final changes = RemoteDiff.between(snapshot, base);

      // A local note with no base row has never been uploaded. Calling the
      // round "nothing to do" on those is what leaves a new note sitting on
      // the device forever.
      final unsyncedLocal = <String>[];
      final locallyEdited = <String>[];
      for (final p in localPaths) {
        final record = await meta.byPath(syncRootId, p);
        if (record == null) {
          unsyncedLocal.add(p);
          continue;
        }
        // A purely local edit produces no remote change at all, so the remote
        // diff cannot see it. Comparing each note's own bytes against its base
        // hash is the only way an offline edit reaches the server.
        final bytes = await files.readBytesIfPresent(p);
        if (bytes == null) continue;
        if (ContentHash.ofBytes(bytes) != record.baseContentHash) {
          locallyEdited.add(p);
        }
      }

      // P1-5: the short-circuit has to mean "there is genuinely nothing to
      // do". `_hasUnsyncedAttachments` answers "is there work left?", so it
      // enters the condition negated.
      //
      // The un-negated version was wrong in both directions at once: an
      // entirely idle vault never short-circuited (every round paid for a
      // full exchange), and — worse — a vault whose notes were all synced but
      // which held one attachment with no base row *did* short-circuit, which
      // is exactly the state a freshly pasted image sits in. The new
      // attachment was shelved indefinitely: the server looked unchanged, the
      // notes looked unchanged, and the one thing that had work to do was
      // the very thing the condition was checking for.
      //
      // Negating it opened a second hole, which the pending-local-deletion
      // check below closes: a file that is gone from this device but still
      // on the server is work too, and the remote diff cannot see it.
      final pendingLocalDeletion =
          await _hasPendingLocalDeletion(base, localPaths.toSet());
      final nothingToDo =
          changes.isEmpty &&
              !backlog &&
              unsyncedLocal.isEmpty &&
              locallyEdited.isEmpty &&
              !_hasUnsyncedAttachments(localAttachments, base) &&
              !pendingLocalDeletion;
      if (nothingToDo) {
        machine.apply(SyncEvent.queueEmpty);
        machine.apply(SyncEvent.backoffElapsed);
        return result;
      }

      machine.apply(SyncEvent.diffBuilt);
      result = await _exchange(
        syncRootId: syncRootId,
        snapshot: snapshot,
        base: base,
        localPaths: localPaths,
        localAttachments: localAttachments,
        nowMs: nowMs,
      );
      machine.apply(SyncEvent.batchCompleted);
      machine.apply(SyncEvent.reindexed);
      return result;
    } on DavException catch (e) {
      final event = e.isAuth ? SyncEvent.authFailed : SyncEvent.networkError;
      machine.apply(event);
      return SyncBatchResult(error: e.toString());
    } on Object catch (e) {
      machine.apply(SyncEvent.networkError);
      return SyncBatchResult(error: e.toString());
    } finally {
      // P1-4: every round converges to idle, however it ended. The early
      // "nothing to do" return used to leave the machine in `diffBuild` and
      // a failure left it in `backoff`; since only `idle` accepts a
      // trigger, the same instance could never run again — a single-flight
      // lock that never unlocks. The backoff deadline that actually guards
      // a retry lives in `sync_roots.next_attempt_at` (see [recordFailure]);
      // this machine only has to stop claiming a session is in flight when
      // none is.
      machine.reset();
    }
  }

  /// Walks the synced subtree one collection at a time.
  ///
  /// Depth is 1 per collection rather than infinity: the client refuses
  /// `Depth: infinity` because most servers answer 403, and the per-directory
  /// listing is also what the CTag-free fallback path in §6.2 describes.
  ///
  /// [base] is this root's merge-base rows, and it is what makes a 404 on the
  /// synced root itself readable (P0-4): with a base the server has held the
  /// subtree once, so a 404 is far more likely to be a misconfigured
  /// baseUrl or a moved share than a deliberate deletion of everything.
  Future<RemoteSnapshot> _walk({
    required String syncRootId,
    required List<SyncMetaRecord> base,
  }) async {
    final entries = <String, RemoteEntry>{};
    final unknownCollections = <String>{};
    String? ctag;
    var probedCtag = false;

    final pending = <String>[syncedRoot];
    final visited = <String>{};

    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      if (!visited.add(current)) continue;

      final listing = await dav.listCollection(current);
      if (listing == null) {
        // "The listing came back 404" is not the same fact at the root and
        // below it.
        if (current == syncedRoot) {
          if (base.isNotEmpty) {
            // Reading this as "an empty collection" makes matrix row 4
            // propagate a remote deletion for every note the vault has ever
            // synced — one mistyped baseUrl empties the vault. Abort
            // instead: the round fails with an error the UI can show, and
            // nothing is deleted or uploaded.
            throw SyncRootUnreachableException(syncRootId);
          }
          // Never synced: an absent root is a legitimate first round
          // against an empty server, and the uploads below create it.
          continue;
        }
        // A subfolder that will not list is *unknown*, not deleted: the
        // server never said the folder or its contents were gone. Anything
        // under it is left alone this round — see
        // [RemoteSnapshot.unknownCollections].
        unknownCollections.add(current);
        continue;
      }

      if (ctag == null) {
        probedCtag = true;
        ctag = listing.collectionCtag;
      }

      for (final r in listing.resources) {
        if (r.path.isEmpty) continue;
        if (!VaultPaths.isInsideNotes(r.path)) continue;
        // The queried collection itself comes back in its own listing.
        if (r.path == current) continue;

        entries[r.path] = RemoteEntry(
          path: r.path,
          etag: r.etag,
          contentLength: r.contentLength,
          lastModified: r.lastModified,
          isCollection: r.isCollection,
        );
        if (r.isCollection) pending.add(r.path);
      }
    }

    return RemoteSnapshot(
      entries: entries,
      collectionCtag: ctag,
      probedCtag: probedCtag,
      unknownCollections: unknownCollections,
    );
  }

  Future<SyncBatchResult> _exchange({
    required String syncRootId,
    required RemoteSnapshot snapshot,
    required List<SyncMetaRecord> base,
    required List<String> localPaths,
    required List<String> localAttachments,
    required int nowMs,
  }) async {
    final downloaded = <String>[];
    final uploaded = <String>[];
    final deleted = <String>[];
    final conflicts = <String>[];
    final skipped = <String>[];

    // 412/409 is tracked apart from `skipped` — see SyncBatchResult.
    final preconditionFailed = <String>[];

    // §5.5: an immutable file has no edit conflict, so it gets its own
    // classifier instead of the note matrix. Sending one through that matrix
    // is not a graceful degradation — a binary has no `uid` on either side,
    // which is precisely that matrix's "refusing to overwrite without
    // identity" row, so every attachment in the vault became a conflict copy
    // while the note embedding it synced perfectly.
    final attachmentViolations = <String>[];

    // Everything the matrix could have an opinion about: what the remote has,
    // what the base remembers, and **what only this device has**. Leaving the
    // local-only paths out is the bug that makes a brand new note invisible:
    // it is in neither the snapshot nor `sync_meta`, so it never reaches
    // `classifySync` and never gets uploaded.
    //
    // Attachments have to be in this set for the same reason and for one more:
    // they are not rows in `notes`, so before they were added here a picture
    // pasted into a note was invisible to the engine in *both* directions —
    // local-only ones never left the device, and a vault's worth of images
    // could not be uploaded at all.
    final referenced = localAttachments.toSet();
    final paths = <String>{
      ...snapshot.entries.keys,
      ...base.map((r) => r.path),
      ...localPaths,
      ...localAttachments,
    }.toList()
      ..sort();

    for (final path in paths) {
      // P0-4: a folder whose listing 404'd this round leaves its whole
      // subtree unknown. Nothing under it is uploaded, downloaded or —
      // above all — deleted: "the server would not answer" is not "the
      // remote deleted it". Even a brand new local note inside waits for
      // the folder to answer again rather than racing a server that may
      // still hold the old contents.
      if (snapshot.isUnderUnknownCollection(path)) {
        skipped.add(path);
        continue;
      }

      final remote = snapshot.entries[path];
      if (remote != null && remote.isCollection) continue;

      final record = await meta.byPath(syncRootId, path);

      if (VaultPaths.isAttachmentPath(path)) {
        final outcome = await _syncAttachment(
          path: path,
          remote: remote,
          record: record,
          syncRootId: syncRootId,
          nowMs: nowMs,
          referencedByANote: referenced.contains(path),
          // P1-3: "this vault has synced this path before" is what the base
          // row records — not "a note currently references it". A deleted
          // attachment's `sync_meta` row survives (§4.4: the index row
          // outlives the file), and that row is the only thing that tells
          // "another device just sent me this picture" (download) apart
          // from "I had this picture and it is gone" (propagate the
          // deletion). Deriving it from the references instead resurrected
          // a deleted attachment from the server on every single round.
          knownToVault: record != null,
        );
        switch (outcome) {
          case _Outcome.downloaded:
            downloaded.add(path);
            await meta.clearRetry(syncRootId, path);
          case _Outcome.uploaded:
            uploaded.add(path);
            await meta.clearRetry(syncRootId, path);
          case _Outcome.deleted:
            deleted.add(path);
            await meta.clearRetry(syncRootId, path);
          case _Outcome.immutableViolation:
            attachmentViolations.add(path);
          case _Outcome.conflicted:
          case _Outcome.skipped:
            skipped.add(path);
          case _Outcome.retryNextRound:
            preconditionFailed.add(path);
        }
        continue;
      }

      final local = await notes.byPath(path, includeDeleted: true);
      final localBytes = await files.readBytesIfPresent(path);

      final observation = await _observe(
        path: path,
        remote: remote,
        record: record,
        localBytes: localBytes,
        localExists: local != null,
        localDeleted: local?.isDeleted ?? false,
        base: base,
      );
      final decision = classifySync(observation);

      final outcome = await _carryOut(
        decision: decision,
        observation: observation,
        path: path,
        remote: remote,
        record: record,
        localBytes: localBytes,
        syncRootId: syncRootId,
        nowMs: nowMs,
        knownBasePath: _knownBasePathFor(observation, base),
      );

      switch (outcome) {
        case _Outcome.downloaded:
          downloaded.add(path);
          await meta.clearRetry(syncRootId, path);
        case _Outcome.uploaded:
          uploaded.add(path);
          await meta.clearRetry(syncRootId, path);
        case _Outcome.deleted:
          deleted.add(path);
          await meta.clearRetry(syncRootId, path);
        case _Outcome.conflicted:
          conflicts.add(path);
          // The refusal that led here has been superseded: the path now waits
          // on a person, and `conflict_state` is what the Settings page shows.
          // Leaving "HTTP 412" on the row would report the same path in two
          // different "needs attention" lists under two different meanings.
          await meta.clearRetry(syncRootId, path);
          machine.apply(SyncEvent.conflictWritten);
        case _Outcome.skipped:
          skipped.add(path);
        case _Outcome.retryNextRound:
          preconditionFailed.add(path);
        case _Outcome.immutableViolation:
          // Unreachable here: attachment paths are diverted above. Present so
          // that adding an outcome cannot quietly fall through and vanish.
          attachmentViolations.add(path);
      }
    }

    return SyncBatchResult(
      downloaded: downloaded,
      uploaded: uploaded,
      deleted: deleted,
      conflicts: conflicts,
      skipped: skipped,
      preconditionFailed: preconditionFailed,
      attachmentViolations: attachmentViolations,
    );
  }

  /// Attachment paths this vault currently knows about, from the derived index.
  ///
  /// The `attachments` table is the right source and not merely a convenient
  /// one: §9.3 defines an attachment as a file a note references, so the index
  /// already answers the only question that matters — *is this file part of
  /// the vault, or is it something lying around in `attachments/`?* — and it
  /// answers it without a directory walk on every round.
  ///
  /// Files that exist but are referenced by nothing are deliberately absent,
  /// and [classifyAttachment] treats their absence as a reason to leave them
  /// alone in both directions.
  Future<List<String>> _referencedAttachmentPaths() =>
      notes.attachmentPaths();

  /// True when at least one local attachment has no base row, so there is work
  /// to do even when every note is in sync.
  ///
  /// Without this the round would short-circuit on "the remote looks
  /// unchanged", which is precisely the state a newly pasted image sits in:
  /// nothing on the server has moved, and nothing in `notes` has moved either.
  bool _hasUnsyncedAttachments(
      List<String> localAttachments, List<SyncMetaRecord> base) {
    if (localAttachments.isEmpty) return false;
    final based = {for (final r in base) r.path};
    return localAttachments.any((p) => !based.contains(p));
  }

  /// True when a path the base remembers is gone from this device, so the
  /// deletion still has to reach the server.
  ///
  /// A deleted file is invisible to the remote diff: the server still has it
  /// and it still matches the base, so as far as the server is concerned
  /// nothing moved. The only way to see this work is to compare what the
  /// base remembers with what is on disk — without it the idle fast path
  /// swallows the deletion and the file lives on the server forever, with
  /// the user having no way to remove it.
  ///
  /// A note the index no longer lists as active was deleted here, and §5.3
  /// rows 4 and 11 propagate that. An attachment is judged by the file
  /// rather than by the index: §5.5 decides an attachment by whether it is
  /// there, and a file that is still on disk but no longer referenced is
  /// not a deletion.
  Future<bool> _hasPendingLocalDeletion(
      List<SyncMetaRecord> base, Set<String> liveNotes) async {
    for (final r in base) {
      if (liveNotes.contains(r.path)) continue;
      if (VaultPaths.isAttachmentPath(r.path)) {
        final file = files.fileFor(r.path);
        if (file == null || !await file.exists()) return true;
        continue;
      }
      return true;
    }
    return false;
  }

  /// §5.5. Everything about an immutable file that the note matrix must not be
  /// asked to decide.
  Future<_Outcome> _syncAttachment({
    required String path,
    required RemoteEntry? remote,
    required SyncMetaRecord? record,
    required String syncRootId,
    required int nowMs,
    required bool referencedByANote,
    required bool knownToVault,
  }) async {
    final bytes = await files.readBytesIfPresent(path);
    final localExists = bytes != null;
    final localHash = bytes == null ? null : ContentHash.ofBytes(bytes);

    // The remote checksum is only worth a download when a cheap pre-filter
    // cannot rule out a change (§5.5: the *judgement* is SHA-256; the ETag is
    // never the judgement, only a way to avoid re-reading bytes we already
    // know). Skipped entirely when the file is absent locally, because the
    // download case is going to fetch the bytes regardless.
    //
    // P1-7: the pre-filter GET carries the length the PROPFIND already
    // reported, so a large attachment gets the scaled timeout instead of the
    // 30-second default — and a transfer that dies on the way is handled as
    // the attachment failure it is (recorded, retried next round) rather
    // than as an exception that escapes the whole round.
    String? remoteHash;
    if (remote != null && localExists) {
      try {
        remoteHash =
            await _remoteAttachmentHash(remote, record, localBytes: bytes);
      } on DavException catch (e) {
        await meta.notePreconditionFailed(
          syncRootId: syncRootId,
          path: path,
          error: '校验中断：${e.reason}',
          at: nowMs,
        );
        return _Outcome.retryNextRound;
      }
    }

    final decision = classifyAttachment(AttachmentObservation(
      path: path,
      localExists: localExists,
      localHash: localHash,
      remoteExists: remote != null,
      remoteHash: remoteHash,
      baseHash: record?.baseContentHash,
      referencedByANote: referencedByANote,
      knownToVault: knownToVault,
    ));

    switch (decision) {
      case AttachmentAction.nothingToDo:
      case AttachmentAction.orphan:
        return _Outcome.skipped;

      case AttachmentAction.immutableViolation:
        // Both copies stay exactly where they are. See the enum's own docs:
        // overwriting is what C3 forbids, and copying a binary into a
        // directory of Markdown gives the user two unreadable files and no
        // way to tell which one is wrong.
        return _Outcome.immutableViolation;

      case AttachmentAction.download:
        // The size comes from the PROPFIND that already told us this file
        // exists, so the wait scales with the body for free. Without it a
        // large attachment runs into the client's 30-second default and is
        // reported as a failed download on a perfectly good connection.
        List<int>? remote2;
        try {
          remote2 = await dav.get(path, expectedLength: remote?.contentLength);
        } on DavException catch (e) {
          await meta.notePreconditionFailed(
            syncRootId: syncRootId,
            path: path,
            error: '下载中断：${e.reason}',
            at: nowMs,
          );
          return _Outcome.retryNextRound;
        }
        if (remote2 == null) return _Outcome.skipped;
        await files.writeAtomic(path, remote2);
        await meta.commitBase(
          syncRootId: syncRootId,
          path: path,
          // No uid: an attachment has no front matter, and ADR-2's logical
          // identity does not exist for it. Its identity *is* the path, which
          // is sound precisely because ADR-11 makes the content at that path
          // immutable.
          uid: null,
          baseEtag: remote?.etag,
          baseContentHash: ContentHash.ofBytes(remote2),
          at: nowMs,
        );
        return _Outcome.downloaded;

      case AttachmentAction.upload:
        final condition =
            _conditionFor(action: SyncAction.uploadCreate, baseEtag: null);
        // Streamed rather than buffered (v3.0 §5.5). The distinction is not
        // speed: a 200 MB video sent from a buffer is a 200 MB allocation,
        // which is fine on a desktop and a process kill on a phone. The file
        // is hashed on the way past, so it is read once and the checksum that
        // becomes the merge base is the checksum of what actually went over
        // the wire.
        //
        // The try is the other half of §5.5's "失败时记录 next_attempt_at，
        // 重试为整文件重传". A transfer that dies mid-body — a dropped socket, a
        // timeout, a captive portal — never produces a status code, so every
        // refusal branch below is unreachable for it and it arrives as a
        // thrown exception instead. Uncaught, one attachment killed the whole
        // round: every other path in the vault went untouched, the failure was
        // not recorded against the attachment, and the user's only evidence was
        // a sync that reported "failed" without saying what. The local file is
        // untouched either way, which is what makes a whole-file retry safe.
        _StreamedPut upload;
        try {
          upload = await _streamAttachment(path: path, condition: condition);
        } on DavException catch (e) {
          await meta.notePreconditionFailed(
            syncRootId: syncRootId,
            path: path,
            error: '传输中断：${e.reason}',
            at: nowMs,
          );
          return _Outcome.retryNextRound;
        }

        if (upload.put.statusCode == 409) {
          // A missing folder, not a stale base — the same thing a note PUT can
          // hit, and for the same reason: a vault that has never had a
          // subfolder on the server yet.
          await dav.ensureCollection(_parentOf(path));
          _StreamedPut retry;
          try {
            retry =
                await _streamAttachment(path: path, condition: condition);
          } on DavException catch (e) {
            await meta.notePreconditionFailed(
              syncRootId: syncRootId,
              path: path,
              error: '传输中断：${e.reason}',
              at: nowMs,
            );
            return _Outcome.retryNextRound;
          }
          if (retry.put.statusCode == 409 || retry.put.statusCode == 412) {
            await meta.notePreconditionFailed(
              syncRootId: syncRootId,
              path: path,
              error: 'HTTP ${retry.put.statusCode}'
                  '${retry.put.statusCode == 409 ? '（远端缺少所在的文件夹，重试后仍被拒绝）' : '（远端已有同名附件，未覆盖）'}',
              at: nowMs,
            );
            return _Outcome.retryNextRound;
          }
          return _commitAttachment(
            path: path,
            streamed: retry,
            fallbackHash: localHash,
            syncRootId: syncRootId,
            nowMs: nowMs,
          );
        }

        if (upload.put.statusCode == 412) {
          // `If-None-Match: *` said the path already exists. Combined with
          // ADR-11 that means two devices generated the same `{uuid}.{ext}`,
          // which is not a conflict to resolve and must not be resolved by
          // overwriting. Report it and let a person look.
          await meta.notePreconditionFailed(
            syncRootId: syncRootId,
            path: path,
            error: 'HTTP 412（远端已有同名附件，未覆盖）',
            at: nowMs,
          );
          return _Outcome.retryNextRound;
        }

        return _commitAttachment(
          path: path,
          streamed: upload,
          fallbackHash: localHash,
          syncRootId: syncRootId,
          nowMs: nowMs,
        );

      case AttachmentAction.deleteRemote:
        // Unconditional, on purpose. §5.5 judges by checksum and distrusts
        // ETags for binary resources; guarding a delete of an immutable file
        // with a token from that same unreliable implementation buys nothing
        // and, on a server that returns weak tags, makes `DavClient.delete`
        // throw on a path that is perfectly safe to remove.
        try {
          await dav.delete(path);
        } on DavException catch (e) {
          await meta.notePreconditionFailed(
            syncRootId: syncRootId,
            path: path,
            error: 'HTTP ${e.statusCode} on DELETE',
            at: nowMs,
          );
          return _Outcome.retryNextRound;
        }
        await meta.remove(syncRootId, path);
        return _Outcome.deleted;
    }
  }

  /// Sends [path] without ever holding the whole file in memory, hashing on the
  /// way past (v3.0 §5.5).
  ///
  /// Hashing during the read is not an optimisation: the checksum that becomes
  /// the merge base has to be the checksum of what the server holds. Reading
  /// the file twice — once to hash, once to send — opens a window in which the
  /// file changes and the base records a checksum the server never saw.
  Future<_StreamedPut> _streamAttachment({
    required String path,
    required DavCondition condition,
  }) async {
    final file = files.fileFor(path);
    // P1-9: the file can vanish between classification and transfer — the
    // user deletes the picture while the round is running. `length()` then
    // throws a FileSystemException, which is not a DavException and so
    // escaped the whole round. Checking first turns it into the same
    // "nothing was sent" answer the null-file case already gives.
    if (file == null || !await file.exists()) {
      return const _StreamedPut(DavPutResult(statusCode: 404, etag: null), null, 0);
    }

    final length = await file.length();
    final digest = _HashSink();
    final hashing = sha256.startChunkedConversion(digest);

    try {
      final put = await dav.putStream(
        path,
        // `openRead()` with **no** buffer size, and the reason is not
        // tidiness. On Dart 3.13.5 / Windows, `File.openRead(n)` silently
        // drops the last `n` bytes of the file: measured on a 300 000-byte
        // file, `openRead(8192)` delivered 291 808 bytes and `openRead(262144)`
        // delivered 37 856 — the same file read whole with no argument. The
        // upload then dies with "Content size below specified contentLength",
        // or, worse on a chunked server that does not check, ships a truncated
        // attachment that nobody notices until someone tries to open it.
        //
        // The default already reads in 64 KB chunks, which is the bound this
        // code wanted anyway.
        file.openRead().map((chunk) {
          hashing.add(chunk);
          return chunk;
        }),
        contentLength: length,
        contentType: mimeTypeFor(path),
        condition: condition,
        onProgress: (sent) => _publishProgress(AttachmentProgress(
          path: path,
          transferred: sent,
          total: length,
          direction: 'upload',
        )),
      );
      hashing.close();
      return _StreamedPut(put, digest.hex, length);
    } on Object {
      // Closing on the failure path too: an unclosed converter keeps the
      // partial digest alive and reports the stream as unfinished.
      hashing.close();
      rethrow;
    }
  }

  void _publishProgress(AttachmentProgress progress) {
    final stream = attachmentProgress;
    if (stream == null || stream.isClosed) return;
    stream.add(progress);
  }

  Future<_Outcome> _commitAttachment({
    required String path,
    required _StreamedPut streamed,
    required String? fallbackHash,
    required String syncRootId,
    required int nowMs,
  }) async {
    // The checksum of the bytes that actually went over the wire. The fallback
    // is only for the case where the digest never finished, and it is the
    // hash taken from the file's own bytes a moment earlier — not a guess.
    //
    // A 404 is not the server answering: it is the local short-circuit for
    // "the file was gone before anything was sent" (see [_streamAttachment]).
    // Committing a base for bytes the server has never seen is how an
    // attachment reports itself synced while the other device has nothing.
    if (streamed.put.statusCode == 404) return _Outcome.skipped;
    final sha256 = streamed.sha256 ?? fallbackHash;
    if (sha256 == null) return _Outcome.skipped;

    await meta.commitBase(
      syncRootId: syncRootId,
      path: path,
      uid: null,
      baseEtag: streamed.put.etag ?? await _etagAfterWrite(path),
      baseContentHash: sha256,
      at: nowMs,
    );
    final stream = attachmentProgress;
    if (stream != null && !stream.isClosed) {
      // The closing tick reports the same byte count the last progress tick
      // did. Reporting zero here would be the one tick that moves backwards,
      // and a consumer that computes a speed or a percentage from the delta
      // would show a nonsense spike at exactly the wrong moment.
      stream.add(AttachmentProgress(
        path: path,
        transferred: streamed.bytes,
        total: streamed.bytes,
        direction: 'done',
      ));
    }
    return _Outcome.uploaded;
  }

  /// The remote's SHA-256, downloading only when the cheap signals disagree.
  Future<String?> _remoteAttachmentHash(
    RemoteEntry remote,
    SyncMetaRecord? record, {
    required List<int> localBytes,
  }) async {
    final baseHash = record?.baseContentHash;
    if (baseHash != null &&
        remote.contentLength == localBytes.length &&
        remote.etag != null &&
        remote.etag == record!.baseEtag) {
      // Same length and the server's own token is unchanged: the bytes have
      // not moved, so the recorded checksum is still true.
      return baseHash;
    }
    // The size hint comes from the same PROPFIND that produced [remote], so
    // the wait scales with the body for free — without it a large
    // attachment hits the 30-second default and is reported as a failed
    // round on a perfectly good connection.
    final bytes =
        await dav.get(remote.path, expectedLength: remote.contentLength);
    return bytes == null ? null : ContentHash.ofBytes(bytes);
  }

  /// Puts an attachment at its new path and removes it from the old one.
  ///
  /// Written as one unit rather than as "let the next round notice" because
  /// §5.5 makes a path an identity: until both halves happen, the server holds
  /// two copies of an immutable file, and any other device that syncs in
  /// between downloads the stale one back as a duplicate.
  ///
  /// `If-None-Match: *` on the create, for the same reason it is used in
  /// [_syncAttachment]: this path is immutable, so if something is already
  /// there it is not this file being overwritten, and overwriting it would be
  /// exactly the silent overwrite C3 forbids.
  Future<void> _relocateAttachment({
    required String oldPath,
    required String newPath,
    required String syncRootId,
    required int nowMs,
  }) async {
    final bytes = await files.readBytesIfPresent(newPath);
    if (bytes == null) return;

    final condition =
        _conditionFor(action: SyncAction.uploadCreate, baseEtag: null);
    var put = await dav.put(newPath, bytes,
        condition: condition, contentType: mimeTypeFor(newPath));
    if (put.statusCode == 409) {
      await dav.ensureCollection(_parentOf(newPath));
      put = await dav.put(newPath, bytes,
          condition: condition, contentType: mimeTypeFor(newPath));
    }

    if (put.statusCode == 201 || put.statusCode == 204) {
      await meta.commitBase(
        syncRootId: syncRootId,
        path: newPath,
        uid: null,
        baseEtag: put.etag ?? await _etagAfterWrite(newPath),
        baseContentHash: ContentHash.ofBytes(bytes),
        at: nowMs,
      );
    } else {
      // P1-2: 412 means something already owns the new path — the create
      // did not happen. Falling through to the delete below used to destroy
      // the old copy anyway, and that old copy was the *only* remote copy of
      // the attachment: the move left the user with nothing on the server
      // and a broken image on every device. Report the refusal and stop;
      // the old copy stays exactly where it is.
      await meta.notePreconditionFailed(
        syncRootId: syncRootId,
        path: newPath,
        error: 'HTTP ${put.statusCode} while moving $oldPath',
        at: nowMs,
      );
      return;
    }

    // The new copy is in place, so the old one is now redundant.
    // A delete that fails leaves litter rather than loss, and the next round
    // sees the old path with no local file and no note pointing at it.
    //
    // The old base row is deliberately **kept**: this round's snapshot was
    // taken before the delete, so the path is still in the walk, and
    // `sync_meta` holding a row for it is what makes the classifier read
    // "this vault had the file and it is gone" (propagate the deletion)
    // instead of "this device has never seen it" (download it back).
    // Removing the row here resurrected the attachment one round later.
    try {
      await dav.delete(oldPath);
    } on DavException {
      // Already gone counts as success inside `DavClient.delete`.
    }
  }

  Future<SyncObservation> _observe({
    required String path,
    required RemoteEntry? remote,
    required SyncMetaRecord? record,
    required List<int>? localBytes,
    required bool localExists,
    required bool localDeleted,
    required List<SyncMetaRecord> base,
  }) async {
    String? remoteUid;
    if (remote != null) {
      // One GET per candidate path, to read the identity out of the front
      // matter. Renames are found by identity, not by path (matrix row 3), and
      // the identity only exists inside the file.
      final bytes = await dav.get(path);
      if (bytes != null && NoteFileStore.isValidUtf8(bytes)) {
        remoteUid = FrontMatterPatcher.readString(utf8.decode(bytes), 'uid');
      }
    }

    final knownBasePath = _knownBasePathForUid(remoteUid, path, base);

    return SyncObservation(
      path: VaultPaths.stripNotesPrefix(path) ?? path,
      localExists: localExists || localBytes != null,
      localDeleted: localDeleted,
      localUid: record?.uid ??
          (localBytes != null && NoteFileStore.isValidUtf8(localBytes)
              ? FrontMatterPatcher.readString(utf8.decode(localBytes), 'uid')
              : null),
      localContentHash: localBytes == null ? null : ContentHash.ofBytes(localBytes),
      remoteExists: remote != null,
      remoteUid: remoteUid,
      remoteContentHash: null,
      remoteEtag: remote?.etag,
      baseEtag: record?.baseEtag,
      baseContentHash: record?.baseContentHash,
      baseUid: record?.uid,
      knownBasePathForRemoteUid: knownBasePath,
      serverRejectedConditional: false,
    );
  }

  /// The base row a remote rename comes from: the row that recorded this uid
  /// under a *different* path.
  ///
  /// Both sides of the comparison live in the same path space. `sync_meta`
  /// keeps the `notes/` prefix in its paths while `SyncObservation.path` has
  /// it removed, so comparing the two directly is never equal — the row for
  /// the path itself was never excluded, and a rename could end up
  /// "adopting" the path it is already on, leaving the old file behind
  /// next to a second copy of the same note.
  ///
  /// Rows in an unresolved conflict are skipped on both sides of the engine:
  /// their copy set is waiting on a person, so the note they point at is
  /// not a rename source.
  String? _knownBasePathForUid(
      String? uid, String path, List<SyncMetaRecord> base) {
    if (uid == null) return null;
    final here = _pathKey(path);
    for (final r in base) {
      if (r.uid != uid) continue;
      if (r.conflictState.isUnresolved) continue;
      if (_pathKey(r.path) == here) continue;
      return r.path;
    }
    return null;
  }

  /// A vault path as the engine compares paths: relative to the vault and
  /// without the `notes/` prefix.
  String _pathKey(String path) => VaultPaths.stripNotesPrefix(path) ?? path;

  String? _knownBasePathFor(
      SyncObservation observation, List<SyncMetaRecord> base) {
    return _knownBasePathForUid(observation.remoteUid, observation.path, base);
  }

  /// An existing `_conflicts/` directory for a conflict that is still waiting
  /// on a person, or null when there is none.
  ///
  /// Consulted before writing copies so that a conflict which stays open
  /// across rounds does not accumulate one copy set per round. Both records
  /// are checked because a rename moves the base row: the pending conflict
  /// may be recorded against the path the note is leaving.
  Future<String?> _pendingConflictDir(
    SyncMetaRecord? primary,
    SyncMetaRecord? secondary,
  ) async {
    for (final record in [primary, secondary]) {
      if (record == null) continue;
      if (!record.conflictState.isUnresolved) continue;
      final dir = record.conflictCopyDir;
      if (dir == null) continue;
      if (await Directory(p.join(conflictsRoot, dir)).exists()) return dir;
    }
    return null;
  }

  Future<_Outcome> _carryOut({
    required SyncDecision decision,
    required SyncObservation observation,
    required String path,
    required RemoteEntry? remote,
    required SyncMetaRecord? record,
    required List<int>? localBytes,
    required String syncRootId,
    required int nowMs,
    required String? knownBasePath,
  }) async {
    // Copies first. Every conflict branch in here writes to `_conflicts/`
    // before a single byte of the user's file or the remote's changes.
    if (decision.preserveLocal || decision.preserveRemote) {
      // A conflict that is already waiting on a person does not earn a
      // second copy directory every round: the copies are on disk and the
      // base row says where. Reusing them keeps `_conflicts/` from growing
      // by one set of files per sync while the dialog sits unanswered —
      // and the path is still reported through the action switch below.
      final existingDir = await _pendingConflictDir(record, null);
      // The bytes are written into the reused directory rather than
      // skipped. Skipping them was the bug: the divergence moves on while
      // the first copy waits — the remote deletes the note, the local edit
      // changes again — and then the copy on disk describes a round that has
      // already been superseded, while the branch below deletes the file the
      // newest edit lives in. Nothing else holds those bytes.
      final remoteBytes = decision.preserveRemote ? await dav.get(path) : null;
      final keptLocal = decision.preserveLocal ? localBytes : null;
      final sources = ConflictSources(
        localUid: record?.uid,
        localHash: keptLocal == null ? null : ContentHash.ofBytes(keptLocal),
        remoteEtag: remote?.etag,
        remoteHash: remoteBytes == null ? null : ContentHash.ofBytes(remoteBytes),
      );
      final written = existingDir == null
          ? await ConflictWriter.write(
              vaultRoot: vaultRoot,
              originalPath: path,
              localBytes: keptLocal,
              remoteBytes: remoteBytes,
              sources: sources,
              when: DateTime.fromMillisecondsSinceEpoch(nowMs, isUtc: true),
              at: nowMs,
            )
          : await ConflictWriter.writeInto(
              vaultRoot: vaultRoot,
              directoryName: existingDir,
              originalPath: path,
              localBytes: keptLocal,
              remoteBytes: remoteBytes,
              sources: sources,
              when: DateTime.fromMillisecondsSinceEpoch(nowMs, isUtc: true),
              at: nowMs,
            );
      await meta.markConflict(
        syncRootId: syncRootId,
        path: path,
        state: ConflictState.pendingResolution,
        copyDir: written.directory,
        at: nowMs,
      );
    }

    switch (decision.action) {
      case SyncAction.nothingToDo:
      case SyncAction.noopSameContent:
        return _Outcome.skipped;

      case SyncAction.remoteRenameAdopt:
        // P0-1: the remote bytes are pulled down **before** anything moves
        // and before the base is committed. The old code renamed the local
        // file and committed a base built from the remote's ETag plus the
        // *local* hash, having never fetched the body — so a device that
        // had never seen the remote edit believed it was in sync while
        // sitting on stale content, and its next upload silently
        // overwrote the other device's edit with that stale content.
        //
        // C3 decides what happens to the local side: bytes both sides last
        // agreed on (the base) may be replaced without comment, but any
        // local edit that cannot be accounted for is copied to
        // `_conflicts/` first — the same trade `deleteVsModifyPreserveLocal`
        // makes. The rename itself is still not a conflict (the uid proves
        // it is the same note), so the remote content is adopted either way
        // and only the unaccounted-for edit is escalated to a person.
        final remoteBytes = await dav.get(path);
        if (remoteBytes == null) return _Outcome.skipped;
        final remoteHash = ContentHash.ofBytes(remoteBytes);

        String? conflictDir;
        var localBytesPreserved = false;

        if (knownBasePath != null && knownBasePath != path) {
          final from = files.fileFor(knownBasePath);
          final to = files.fileFor(path);
          final oldRecord = await meta.byPath(syncRootId, knownBasePath);

          // A missing File handle and a missing file are the same "not
          // there" to every branch below, so the existence check and the
          // null check are folded into one nullable File.
          final File? fromHere =
              from != null && await from.exists() ? from : null;
          final File? toHere = to != null && await to.exists() ? to : null;

          // Which local file is "the note"? The one at the path the base
          // was recorded against if it is still there; otherwise the copy
          // already sitting at the target.
          final List<int>? localBytes = fromHere != null
              ? await fromHere.readAsBytes()
              : (toHere != null ? await toHere.readAsBytes() : null);

          // "Unsynced" means the local bytes are not the state both sides
          // last agreed on. A missing base row counts as unsynced too:
          // without a recorded merge base nothing about the local bytes can
          // be proven, and C3 does not gamble on unprovable state.
          if (localBytes != null &&
              (oldRecord == null ||
                  oldRecord.baseContentHash == null ||
                  ContentHash.ofBytes(localBytes) != oldRecord.baseContentHash)) {
            localBytesPreserved = true;
            // The copy of the local edit is refreshed even when a directory
            // is being reused: the edit may have changed since the round
            // that wrote it, and this is the only place those bytes exist.
            final dir = conflictDir ?? await _pendingConflictDir(record, oldRecord);
            final written = dir == null
                ? await ConflictWriter.write(
                    vaultRoot: vaultRoot,
                    originalPath: knownBasePath,
                    localBytes: localBytes,
                    remoteBytes: null,
                    sources: ConflictSources(
                      localUid: oldRecord?.uid ?? observation.localUid,
                      localHash: ContentHash.ofBytes(localBytes),
                      remoteEtag: remote?.etag,
                      remoteHash: remoteHash,
                      remoteUid: observation.remoteUid,
                    ),
                    when: DateTime.fromMillisecondsSinceEpoch(nowMs, isUtc: true),
                    at: nowMs,
                  )
                : await ConflictWriter.writeInto(
                    vaultRoot: vaultRoot,
                    directoryName: dir,
                    originalPath: knownBasePath,
                    localBytes: localBytes,
                    remoteBytes: null,
                    sources: ConflictSources(
                      localUid: oldRecord?.uid ?? observation.localUid,
                      localHash: ContentHash.ofBytes(localBytes),
                      remoteEtag: remote?.etag,
                      remoteHash: remoteHash,
                      remoteUid: observation.remoteUid,
                    ),
                    when: DateTime.fromMillisecondsSinceEpoch(nowMs, isUtc: true),
                    at: nowMs,
                  );
            conflictDir = written.directory;
          }

          // P0-3 (engine side): the rename below destroys whatever already
          // sits at the target path. The matrix now keeps a target holding
          // a *different* identity out of this branch entirely, so what can
          // reach here is a stale copy of the same note — but its bytes are
          // still not ours to drop, and the unconditional `to.delete()`
          // that used to sit here destroyed an unsynced local note without
          // a trace.
          if (toHere != null) {
            final doomed = await toHere.readAsBytes();
            localBytesPreserved = true;
            // This is a *different* file from the local edit above, and one
            // conflict directory holds one local side. When both copies exist
            // in the same round the doomed file gets a directory of its own
            // instead of overwriting the edit that was just preserved.
            final pending = await _pendingConflictDir(record, null);
            final dir =
                (pending == null || pending == conflictDir) ? null : pending;
            final written = dir == null
                ? await ConflictWriter.write(
                    vaultRoot: vaultRoot,
                    originalPath: path,
                    localBytes: doomed,
                    remoteBytes: null,
                    sources: ConflictSources(
                      localUid: observation.remoteUid ?? observation.localUid,
                      localHash: ContentHash.ofBytes(doomed),
                      remoteEtag: remote?.etag,
                      remoteHash: remoteHash,
                      remoteUid: observation.remoteUid,
                    ),
                    when: DateTime.fromMillisecondsSinceEpoch(nowMs, isUtc: true),
                    at: nowMs,
                  )
                : await ConflictWriter.writeInto(
                    vaultRoot: vaultRoot,
                    directoryName: dir,
                    originalPath: path,
                    localBytes: doomed,
                    remoteBytes: null,
                    sources: ConflictSources(
                      localUid: observation.remoteUid ?? observation.localUid,
                      localHash: ContentHash.ofBytes(doomed),
                      remoteEtag: remote?.etag,
                      remoteHash: remoteHash,
                      remoteUid: observation.remoteUid,
                    ),
                    when: DateTime.fromMillisecondsSinceEpoch(nowMs, isUtc: true),
                    at: nowMs,
                  );
            // The base row records one directory. The other one is still on
            // disk, and `ConflictWriter.pending` lists it like any other
            // copy set — nothing is lost by the row naming only one.
            conflictDir ??= written.directory;
          }

          if (to != null) await to.parent.create(recursive: true);
          if (toHere != null) await toHere.delete();
          if (fromHere != null && to != null) {
            await fromHere.rename(to.path);
            await meta.remove(syncRootId, knownBasePath);
            // The index row follows the file. Leaving a live row at the old
            // path points the vault at a note that is no longer there, and
            // the next reindex would resurrect it as a new one.
            await notes.softDelete(knownBasePath, at: nowMs);
          }
          // §9.3 rule 4. Renaming the file alone leaves this device with a
          // note whose link points at an `attachments/` folder that stayed
          // behind — a note that reads perfectly and shows a broken image,
          // with nothing anywhere reporting a problem. Doing it after the
          // file moves rather than before is deliberate: the move is what
          // creates the situation.
          final carried = await mover.moveAttachments(
            fromNotePath: knownBasePath,
            toNotePath: path,
          );
          // And finish the move on the server, in the same round. Leaving
          // the upload to "the next round" would mean the path set — which
          // is fixed before the rename happens — never contained the new
          // path, so a single click of 立即同步 would move the picture
          // locally and leave the other device still showing a broken one.
          for (final entry in carried.relocations.entries) {
            await _relocateAttachment(
              oldPath: entry.key,
              newPath: entry.value,
              syncRootId: syncRootId,
              nowMs: nowMs,
            );
          }
        }

        // The identity comes from the *remote* copy. Taking the local base
        // row's uid instead writes null, and the following round then sees a
        // delete plus an unrelated new file rather than a rename.
        //
        // The base records the hash of the bytes actually written below:
        // committing any other hash is what made the next round disagree
        // with the disk and re-transfer a note that was already in sync.
        await files.writeAtomic(path, remoteBytes);
        await meta.commitBase(
          syncRootId: syncRootId,
          path: path,
          uid: observation.remoteUid ?? observation.localUid,
          baseEtag: remote?.etag,
          baseContentHash: remoteHash,
          at: nowMs,
        );
        if (localBytesPreserved && conflictDir != null) {
          // After [commitBase], not before: commitBase rewrites the row and
          // resets `conflict_state`, which would erase the very flag the
          // Settings page reads.
          await meta.markConflict(
            syncRootId: syncRootId,
            path: path,
            state: ConflictState.pendingResolution,
            copyDir: conflictDir,
            at: nowMs,
          );
        }
        // A preserved local edit is reported as a conflict: the vault has
        // converged on the remote content, but a person still has bytes to
        // recover from `_conflicts/`.
        return localBytesPreserved ? _Outcome.conflicted : _Outcome.downloaded;

      case SyncAction.downloadRemote:
        final bytes = await dav.get(path);
        if (bytes == null) return _Outcome.skipped;
        // Written before the base moves, and the base records what the server
        // actually said. Committing the base first would re-download forever;
        // writing the file first without the base is what §5.3 forbids.
        await files.writeAtomic(path, bytes);
        await meta.commitBase(
          syncRootId: syncRootId,
          path: path,
          // A download is by definition a file this device has never seen, so
          // the local uid is null here and the *remote* copy is the only place
          // an identity can come from. Recording null breaks rename detection
          // for every note that arrived from another device — which, in a
          // multi-device vault, is nearly all of them.
          uid: observation.remoteUid ?? observation.localUid,
          baseEtag: remote?.etag,
          baseContentHash: ContentHash.ofBytes(bytes),
          at: nowMs,
        );
        return _Outcome.downloaded;

      case SyncAction.uploadCreate:
      case SyncAction.uploadUpdate:
        final bytes = localBytes;
        if (bytes == null) return _Outcome.skipped;

        final condition = _conditionFor(
          action: decision.action,
          baseEtag: record?.baseEtag,
        );
        var put = await dav.put(path, bytes, condition: condition);

        if (put.statusCode == 409) {
          // 409 from a PUT is a missing folder, not a stale base. On a server
          // that has never seen this vault it comes back for every note, and
          // reporting it as "your base moved" is worse than useless: the
          // counter climbs, nothing is uploaded, and the Settings page
          // describes a race that never happened.
          await dav.ensureCollection(_parentOf(path));
          put = await dav.put(path, bytes, condition: condition);
        }

        if (put.statusCode == 412 || put.statusCode == 409) {
          // §5.3 row 10: our base is stale. Re-classify next round rather than
          // retrying blindly against a token the server has moved past.
          //
          // The count is what stops that from being silent. A path whose base
          // never catches up will 412 on every pass for as long as the vault
          // exists, and an empty "skipped" list is indistinguishable from a
          // vault that simply had nothing to do.
          await meta.notePreconditionFailed(
            syncRootId: syncRootId,
            path: path,
            error: put.statusCode == 409
                ? 'HTTP 409（远端缺少所在的文件夹，重试后仍被拒绝）'
                : 'HTTP ${put.statusCode}',
            at: nowMs,
          );
          return _Outcome.retryNextRound;
        }
        await meta.commitBase(
          syncRootId: syncRootId,
          path: path,
          uid: observation.localUid,
          baseEtag: put.etag ?? await _etagAfterWrite(path),
          baseContentHash: ContentHash.ofBytes(bytes),
          at: nowMs,
        );
        return _Outcome.uploaded;

      case SyncAction.deleteRemote:
        try {
          await dav.delete(path, ifMatch: record?.baseEtag);
        } on DavException catch (e) {
          // A refused conditional DELETE is the same situation as a refused
          // conditional PUT: our base moved under us. Row 11's delete never
          // happened, so nothing is removed locally either.
          if (e.statusCode == 412 || e.statusCode == 409) {
            await meta.notePreconditionFailed(
              syncRootId: syncRootId,
              path: path,
              error: 'HTTP ${e.statusCode} on DELETE',
              at: nowMs,
            );
            return _Outcome.retryNextRound;
          }
          rethrow;
        }
        await meta.remove(syncRootId, path);
        return _Outcome.deleted;

      case SyncAction.forgetSyncMeta:
        await meta.remove(syncRootId, path);
        return _Outcome.skipped;

      case SyncAction.restoreRemoteDelete:
        // The remote is the authority on deletions. Marking the index row
        // without removing the file would let the next reindex resurrect it,
        // and a resurrection looks exactly like the device undoing the
        // deletion by itself.
        await _applyLocalDeletion(path: path, at: nowMs, uid: observation.localUid);
        return _Outcome.deleted;

      case SyncAction.deleteVsModifyPreserveLocal:
        // Copies are already on disk. The local edit becomes a tombstone so
        // the deletion propagates, and the edit stays recoverable.
        await _applyLocalDeletion(path: path, at: nowMs, uid: observation.localUid);
        return _Outcome.deleted;

      case SyncAction.deleteVsModifyPreserveRemote:
        return _Outcome.conflicted;

      case SyncAction.pathCollision:
      case SyncAction.trueConflict:
        return _Outcome.conflicted;

      case SyncAction.retryNextRound:
        return _Outcome.retryNextRound;
    }
  }

  /// Decides what precondition to attach to a write, from what the server has
/// actually admitted about itself.
///
/// Three things are being avoided here, each of which produced a real failure:
///
///  * Sending `If-Match` to a weak-ETag server. RFC 7232 requires strong
///    comparison, so it can never succeed, and `DavClient.put` refuses to
///    send it at all — an unguarded engine threw out of every upload round.
///    The Synology box behind this decision returns `W/"31-..."` for files.
///  * Sending `If-None-Match: *` for an *update*. That turns "we do not have a
///    base token" into "this path must not exist", so an update against a
///    server that never returns an ETag is refused forever as a phantom 412.
///  * Losing atomic create. `If-None-Match: *` compares nothing, so it is
///    perfectly safe on a weak-ETag server and it is what keeps two devices
///    from both creating the same path (matrix row 2).
DavCondition _conditionFor({
  required SyncAction action,
  required String? baseEtag,
}) {
  final caps = dav.capabilities;
  if (action == SyncAction.uploadCreate && caps.supportsIfNoneMatch) {
    return const DavIfAbsent();
  }
  if (baseEtag != null && baseEtag.isNotEmpty &&
      caps.supportsIfMatch && !caps.etagIsWeak) {
    return DavIfMatch(baseEtag);
  }
  // No protection available on this server. §6.3 accepts the narrow
  // lost-update window for the nginx-dav and weak-ETag profiles; what it does
  // not accept is pretending the write was protected.
  return const DavUnconditional();
}

/// The folder [path] lives in, relative to the vault root.
///
/// `notes/a.md` is in `notes`, and a note in a subfolder is in that subfolder:
/// the server has to be asked to create the whole chain, not just the last
/// step, or `notes/sub/a.md` fails on a vault that has never had a subfolder.
String _parentOf(String path) {
  final slash = path.lastIndexOf('/');
  return slash <= 0 ? '' : path.substring(0, slash);
}

/// The server's current ETag for [path], for servers that do not return one
/// on PUT.
///
/// Apache mod_dav — which is what Synology DSM's WebDAV is — answers a
/// successful PUT with no ETag header at all. Committing a null base there
/// means every later round classifies the note as "remote state unknown" and
/// re-downloads bytes it just wrote. One extra PROPFIND is cheaper than that,
/// and the tag is needed before the next conditional write can be considered
/// at all.
Future<String?> _etagAfterWrite(String path) async {
  try {
    return (await dav.stat(path))?.etag;
  } on DavException {
    return null;
  }
}

/// Removes the local file and records the tombstone.
  ///
  /// Both halves are required. The file alone would be resurrected by the next
  /// reindex; the index row alone would leave the file sitting in `notes/`,
  /// which is a deleted note that still opens.
  Future<void> _applyLocalDeletion({
    required String path,
    required int at,
    required String? uid,
  }) async {
    final file = files.fileFor(path);
    if (file != null && await file.exists()) await file.delete();
    await notes.softDelete(path, at: at);
  }

  /// Folds the round's outcome back into `sync_roots`: the CTag that lets the
  /// next round skip the walk, and the backoff deadline that keeps a restart
  /// from resetting the wait.
  Future<void> recordSuccess({
    required String syncRootId,
    required int nowMs,
    String? collectionCtag,
  }) async {
    await roots.saveCollectionCtag(syncRootId, collectionCtag);
    await roots.markSuccess(syncRootId, nowMs);
  }

  Future<void> recordFailure({
    required String syncRootId,
    required int nowMs,
    required int retryCount,
    required String error,
  }) =>
      roots.markFailure(
        id: syncRootId,
        nowMs: nowMs,
        retryCount: retryCount,
        error: error,
        jitterFactor: _jitter(),
      );
  double _jitter() {
    final r = random;
    if (r == null) return 1.0;
    return 0.5 + r.nextDouble();
  }

  /// Vault-absolute path for a `notes/`-relative key, for UI use.
  String? absoluteFor(String notePath) => files.absolutePathFor(notePath);

  /// Directory the engine considers local-only.
  String get conflictsRoot => VaultPaths.conflictsRoot(vaultRoot);
}

/// The synced root itself answered 404 while `sync_meta` still holds a merge
/// base for it (P0-4).
///
/// Reading that 404 as "an empty collection" makes matrix row 4 propagate a
/// remote deletion for every note the vault has ever synced — one tap on
/// 立即同步 with a mistyped baseUrl empties the vault. This is thrown
/// instead, so [SyncEngine.run] returns a result carrying an error and the UI
/// can say the remote state is unknown and the round was aborted. Nothing is
/// deleted and nothing is uploaded.
class SyncRootUnreachableException implements Exception {
  const SyncRootUnreachableException(this.syncRootId);

  final String syncRootId;

  @override
  String toString() =>
      '远端状态不明，已中止：同步根返回 404，但本地存在已同步记录'
      '（root $syncRootId）。请检查 baseUrl 与服务器状态后重试；本轮未做任何改动。';
}

/// A streamed `PUT` and the checksum of what actually went over the wire.
class _StreamedPut {
  const _StreamedPut(this.put, this.sha256, this.bytes);

  final DavPutResult put;

  /// Null when the file vanished between classification and upload.
  final String? sha256;

  /// How many bytes went out, so the closing progress tick can report the
  /// same number rather than resetting to zero.
  final int bytes;
}

/// Collects the finished digest from a chunked SHA-256 conversion.
///
/// `package:crypto` 3.x does not export an accumulator sink, and the reason
/// one is needed here rather than at the end of the transfer is that the
/// checksum has to be of the bytes that went on the wire — see
/// [_streamAttachment].
class _HashSink implements Sink<Digest> {
  Digest? _digest;

  String get hex => _digest?.toString() ?? '';

  @override
  void add(Digest data) => _digest = data;

  @override
  void close() {}
}

enum _Outcome {  downloaded,
  uploaded,
  deleted,
  conflicted,
  skipped,
  retryNextRound,

  /// §5.5: both sides hold different bytes at one immutable attachment path.
  /// Reported, never resolved, never overwritten.
  immutableViolation,
}