import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../app/providers.dart';
import '../core/vault_paths.dart';
import '../domain/entities/markdown_parser.dart';
import '../domain/entities/markdown_syntax.dart';
import '../domain/entities/parsed_note.dart';
import '../domain/vault/link_resolver.dart';
import '../domain/vault/mention_index.dart';
import 'audio_clip.dart';
import 'theme.dart';

/// Schemes invented by the preview pipeline. Wiki syntax does not survive a
/// CommonMark renderer, so `renderableBody` rewrites `[[target]]` /
/// `![[target]]` into ordinary markdown links pointing at these schemes, and
/// the tap / image builders decode them back into a [WikiLink] for
/// [LinkResolver] — the same resolver the sync engine's link graph uses.
const String _linkScheme = 'jotit-note';
const String _embedScheme = 'jotit-embed';

final RegExp _wikiLink = RegExp(r'(!?)\[\[([^\[\]\n]*)\]\]');

/// Image extensions the preview can render from disk. Anything else inside an
/// embed becomes a labelled placeholder rather than a broken picture frame.
const Set<String> _imageExtensions = {
  'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp',
  // HEIC is what a phone hands over by default, and the attachment policy
  // already knows the type — a preview that refused to show it would make
  // the app look like it had lost the picture.
  'heic', 'heif', 'tif', 'tiff',
};

/// Audio extensions the preview can play from disk.
///
/// A recorded clip is an attachment like any other — it lives in the vault,
/// it syncs, it is immutable — and it is written into the note with the same
/// `![[…]]` embed syntax a picture uses. The difference is only what the
/// page does with it: a picture is shown, a clip is played.
const Set<String> _audioExtensions = {
  'm4a', 'mp3', 'wav', 'ogg', 'aac', 'flac', 'm4b',
};

/// Turns raw note text into markdown the renderer understands.
///
/// Two things happen here, in order:
///
///  1. The front-matter block is stripped. It is machine metadata the user
///     asked to keep out of sight (the status bar already reports uid/BOM).
///  2. Wiki links are rewritten to the internal schemes. The original text is
///     never mutated — only the copy handed to the renderer.
///
/// Fenced blocks and inline code spans are skipped: `[[a]]` inside a code
/// block is documentation *about* the syntax, not a link.
String renderableBody(
  String text, {
  MentionIndex? mentions,
  String? sourcePath,
}) {
  final body = const MarkdownParser().splitFrontMatter(text).body;

  // Character ranges inside code, so wiki syntax there stays literal.
  final masked = _codeRanges(body);

  // The two kinds of thing that are not prose: the links the user wrote,
  // and the mentions the app worked out on its own. Both become links;
  // the difference is that only the first one is in the file.
  final edits = <({int start, int end, String text})>[];

  for (final m in _wikiLink.allMatches(body)) {
    if (masked.any((r) => m.start >= r.$1 && m.end <= r.$2)) continue;
    edits.add((start: m.start, end: m.end, text: _rewriteWikiLink(m)));
  }

  if (mentions != null) {
    for (final mention
        in mentions.findIn(body, selfPath: sourcePath, masked: masked)) {
      // A mention inside a link the user wrote is that link's business.
      if (edits.any((e) => mention.start < e.end && e.start < mention.end)) {
        continue;
      }
      edits.add((
        start: mention.start,
        end: mention.end,
        text: _rewriteMention(mention),
      ));
    }
  }

  // Longest edit first where two start at the same place, so a mention
  // that overlaps a link never truncates it.
  edits.sort((a, b) =>
      a.start != b.start ? a.start.compareTo(b.start) : b.end.compareTo(a.end));

  final out = StringBuffer();
  var cursor = 0;
  for (final e in edits) {
    if (e.start < cursor) continue; // overlaps an edit already written
    out.write(body.substring(cursor, e.start));
    out.write(e.text);
    cursor = e.end;
  }
  out.write(body.substring(cursor));
  return out.toString();
}

/// An automatic association: a word in the prose that is another note's
/// name.
///
/// The label is the text as the user wrote it, and the target is the
/// note's *path* — the path rather than the name, because two notes can
/// share a name and a link that guesses between them is a link that lies.
/// The path is what [LinkResolver] resolves by full path, exactly and
/// without an index lookup by name.
String _rewriteMention(Mention mention) {
  final label = _escapeMentionLabel(mention.keyword);
  return '[$label]($_linkScheme:${Uri.encodeComponent(mention.target.path)})';
}

/// The label of an automatic association is prose the user wrote, not a
/// name the app chose — so it can contain whatever a sentence can contain.
String _escapeMentionLabel(String label) => label
    .replaceAll('\\', r'\\')
    .replaceAll('[', r'\[')
    .replaceAll(']', r'\]')
    .replaceAll('*', r'\*')
    .replaceAll('_', r'\_')
    .replaceAll('`', r'\`');

/// One wiki link -> one markdown link or image.
///
/// The alias and anchor are resolved here because the markdown link carries
/// only a destination and a label: `[[note#Head|alias]]` renders the alias (or
/// `note › Head` when there is none) and encodes bare `note` in the href. The
/// href is percent-encoded as a whole, which keeps spaces and parentheses out
/// of the markdown destination — the two characters CommonMark cannot abide
/// unescaped in that position.
String _rewriteWikiLink(RegExpMatch m) {
  final embed = m.group(1) == '!';
  final inner = m.group(2) ?? '';

  final pipe = inner.indexOf('|');
  final targetPart = (pipe < 0 ? inner : inner.substring(0, pipe)).trim();
  final alias = pipe < 0 ? null : inner.substring(pipe + 1).trim();

  String target = targetPart;
  String? anchor;
  final hash = targetPart.indexOf('#');
  if (hash >= 0) {
    final tail = targetPart.substring(hash + 1).trim();
    target = targetPart.substring(0, hash).trim();
    if (tail.isNotEmpty && !tail.startsWith('^')) anchor = tail;
  }

  if (target.isEmpty) return m.group(0)!; // `[[]]` — a typo, keep it literal.

  final label = _escapeLabel(alias ?? (anchor == null ? target : '$target › $anchor'));
  final scheme = embed ? _embedScheme : _linkScheme;
  // The `!` prefix is what makes this an image request rather than a link;
  // dropping it silently turns every embed into a plain hyperlink.
  return '${embed ? '!' : ''}[$label]($scheme:${Uri.encodeComponent(target)})';
}

/// Backslash-escapes the two characters that would terminate a markdown link
/// label early. CommonMark resolves `\[` / `\]` back to the literal brackets.
String _escapeLabel(String label) =>
    label.replaceAll('[', r'\[').replaceAll(']', r'\]');

/// Fenced blocks and inline code spans, as (start, end) offsets — the same
/// masking rule `MarkdownParser.extractLinks` applies to indexing, so what the
/// preview renders as a link agrees with what the link graph indexes.
///
/// 规则住在领域层（`markdown_syntax.dart`），因为反向关联也要用同一份：
/// 两边各写一份，它们会各自漂移。
List<(int, int)> _codeRanges(String body) => codeRegions(body);

/// The rendered note.
///
/// Reads the editor's live text, so a save is not needed to see the current
/// state. Resolution goes through [LinkResolver] with the index loaded from
/// the vault, which is what makes `[[b]]` jump to the same note the sync
/// engine thinks `b` is.
class NotePreview extends ConsumerStatefulWidget {
  const NotePreview({
    super.key,
    required this.text,
    required this.onOpenNote,
    required this.onTapBlock,
    this.sourcePath,
  });

  final String text;

  /// The path of the note this preview is showing.
  ///
  /// The preview reads this rather than the open-note provider, because the
  /// provider can already name the *next* note while this preview is still
  /// showing the previous one — the reload window after a link jump. A
  /// relative link resolved against the wrong path opens the wrong note,
  /// and an image lands on the wrong file.
  final String? sourcePath;

  /// Called when a wiki link resolves to an existing note. The path is the
  /// `notes/`-prefixed vault path the index holds.
  final void Function(String targetPath) onOpenNote;

  /// Called when the user taps a rendered block. The argument is the plain
  /// text of the block the tap landed in — the editor uses it to find the
  /// matching source line and put the caret there.
  final void Function(String blockText) onTapBlock;

  @override
  ConsumerState<NotePreview> createState() => _NotePreviewState();
}

/// Typography for the reading surface.
///
/// These are the four things the reference apps get right and the generated
/// Material defaults get wrong: line height (1.75, not 1.4), heading weight
/// instead of heading colour, block spacing that breathes, and one accent
/// colour reserved for links. Nothing here is decorative — it is all about
/// staying readable for a long sitting.
MarkdownStyleSheet _previewStyleSheet(ThemeData theme) {
  final c = theme.colorScheme;
  final mono = JotItTokens.monoBase;
  final bool dark = theme.brightness == Brightness.dark;

  return MarkdownStyleSheet.fromTheme(theme).copyWith(
    p: theme.textTheme.bodyLarge?.copyWith(height: 1.75, color: c.onSurface),
    pPadding: EdgeInsets.zero,
    blockSpacing: 12,
    // Headings keep the body colour; size and weight do the work (Bear and
    // Notion both refuse to tint headings, and they are right).
    h1: TextStyle(
        fontSize: 24, fontWeight: FontWeight.w700, height: 1.3, color: c.onSurface),
    h1Padding: const EdgeInsets.only(top: 12, bottom: 4),
    h2: TextStyle(
        fontSize: 20, fontWeight: FontWeight.w600, height: 1.35, color: c.onSurface),
    h2Padding: EdgeInsets.zero,
    h3: TextStyle(
        fontSize: 17, fontWeight: FontWeight.w600, height: 1.4, color: c.onSurface),
    h3Padding: EdgeInsets.zero,
    h4: TextStyle(
        fontSize: 15, fontWeight: FontWeight.w600, height: 1.4,
        color: c.onSurfaceVariant),
    h4Padding: EdgeInsets.zero,
    h5: TextStyle(
        fontSize: 15, fontWeight: FontWeight.w600, height: 1.4,
        color: c.onSurfaceVariant),
    h5Padding: EdgeInsets.zero,
    h6: TextStyle(
        fontSize: 15, fontWeight: FontWeight.w600, height: 1.4,
        color: c.onSurfaceVariant),
    h6Padding: EdgeInsets.zero,
    em: TextStyle(fontStyle: FontStyle.italic, color: c.onSurface),
    strong: TextStyle(fontWeight: FontWeight.w600, color: c.onSurface),
    del: TextStyle(
        decoration: TextDecoration.lineThrough, color: c.onSurfaceVariant),
    // The only coloured text in a note. No underline: the colour already says
    // "this is a link", and a line under every reference is noise.
    a: TextStyle(
      color: c.primary,
      decoration: TextDecoration.none,
    ),
    code: mono.copyWith(
      backgroundColor: c.primaryContainer,
      color: c.onPrimaryContainer,
    ),
    blockquote: theme.textTheme.bodyMedium?.copyWith(color: c.onSurfaceVariant),
    blockquotePadding:
        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    blockquoteDecoration: BoxDecoration(
      color: c.surfaceContainerLow,
      border: Border(left: BorderSide(color: c.primary, width: 3)),
      borderRadius: const BorderRadius.horizontal(
        right: Radius.circular(JotItTokens.rSm),
      ),
    ),
    codeblockDecoration: BoxDecoration(
      color: c.surfaceContainer,
      borderRadius: BorderRadius.circular(JotItTokens.rSm),
      border: Border.all(color: c.outlineVariant),
    ),
    codeblockPadding: const EdgeInsets.all(12),
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(color: c.outlineVariant)),
    ),
    listBullet: TextStyle(color: c.onSurfaceVariant),
    tableBorder: TableBorder.all(color: c.outlineVariant, width: 1),
    tableHead: TextStyle(
      fontWeight: FontWeight.w600,
      fontSize: 13.5,
      color: c.onSurface,
    ),
    tableBody: TextStyle(fontSize: 13.5, color: c.onSurface),
    tableCellsPadding:
        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    // A checked task box is a primary-coloured tick; unchecked boxes stay
    // neutral so a long checklist does not turn the page green.
    checkbox: TextStyle(color: dark ? c.primary : c.primary),
  );
}


class _NotePreviewState extends ConsumerState<NotePreview> {
  LinkIndex? _index;
  MentionIndex? _mentions;
  String? _vaultRoot;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final session = await ref.read(vaultProvider.future);
    final index = await session.loadLinkIndex();
    final mentions = await session.loadMentionIndex();
    if (!mounted) return;
    setState(() {
      _index = index;
      _mentions = mentions;
      _vaultRoot = session.vaultRoot;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The gesture wrapper is what makes the rendered page a *viewer you can
    // tap through*: a tap lands on some RenderParagraph in the hit-test path,
    // and its plain text identifies the source block. Tapping a wiki link
    // still wins the gesture arena (the inline recognizer sits deeper), so
    // links navigate instead of repositioning the caret.
    //
    // The scroll view lives *inside* the gesture detector, never around it.
    // `MarkdownBody` does not scroll (flutter_markdown_plus leaves that to the
    // caller), and a note taller than the window used to be clipped at both
    // ends with no way to reach the middle. Wrapping the detector instead
    // would move the coordinate space the tap position is reported in, and
    // `_handleTap` would then look for the paragraph at the wrong offset.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (details) => _handleTap(context, details.localPosition),
      child: SingleChildScrollView(
        child: MarkdownBody(
          key: ValueKey(
            'md-index-${_index != null}-mentions-${_mentions != null}'
            '-root-${_vaultRoot != null}',
          ),
          data: renderableBody(
            widget.text,
            mentions: _mentions,
            sourcePath: widget.sourcePath ?? ref.read(openNoteProvider),
          ),
          softLineBreak: true,
          onTapLink: _onTapLink,
          imageBuilder: (uri, title, alt) => _buildImage(uri, title, alt, theme),
          styleSheet: _previewStyleSheet(theme),
        ),
      ),
    );
  }

  /// Finds the rendered paragraph the tap landed in and reports its text.
  void _handleTap(BuildContext context, Offset localPosition) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final result = BoxHitTestResult();
    if (!box.hitTest(result, position: localPosition)) return;
    for (final entry in result.path) {
      final target = entry.target;
      if (target is RenderParagraph) {
        widget.onTapBlock(target.text.toPlainText());
        return;
      }
    }
  }

  WikiLink _decodedLink(Uri uri, {required bool embed}) {
    final raw = Uri.decodeComponent(uri.path);
    return WikiLink(
      target: raw,
      isEmbed: embed,
      anchor: null,
      blockId: null,
      alias: null,
      start: 0,
      end: 0,
    );
  }

  void _onTapLink(String text, String? href, String title) {
    final uri = href == null ? null : Uri.tryParse(href);
    if (uri == null) return;

    final scheme = uri.scheme;
    if (scheme != _linkScheme && scheme != _embedScheme) {
      _snack('外部链接：${uri.toString()}');
      return;
    }

    final index = _index;
    if (index == null) {
      _snack('链接索引尚未就绪，稍后再试');
      return;
    }

    // The note this preview is showing, not the one the provider currently
    // names — see [NotePreview.sourcePath].
    final sourcePath = widget.sourcePath ?? ref.read(openNoteProvider) ?? '';
    final resolution = LinkResolver.resolve(
      index,
      sourcePath,
      _decodedLink(uri, embed: scheme == _embedScheme),
    );

    // Only links that resolved to a note actually existing in the vault
    // trigger navigation. A dangling link opening an empty editor reads as
    // data loss; a message reads as what it is.
    if (resolution.targetNoteId != null && resolution.targetPath != null) {
      widget.onOpenNote(resolution.targetPath!);
      return;
    }

    switch (resolution.method) {
      case LinkMethod.ambiguous:
        _snack('这个名字对应多个笔记，请改用完整路径');
      case LinkMethod.external:
        _snack('外部链接：${resolution.targetPath}');
      default:
        // The path in the href is percent-encoded, and showing that form to
        // the user means showing "my%20note.md" for a note they wrote as
        // "my note.md" — a name they cannot act on.
        _snack('未找到笔记：${_decodedPath(uri.path)}');
    }
  }

  Widget _buildImage(Uri uri, String? title, String? alt, ThemeData theme) {
    // Real web images keep working; there is no reason to break standard
    // markdown while adding wiki embeds.
    if (uri.scheme == 'http' || uri.scheme == 'https') {
      return _framed(
        Image.network(uri.toString(), errorBuilder: _imageError(alt)),
        theme,
      );
    }

    String target;
    if (uri.scheme == _embedScheme) {
      target = Uri.decodeComponent(uri.path);
    } else if (uri.scheme.isEmpty) {
      target = uri.toString(); // ordinary relative `![](x.png)`
    } else {
      return _imagePlaceholder(alt, theme);
    }

    final vaultRoot = _vaultRoot;
    // The note this preview is showing, not the one the provider currently
    // names — see [NotePreview.sourcePath].
    final sourcePath = widget.sourcePath ?? ref.read(openNoteProvider) ?? '';
    // An index is not required for path-shaped targets: the attachment branch
    // of the resolver is pure path arithmetic. An empty index only means a
    // bare `![[img.png]]` cannot be found by name yet.
    final resolution = LinkResolver.resolve(
      _index ?? LinkIndex(),
      sourcePath,
      WikiLink(
        target: target,
        isEmbed: true,
        anchor: null,
        blockId: null,
        alias: null,
        start: 0,
        end: 0,
      ),
    );

    final vaultPath = resolution.targetPath;
    final norm = vaultPath == null ? null : VaultPaths.normalizeRelative(vaultPath);
    if (vaultRoot == null ||
        norm == null ||
        !VaultPaths.isInsideNotes(norm)) {
      return _imagePlaceholder(alt, theme);
    }

    final extension =
        p.posix.extension(norm).replaceFirst('.', '').toLowerCase();
    final fsPath =
        p.join(vaultRoot, p.joinAll(norm.split('/')));

    // A clip is played where it is referenced, not shown. It arrives through
    // the same embed syntax a picture uses, so without this branch it would
    // land in the "cannot display this image" placeholder — which is a lie
    // about a file the app can play perfectly well.
    if (_audioExtensions.contains(extension)) {
      return AudioClip(
        path: fsPath,
        playerFactory: ref.read(clipPlayerFactoryProvider),
        label: _clipLabel(alt, target),
      );
    }

    if (!_imageExtensions.contains(extension)) {
      return _imagePlaceholder(alt, theme);
    }

    return _framed(
      Image.file(
        File(fsPath),
        fit: BoxFit.contain,
        errorBuilder: _imageError(alt),
      ),
      theme,
    );
  }

  /// Pictures sit on the page like prints on a desk: rounded corner, one
  /// hairline edge, no shadow.
  Widget _framed(Widget image, ThemeData theme) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(JotItTokens.rSm),
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: theme.colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(JotItTokens.rSm),
            ),
            child: image,
          ),
        ),
      );

  ImageErrorWidgetBuilder _imageError(String? alt) =>
      (BuildContext context, Object error, StackTrace? stackTrace) =>
          _imagePlaceholder(alt, Theme.of(context));

  /// What a recorded clip is called on screen.
  ///
  /// The label of a wiki embed is the *target* unless the user wrote one:
  /// `![[clip.m4a]]` renders as a link labelled `clip.m4a`, and
  /// `![[clip.m4a|周五的想法]]` renders as one labelled `周五的想法`. So the
  /// label is only worth showing when it is not just the file name again —
  /// "attachments/clip.m4a" is not a name anybody gave anything.
  static String _clipLabel(String? alt, String target) {
    final text = alt?.trim() ?? '';
    if (text.isEmpty || text == target) return '录音';
    return text;
  }

  Widget _imagePlaceholder(String? alt, ThemeData theme) {
    final label = (alt == null || alt.isEmpty) ? '无法显示的图片' : alt;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(JotItTokens.rXs),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.broken_image_outlined,
              size: 18, color: theme.colorScheme.outline),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// The path as the user wrote it, not as it travels in a URL.
  ///
  /// A malformed escape is left alone rather than turned into an error: the
  /// message is about a note that was not found, and a decoder failure would
  /// replace that with a different problem the user cannot do anything about.
  String _decodedPath(String path) {
    try {
      return Uri.decodeComponent(path);
    } on ArgumentError {
      return path;
    } on FormatException {
      return path;
    }
  }
}
