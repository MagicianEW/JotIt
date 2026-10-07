/// Pure classification of a single path during a sync round.
///
/// This is the file that fixes v2.0's P0-3, P0-4, P0-5 and P0-6. Everything
/// here is a pure function of an already-observed [SyncObservation]: no file
/// I/O, no database, no network, no clock. That is deliberate — the 13 rows of
/// the v3.0 §5.3 decision matrix are the last gate before user data can be
/// destroyed, so they must be exhaustively table-testable in milliseconds
/// (see `test/domain/sync/decision_matrix_test.dart`).
///
/// ## Why v2.0's version could not work
///
/// v2.0 compared `local_etag` with `remote_etag`. After a successful sync
/// those two are *equal by construction*, so "only local changed" and "both
/// sides changed" were structurally indistinguishable — the schema could not
/// express the difference, so no amount of state-machine work could fix it.
///
/// The fix is a three-way merge base ([SyncObservation.baseEtag] /
/// [baseContentHash]): the state both sides last agreed on. Change is then
/// computed as a delta against the base, never as an equality between the two
/// live sides.
///
/// ## Safety rule (v3.0 constraint C3)
///
/// When the correct answer is *unclear*, return a conflict and keep both
/// copies. A spurious conflict costs the user one dialog. A wrong `noop` costs
/// them an edit that cannot be recovered.
library;

import 'dart:convert';

import 'package:meta/meta.dart';

/// The action the sync engine must take for one path.
enum SyncAction {
  /// Nothing to do. Either both sides agree and are unchanged, or neither
  /// side has the file and there is no base.
  nothingToDo,

  /// No local note; remote has a file we have never synced. Pull it down.
  downloadRemote,

  /// New local note that has never been uploaded. Create it remotely.
  uploadCreate,

  /// Local note changed since the base, remote unchanged. Conditional PUT.
  uploadUpdate,

  /// Local note is soft-deleted and remote still has it. Conditional DELETE.
  deleteRemote,

  /// Both sides deleted. Forget the sync metadata.
  forgetSyncMeta,

  /// Both sides hold byte-identical content. Only advance the base.
  noopSameContent,

  /// Remote deleted, local edited. Preserve the local edit, then accept the
  /// deletion. (v2.0 dropped this edit silently — P0-5.)
  deleteVsModifyPreserveLocal,

  /// Local deleted, remote edited. Preserve the remote content, then accept
  /// the deletion. The dual of the above.
  deleteVsModifyPreserveRemote,

  /// Remote deleted, local untouched. Propagate the deletion locally.
  restoreRemoteDelete,

  /// Both sides have the same path but *different identities*. Two devices
  /// each created `daily/2024-01-01.md`. Neither copy may be overwritten.
  /// (v2.0 had no detection for this at all — P0-6.)
  pathCollision,

  /// Both sides edited to different content. Keep both, let the user choose.
  trueConflict,

  /// Remote holds a note whose identity we already track under a different
  /// path. The remote side renamed it; adopt the new path without conflict.
  remoteRenameAdopt,

  /// The server rejected our conditional request (412/409), meaning our
  /// `base_etag` is stale. Re-fetch this path's metadata and classify again on
  /// the next round. Never retry blindly against a stale base.
  retryNextRound,
}

/// Everything the classifier needs about one path. All fields are values that
/// have already been read and normalised; the classifier performs no I/O.
@immutable
class SyncObservation {
  const SyncObservation({
    required this.path,
    this.localExists = false,
    this.localDeleted = false,
    this.localUid,
    this.localContentHash,
    this.remoteExists = false,
    this.remoteUid,
    this.remoteContentHash,
    this.remoteEtag,
    this.baseEtag,
    this.baseContentHash,
    this.baseUid,
    this.knownBasePathForRemoteUid,
    this.serverRejectedConditional = false,
  });

  /// Vault-relative key, e.g. `daily/2024-01-01.md`. The transport-layer
  /// identity (v3.0 ADR-2).
  final String path;

  /// A note row exists locally for this path, whether alive or soft-deleted.
  final bool localExists;

  /// That local row has `is_deleted = 1`.
  final bool localDeleted;

  /// `uid` from the local file's front matter — the logical identity.
  final String? localUid;

  final String? localContentHash;

  final bool remoteExists;
  final String? remoteUid;
  final String? remoteContentHash;

  /// Opaque server token. Only ever compared for equality (v3.0 §6.2:
  /// never parse its format).
  final String? remoteEtag;

  /// The state both sides last agreed on.
  final String? baseEtag;
  final String? baseContentHash;
  final String? baseUid;

  /// If [remoteUid] is an identity we already track under a different synced
  /// path, that path. Signals a remote-side rename rather than a conflict.
  final String? knownBasePathForRemoteUid;

  /// The server answered our conditional request with 412 or 409.
  final bool serverRejectedConditional;

  bool get remoteChanged =>
      remoteExists && remoteEtag != null && remoteEtag != baseEtag;

  bool get localChanged =>
      localContentHash != null && localContentHash != baseContentHash;

  @override
  String toString() => 'SyncObservation($path) ' + jsonEncode({
        'localExists': localExists,
        'localDeleted': localDeleted,
        'localUid': localUid,
        'localHash': _ab(localContentHash),
        'remoteExists': remoteExists,
        'remoteUid': remoteUid,
        'remoteHash': _ab(remoteContentHash),
        'remoteEtag': remoteEtag,
        'baseEtag': baseEtag,
        'baseHash': _ab(baseContentHash),
        'knownBasePath': knownBasePathForRemoteUid,
        'rejected': serverRejectedConditional,
      });

  static String _ab(String? v) =>
      v == null ? 'null' : '${v.substring(0, 8)}…';
}

/// The classifier's verdict, plus the instruction on which copies must be
/// preserved into `_conflicts/` before any destructive step.
@immutable
class SyncDecision {
  const SyncDecision(this.action, {this.preserveLocal = false, this.preserveRemote = false, this.detail = ''});

  final SyncAction action;

  /// Write the local content into `_conflicts/<...>/local.md` before acting.
  final bool preserveLocal;

  /// Write the remote content into `_conflicts/<...>/remote.md` before acting.
  final bool preserveRemote;

  /// Human-readable explanation, surfaced in the sync log.
  final String detail;

  bool get isConflict =>
      action == SyncAction.pathCollision || action == SyncAction.trueConflict;

  @override
  String toString() =>
      'SyncDecision(${action.name}${preserveLocal ? ', keepLocal' : ''}'
      '${preserveRemote ? ', keepRemote' : ''}'
      '${detail.isEmpty ? '' : ' — $detail'})';
}

/// Classify one path. Pure; see the library docs for the rationale.
///
/// Rows correspond 1:1 to the table in v3.0 §5.3.
SyncDecision classifySync(SyncObservation o) {
  // Row 10 — the server's answer outranks everything we could infer locally.
  if (o.serverRejectedConditional) {
    return const SyncDecision(
      SyncAction.retryNextRound,
      detail: 'conditional request rejected; base_etag is stale',
    );
  }

  // Dart only promotes *local* variables through null checks, never fields or
  // getters on another object, so both identities are captured up front.
  final localUid = o.localUid;
  final remoteUid = o.remoteUid;

  // Row 3 — remote holds an identity we already track elsewhere. This is a
  // rename on the remote side, not a conflict. Checked before any equality
  // test because a renamed file legitimately has no local counterpart at the
  // new path yet.
  final knownPath = o.knownBasePathForRemoteUid;
  if (o.remoteExists && remoteUid != null && knownPath != null && knownPath != o.path) {
    return SyncDecision(
      SyncAction.remoteRenameAdopt,
      detail: 'uid ${_short(remoteUid)} was last synced at $knownPath',
    );
  }

  // Row 1 (both absent) — nothing at either end.
  if (!o.localExists && !o.remoteExists) {
    return const SyncDecision(SyncAction.nothingToDo, detail: 'absent on both sides');
  }

  // Remote-only. Two sub-cases that differ in urgency but not in action.
  if (!o.localExists && o.remoteExists) {
    return const SyncDecision(
      SyncAction.downloadRemote,
      detail: 'remote-only; no local content can be lost',
    );
  }

  // From here on, localExists is true.
  if (!o.remoteExists) {
    // Row 12 — both sides deleted.
    if (o.localDeleted) {
      return const SyncDecision(SyncAction.forgetSyncMeta, detail: 'deleted on both sides');
    }
    // Row 1 — a local note that has never been uploaded.
    if (o.baseEtag == null && o.baseContentHash == null) {
      return const SyncDecision(SyncAction.uploadCreate, detail: 'new local note, never synced');
    }
    // Row 5 — remote deleted it, we edited it. P0-5: v2.0 had no edge here,
    // so the edit vanished. Preserve it first, then accept the deletion.
    if (o.localChanged) {
      return const SyncDecision(
        SyncAction.deleteVsModifyPreserveLocal,
        preserveLocal: true,
        detail: 'remote deleted, local edited — keeping the edit in _conflicts/',
      );
    }
    // Row 4 — remote deleted, local untouched. Propagate.
    return const SyncDecision(
      SyncAction.restoreRemoteDelete,
      detail: 'remote deleted, local untouched — propagating deletion',
    );
  }

  // Both sides present.
  if (o.localDeleted) {
    // Row 13 — the dual of row 5: they deleted it, we edited it.
    if (o.remoteChanged) {
      return const SyncDecision(
        SyncAction.deleteVsModifyPreserveRemote,
        preserveRemote: true,
        detail: 'local deleted, remote edited — keeping the edit in _conflicts/',
      );
    }
    // Row 11 — clean delete propagation.
    return const SyncDecision(SyncAction.deleteRemote, detail: 'local deleted, remote unchanged');
  }

  // Identity comparison. `uid` is what makes this decidable at all (ADR-2).
  if (localUid != null && remoteUid != null) {
    if (localUid != remoteUid) {
      // Row 2 — path collision. P0-6.
      return SyncDecision(
        SyncAction.pathCollision,
        preserveLocal: true,
        preserveRemote: true,
        detail: 'same path, different uid '
            '(${_short(localUid)} vs ${_short(remoteUid)}) — '
            'two devices each created this path',
      );
    }
  } else if (remoteUid == null) {
    // A remote file with no `uid` — created externally and never stamped.
    // We cannot tell "our note with a stripped header" from "someone else's
    // file", so C3 applies: report a conflict rather than overwrite.
    return const SyncDecision(
      SyncAction.trueConflict,
      preserveLocal: true,
      preserveRemote: true,
      detail: 'remote file has no uid; refusing to overwrite without identity',
    );
  }

  // Same identity on both sides.
  final neverSynced = o.baseEtag == null && o.baseContentHash == null;
  if (neverSynced) {
    return const SyncDecision(
      SyncAction.trueConflict,
      preserveLocal: true,
      preserveRemote: true,
      detail: 'same uid on both sides but no base — cannot prove which is newer',
    );
  }

  final remoteChanged = o.remoteChanged;
  final localChanged = o.localChanged;

  if (!remoteChanged && !localChanged) {
    return const SyncDecision(SyncAction.nothingToDo, detail: 'both sides match the base');
  }
  if (!remoteChanged && localChanged) {
    return const SyncDecision(SyncAction.uploadUpdate, detail: 'local-only change');
  }
  if (remoteChanged && !localChanged) {
    return const SyncDecision(SyncAction.downloadRemote, detail: 'remote-only change');
  }

  // Both changed. Row 8 first: identical content is not a conflict.
  if (o.localContentHash != null &&
      o.remoteContentHash != null &&
      o.localContentHash == o.remoteContentHash) {
    return const SyncDecision(SyncAction.noopSameContent, detail: 'both changed to identical bytes');
  }

  // Row 9 — genuine conflict.
  return const SyncDecision(
    SyncAction.trueConflict,
    preserveLocal: true,
    preserveRemote: true,
    detail: 'both sides changed to different content',
  );
}

String _short(String s) => s.length <= 8 ? s : '${s.substring(0, 8)}…';