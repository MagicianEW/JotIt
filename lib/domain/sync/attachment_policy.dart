import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// What to do with one attachment during a sync round (v3.0 §5.5).
enum AttachmentAction {
  /// Both sides hold the same bytes, or neither side holds the file.
  nothingToDo,

  /// The remote has never seen this attachment. Create it there.
  upload,

  /// The other device has it and this device has never seen it.
  download,

  /// This vault had it, the index still has its row, and the file is gone.
  /// ADR-11 makes deletion part of how an attachment is "replaced", so it has
  /// to propagate — otherwise the old picture returns on the next round and
  /// stays forever, and the user can never finish removing an image.
  deleteRemote,

  /// Both sides hold this path with **different bytes**.
  ///
  /// This is the state ADR-11 says cannot exist. The verdict is deliberately
  /// *not* "last writer wins" and deliberately *not* a `_conflicts/` pair:
  ///
  ///  * Picking a winner is a silent overwrite, which is what constraint C3
  ///    forbids outright.
  ///  * Writing copies of a binary into a directory whose sibling files are
  ///    Markdown gets the user two files they cannot read and no UI that says
  ///    what happened, to resolve something that is almost always a tool
  ///    outside this app having rewritten the same path.
  ///
  /// So the engine keeps both, copies neither, and reports the path. A person
  /// can then delete whichever one is wrong — which is a decision they are
  /// actually in a position to make.
  immutableViolation,

  /// The file is on disk but no note references it.
  ///
  /// Never pushed. "Nothing points at this" is not evidence the user wants it
  /// on their other devices: they may have deleted the note and be about to
  /// paste the image back. Uploading is the only half that does any damage
  /// here, so this is the only half that is blocked.
  orphan,
}

/// Everything the classifier needs about one attachment. Values only; the
/// classifier performs no I/O.
///
/// The distinction that matters: [remoteHash] may be **null** while the remote
/// very much exists. That is the "we have not spent a download to find out yet"
/// state, and it is the engine's job to resolve it before asking for a verdict
/// — see [RemoteAttachmentProbe].
@immutable
class AttachmentObservation {
  const AttachmentObservation({
    required this.path,
    this.localExists = false,
    this.localHash,
    this.remoteExists = false,
    this.remoteHash,
    this.baseHash,
    this.referencedByANote = true,
    this.knownToVault = false,
  });

  /// Vault-relative, `notes/`-prefixed, forward slashes.
  final String path;

  final bool localExists;

  /// SHA-256 of the local bytes.
  final String? localHash;

  final bool remoteExists;

  /// SHA-256 of the remote bytes, or null when it has not been fetched.
  final String? remoteHash;

  /// SHA-256 both sides last agreed on.
  final String? baseHash;

  /// False when the file exists but the index says no note references it.
  final bool referencedByANote;

  /// True when the derived index has a row for this path.
  ///
  /// This is the flag that separates "another device just sent me a picture"
  /// from "I had this picture and it is gone", and the two want opposite
  /// answers. §4.4 is the reason the row survives the file's disappearance —
  /// "文件缺失时记录警告，不删除元数据" — so this is that rule being used for
  /// something, not a second piece of state invented to make the classifier
  /// work.
  final bool knownToVault;

  @override
  String toString() => 'AttachmentObservation($path){'
      'local: ${localExists ? _ab(localHash) : "absent"}, '
      'remote: ${remoteExists ? _ab(remoteHash) : "absent"}, '
      'base: ${_ab(baseHash)}, ref: $referencedByANote, '
      'known: $knownToVault}';

  static String _ab(String? v) =>
      v == null ? 'no-hash' : '${v.substring(0, 8)}…';
}

/// Pure classification of one attachment, per v3.0 §5.5.
///
/// **It is a separate function from `classifySync` on purpose.** The note
/// matrix exists to resolve concurrent edits to a file two devices both
/// author, and it decides those by identity (`uid` in front matter). An
/// attachment has no front matter, is never authored concurrently — ADR-11
/// makes its content immutable after the first write — and consequently has no
/// edit conflict to resolve. Feeding one through the note matrix does not
/// degrade gracefully; it lands on that matrix's "remote file has no uid,
/// refusing to overwrite without identity" row, which is a correct answer to
/// the wrong question and produces a `_conflicts/` entry for a file that could
/// not possibly be in conflict.
///
/// The three rules §5.5 gives, and where each one lives here:
///
///  * *immutable* → [AttachmentAction.immutableViolation] exists and nothing
///    resolves a content difference,
///  * *judge by SHA-256, not by ETag* → every comparison below is a checksum;
///    the ETag never appears,
///  * *retry is a whole-file retransmission* → this function never emits a
///    resume; see `SyncEngine` for the `next_attempt_at` bookkeeping.
AttachmentAction classifyAttachment(AttachmentObservation o) {
  if (!o.localExists && !o.remoteExists) {
    return AttachmentAction.nothingToDo;
  }

  if (!o.localExists && o.remoteExists) {
    // The one genuinely ambiguous question in this file: the file is missing
    // here and present there. Two readings, opposite actions.
    //
    // `knownToVault` is what tells them apart. The index still holding a row
    // for the path means this vault had the file and it is now gone, and §5.5
    // makes deletion part of replacing an image — so it propagates. No row
    // means this device has simply never seen it, and the answer is to fetch
    // it.
    //
    // Getting this the other way round is not a subtle degradation: a deleted
    // picture is re-downloaded from the server on every round forever, and the
    // user has no way to finish removing an image.
    if (o.knownToVault) return AttachmentAction.deleteRemote;
    return AttachmentAction.download;
  }

  if (o.localExists && !o.remoteExists) {
    // Nothing points at this file, so it is not part of the vault yet. Do not
    // push it — see [AttachmentAction.orphan].
    if (!o.referencedByANote) return AttachmentAction.orphan;
    // Upload whether or not a base exists. A base means we synced this path
    // once and the remote has since lost it; no base means the other device
    // has never seen it. Both end the same way, and sending `If-None-Match: *`
    // makes the second device to arrive lose the race rather than overwrite.
    return AttachmentAction.upload;
  }

  // Both sides present. [remoteHash] must be known here; the engine is
  // required to resolve it before asking. Comparing a null hash as "different"
  // would report a violation on every single attachment, every round.
  final localHash = o.localHash;
  final remoteHash = o.remoteHash;
  if (localHash == null || remoteHash == null) {
    return AttachmentAction.nothingToDo;
  }
  if (localHash == remoteHash) return AttachmentAction.nothingToDo;

  // Different bytes at the same immutable path. Report, touch nothing.
  return AttachmentAction.immutableViolation;
}

/// Decides whether resolving [AttachmentObservation.remoteHash] is worth a
/// download.
///
/// §5.5 insists the *judgement* be the checksum. It says nothing about being
/// allowed to avoid computing one, and a vault with a few hundred photographs
/// would otherwise download itself in full on every single round just to
/// confirm that nothing moved.
///
/// So the server's `Content-Length` and ETag are used as a **pre-filter only**:
/// when both are unchanged since the recorded base, the remote bytes cannot
/// have changed, so the base's checksum is still the truth and no transfer is
/// needed. The moment either disagrees, the engine downloads and hashes for
/// real, and the verdict is computed from SHA-256 alone.
///
/// Returning true means "call `GET`, then build the observation again with the
/// hash filled in".
bool remoteChecksumNeedsFetching({
  required bool remoteExists,
  required String? baseHash,
  required int? remoteContentLength,
  required int? baseContentLength,
  required String? remoteEtag,
  required String? baseEtag,
}) {
  if (!remoteExists) return false;
  if (baseHash == null) return true; // never synced: only a fetch can prove anything
  // Different size is proof on its own, and it is free.
  if (remoteContentLength != null &&
      baseContentLength != null &&
      remoteContentLength != baseContentLength) {
    return true;
  }
  // Same size but a different token: could be a rewrite to the same length.
  if (remoteEtag != null && baseEtag != null && remoteEtag != baseEtag) {
    return true;
  }
  // Nothing the server told us has moved, so the bytes have not either.
  return false;
}

/// The best guess at a MIME type for [path], by extension.
///
/// Extracted here rather than left in the scanner because two callers need it
/// for different reasons and disagreed last time they each had a copy: the
/// scanner stores it as metadata, and the sync engine has to send it as
/// `Content-Type` or every attachment lands on the server as `text/markdown`.
///
/// The fallback is deliberately `application/octet-stream` and not something
/// prettier. A wrong-but-specific type makes a server and its other clients
/// treat the file as something it is not — an image served as text is a
/// rendered error page — whereas an unknown binary type is merely unhelpful.
String mimeTypeFor(String path) {
  switch (p.posix.extension(path).toLowerCase()) {
    case '.png':
      return 'image/png';
    case '.jpg':
    case '.jpeg':
      return 'image/jpeg';
    case '.gif':
      return 'image/gif';
    case '.webp':
      return 'image/webp';
    case '.bmp':
      return 'image/bmp';
    case '.svg':
      return 'image/svg+xml';
    case '.ico':
      return 'image/vnd.microsoft.icon';
    case '.heic':
      return 'image/heic';
    case '.pdf':
      return 'application/pdf';
    case '.zip':
      return 'application/zip';
    case '.gz':
      return 'application/gzip';
    case '.txt':
    case '.log':
    case '.md':
      return 'text/plain; charset=utf-8';
    case '.json':
      return 'application/json';
    case '.csv':
      return 'text/csv; charset=utf-8';
    case '.mp3':
      return 'audio/mpeg';
    case '.m4a':
      return 'audio/mp4';
    case '.wav':
      return 'audio/wav';
    case '.ogg':
      return 'audio/ogg';
    case '.mp4':
      return 'video/mp4';
    case '.mov':
      return 'video/quicktime';
    case '.webm':
      return 'video/webm';
    default:
      return 'application/octet-stream';
  }
}

/// Bytes at or above this size take the streamed, retry-tolerant path (§5.5).
///
/// The number is the spec's, not a measurement: v3.0 §5.5 puts the boundary
/// between an ordinary in-memory `PUT` and a streamed one at 10 MB. Below it,
/// buffering the whole body is cheaper than streaming it; above it, buffering
/// risks a multi-hundred-megabyte allocation for a file the user just picked
/// on a phone.
const int kLargeAttachmentBytes = 10 * 1024 * 1024;

/// True when [size] is in the range §5.5 singles out for chunked or streamed
/// transfer.
bool isLargeAttachment(int size) => size >= kLargeAttachmentBytes;

/// A JSON-safe progress tick, for the `Stream` the UI subscribes to while a
/// large attachment is in flight.
///
/// Bytes rather than a percentage: a percentage needs a total the engine may
/// only learn partway through a remote download, and a progress bar that has to
/// be re-based mid-flight is worse than one that counts up.
@immutable
class AttachmentProgress {
  const AttachmentProgress({
    required this.path,
    required this.transferred,
    required this.total,
    required this.direction,
  });

  final String path;
  final int transferred;

  /// -1 when the size is not yet known.
  final int total;

  /// `upload` or `download`.
  final String direction;

  double get fraction => total > 0 ? transferred / total : -1;

  Map<String, Object?> toJson() => <String, Object?>{
        'path': path,
        'transferred': transferred,
        'total': total,
        'direction': direction,
      };

  @override
  String toString() =>
      'AttachmentProgress($direction $path $transferred/$total)';

  static AttachmentProgress? fromJson(String raw) {
    try {
      final map = jsonDecode(raw);
      if (map is! Map) return null;
      return AttachmentProgress(
        path: map['path'] as String? ?? '',
        transferred: (map['transferred'] as num?)?.toInt() ?? 0,
        total: (map['total'] as num?)?.toInt() ?? -1,
        direction: map['direction'] as String? ?? 'upload',
      );
    } on Object {
      return null;
    }
  }
}
