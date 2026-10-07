import 'dart:convert';

import 'package:path/path.dart' as p;

/// Vault layout and path safety.
///
/// Implements v3.0 §3.3 (data ownership) and §9.3 (attachment path
/// validation). The rule that replaced v2.0's blanket "reject any `../`" ban:
///
///     resolved = normalize(join(dirname(note.path), linkTarget))
///     if !resolved.startsWith(vaultRoot + 'notes/') -> reject
///
/// A blanket ban is wrong because a note at `projects/jotit/design.md` linking
/// to `../../attachments/x.png` is perfectly legitimate. What actually matters
/// is that a link can never escape the synced `notes/` subtree.
abstract final class VaultPaths {
  /// The only subtree that is synchronised. Everything else is local-only.
  static const String notesDirName = 'notes';

  /// Local-only conflict quarantine. Deliberately a **sibling** of [notesDir],
  /// never a child: the scanner walks `notes/` and therefore cannot pick these
  /// up. See v3.0 ADR-7 — v2.0 declared conflict files non-syncing while
  /// storing them inside the notes tree, which caused them to replicate to
  /// every device and multiply.
  static const String conflictsDirName = '_conflicts';

  /// Local-only application directory (database, logs, models).
  static const String appDirName = '.jotit';

  static String notesRoot(String vaultRoot) =>
      p.join(vaultRoot, notesDirName);

  static String conflictsRoot(String vaultRoot) =>
      p.join(vaultRoot, conflictsDirName);

  static String appRoot(String vaultRoot) => p.join(vaultRoot, appDirName);

  /// Windows reserved device names. A file called `NUL` or `COM1` cannot be
  /// created on NTFS, and Nextcloud-on-Windows will silently fail to write it.
  /// Rejecting these up front beats a confusing runtime error on a user's
  /// existing file.
  static const Set<String> _reservedNames = {
    'CON', 'PRN', 'AUX', 'NUL',
    'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
    'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9',
  };

  /// Characters illegal in a Windows path segment.
  static final RegExp _illegalSegmentChars = RegExp(r'[*?"<>|:\x00-\x1f]');

  /// Normalise a vault-relative path to the canonical separator form used by
  /// the index (`notes/daily/2024-01-01.md`, forward slashes, no `.`/`..`,
  /// no leading or trailing separator).
  ///
  /// Returns `null` for anything that cannot be a legitimate vault path:
  /// absolute paths, Windows drive-qualified paths, UNC paths, or paths that
  /// climb above the vault root.
  static String? normalizeRelative(String raw) {
    var s = raw.trim().replaceAll('\\', '/');
    if (s.isEmpty) return null;
    if (s.startsWith('/')) return null; // absolute posix
    if (RegExp(r'^[A-Za-z]:').hasMatch(s)) return null; // C:\... or C:/...
    if (s.startsWith('//')) return null; // UNC

    // Normalise without letting it escape: walk segments manually.
    final out = <String>[];
    for (final seg in s.split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        if (out.isEmpty) return null; // would climb above vault root
        out.removeLast();
        continue;
      }
      out.add(seg);
    }
    if (out.isEmpty) return null;
    return out.join('/');
  }

  /// True when [relativePath] lies inside the synced notes subtree.
  static bool isInsideNotes(String relativePath) {
    final norm = normalizeRelative(relativePath);
    if (norm == null) return false;
    return norm == notesDirName || norm.startsWith('$notesDirName/');
  }

  /// Strip the `notes/` prefix, yielding the index key and the remote path.
  static String? stripNotesPrefix(String pathWithNotesPrefix) {
    final norm = normalizeRelative(pathWithNotesPrefix);
    if (norm == null || !isInsideNotes(norm)) return null;
    if (norm == notesDirName) return null;
    return norm.substring(notesDirName.length + 1);
  }

  /// Resolve an attachment or relative link found inside [notePath].
  ///
  /// Returns the vault-absolute path, or `null` when the link escapes the
  /// synced subtree or names a reserved device. Callers should surface the
  /// rejection in the UI rather than silently dropping the link.
  static String? resolveWithinVault({
    required String vaultRoot,
    required String notePath,
    required String linkTarget,
  }) {
    final noteKey = stripNotesPrefix(notePath);
    if (noteKey == null) return null;

    final decoded = _percentDecodeIfAny(linkTarget);
    if (decoded.isEmpty) return null;

    final dir = _posixDirname(noteKey);
    final joined = dir.isEmpty ? decoded : '$dir/$decoded';
    final norm = normalizeRelative(joined);
    if (norm == null) return null;

    final withPrefix = '$notesDirName/$norm';
    if (!isInsideNotes(withPrefix)) return null;

    final base = p.posix.basename(norm);
    final stem = base.contains('.')
        ? base.substring(0, base.lastIndexOf('.'))
        : base;
    if (_reservedNames.contains(stem.toUpperCase())) return null;

    return p.join(vaultRoot, p.joinAll(withPrefix.split('/')));
  }

  /// Build the relative link text that should be written into a note when an
  /// attachment is inserted. Always normalised relative to the note's own
  /// directory so the note stays portable if the folder moves.
  static String relativeLinkFromNote({
    required String notePath,
    required String targetVaultPath,
  }) {
    final noteKey = stripNotesPrefix(notePath);
    if (noteKey == null) return targetVaultPath;
    final dir = _posixDirname(noteKey);
    final relative = p.posix.relative(
      targetVaultPath,
      from: dir.isEmpty ? '.' : dir,
    );
    return relative;
  }

  /// Attachments live in an `attachments/` folder beside the note (v3.0 §9.3),
  /// so that folder moves together with the note.
  static String attachmentsDirForNote(String notePath) {
    final key = stripNotesPrefix(notePath) ?? '';
    final dir = _posixDirname(key);
    final seg = dir.isEmpty ? 'attachments' : '$dir/attachments';
    return '$notesDirName/$seg';
  }

  /// Sanitise one path segment for use in a conflict directory name
  /// (v3.0 §7.2). Replaces characters that are illegal on Windows or in
  /// Nextcloud, collapses control characters, and truncates to 160 UTF-8
  /// bytes so that the `.conflict` suffix and sequence number still fit
  /// inside the 255-byte limit of ext4 / NTFS.
  static String sanitizeSegment(String raw, {int maxBytes = 160}) {
    var s = raw.replaceAll(_illegalSegmentChars, '_');
    s = s.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '_');
    s = s.trim();
    if (s.isEmpty) s = 'untitled';

    // Truncate on a code-point boundary, not mid-surrogate.
    final encoded = utf8.encode(s);
    if (encoded.length <= maxBytes) return s;
    var end = maxBytes;
    while (end > 0 && (encoded[end] & 0xC0) == 0x80) {
      end--; // do not split a multi-byte sequence
    }
    return utf8.decode(encoded.sublist(0, end), allowMalformed: true);
  }

  static String _posixDirname(String posixPath) {
    final i = posixPath.lastIndexOf('/');
    return i < 0 ? '' : posixPath.substring(0, i);
  }

  static String _percentDecodeIfAny(String value) {
    if (!value.contains('%')) return value;
    try {
      return Uri.decodeComponent(value);
    } on ArgumentError {
      // Malformed escape: treat the raw text as the target rather than
      // dropping the link entirely.
      return value;
    }
  }
}