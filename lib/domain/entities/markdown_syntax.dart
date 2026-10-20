/// Markdown 语法上那些「看着像正文、其实不是正文」的区间。
///
/// 正向（正文里哪些字渲染成链接）和反向（哪些笔记提到了我）必须对同一段
/// 正文得出同一个答案。两处各写一份规则，它们会各自漂移，最后用户在预览
/// 里看到一个不是链接的词、却在「提到本篇的笔记」里看见它指向自己。
library;

/// 用户自己写的双链：`[[note]]`、`![[note]]`、`[[note|别名]]`。
///
/// 它和自动提及的区别是**谁写的**：用户写的双链在文件里，笔记改名它就跟着
/// 改；自动提及是 App 认出来的，文件里根本没有。
final RegExp wikiLinkPattern = RegExp(r'(!?)\[\[([^\[\]\n]*)\]\]');

/// 正文里属于「代码」的那些字符区间。
///
/// 代码区里的字样是在**讲语法**，不是在提到一篇笔记：`[[链接]]` 写在围栏块
/// 里是文档的一部分，`录音` 写在行内代码里是变量名。把它算成一次提及，
/// 渲染出来的链接会当着读者的面撒谎。
///
/// 返回的区间是半开区间 `[start, end)`。
List<(int, int)> codeRegions(String body) {
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

/// 正文里用户自己写的双链所占的区间。
///
/// 代码区里的双链不算：那里的 `[[链接]]` 是文档的一部分，不是链接。
List<(int, int)> userLinkSpans(
  String body, {
  List<(int, int)> masked = const <(int, int)>[],
}) {
  final spans = <(int, int)>[];
  for (final m in wikiLinkPattern.allMatches(body)) {
    final insideCode = masked.any((r) => m.start >= r.$1 && m.end <= r.$2);
    if (insideCode) continue;
    spans.add((m.start, m.end));
  }
  return spans;
}

/// 两个区间是否相交。
bool spansOverlap((int, int) a, (int, int) b) => a.$1 < b.$2 && b.$1 < a.$2;
