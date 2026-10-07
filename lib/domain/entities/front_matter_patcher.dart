/// Surgical front-matter editing.
///
/// v3.0 §9.2 requires that a write preserve unknown keys, comments and the
/// user's formatting. That rules out the obvious implementation — parse the
/// YAML into a map, mutate it, re-emit — which silently deletes anything it
/// did not model and drops every comment.
///
/// Instead each managed key is edited in place inside the raw text. A note
/// written by another tool with ten custom fields and three comments comes
/// back from JotIt byte-identical apart from the fields JotIt owns.
class FrontMatterPatcher {
  const FrontMatterPatcher._();

  /// Ensure the file carries `uid: <value>`, preserving all other front matter.
  ///
  /// This is what makes ADR-2 work for notes created outside the app: the
  /// identity is written back into the file so it travels to every device
  /// through ordinary synchronisation.
  static String withUid(String fileText, String uid) =>
      withStringValue(fileText, 'uid', uid);

  /// Set (or add) a scalar key in the front matter.
  static String withStringValue(String fileText, String key, String value) {
    final text = fileText.startsWith('\uFEFF')
        ? fileText.substring(1)
        : fileText;
    final hasFm = text.startsWith('---');
    if (!hasFm) {
      return '---\n$key: $value\n---\n\n$text';
    }

    final newline = text.contains('\r\n') ? '\r\n' : '\n';
    final lines = text.split(newline);

    var closeIndex = -1;
    for (var i = 1; i < lines.length; i++) {
      if (lines[i].trim() == '---' || lines[i].trim() == '...') {
        closeIndex = i;
        break;
      }
    }
    if (closeIndex < 0) {
      // Unterminated block. Do not guess where it was meant to end; leave the
      // file alone and let the caller fall back to creating a new block.
      return withStringValue('---\n$key: $value\n---$newline$newline$text', key, value);
    }

    final pattern = RegExp('^(\\s*)($key)(\\s*:)(\\s*)(.*)\$');
    for (var i = 1; i < closeIndex; i++) {
      final m = pattern.firstMatch(lines[i]);
      if (m == null) continue;
      final indent = m.group(1)!;
      final colon = m.group(3)!;
      final original = m.group(5)!.trim();
      // Preserve whatever quoting the author used so a `#` inside the value
      // cannot be reinterpreted as a comment on the next write.
      final quoted = original.length >= 2 &&
          ((original.startsWith('"') && original.endsWith('"')) ||
              (original.startsWith("'") && original.endsWith("'")));
      final rendered = quoted
          ? '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"'
          : _yamlSafe(value);
      lines[i] = '$indent$key$colon $rendered';
      return lines.join(newline);
    }

    // Not present — append just before the closing fence.
    lines.insert(closeIndex, '$key: ${_yamlSafe(value)}');
    return lines.join(newline);
  }

  /// True when the file already declares this exact uid.
  static bool hasUid(String fileText, String uid) {
    final m = RegExp(r'^\s*uid\s*:\s*(.+)$', multiLine: true)
        .firstMatch(_fmOnly(fileText));
    if (m == null) return false;
    return _unquote(m.group(1)!.trim()) == uid;
  }

  /// Read a scalar front-matter key without a full parse.
  static String? readString(String fileText, String key) {
    final m = RegExp('^\\s*$key\\s*:\\s*(.+)\$', multiLine: true)
        .firstMatch(_fmOnly(fileText));
    if (m == null) return null;
    return _unquote(m.group(1)!.trim());
  }

  static String _fmOnly(String text) {
    if (!text.startsWith('---')) return '';
    final lines = text.split('\n');
    for (var i = 1; i < lines.length; i++) {
      if (lines[i].trim() == '---' || lines[i].trim() == '...') {
        return lines.sublist(1, i).join('\n');
      }
    }
    return '';
  }

  static String _unquote(String v) {
    if (v.length >= 2 &&
        ((v.startsWith('"') && v.endsWith('"')) ||
            (v.startsWith("'") && v.endsWith("'")))) {
      return v.substring(1, v.length - 1);
    }
    return v;
  }

  /// Quote a value only when plain YAML would misread it.
  static String _yamlSafe(String value) {
    // Triple-quoted raw string: the class contains both a backtick, a double
    // quote and a single quote, and a raw r'...' would terminate on the
    // escaped single quote.
    final needsQuotes = value.isEmpty ||
        RegExp(r'''^[\s]|[\s]$''').hasMatch(value) ||
        RegExp(r'''^[-?:,\[\]{}#&*!|>%@`"']''').hasMatch(value) ||
        value.contains(': ') ||
        value.contains(' #') ||
        value.contains('\n');
    if (!needsQuotes) return value;
    return '"${value.replaceAll('\\', r'\\').replaceAll('"', r'\"').replaceAll('\n', r'\n')}"';
  }
}