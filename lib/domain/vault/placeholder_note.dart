import 'dart:convert';

import '../../core/vault_paths.dart';
import '../../data/vault/note_file_store.dart';
import '../entities/front_matter_patcher.dart';

/// Where a placeholder should live, and whether the name had to be cleaned up.
class PlaceholderPlan {
  const PlaceholderPlan({
    required this.notePath,
    required this.title,
    this.sanitized = false,
  });

  /// `notes/`-prefixed vault path of the note to create.
  final String notePath;

  /// Front-matter title, taken from the link text.
  final String title;

  /// True when [notePath] no longer matches the text the user typed — the
  /// caller must say so rather than let the link stay mysteriously broken.
  final bool sanitized;
}

/// Creates the "no target" note from v3.0 §9.1 step 6.
///
/// Scope note, because this is the one place in the app that creates files the
/// user did not explicitly name: a placeholder is written **only** when a
/// person asks for one by following a dangling link. Reindex and sync never
/// call this. A vault that half-synced overnight would otherwise sprout
/// hundreds of empty notes on every device, and a placeholder written from a
/// stale index is a note the user never asked for and cannot delete without a
/// fight.
///
/// The file is the truth (ADR-1), so the placeholder is an ordinary note with
/// an ordinary front matter block, `is_deleted = 0`, and a real `uid` written
/// into it — otherwise each device would mint a different identity for it on
/// the next index pass. `placeholder: true` is what lets the UI draw it
/// dashed (§9.1) after the fact, on every device, with no extra channel.
abstract final class PlaceholderNoteFactory {
  /// Front-matter key marking a note as a not-yet-written placeholder.
  static const String markerKey = 'placeholder';

  static final RegExp _scheme = RegExp(r'^(?:[a-zA-Z][a-zA-Z0-9+.-]+:|//)');

  /// Works out where a placeholder for [target] should go, or null when the
  /// link is not something a note can be made for.
  ///
  /// [sourcePath] is the `notes/`-prefixed path of the note holding the link.
  static PlaceholderPlan? plan({
    required String sourcePath,
    required String target,
    String? displayText,
  }) {
    final decoded = _decode(target.trim());
    if (decoded.isEmpty) return null;

    // Only real notes can be created. A URL has no file to make, the `uid:`
    // namespace refers to a note that exists or does not, and an attachment
    // target names bytes rather than a note.
    if (_scheme.hasMatch(decoded)) return null;
    if (RegExp(r'^uid:', caseSensitive: false).hasMatch(decoded)) return null;
    if (_isNonNoteFile(decoded)) return null;

    // An absolute path names something outside the vault, and re-reading it
    // as vault-relative would create a note at a path the user never wrote.
    if (decoded.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(decoded)) {
      return null;
    }

    final noteKey = VaultPaths.stripNotesPrefix(sourcePath);
    if (noteKey == null) return null;

    // §9.1: a bare filename is resolved beside the linking note (step 3), a
    // multi-segment target is a full path from the vault root (step 2). Both
    // land on the file the resolver will later pick, so the placeholder
    // cannot come back as a link that points at itself.
    final withoutNotesPrefix = decoded.startsWith('$notesPrefix/')
        ? decoded.substring(notesPrefix.length + 1)
        : decoded;
    final sourceDir = _dirnameOf(noteKey);
    // `./x` and `../x` say "relative to me" in as many words, so they are
    // honoured even though they contain a separator.
    final explicitlyRelative = withoutNotesPrefix.startsWith('./') ||
        withoutNotesPrefix.startsWith('../');
    final isSourceRelative = explicitlyRelative ||
        (!withoutNotesPrefix.contains('/') && sourceDir.isNotEmpty);
    final relative = !isSourceRelative || sourceDir.isEmpty
        ? withoutNotesPrefix
        : '$sourceDir/$withoutNotesPrefix';

    final norm = VaultPaths.normalizeRelative(relative);
    if (norm == null) return null;

    final segments = norm.split('/');
    for (final seg in segments) {
      if (VaultPaths.hasIllegalFileNameChar(seg)) return null;
    }

    // The `.md` suffix comes off before sanitising, so `nul.md` is judged as
    // the device name `nul` and becomes `nul_.md` rather than `nul.md_.md`.
    final cleaned = <String>[];
    for (var i = 0; i < segments.length; i++) {
      final seg = segments[i];
      if (i == segments.length - 1 && seg.toLowerCase().endsWith('.md')) {
        cleaned.add(
            '${VaultPaths.sanitizeFileName(seg.substring(0, seg.length - 3))}.md');
      } else {
        cleaned.add(VaultPaths.sanitizeFileName(seg));
      }
    }
    // Compared before the `.md` suffix is added, otherwise every link reads
    // as "sanitized" and the UI warns about notes it never changed.
    final wasSanitized = cleaned.join('/') != norm;

    final dirs = cleaned.take(cleaned.length - 1).toList(growable: false);
    var filename = cleaned.last;
    if (!filename.toLowerCase().endsWith('.md')) filename = '$filename.md';

    final withPrefix = dirs.isEmpty
        ? '$notesPrefix/$filename'
        : '$notesPrefix/${dirs.join('/')}/$filename';
    if (!VaultPaths.isInsideNotes(withPrefix)) return null;

    return PlaceholderPlan(
      notePath: withPrefix,
      title: _titleFor(displayText, decoded),
      sanitized: wasSanitized,
    );
  }

  /// Writes the placeholder. Returns null when the link cannot become a note,
  /// and a plan with `notePath` set — but no file written — when something
  /// already occupies that path.
  ///
  /// The uid is a parameter rather than generated here so the caller can mint
  /// it through whatever id source the app uses and log it once.
  static Future<PlaceholderPlan?> create({
    required NoteFileStore store,
    required String sourcePath,
    required String target,
    required String uid,
    String? displayText,
  }) async {
    final resolved = plan(
      sourcePath: sourcePath,
      target: target,
      displayText: displayText,
    );
    if (resolved == null) return null;

    final existing = store.fileFor(resolved.notePath);
    if (existing != null && await existing.exists()) {
      // Never overwrite: the link resolves to *something*, and JotIt does not
      // get to decide that file is empty enough to be disposable.
      return null;
    }

    await store.writeAtomic(
        resolved.notePath, utf8.encode(_render(resolved, uid)));
    return resolved;
  }

  /// The placeholder's initial content.
  ///
  /// Built through [FrontMatterPatcher] rather than a YAML string so the uid
  /// and marker go through exactly the same quoting rules as every other write.
  static String _render(PlaceholderPlan plan, String uid) {
    var text = '# ${plan.title}\n';
    text = FrontMatterPatcher.withStringValue(text, 'title', plan.title);
    text = FrontMatterPatcher.withStringValue(text, 'uid', uid);
    text = FrontMatterPatcher.withStringValue(text, markerKey, 'true');
    return '$text\n';
  }

  static String _titleFor(String? displayText, String decoded) {
    final candidate = (displayText != null && displayText.trim().isNotEmpty)
        ? displayText.trim()
        : decoded;
    // Title from the link *text*, not from the final filename: `[[projects/jotit/design]]`
    // is called "design" in a list, not "design.md".
    final base = candidate.contains('/')
        ? candidate.substring(candidate.lastIndexOf('/') + 1)
        : candidate;
    final stem = base.toLowerCase().endsWith('.md')
        ? base.substring(0, base.length - 3)
        : base;
    return stem.trim().isEmpty ? 'untitled' : stem.trim();
  }

  static bool _isNonNoteFile(String decoded) {
    final base = decoded.contains('/')
        ? decoded.substring(decoded.lastIndexOf('/') + 1)
        : decoded;
    final i = base.lastIndexOf('.');
    if (i <= 0) return false;
    final ext = base.substring(i + 1);
    return ext.toLowerCase() != 'md' && RegExp(r'[A-Za-z]').hasMatch(ext);
  }

  static String _dirnameOf(String posixPath) {
    final i = posixPath.lastIndexOf('/');
    return i < 0 ? '' : posixPath.substring(0, i);
  }

  static String _decode(String value) {
    if (!value.contains('%')) return value;
    try {
      return Uri.decodeComponent(value);
    } on ArgumentError {
      return value;
    }
  }

  static const String notesPrefix = VaultPaths.notesDirName;
}