import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../../core/vault_paths.dart';
import '../../domain/entities/front_matter_patcher.dart';

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
    final normalised = crlf ? text.replaceAll('\r\n', '\n') : text;
    return <int>[...bom, ...utf8.encode(crlf ? normalised.replaceAll('\n', '\r\n') : normalised)];
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
  Future<List<int>?> ensureUid(String notePath, String uid) async {
    final f = fileFor(notePath);
    if (f == null) return null;
    final bytes = await f.readAsBytes();
    if (!isValidUtf8(bytes)) return null;

    final text = utf8.decode(bytes);
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
}