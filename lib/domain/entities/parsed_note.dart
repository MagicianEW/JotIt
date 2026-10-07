import 'package:meta/meta.dart';

/// One `[[...]]` or `![[...]]` reference found in a note.
@immutable
class WikiLink {
  const WikiLink({
    required this.target,
    required this.isEmbed,
    required this.anchor,
    required this.blockId,
    required this.alias,
    required this.start,
    required this.end,
  });

  /// Link text before `|`, `#` or the closing brackets. May itself be a path.
  final String target;

  /// `![[...]]` rather than `[[...]]`.
  final bool isEmbed;

  /// `[[note#Heading]]` — optional heading anchor.
  final String? anchor;

  /// `[[note#^blockid]]` — block-level reference.
  final String? blockId;

  /// `[[note|shown text]]` — display override, never a resolution key.
  final String? alias;

  final int start;
  final int end;

  bool get isAttachmentLike =>
      isEmbed &&
      target.contains('.') &&
      !target.endsWith('.md');

  @override
  String toString() =>
      'WikiLink(${isEmbed ? '!' : ''}[[$target]]${anchor != null ? '#$anchor' : ''}'
      '${alias != null ? '|$alias' : ''})';
}

/// Result of parsing one Markdown file.
@immutable
class ParsedNote {
  const ParsedNote({
    required this.frontMatter,
    required this.rawFrontMatter,
    required this.body,
    required this.title,
    required this.uid,
    required this.links,
    required this.tags,
    required this.frontMatterMalformed,
    required this.hasFrontMatter,
  });

  /// Parsed keys. Empty when there is no front matter or it failed to parse.
  final Map<String, Object?> frontMatter;

  /// The front-matter block exactly as it appeared on disk, including its
  /// fences and every comment. Re-serialising [frontMatter] would silently
  /// delete unknown keys and comments that other tools depend on, so writes
  /// patch this text surgically instead (see `FrontMatterPatcher`).
  final String rawFrontMatter;

  /// Body text with the front-matter block removed.
  final String body;

  /// Resolved title, per the three-step fallback in v3.0 §4.4.
  final String title;

  /// `uid` from front matter — the cross-device logical identity (ADR-2).
  /// `null` means the note has never been stamped; `ReindexVault` writes one.
  final String? uid;

  final List<WikiLink> links;
  final List<String> tags;

  /// True when a front-matter block exists but YAML would not parse.
  final bool frontMatterMalformed;

  final bool hasFrontMatter;

  @override
  String toString() =>
      'ParsedNote(title: $title, uid: $uid, links: ${links.length}, '
      'tags: $tags, malformedFM: $frontMatterMalformed)';
}