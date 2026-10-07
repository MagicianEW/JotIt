import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/vault_paths.dart';
import '../entities/front_matter_patcher.dart';
import 'conflict_naming.dart';

/// Which side of a divergence each copy came from.
enum ConflictSide { local, remote }

/// The two sources behind a conflict, as §7.2 requires them to be recorded.
class ConflictSources {
  const ConflictSources({
    required this.localUid,
    required this.localHash,
    required this.remoteEtag,
    this.remoteHash,
    this.remoteUid,
  });

  final String? localUid;
  final String? localHash;

  /// Opaque token, stored verbatim.
  final String? remoteEtag;
  final String? remoteHash;
  final String? remoteUid;
}

/// What was written, and where.
class ConflictRecord {
  const ConflictRecord({
    required this.directory,
    required this.originalPath,
    required this.sources,
    required this.hasLocal,
    required this.hasRemote,
    required this.at,
  });

  /// `_conflicts/`-relative directory name.
  final String directory;

  /// The vault path the conflict was detected at.
  final String originalPath;

  final ConflictSources sources;
  final bool hasLocal;
  final bool hasRemote;

  /// Epoch milliseconds.
  final int at;
}

/// Writes the two copies of a conflict to disk (§7.2).
///
/// Two rules this file exists to enforce, both of which v2.0 got backwards:
///
///  * **The copies never synchronise.** They go to `_conflicts/`, a sibling of
///    `notes/`, which the scanner walks nothing of. Copies inside `notes/`
///    replicate to every device and multiply.
///  * **The user's bytes are not touched.** No banner, no header, no
///    re-serialisation. Adding a "this conflicted" line changes the hash,
///    which is the same hash the next sync round compares against as its merge
///    base — the banner poisons the next pass, not just the file.
///
/// The third rule is about deletion: copies are never removed here. §7.3 has
/// the user pick, and the directory goes away only when they do.
abstract final class ConflictWriter {
  static const String localFile = 'local.md';
  static const String remoteFile = 'remote.md';
  static const String metaFile = 'meta.json';

  /// Writes [localBytes] and [remoteBytes] into a fresh directory.
  ///
  /// Either side may be null — a delete-versus-edit conflict has no remote
  /// file to keep — and the directory records that rather than leaving a
  /// misleading empty file behind.
  static Future<ConflictRecord> write({
    required String vaultRoot,
    required String originalPath,
    required List<int>? localBytes,
    required List<int>? remoteBytes,
    required ConflictSources sources,
    required DateTime when,
    int? at,
  }) async {
    final conflictsRoot = VaultPaths.conflictsRoot(vaultRoot);
    final stamp = when.toUtc();

    final name = ConflictNaming.directoryName(
      when: stamp,
      originalPath: originalPath,
      sequence: ConflictNaming.nextSequence(
        when: stamp,
        originalPath: originalPath,
        exists: (candidate) =>
            Directory(p.join(conflictsRoot, candidate)).existsSync(),
      ),
    );

    final dir = Directory(p.join(conflictsRoot, name));
    await dir.create(recursive: true);

    if (localBytes != null) {
      await File(p.join(dir.path, localFile)).writeAsBytes(localBytes, flush: true);
    }
    if (remoteBytes != null) {
      await File(p.join(dir.path, remoteFile)).writeAsBytes(remoteBytes, flush: true);
    }

    final record = ConflictRecord(
      directory: name,
      originalPath: originalPath,
      sources: sources,
      hasLocal: localBytes != null,
      hasRemote: remoteBytes != null,
      at: at ?? stamp.millisecondsSinceEpoch,
    );
    await File(p.join(dir.path, metaFile)).writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(_metaJson(record))}\n',
      flush: true,
    );
    return record;
  }

  static Map<String, Object?> _metaJson(ConflictRecord record) => {
        'original_path': record.originalPath,
        'detected_at': record.at,
        'detected_at_iso': DateTime.fromMillisecondsSinceEpoch(record.at,
            isUtc: true).toIso8601String(),
        'has_local': record.hasLocal,
        'has_remote': record.hasRemote,
        'local_uid': record.sources.localUid,
        'local_content_hash': record.sources.localHash,
        'remote_etag': record.sources.remoteEtag,
        'remote_content_hash': record.sources.remoteHash,
        'remote_uid': record.sources.remoteUid,
        'schema': 1,
      };

  /// Reads a conflict directory back, for §7.3's resolution screen.
  static Future<ConflictRecord?> read(
    String vaultRoot,
    String directoryName,
  ) async {
    final dir = Directory(p.join(VaultPaths.conflictsRoot(vaultRoot), directoryName));
    final meta = File(p.join(dir.path, metaFile));
    if (!await meta.exists()) return null;

    Map<String, Object?> json;
    try {
      json = jsonDecode(await meta.readAsString()) as Map<String, Object?>;
    } on FormatException {
      // A hand-edited meta.json is not worth losing the copies over.
      return null;
    }

    return ConflictRecord(
      directory: directoryName,
      originalPath: json['original_path'] as String? ?? '',
      hasLocal: json['has_local'] as bool? ??
          File(p.join(dir.path, localFile)).existsSync(),
      hasRemote: json['has_remote'] as bool? ??
          File(p.join(dir.path, remoteFile)).existsSync(),
      at: (json['detected_at'] as int?) ?? 0,
      sources: ConflictSources(
        localUid: json['local_uid'] as String?,
        localHash: json['local_content_hash'] as String?,
        remoteEtag: json['remote_etag'] as String?,
        remoteHash: json['remote_content_hash'] as String?,
        remoteUid: json['remote_uid'] as String?,
      ),
    );
  }

  /// Reads one side's bytes, or null when that side was not preserved.
  static Future<List<int>?> readSide(
    String vaultRoot,
    String directoryName,
    ConflictSide side,
  ) async {
    final file = File(p.join(
      VaultPaths.conflictsRoot(vaultRoot),
      directoryName,
      side == ConflictSide.local ? localFile : remoteFile,
    ));
    return await file.exists() ? file.readAsBytes() : null;
  }

  /// Removes a resolved conflict. Only §7.3's resolution calls this, and only
  /// after the user has chosen a side — nothing sweeps this directory.
  static Future<void> remove(String vaultRoot, String directoryName) async {
    final dir = Directory(
        p.join(VaultPaths.conflictsRoot(vaultRoot), directoryName));
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  /// Every conflict still awaiting a decision.
  static List<String> pending(String vaultRoot) {
    final root = Directory(VaultPaths.conflictsRoot(vaultRoot));
    if (!root.existsSync()) return const [];
    return root
        .listSync()
        .whereType<Directory>()
        .where((d) => File(p.join(d.path, metaFile)).existsSync())
        .map((d) => p.basename(d.path))
        .toList()
      ..sort();
  }

  /// The note title a conflict screen shows, taken from the preserved copies.
  static String? titleOf(List<int> bytes) {
    if (!NoteBytes.isUtf8(bytes)) return null;
    try {
      final text = utf8.decode(bytes);
      final fmTitle = FrontMatterPatcher.readString(text, 'title');
      if (fmTitle != null && fmTitle.trim().isNotEmpty) return fmTitle;
      final heading =
          RegExp(r'^#\s+(.+)$', multiLine: true).firstMatch(text)?.group(1);
      return heading?.trim();
    } on FormatException {
      return null;
    }
  }
}

/// Small helper kept local so this file does not reach across layers for one
/// predicate that only matters when reading copies back.
abstract final class NoteBytes {
  static bool isUtf8(List<int> bytes) {
    try {
      utf8.decode(bytes);
      return true;
    } on FormatException {
      return false;
    }
  }
}