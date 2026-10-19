import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../../core/vault_paths.dart';
import '../../domain/entities/front_matter_patcher.dart';
import 'path_lock.dart';

/// Reads and writes note files under a vault.
///
/// Every write goes through [writeAtomic]. A note file that is truncated to
/// zero bytes by a crash mid-write is a data-loss event that the sync engine
/// will happily propagate to every other device, so the temp-file dance below
/// is not ceremony — it is the difference between a crash and a lost note.
class NoteFileStore {
  NoteFileStore({required this.vaultRoot, Random? random})
      : _random = random ?? Random.secure();

  final String vaultRoot;
  final Random _random;

  /// Serialises read-modify-write sequences per path. See [exclusive] for why
  /// a save and the scanner's uid backfill must not interleave.
  final PathLock _pathLock = PathLock();

  static const String _tmpSuffix = '.jotit-tmp';
  static const String _bakSuffix = '.jotit-bak';

  String notesRoot() => VaultPaths.notesRoot(vaultRoot);

  /// Absolute path for a `notes/`-prefixed vault path. Returns null for a path
  /// that escapes the synced subtree, which is the only place such a path can
  /// come from — a link, a sync payload, or a stale `sync_meta` row.
  String? absolutePathFor(String notePath) {
    final norm = VaultPaths.normalizeRelative(notePath);
    if (norm == null || !VaultPaths.isInsideNotes(norm)) return null;
    // `joinAll` takes a single Iterable — `joinAll(root, parts)` is not a
    // two-argument call, and dropping `vaultRoot` to satisfy the signature
    // silently turns every path relative to the process CWD.
    return p.joinAll([vaultRoot, ...p.split(norm)]);
  }

  /// The `notes/`-prefixed vault path for an absolute file path, or null when
  /// the file is not inside the synced subtree.
  String? notePathFor(String absolutePath) {
    final abs = p.normalize(p.absolute(absolutePath));
    final root = p.normalize(p.absolute(VaultPaths.notesRoot(vaultRoot)));
    if (!p.isWithin(root, abs)) return null;
    // From here up it is a plain path join, so the separators that reach
    // `normalizeRelative` are already `/` — it rejects a `\` outright as a
    // literal filename character rather than silently accepting either kind.
    final inner = p.relative(abs, from: root).replaceAll('\\', '/');
    return VaultPaths.normalizeRelative('notes/$inner');
  }

  File? fileFor(String notePath) {
    final abs = absolutePathFor(notePath);
    return abs == null ? null : File(abs);
  }

  Future<List<int>?> readBytesIfPresent(String notePath) async {
    final f = fileFor(notePath);
    if (f == null) return null;
    if (!await f.exists()) return null;
    return f.readAsBytes();
  }

  Future<void> writeAtomic(String notePath, List<int> bytes) async {
    final target = fileFor(notePath);
    if (target == null) {
      throw ArgumentError('refusing to write outside notes/: $notePath');
    }
    await target.parent.create(recursive: true);
    await _writeAtomicTo(target, bytes);
  }

  /// Writes [bytes] to an arbitrary [target] with the same tmp + rename
  /// atomicity as [writeAtomic].
  ///
  /// Exists for files that are not notes: the rolling backup lives in
  /// `.jotit/backups/`, outside the synced subtree [writeAtomic] is confined
  /// to. It is the same crash-safety dance for the same reason — a half-written
  /// backup is worse than no backup, because it looks like a recovery point.
  Future<void> writeFileAtomic(File target, List<int> bytes) async {
    await target.parent.create(recursive: true);
    await _writeAtomicTo(target, bytes);
  }

  /// Runs [body] while holding this path's write lock.
  ///
  /// The lock exists for the one race ADR-2 cannot survive: a save and the
  /// scanner's uid backfill are both read-modify-write sequences over the same
  /// file. Without mutual exclusion the backfill stamps uid A, the save's
  /// earlier read — which saw no uid — clobbers the file and mints uid B, and
  /// the note's identity drifts with nothing on screen to show it. Callers
  /// take the lock around the *whole* sequence (read, write, ensureUid); the
  /// primitives below stay lock-free, and the lock is not reentrant.
  ///
  /// A path outside `notes/` has no lock — there is nothing valid to write
  /// there, and the body refuses it loudly.
  Future<T> exclusive<T>(String notePath, Future<T> Function() body) async {
    final abs = absolutePathFor(notePath);
    if (abs == null) return body();
    return _pathLock.synchronized(abs, body);
  }

  Future<void> _writeAtomicTo(File target, List<int> bytes) async {
    final token = _random.nextInt(1 << 30).toRadixString(36);
    final tmp = File('${target.path}$_tmpSuffix.$token');
    final backup = File('${target.path}$_bakSuffix.$token');

    await tmp.writeAsBytes(bytes, flush: true);

    final hadOriginal = await target.exists();
    if (hadOriginal) {
      await target.rename(backup.path);
    }
    try {
      await tmp.rename(target.path);
    } on Object {
      // Put the original back rather than leaving the user with nothing.
      if (hadOriginal && await backup.exists()) {
        await backup.rename(target.path);
      }
      if (await tmp.exists()) await tmp.delete();
      rethrow;
    }
    if (hadOriginal && await backup.exists()) await backup.delete();
  }

  /// Writes [text] using [lineEnding] and the original byte-order mark.
  ///
  /// Re-encoding a note the user wrote is a silent edit: a UTF-8 file decoded
  /// and re-encoded without the BOM loses the BOM, and a file that was never
  /// CRLF turns into CRLF. Either one changes `content_hash`, which the sync
  /// engine reads as "the user edited this note" and uploads.
  Future<List<int>> encodeLike({
    required List<int> originalBytes,
    required String text,
  }) async {
    var bom = <int>[];
    var body = originalBytes;
    if (body.length >= 3 &&
        body[0] == 0xEF &&
        body[1] == 0xBB &&
        body[2] == 0xBF) {
      bom = body.sublist(0, 3);
      body = body.sublist(3);
    }
    final decoded = utf8.decode(body, allowMalformed: true);
    final crlf = decoded.contains('\r\n');
    // Normalise to LF first, then re-expand to whatever the file already used.
    // Doing this one direction only (LF text -> CRLF, but not back) would
    // rewrite every line of an LF note the moment a user pasted CRLF text
    // into it — a whole-file diff that is both invisible and pointless.
    final normalised = text.replaceAll('\r\n', '\n');
    return <int>[
      ...bom,
      ...utf8.encode(crlf ? normalised.replaceAll('\n', '\r\n') : normalised),
    ];
  }

  /// True when [bytes] is valid UTF-8.
  ///
  /// Used before any decode-and-re-encode write. A file that is not valid
  /// UTF-8 is left completely alone: "helpfully" round-tripping it would
  /// replace the user's bytes with U+FFFD, and the sync engine would ship that
  /// damage to every device.
  static bool isValidUtf8(List<int> bytes) {
    try {
      utf8.decode(bytes);
      return true;
    } on FormatException {
      return false;
    }
  }

  /// Adds `uid` to the front matter if it is missing.
  ///
  /// Returns the new bytes, or null when nothing had to change or when the
  /// file cannot be safely rewritten.
  ///
  /// Lock-free by design: callers performing a read-modify-write sequence
  /// (a save, the scanner's backfill) must hold the path's lock via
  /// [exclusive] around the whole sequence — this method re-reads the file,
  /// so calling it *inside* such a sequence is the point, and nesting it
  /// under a second lock acquisition would deadlock.
  Future<List<int>?> ensureUid(String notePath, String uid) async {
    final f = fileFor(notePath);
    if (f == null) return null;
    final bytes = await f.readAsBytes();
    if (!isValidUtf8(bytes)) return null;

    final text = utf8.decode(bytes);
    // "Ensure" means add when missing. The uid is the note's identity across
    // devices (ADR-2): re-stamping an existing one on every save would make
    // the identity drift with each keystroke saved, and the sync engine —
    // which matches on uid — would see every note as a new note.
    final existing = FrontMatterPatcher.readString(text, 'uid');
    if (existing != null && existing.trim().isNotEmpty) return null;

    final patched = FrontMatterPatcher.withUid(text, uid);
    if (patched == text) return null;

    final encoded = await encodeLike(originalBytes: bytes, text: patched);
    await _writeAtomicTo(f, encoded);
    return encoded;
  }

  /// Creates the `notes/` tree. Called once at vault creation.
  static Future<void> ensureLayout(String vaultRoot) async {
    await Directory(VaultPaths.notesRoot(vaultRoot)).create(recursive: true);
    await Directory(VaultPaths.conflictsRoot(vaultRoot)).create(recursive: true);
    await Directory(VaultPaths.appRoot(vaultRoot)).create(recursive: true);
  }

  /// Startup recovery for a write that was interrupted by a crash.
  ///
  /// [_writeAtomicTo] renames the original aside (`.jotit-bak.<token>`) and
  /// then renames the temp into place. A process killed between those two
  /// renames leaves the backup as the *only* copy of the previous content,
  /// and nothing in the app ever looked at it — the scanner deliberately
  /// ignores these names, so a note whose only copy is a `.jotit-bak` was
  /// gone until the user found it by hand. A leftover `.jotit-tmp` is bytes
  /// that were never committed.
  ///
  /// Run once at vault open, before the first reindex: the index must be
  /// built from the files as they are *after* recovery, not before.
  static Future<void> recoverInterruptedWrites(String vaultRoot) async {
    final root = Directory(VaultPaths.notesRoot(vaultRoot));
    if (!await root.exists()) return;

    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);

      final tmpAt = name.lastIndexOf('$_tmpSuffix.');
      if (tmpAt >= 0 && _looksLikeOurDebris(name, tmpAt)) {
        // 未提交的临时文件：删掉。它可能是半截字节，留下只会被索引进索引。
        await _deleteQuietly(entity);
        continue;
      }

      final bakAt = name.lastIndexOf('$_bakSuffix.');
      if (bakAt >= 0 && _looksLikeOurDebris(name, bakAt)) {
        final target = File(p.join(p.dirname(entity.path),
            name.substring(0, bakAt)));
        if (await target.exists()) {
          // 新文件已经在位（第一次 rename 之后、备份删除之前被杀）：
          // 备份只是残留，删掉。
          await _deleteQuietly(entity);
        } else {
          // 目标不在：这个备份就是上一版内容的唯一副本，搬回去。
          await target.parent.create(recursive: true);
          await entity.rename(target.path);
        }
      }
    }
  }

  /// True when [name] is `<something-with-an-extension>.jotit-tmp.<token>` /
  /// `.jotit-bak.<token>` and not a user file that merely contains the marker.
  ///
  /// The extension check is the discriminator: a real leftover always wraps a
  /// real filename (`a.md.jotit-bak.7x`), while a note the user genuinely
  /// named `weird.jotit-bak.md` parses to an extension-less target — and
  /// renaming *that* would be the recovery destroying data.
  static bool _looksLikeOurDebris(String name, int markerAt) {
    final target = name.substring(0, markerAt);
    return p.extension(target).isNotEmpty;
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // 恢复是尽力而为：删不掉的 debris 会被扫描器忽略，不影响使用。
    }
  }
}