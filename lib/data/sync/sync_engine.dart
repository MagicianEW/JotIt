import 'dart:convert';
import 'dart:math';


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
import '../../domain/sync/conflict_writer.dart';
import '../../domain/sync/decision_matrix.dart';
import '../../domain/sync/remote_snapshot.dart';
import '../../domain/sync/sync_session.dart';
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
      'conflict ${conflicts.length}, 412 ${preconditionFailed.length})';
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
  });

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

      final snapshot = await _walk();
      if (snapshot.collectionCtag == null) {
        // A server with no CTag stays in `remoteScan` for the full walk and
        // only moves on once the listing is in hand — the §5.2 self-loop.
        machine.apply(SyncEvent.remoteScanDegraded);
      }
      machine.apply(SyncEvent.remoteScanned);
      machine.apply(SyncEvent.localScanned);

      final base = await meta.allForRoot(syncRootId);
      final localPaths = (await notes.allActive()).map((n) => n.path).toList();

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

      final nothingToDo =
          changes.isEmpty && !backlog && unsyncedLocal.isEmpty && locallyEdited.isEmpty;
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
    }
  }

  /// Walks the synced subtree one collection at a time.
  ///
  /// Depth is 1 per collection rather than infinity: the client refuses
  /// `Depth: infinity` because most servers answer 403, and the per-directory
  /// listing is also what the CTag-free fallback path in §6.2 describes.
  Future<RemoteSnapshot> _walk() async {
    final entries = <String, RemoteEntry>{};
    String? ctag;
    var probedCtag = false;

    final pending = <String>[syncedRoot];
    final visited = <String>{};

    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      if (!visited.add(current)) continue;

      final listing = await dav.listCollection(current);
      if (listing == null) continue; // collection absent; nothing to list

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
    );
  }

  Future<SyncBatchResult> _exchange({
    required String syncRootId,
    required RemoteSnapshot snapshot,
    required List<SyncMetaRecord> base,
    required List<String> localPaths,
    required int nowMs,
  }) async {
    final downloaded = <String>[];
    final uploaded = <String>[];
    final deleted = <String>[];
    final conflicts = <String>[];
    final skipped = <String>[];

    // 412/409 is tracked apart from `skipped` — see SyncBatchResult.
    final preconditionFailed = <String>[];

    // Everything the matrix could have an opinion about: what the remote has,
    // what the base remembers, and **what only this device has**. Leaving the
    // local-only paths out is the bug that makes a brand new note invisible:
    // it is in neither the snapshot nor `sync_meta`, so it never reaches
    // `classifySync` and never gets uploaded.
    final paths = <String>{
      ...snapshot.entries.keys,
      ...base.map((r) => r.path),
      ...localPaths,
    }.toList()
      ..sort();

    final knownPaths = <String>{};
    for (final record in base) {
      final uid = record.uid;
      if (uid != null && uid.isNotEmpty) knownPaths.add(uid);
    }

    for (final path in paths) {
      final remote = snapshot.entries[path];
      if (remote != null && remote.isCollection) continue;

      final record = await meta.byPath(syncRootId, path);
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
      }
    }

    return SyncBatchResult(
      downloaded: downloaded,
      uploaded: uploaded,
      deleted: deleted,
      conflicts: conflicts,
      skipped: skipped,
      preconditionFailed: preconditionFailed,
    );
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

    final knownBasePath = remoteUid == null
        ? null
        : base
            .where((r) =>
                r.uid == remoteUid && r.path != path && !r.conflictState.isUnresolved)
            .map((r) => r.path)
            .firstOrNull;

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

  String? _knownBasePathFor(
      SyncObservation observation, List<SyncMetaRecord> base) {
    final uid = observation.remoteUid;
    if (uid == null) return observation.knownBasePathForRemoteUid;
    return base
        .where((r) => r.uid == uid && r.path != observation.path)
        .map((r) => r.path)
        .firstOrNull;
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
      final remoteBytes = decision.preserveRemote ? await dav.get(path) : null;
      final written = await ConflictWriter.write(
        vaultRoot: vaultRoot,
        originalPath: path,
        localBytes: decision.preserveLocal ? localBytes : null,
        remoteBytes: remoteBytes,
        sources: ConflictSources(
          localUid: record?.uid,
          localHash: localBytes == null ? null : ContentHash.ofBytes(localBytes),
          remoteEtag: remote?.etag,
          remoteHash: remoteBytes == null ? null : ContentHash.ofBytes(remoteBytes),
        ),
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
        // The other device moved the file; the uid proves it is the same
        // note. Move the local file too, or the vault ends up holding one
        // note twice under two paths — and the next round cannot tell which
        // is which.
        if (knownBasePath != null && knownBasePath != path) {
          final from = files.fileFor(knownBasePath);
          final to = files.fileFor(path);
          if (from != null && to != null && await from.exists()) {
            await to.parent.create(recursive: true);
            if (await to.exists()) await to.delete();
            await from.rename(to.path);
            await meta.remove(syncRootId, knownBasePath);
          }
        }
        // The identity comes from the *remote* copy. Taking the local base
        // row's uid instead writes null, and the following round then sees a
        // delete plus an unrelated new file rather than a rename.
        await meta.commitBase(
          syncRootId: syncRootId,
          path: path,
          uid: observation.remoteUid ?? observation.localUid,
          baseEtag: remote?.etag,
          baseContentHash: record?.baseContentHash,
          at: nowMs,
        );
        return _Outcome.downloaded;

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
        final put = await dav.put(path, bytes, condition: condition);
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
            error: 'HTTP ${put.statusCode}',
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

enum _Outcome {
  downloaded,
  uploaded,
  deleted,
  conflicted,
  skipped,
  retryNextRound,
}