import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../app/providers.dart';
import '../core/vault_paths.dart';
import '../domain/entities/markdown_parser.dart';
import '../domain/entities/parsed_note.dart';
import '../domain/vault/link_resolver.dart';
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
String renderableBody(String text) {
  final body = const MarkdownParser().splitFrontMatter(text).body;

  // Character ranges inside code, so wiki syntax there stays literal.
  final masked = _codeRanges(body);
  final out = StringBuffer();
  var cursor = 0;
  for (final m in _wikiLink.allMatches(body)) {
    if (masked.any((r) => m.start >= r.$1 && m.end <= r.$2)) continue;
    out.write(body.substring(cursor, m.start));
    out.write(_rewriteWikiLink(m));
    cursor = m.end;
  }
  out.write(body.substring(cursor));
  return out.toString();
}

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
List<(int, int)> _codeRanges(String body) {
  final ranges = <(int, int)>[];
  final lines = body.split('\n');
  var offset = 0;
  RegExp? closeFence;
  var fenceStart = -1;

  for (final line in lines) {
    final lineStart = offset;
    offset += line.length + 1;
    final trimmed = line.trimLeft();

    if (closeFence != null) {
      if (closeFence.hasMatch(trimmed)) {
        ranges.add((fenceStart, offset));
        closeFence = null;
        fenceStart = -1;
      }
      continue;
    }

    final open = RegExp(r'^(`{3,}|~{3,})').firstMatch(trimmed);
    if (open != null) {
      final marker = open.group(1)!;
      final sameLineClose = RegExp('^\\$marker\\s*\$').firstMatch(
          trimmed.substring(open.end));
      if (sameLineClose != null) {
        ranges.add((lineStart, offset)); // opened and closed on one line
      } else {
        closeFence = RegExp('^\\${marker[0]}{${marker.length},}\\s*\$');
        fenceStart = lineStart;
      }
      continue;
    }

    // Inline spans on this line: `code`, including an odd stray backtick
    // running to end of line.
    for (final m in RegExp(r'`+[^`]*`+|`+[^`]*$').allMatches(line)) {
      ranges.add((lineStart + m.start, lineStart + m.end));
    }
  }
  if (closeFence != null) ranges.add((fenceStart, offset));
  return ranges;
}

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
  });

  final String text;

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
  String? _vaultRoot;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final session = await ref.read(vaultProvider.future);
    final index = await session.loadLinkIndex();
    if (!mounted) return;
    setState(() {
      _index = index;
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
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (details) => _handleTap(context, details.localPosition),
      child: MarkdownBody(
        key: ValueKey('md-index-${_index != null}-root-${_vaultRoot != null}'),
        data: renderableBody(widget.text),
        softLineBreak: true,
        onTapLink: _onTapLink,
        imageBuilder: (uri, title, alt) => _buildImage(uri, title, alt, theme),
        styleSheet: _previewStyleSheet(theme),
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

    final sourcePath = ref.read(openNoteProvider) ?? '';
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
        _snack('未找到笔记：${uri.path}');
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
    final sourcePath = ref.read(openNoteProvider) ?? '';
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
        !VaultPaths.isInsideNotes(norm) ||
        !_imageExtensions.contains(
            p.posix.extension(norm).replaceFirst('.', '').toLowerCase())) {
      return _imagePlaceholder(alt, theme);
    }

    final fsPath =
        p.join(vaultRoot, p.joinAll(norm.split('/')));
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
}
