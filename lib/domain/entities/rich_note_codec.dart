import 'package:super_editor/super_editor.dart';

export 'package:super_editor/super_editor.dart'
    show MutableDocument, Document, Editor;

/// The rich-text (WYSIWYG) side of the editor: markdown <-> super_editor
/// documents, plus the rules that decide which notes may enter rich mode at
/// all.
///
/// Everything here follows the byte-fidelity waiver agreed with the boss:
///
///  * the front matter is NEVER touched here — it never enters a document
///    and never comes out of one ([EditorPage] stitches it back on save);
///  * serialisation uses [MarkdownSyntax.normal], because the superEditor
///    dialect writes non-standard things (`¬underline¬`, `:---` alignment)
///    that would corrupt the file for every other tool;
///  * notes carrying syntax the rich editor cannot represent (HTML blocks,
///    footnotes, wiki links — until they are wired in) fall back to the
///    source view, decided by [detectUnsupportedSyntax].
export 'package:super_editor/super_editor.dart'
    show deserializeMarkdownToDocument, serializeDocumentToMarkdown, MarkdownSyntax;

/// Parses the note body into an editable document.
MutableDocument deserializeNoteBody(String body) =>
    deserializeMarkdownToDocument(body, syntax: MarkdownSyntax.normal);

/// Renders an edited document back to standard markdown.
///
/// super_editor's table serialiser does not emit a blank line between the
/// last table row and the next block; CommonMark then glues the following
/// paragraph into the table on the next parse. [serializeNoteBody] therefore
/// post-processes the output so every block is blank-line separated.
String serializeNoteBody(Document doc) => _normalizeStrikethrough(
    _ensureBlankLineAfterTable(
        serializeDocumentToMarkdown(doc, syntax: MarkdownSyntax.normal)));

/// super_editor serialises strikethrough with a single tilde (`~text~`),
/// which GFM tools do not render as a strike at all. Rewrites the markers to
/// the standard double tilde. Code spans and fenced blocks are skipped so
/// literal tildes inside code stay literal, and the look-arounds keep an
/// existing `~~` run from being extended a third time.
String _normalizeStrikethrough(String md) {
  final pattern = RegExp(r'(?<!~)~([^~\n]+?)~(?!~)');
  final out = <String>[];
  var inFence = false;
  for (final line in md.split('\n')) {
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('```') || trimmed.startsWith('~~~')) {
      inFence = !inFence;
      out.add(line);
      continue;
    }
    if (inFence) {
      out.add(line);
      continue;
    }
    // Mask inline code spans so their tildes are never touched.
    final codeSpans = <String>[];
    final masked = line.replaceAllMapped(RegExp(r'`[^`]*`'), (m) {
      codeSpans.add(m.group(0)!);
      return '\u0000${codeSpans.length - 1}\u0000';
    });
    final replaced =
        masked.replaceAllMapped(pattern, (m) => '~~${m.group(1)}~~');
    out.add(replaced.replaceAllMapped(
        RegExp(r'\u0000(\d+)\u0000'), (m) => codeSpans[int.parse(m.group(1)!)]));
  }
  return out.join('\n');
}

String _ensureBlankLineAfterTable(String md) {
  final out = <String>[];
  var inFence = false;
  var prevWasTableRow = false;
  for (final line in md.split('\n')) {
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('```') || trimmed.startsWith('~~~')) {
      inFence = !inFence;
      out.add(line);
      prevWasTableRow = false;
      continue;
    }
    final isTableRow = !inFence && trimmed.startsWith('|');
    if (prevWasTableRow && !isTableRow && line.trim().isNotEmpty) {
      out.add('');
    }
    out.add(line);
    prevWasTableRow = isTableRow;
  }
  return out.join('\n');
}

/// Returns the name of the first syntax the rich editor cannot represent, or
/// null when the body may be opened in rich mode.
///
/// Deliberately conservative: a false "unsupported" only costs a mode
/// downgrade, while a false "supported" means a save rewrites text the user
/// never agreed to have rewritten. Code fences are skipped, because a
/// fenced example is documentation about the syntax, not the syntax itself.
String? detectUnsupportedSyntax(String body) {
  var inFence = false;
  for (final line in body.split('\n')) {
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('```') || trimmed.startsWith('~~~')) {
      inFence = !inFence;
      continue;
    }
    if (inFence) continue;

    if (trimmed.startsWith('<!--') || RegExp(r'^<[a-zA-Z][^>]*>$').hasMatch(trimmed)) {
      return 'HTML 块';
    }
    if (RegExp(r'^\[\^[^\]]+\]:').hasMatch(trimmed)) {
      return '脚注';
    }
    if (RegExp(r'^:\s+\S').hasMatch(trimmed)) {
      return '定义列表';
    }
    // Wiki links and embeds are core JotIt syntax; the rich editor gains
    // them in a later stage, and until then a note carrying them must not
    // be rewritten by a serializer that would mangle them.
    if (trimmed.contains('[[')) {
      return '双链语法';
    }
  }
  return null;
}
