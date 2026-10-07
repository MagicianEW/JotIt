import 'package:jotit/domain/entities/parsed_note.dart';
import 'package:yaml/yaml.dart';

/// Parses a note's Markdown into the parts the index and the editor need.
///
/// Three correctness details drive the design:
///
/// 1. **Code regions are excluded from link extraction.** A `[[...]]` inside a
///    fenced block or inline span is documentation *about* the syntax, not a
///    link. Without this, this very source file would create notes for its
///    own examples.
/// 2. **Front-matter round-trips byte-for-byte.** Parsed keys are for reading;
///    writes patch [ParsedNote.rawFrontMatter] surgically. Re-emitting YAML
///    would delete unknown keys and comments, which breaks the "open standard"
///    promise in v3.0 §9.2.
/// 3. **Malformed YAML never throws.** A bad header degrades to plain text
///    with a warning flag; the user still gets their note back.
class MarkdownParser {
  const MarkdownParser();

  /// Splits [raw] into its front matter and body.
  ///
  /// [hasBlock] distinguishes "a front-matter block was actually found" from
  /// "the body merely happens to begin with `---`". Guessing from
  /// `startsWith` alone makes a horizontal rule at the top of a note look like
  /// an (empty) header.
  ({String raw, String body, bool hasBlock}) splitFrontMatter(String raw) {
    // A BOM would make the opening `---` invisible to startsWith.
    final text = raw.startsWith('\uFEFF') ? raw.substring(1) : raw;
    if (!text.startsWith('---')) {
      return (raw: text, body: text, hasBlock: false);
    }

    final lines = text.split('\n');
    // The opening fence must be a lone `---`, not `--- something`.
    if (lines.first.trim() != '---') {
      return (raw: text, body: text, hasBlock: false);
    }

    for (var i = 1; i < lines.length; i++) {
      if (lines[i].trim() == '---' || lines[i].trim() == '...') {
        final block = lines.sublist(0, i + 1).join('\n');
        final body = i + 1 < lines.length ? lines.sublist(i + 1).join('\n') : '';
        return (raw: block, body: body, hasBlock: true);
      }
    }
    // Opened but never closed: treat the whole thing as body rather than
    // silently eating the user's content.
    return (raw: text, body: text, hasBlock: false);
  }

  /// Full parse. [fallbackTitle] is normally the filename without extension.
  ParsedNote parse(String raw, {required String fallbackTitle}) {
    final split = splitFrontMatter(raw);
    var frontMatter = <String, Object?>{};
    var isMalformed = false;

    if (split.hasBlock) {
      final inner = _stripFences(split.raw);
      if (inner == null) {
        isMalformed = true;
      } else {
        try {
          final doc = loadYaml(inner);
          if (doc is YamlMap) {
            frontMatter = _plain(doc) as Map<String, Object?>;
          } else if (doc != null) {
            isMalformed = true;
          }
        } on YamlException {
          isMalformed = true;
        }
      }
    }

    final body = split.body;
    final links = extractLinks(body);
    final tags = _readTags(frontMatter);
    final title = _resolveTitle(frontMatter, body, fallbackTitle);

    final uidValue = frontMatter['uid'];
    final uid = uidValue is String && uidValue.trim().isNotEmpty
        ? uidValue.trim()
        : null;

    return ParsedNote(
      frontMatter: frontMatter,
      rawFrontMatter: split.raw,
      body: body,
      title: title,
      uid: uid,
      links: links,
      tags: tags,
      frontMatterMalformed: isMalformed,
      hasFrontMatter: split.hasBlock,
    );
  }

  /// Extracts every `[[...]]` / `![[...]]` that is not inside code.
  ///
  /// Supports all five forms from v3.0 §9.1:
  /// `[[note]]`, `[[note|alias]]`, `[[note#heading]]`, `[[note#^block]]`,
  /// `![[note]]`, plus the `[[uid:...]]` direct-identity escape hatch.
  List<WikiLink> extractLinks(String body) {
    final masked = _codeRanges(body);
    final out = <WikiLink>[];
    for (final m in RegExp(r'(!?)\[\[([^\[\]\n]*)\]\]').allMatches(body)) {
      if (_overlaps(masked, m.start, m.end)) continue;
      final inner = m.group(2) ?? '';
      if (inner.trim().isEmpty) continue; // `[[]]` means "create note"

      // Alias splits first: `[[a|b]]`. Only the part before `|` is a target.
      final pipe = inner.indexOf('|');
      final targetPart = (pipe < 0 ? inner : inner.substring(0, pipe)).trim();
      final alias =
          pipe < 0 ? null : inner.substring(pipe + 1).trim();

      String? anchor;
      String? blockId;
      var target = targetPart;
      final hash = targetPart.indexOf('#');
      if (hash >= 0) {
        final tail = targetPart.substring(hash + 1).trim();
        target = targetPart.substring(0, hash).trim();
        if (tail.startsWith('^')) {
          blockId = tail.substring(1);
        } else if (tail.isNotEmpty) {
          anchor = tail;
        }
      }

      out.add(WikiLink(
        target: target,
        isEmbed: m.group(1) == '!',
        anchor: anchor,
        blockId: blockId,
        alias: (alias == null || alias.isEmpty) ? null : alias,
        start: m.start,
        end: m.end,
      ));
    }
    return out;
  }

  /// Extracts standard markdown links and images: `[text](target)` and
  /// `![alt](target)`.
  ///
  /// Reported separately from [extractLinks] rather than merged into it: the
  /// two are indexed under different `link_type` values, and a `[[wiki]]` link
  /// inside a markdown link's *title* must not be counted twice.
  List<WikiLink> extractMarkdownLinks(String body) {
    final masked = _codeRanges(body);
    final out = <WikiLink>[];
    // Not autolinks (`<http://…>`): those are external by definition and
    // belong in neither graph.
    final re = RegExp(r'(!?)\[([^\]\[\n]*)\]\(([^()\s]*)'
        r'(?:\s+"[^"]*")?\)');
    for (final m in re.allMatches(body)) {
      if (_overlaps(masked, m.start, m.end)) continue;
      final target = (m.group(3) ?? '').trim();
      if (target.isEmpty) continue;

      String? anchor;
      var bare = target;
      final hash = bare.indexOf('#');
      if (hash >= 0) {
        anchor = bare.substring(hash + 1).trim();
        bare = bare.substring(0, hash).trim();
      }

      out.add(WikiLink(
        target: bare,
        isEmbed: m.group(1) == '!',
        blockId: null,
        anchor: (anchor == null || anchor.isEmpty) ? null : anchor,
        alias: (m.group(2) ?? '').trim().isEmpty
            ? null
            : m.group(2)!.trim(),
        start: m.start,
        end: m.end,
      ));
    }
    return out;
  }

  // ---- internals ---------------------------------------------------------

  String? _stripFences(String raw) {
    if (!raw.startsWith('---')) return null;
    final lines = raw.split('\n');
    if (lines.length < 2) return null;
    return lines.sublist(1, lines.length - 1).join('\n');
  }

  /// Unwrap the YAML tree into plain Dart collections.
  ///
  /// `YamlNode.value` already returns the inner value for scalars and `this`
  /// for collections, so exactly one unwrap per level is correct. Doing
  /// `.value.value` on a list element reaches for `value` on a `String` — the
  /// nested-collection shape is what makes that tempting and wrong.
  Object? _plain(Object? v) {
    if (v is YamlMap) {
      return <String, Object?>{
        for (final e in v.nodes.entries) '${e.key.value}': _plain(e.value.value),
      };
    }
    if (v is YamlList) {
      return <Object?>[for (final e in v.nodes) _plain(e.value)];
    }
    return v;
  }

  List<String> _readTags(Map<String, Object?> fm) {
    final t = fm['tags'];
    if (t == null) return const [];
    if (t is String) {
      return t
          .split(RegExp(r'[,，]'))
          .map((s) => s.trim().replaceAll(RegExp(r'^[#]'), ''))
          .where((s) => s.isNotEmpty)
          .toList();
    }
    if (t is List) {
      return t
          .map((e) => e.toString().trim().replaceAll(RegExp(r'^[#]'), ''))
          .where((s) => s.isNotEmpty)
          .toList();
    }
    return const [];
  }

  /// `front matter title` > first `# H1` > filename stem (v3.0 §4.4).
  String _resolveTitle(Map<String, Object?> fm, String body, String fallback) {
    final t = fm['title'];
    if (t is String && t.trim().isNotEmpty) return t.trim();

    for (final line in body.split('\n')) {
      final m = RegExp(r'^\s{0,3}#\s+(.*\S)\s*$').firstMatch(line);
      if (m != null) return m.group(1)!.trim();
    }
    return fallback;
  }

  /// Character ranges covered by fenced blocks or inline code spans.
  List<({int start, int end})> _codeRanges(String body) {
    final ranges = <({int start, int end})>[];
    final lines = body.split('\n');
    var offset = 0;
    RegExp? closeFence; // matches only the closing marker of the open fence

    for (final line in lines) {
      final lineStart = offset;
      offset += line.length + 1; // +1 for the '\n' we split on

      if (closeFence != null) {
        // Everything between an opening fence and its closing marker is code —
        // including the interior lines that carry no marker at all. Masking
        // only the marker lines is how a `[[link]]` inside a code block ends
        // up in the graph.
        ranges.add((start: lineStart, end: lineStart + line.length));
        if (closeFence.firstMatch(line) != null) closeFence = null;
        continue;
      }

      final open = RegExp(r'^\s{0,3}(`{3,}|~{3,})').firstMatch(line);
      if (open == null) {
        ranges.addAll(_inlineCodeRanges(line, lineStart));
        continue;
      }

      final marker = open.group(1)!;
      final char = marker[0]; // '`' or '~'; neither is a regex metacharacter
      // A closing fence uses the same character, is at least as long as the
      // opener, and carries no info string.
      closeFence = RegExp('^\\s{0,3}$char{${marker.length},}\\s*\$');

      final sameLineClose =
          RegExp('$char{${marker.length},}').firstMatch(line.substring(open.end));
      if (sameLineClose != null) {
        // Opened and closed on one line: mask only the fence itself, so prose
        // sharing that line is still scanned for links.
        final after = open.end + sameLineClose.end;
        ranges.add((start: lineStart + open.start, end: lineStart + after));
        closeFence = null;
        ranges.addAll(
            _inlineCodeRanges(line.substring(after), lineStart + after));
      } else {
        ranges.add((start: lineStart, end: lineStart + line.length));
      }
    }
    return ranges;
  }

  List<({int start, int end})> _inlineCodeRanges(String line, int lineStart) {
    final out = <({int start, int end})>[];
    var i = 0;
    while (i < line.length) {
      if (line[i] != '`') {
        i++;
        continue;
      }
      var run = 0;
      while (i + run < line.length && line[i + run] == '`') {
        run++;
      }
      final open = i;
      final marker = '`' * run;
      final close = _indexOfUnescaped(line, marker, i + run);
      if (close < 0) {
        // Unbalanced backticks: not a code span, keep scanning after them.
        i += run;
        continue;
      }
      out.add((start: lineStart + open, end: lineStart + close + run));
      i = close + run;
    }
    return out;
  }

  int _indexOfUnescaped(String haystack, String needle, int from) {
    var idx = from;
    while (idx >= 0 && idx < haystack.length) {
      final at = haystack.indexOf(needle, idx);
      if (at < 0) return -1;
      var backslashes = 0;
      for (var k = at - 1; k >= 0 && haystack[k] == r'\'; k--) {
        backslashes++;
      }
      if (backslashes.isEven) return at;
      idx = at + needle.length;
    }
    return -1;
  }

  bool _overlaps(List<({int start, int end})> ranges, int start, int end) {
    for (final r in ranges) {
      if (start < r.end && r.start < end) return true;
    }
    return false;
  }
}