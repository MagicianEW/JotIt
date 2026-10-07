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
  ///
  /// Both operands are put in the **same frame** first — both stripped of
  /// `notes/` — because the two arrive in different ones: [notePath] is
  /// vault-relative by convention, and mixing a `notes/`-relative `from` with
  /// a vault-relative `to` does not produce a wrong answer so much as a
  /// plausible one: a note at `notes/a.md` came out linking
  /// `notes/attachments/x.png`, which resolves to `notes/notes/attachments/x.png`
  /// and silently finds nothing.
  static String relativeLinkFromNote({
    required String notePath,
    required String targetVaultPath,
  }) {
    final noteKey = stripNotesPrefix(notePath);
    if (noteKey == null) return targetVaultPath;
    final targetKey = stripNotesPrefix(targetVaultPath);
    // Outside the notes tree: not something an attachment ever is, and the
    // caller is expected to have refused it already (§9.3 rule 3). Handing the
    // path back untouched keeps the failure visible rather than inventing a
    // relative path that happens to look fine.
    if (targetKey == null) return targetVaultPath;

    final dir = _posixDirname(noteKey);
    return p.posix.relative(
      targetKey,
      from: dir.isEmpty ? '.' : dir,
    );
  }

  /// Attachments live in an `attachments/` folder beside the note (v3.0 §9.3),
  /// so that folder moves together with the note.
  static String attachmentsDirForNote(String notePath) {
    final key = stripNotesPrefix(notePath) ?? '';
    final dir = _posixDirname(key);
    final seg = dir.isEmpty ? 'attachments' : '$dir/attachments';
    return '$notesDirName/$seg';
  }

  /// The directory name that marks a subtree as attachments rather than notes.
  static const String attachmentsDirName = 'attachments';

  /// True when [vaultPath] names an attachment rather than a note.
  ///
  /// The test is the *directory*, not the extension: `notes/a/b.png` is a note
  /// that happens to be called `.png` (and should be ignored as one, or at
  /// least never uploaded as an attachment), while `notes/b/attachments/x.png`
  /// is an attachment whatever it is called. §9.3 is what put the directory
  /// there, so the directory is what identifies one.
  ///
  /// This lives here rather than in the scanner because three unrelated places
  /// have to agree on it — the scanner (what to index), the sync engine (what
  /// to transfer, and under *different* rules, §5.5), and anything that asks
  /// "is this a note or a picture". Three private copies of the same three-line
  /// predicate is three chances to disagree, and the sync engine disagreeing
  /// with the scanner is how an image ends up in `_conflicts/`.
  static bool isAttachmentPath(String vaultPath) {
    final norm = normalizeRelative(vaultPath);
    if (norm == null) return false;
    final relative = stripNotesPrefix(norm);
    if (relative == null) return false;
    final segments = relative.split('/');
    // The last segment is the file name; an `attachments` among the
    // directories above it is what makes this an attachment.
    return segments.sublist(0, segments.length - 1).contains(attachmentsDirName);
  }

  /// True when [name] contains a character that cannot appear in a filename on
  /// Windows at all.
  ///
  /// Distinct from "creatable with a different name": a name holding one of
  /// these can never equal the link text, so making a note for it would
  /// produce an orphan file rather than a resolved link.
  static bool hasIllegalFileNameChar(String name) =>
      _illegalSegmentChars.hasMatch(name) ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(name);

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

  /// Sanitise a *filename* — stricter than [sanitizeSegment], because a name
  /// that merely looks legal can still be uncreatable or, worse, silently
  /// alias another file.
  ///
  /// Two Windows behaviours drive the extras:
  ///
  ///  * `report.` and `report` are the same file. Trailing dots and spaces are
  ///    stripped by the filesystem without any error, so `[[v1.2]]` and
  ///    `[[v1.2.]]` would land on one note and fight over it.
  ///  * `CON`, `NUL`, `COM1`… cannot be created at all; worse, a path
  ///    containing one is treated as a device reference by some APIs.
  ///
  /// Returns the cleaned name; never empty.
  static String sanitizeFileName(String raw, {String fallback = 'untitled'}) {
    var s = sanitizeSegment(raw, maxBytes: 100)
        .replaceAll(RegExp(r'[. ]+$'), '')
        .trim();
    if (s.isEmpty) s = fallback;

    final stem = s.contains('.')
        ? s.substring(0, s.lastIndexOf('.')).toUpperCase()
        : s.toUpperCase();
    if (_reservedNames.contains(stem)) {
      s = '${s}_';
    }
    return s;
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