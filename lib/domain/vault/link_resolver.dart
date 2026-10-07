import 'package:path/path.dart' as p;

import '../../core/vault_paths.dart';
import '../entities/parsed_note.dart';

/// How a link was matched to a target. The order of these values *is* the
/// resolution priority from v3. §8.1 — the list was truncated to steps 2/4/6
/// in v2.0, which is why "my link is broken" reports were unanswerable.
enum LinkMethod {
  /// `[[uid:<uuid>]]` — the only unambiguous form, and the reason ADR-2 made
  /// uid part of the file rather than only part of the index.
  byUid,

  /// A full path relative to the note, or vault-relative under `notes/`.
  byFullPath,

  /// A bare filename that matches exactly one note in the same directory.
  bySiblingName,

  /// A bare filename that matches exactly one note anywhere in the vault.
  byUniqueName,

  /// A bare filename that matches two or more notes. Never guessed: the user
  /// picks, and the choice is persisted in `link_aliases`.
  ambiguous,

  /// A URL or a file that is not a note.
  external,

  /// Nothing matched. The note may not exist yet.
  dangling,
}

/// The outcome of resolving one link.
class LinkResolution {
  const LinkResolution({
    required this.method,
    this.targetNoteId,
    this.targetPath,
    this.candidates = const <String>[],
  });

  final LinkMethod method;

  /// Set when the target is a real note.
  final String? targetNoteId;

  /// Set when the target is a note *or* a vault-relative file path.
  final String? targetPath;

  /// Populated for [LinkMethod.ambiguous] so the UI can offer a choice.
  final List<String> candidates;

  bool get isResolved => targetNoteId != null;
  bool get isAmbiguous => method == LinkMethod.ambiguous;
}

/// A snapshot of the vault's paths, used to resolve links.
///
/// Deliberately a value object rather than a live query: reindexing a vault
/// resolves every link in one pass, and issuing one `SELECT` per link turns
/// a 1000-note vault into 3000 queries. Loading once also makes resolution a
/// pure function, which is where the interesting bugs live.
class LinkIndex {
  LinkIndex({
    Map<String, String>? uidToPath,
    Map<String, String>? pathToUid,
    Map<String, List<String>>? byStem,
    this.aliases = const <String, String>{},
  })  : uidToPath = uidToPath ?? <String, String>{},
        pathToUid = pathToUid ?? <String, String>{},
        byStem = byStem ?? <String, List<String>>{};

  /// uid -> `notes/`-prefixed vault path.
  final Map<String, String> uidToPath;

  /// `notes/`-prefixed vault path -> uid.
  final Map<String, String> pathToUid;

  /// Lower-cased filename stem -> every path carrying it.
  final Map<String, List<String>> byStem;

  /// `"sourcePath\u0000alias"` -> target path, from `link_aliases`.
  final Map<String, String> aliases;

  /// Builds a lookup key the same way for aliases, so a change here cannot
  /// silently invalidate every stored disambiguation.
  static String aliasKey(String sourcePath, String alias) =>
      '$sourcePath\u0000${alias.toLowerCase()}';

  static String stemOf(String path) {
    final base = p.posix.basename(path);
    if (!base.contains('.')) return base.toLowerCase();
    return base.substring(0, base.lastIndexOf('.')).toLowerCase();
  }

  /// Names of every note whose filename stem matches, without a directory.
  static String displayNameOf(String path) {
    final base = p.posix.basename(path);
    if (!base.contains('.')) return base;
    return base.substring(0, base.lastIndexOf('.'));
  }

  List<String> candidatesFor(String stem) =>
      byStem[stem.toLowerCase()] ?? const <String>[];
}

/// Resolves one link against a [LinkIndex].
///
/// Pure and synchronous on purpose. Every branch here is a decision about
/// which note a human meant, and those decisions are the ones the whole
/// conflict-safety story rests on, so they are tested as a table rather than
/// exercised through a database.
abstract final class LinkResolver {
  static final RegExp _externalScheme =
      RegExp(r'^(?:[a-zA-Z][a-zA-Z0-9+.-]*:|//)');

  /// Resolves [link], found in the note at [sourcePath] (`notes/`-prefixed).
  static LinkResolution resolve(
    LinkIndex index,
    String sourcePath,
    WikiLink link,
  ) {
    final rawTarget = link.target.trim();

    if (rawTarget.isEmpty) {
      // `[[]]` — an empty link is a typo, not a broken reference. Treat it as
      // dangling but do not guess a target.
      return const LinkResolution(method: LinkMethod.dangling);
    }

    if (_externalScheme.hasMatch(rawTarget)) {
      return LinkResolution(
        method: LinkMethod.external,
        targetPath: rawTarget,
      );
    }

    // Step 1 — explicit identity.
    final uidMatch =
        RegExp(r'^uid:([0-9a-fA-F-]{32,36})$').firstMatch(rawTarget);
    if (uidMatch != null) {
      final uid = uidMatch.group(1)!.toLowerCase();
      final hit = index.uidToPath[uid];
      if (hit != null) {
        return LinkResolution(
          method: LinkMethod.byUid,
          targetNoteId: uid,
          targetPath: hit,
        );
      }
      return const LinkResolution(method: LinkMethod.dangling);
    }

    final decoded = _decode(rawTarget);

    // Step 5 first in *lookup* order only: a stored disambiguation is a
    // decision the user already made, so honouring it before anything else is
    // what stops a rename from silently re-pointing the link somewhere else.
    final aliasHit = index.aliases[LinkIndex.aliasKey(sourcePath, decoded)];
    if (aliasHit != null) {
      final uid = index.pathToUid[aliasHit];
      if (uid != null) {
        return LinkResolution(
          method: LinkMethod.byUid,
          targetNoteId: uid,
          targetPath: aliasHit,
        );
      }
    }

    // Step 2 — a full path. Tried before any name matching so a deliberate
    // `projects/a/notes.md` is never shadowed by `notes.md` in the root.
    final byPath = _matchFullPath(index, sourcePath, decoded);
    if (byPath != null) {
      return LinkResolution(
        method: LinkMethod.byFullPath,
        targetNoteId: index.pathToUid[byPath],
        targetPath: byPath,
      );
    }

    // Attachments and embeds of non-notes (`![[diagram.png]]`) resolve as
    // files. They are resolved by path only; a bare `diagram.png` is a
    // dangling file reference, not a request to find a note called "diagram".
    if (link.isAttachmentLike ||
        (!decoded.contains('/') && _looksLikeFile(decoded))) {
      final filePath = _resolveFilePath(index, sourcePath, decoded);
      return LinkResolution(
        method: LinkMethod.external,
        targetPath: filePath ?? 'notes/$decoded',
      );
    }

    // Steps 3 and 4 — by name, preferring the same directory.
    final stem = decoded.toLowerCase();
    final candidates = index.candidatesFor(stem);

    if (candidates.length == 1) {
      final only = candidates.single;
      return LinkResolution(
        method: _sameDirectory(sourcePath, only)
            ? LinkMethod.bySiblingName
            : LinkMethod.byUniqueName,
        targetNoteId: index.pathToUid[only],
        targetPath: only,
      );
    }

    if (candidates.length > 1) {
      final siblings = candidates
          .where((c) => _sameDirectory(sourcePath, c))
          .toList(growable: false);
      if (siblings.length == 1) {
        return LinkResolution(
          method: LinkMethod.bySiblingName,
          targetNoteId: index.pathToUid[siblings.single],
          targetPath: siblings.single,
        );
      }
      // Still ambiguous even after preferring siblings: two notes in the same
      // folder share a name. Guessing would make the graph a fiction.
      return LinkResolution(
        method: LinkMethod.ambiguous,
        candidates: candidates,
      );
    }

    return const LinkResolution(method: LinkMethod.dangling);
  }

  /// True when the target names a file rather than a note.
  static bool _looksLikeFile(String target) {
    final base = p.posix.basename(target);
    final i = base.lastIndexOf('.');
    if (i <= 0) return false;
    final ext = base.substring(i + 1).toLowerCase();
    return !ext.contains(RegExp(r'[A-Za-z]')) ? false : true;
  }

  static bool _sameDirectory(String a, String b) =>
      _dirnameOf(a) == _dirnameOf(b);

  /// The path of the directory [path] lives in, `notes/`-prefixed and
  /// slash-separated. `''` for a note directly in the notes root.
  static String dirOf(String path) => _dirnameOf(path);

  static String _dirnameOf(String path) {
    final i = path.lastIndexOf('/');
    return i < 0 ? '' : path.substring(0, i);
  }

  static String _decode(String target) {
    if (!target.contains('%')) return target;
    try {
      return Uri.decodeComponent(target);
    } on ArgumentError {
      return target;
    }
  }

  /// Resolves a path-shaped target. Accepts both a path relative to the note
  /// and a vault-relative path written from the root, because both are things
  /// people actually type.
  static String? _matchFullPath(LinkIndex index, String sourcePath, String raw) {
    final fromNote = _resolveFilePath(index, sourcePath, raw);
    if (fromNote != null && index.pathToUid.containsKey(fromNote)) {
      return fromNote;
    }

    // `notes/...` written from the vault root.
    final rooted = VaultPaths.normalizeRelative(raw);
    if (rooted != null && index.pathToUid.containsKey(rooted)) return rooted;

    // A bare relative path from the vault root.
    if (rooted != null && !rooted.startsWith('notes/')) {
      final prefixed = 'notes/$rooted';
      if (index.pathToUid.containsKey(prefixed)) return prefixed;
    }
    return null;
  }

  /// Vault path for a target that is a file, whether or not it is a note.
  static String? _resolveFilePath(
      LinkIndex index, String sourcePath, String raw) {
    final noteKey = VaultPaths.stripNotesPrefix(sourcePath);
    if (noteKey == null) return null;

    final dir = _dirnameOf(noteKey);
    final joined = dir.isEmpty ? raw : '$dir/$raw';
    final norm = VaultPaths.normalizeRelative(joined);
    if (norm == null) return null;

    final withPrefix = 'notes/$norm';
    if (!VaultPaths.isInsideNotes(withPrefix)) return null;
    return withPrefix;
  }
}