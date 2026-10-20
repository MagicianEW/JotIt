import 'package:meta/meta.dart';

import '../entities/markdown_syntax.dart';

/// 一篇可以被"提到"的笔记。
///
/// 关键词有两个来源：front matter 的标题，和文件名主干。两者都要，因为
/// 人写字时用的是**看得见的那个名字**——标题改了文件名还没改的时候，
/// 只认标题就找不到；反之只认文件名，标题和文件名不一样时正文里的
/// 标题就成了死词。
@immutable
class MentionTarget {
  const MentionTarget({
    required this.path,
    required this.uid,
    required this.title,
    required this.stem,
  });

  /// `notes/`-prefixed vault path。
  final String path;

  /// front matter 里的 uid（ADR-2：身份住在文件里）。
  final String uid;

  /// front matter 标题 > 第一个 `# H1` > 文件名主干（v3.0 §4.4）。
  final String title;

  /// 文件名主干。`notes/功能/录音.md` 的主干是「录音」。
  final String stem;
}

/// 正文里的一处命中：这段文字说的就是另一篇笔记。
@immutable
class Mention {
  const Mention({
    required this.start,
    required this.end,
    required this.keyword,
    required this.target,
  });

  /// 命中在正文中的起止位置。
  final int start;
  final int end;

  /// 正文里被认出来的那段原文，**保持原样**（大小写照抄）。
  ///
  /// 显示的是它而不是关键词本身：库里那篇笔记叫「录音」，正文里写的是
  /// 「录音」，两样东西碰巧一样时看不出差别，但标题带空格、带大小写
  /// 的时候，替用户改字就是在替用户说话。
  final String keyword;

  final MentionTarget target;
}

/// 一条反向关联：某篇笔记的正文里提到了我。
///
/// 方向和 [Mention] 相反。[Mention] 是「这段字指向哪篇笔记」，
/// [Backlink] 是「哪篇笔记的字指向了我」。
@immutable
class Backlink {
  const Backlink({
    required this.sourcePath,
    required this.sourceTitle,
    required this.keyword,
    required this.excerpt,
    required this.excerptKeywordStart,
  });

  /// 提到我的那篇笔记（`notes/`-prefixed vault path）。
  final String sourcePath;

  /// 那篇笔记的标题（front matter > H1 > 文件名主干）。
  final String sourceTitle;

  /// 那篇笔记里写下的那几个字，保持原样。
  final String keyword;

  /// 命中所在的那一行，让用户看清「为什么算一次提到」。
  final String excerpt;

  /// [keyword] 在 [excerpt] 里的位置——界面要把它标出来。
  final int excerptKeywordStart;
}

/// 库里所有能被提到的笔记，以及在正文里认出它们的规则。
///
/// **这个索引只读，不写。** 命中的词不会去改用户的文件——「设计」这两个字
/// 在正文里就是正文，App 没有资格把它变成链接。自动关联是**读的时候
/// 算出来的**，所以用户随时可以关掉它，文件也永远是他自己写的那份。
///
/// 匹配的规矩只有四条，每一条都是因为不这么做就会出错：
///
///  * 长的优先。库里同时有「录音」和「录音功能」，正文里的「录音功能」
///    指的是后者。
///  * 英文要卡词边界。`API` 不该出现在 `rapid` 里面。
///  * 代码里的不算。文档里写 `[[链接]]` 是讲语法，不是在提到一篇笔记。
///  * 不提自己。一篇笔记提到自己的标题，对谁都没有用。
class MentionIndex {
  MentionIndex(Iterable<MentionTarget> targets)
      : targets = List<MentionTarget>.unmodifiable(targets) {
    final byKeyword = <String, List<MentionTarget>>{};
    for (final target in targets) {
      for (final keyword in _keywordsOf(target)) {
        byKeyword.putIfAbsent(keyword.toLowerCase(), () => <MentionTarget>[]).add(target);
      }
    }
    for (final list in byKeyword.values) {
      // 同一个词命中多篇笔记时，顺序必须稳定，否则同一个词在不同机器上
      // 会链到不同的笔记。
      list.sort((a, b) => a.path.compareTo(b.path));
    }
    _byKeyword = byKeyword;
  }

  /// 空索引。预览在没有库的时候用它，而不是 null——「没有可关联的笔记」
  /// 和「还没加载完」不该是两套分支。
  static final MentionIndex empty = MentionIndex(const <MentionTarget>[]);

  final List<MentionTarget> targets;

  late final Map<String, List<MentionTarget>> _byKeyword;

  /// 最短的关键词。两个字是下限：一个字的词（「书」「图」）出现在任何一段
  /// 话里，全篇都会变成链接，那不是关联，那是噪音。
  static const int minKeywordLength = 2;

  static List<String> _keywordsOf(MentionTarget target) {
    final out = <String>[];
    for (final candidate in <String>[target.title, target.stem]) {
      final trimmed = candidate.trim();
      if (trimmed.length < minKeywordLength) continue;
      if (!_hasWordChar(trimmed)) continue;
      if (out.contains(trimmed)) continue;
      out.add(trimmed);
    }
    return out;
  }

  /// 关键词里至少得有一个字母或数字，否则「——」「（）」这种标点也会
  /// 变成关键词。
  ///
  /// 用 Unicode 属性而不是手写区间：中文、西里尔、希腊文都算字母，而
  /// 破折号、逗号不算。手写的区间会把标点也放进去，然后满篇正文都是
  /// 链接。
  static final RegExp _wordChar = RegExp(r'[\p{L}\p{N}]', unicode: true);

  static bool _hasWordChar(String s) => _wordChar.hasMatch(s);

  /// 在 [body] 里找出所有提到别篇笔记的地方。
  ///
  /// [selfPath] 是这段正文所属的笔记：它不会被提到自己。
  /// [masked] 是代码区间的偏移——围栏代码块和行内代码，里面的字样是
  /// 讲语法，不是提到笔记。
  List<Mention> findIn(
    String body, {
    String? selfPath,
    List<(int, int)> masked = const <(int, int)>[],
  }) {
    if (body.isEmpty || _byKeyword.isEmpty) return const <Mention>[];

    // 大小写：英文笔记名大小写不敏感。中文不受影响。
    //
    // `toLowerCase()` 偶尔会改变长度（`İ` 变成两个字符），那时候偏移就
    // 对不上原文了，退回大小写敏感匹配，宁可少认几个也不要把链接安在
    // 错的位置上。
    final lowered = body.toLowerCase();
    final caseInsensitive = lowered.length == body.length;
    final haystack = caseInsensitive ? lowered : body;

    final candidates = <_Candidate>[];
    for (final entry in _byKeyword.entries) {
      final needle = entry.key;
      var from = 0;
      while (true) {
        final at = haystack.indexOf(needle, from);
        if (at < 0) break;
        from = at + 1;
        final end = at + needle.length;
        if (_insideMasked(masked, at, end)) continue;
        // 关键词不能横跨换行：markdown 里换行常常是段落边界，一个跨行
        // 的命中会拼出正文里根本不存在的词。
        if (body.codeUnitAt(at) == 0x0A || body.substring(at, end).contains('\n')) {
          continue;
        }
        if (!_hasWordBoundaries(haystack, at, end)) continue;

        final keyword = body.substring(at, end);
        for (final target in entry.value) {
          if (target.path == selfPath) continue;
          candidates.add(_Candidate(at, end, keyword, target));
        }
      }
    }
    if (candidates.isEmpty) return const <Mention>[];

    // 长的优先；同一起点时也长的优先。
    candidates.sort((a, b) {
      if (a.start != b.start) return a.start.compareTo(b.start);
      return b.end.compareTo(a.end);
    });

    // 贪心地吃掉不重叠的那些。「录音功能」和「功能」重叠时，留长的。
    final out = <Mention>[];
    var cursor = 0;
    for (final c in candidates) {
      if (c.start < cursor) continue;
      // 同一段文字命中多篇同名笔记时，只留第一篇——但要跳过被吃掉的那些，
      // 免得同一段文字被链两次。
      final same = out.any((m) => m.start == c.start && m.end == c.end);
      if (same) continue;
      out.add(Mention(
        start: c.start,
        end: c.end,
        keyword: c.keyword,
        target: c.target,
      ));
      cursor = c.end;
    }
    return out;
  }

  static bool _insideMasked(
    List<(int, int)> masked,
    int start,
    int end,
  ) {
    for (final r in masked) {
      if (start >= r.$1 && end <= r.$2) return true;
    }
    return false;
  }

  /// 英文词的左右边界。
  ///
  /// 中文没有词边界，「录音」出现在「录音功能」里是正常的；英文有，
  /// `API` 出现在 `rapid` 里就是另一个词了。所以只有当关键词**自己**
  /// 的首尾是字母数字时，才要求旁边的字不是字母数字。
  static bool _hasWordBoundaries(String haystack, int start, int end) {
    if (_isWordChar(haystack.codeUnitAt(start))) {
      if (start > 0 && _isWordChar(haystack.codeUnitAt(start - 1))) return false;
    }
    if (_isWordChar(haystack.codeUnitAt(end - 1))) {
      if (end < haystack.length && _isWordChar(haystack.codeUnitAt(end))) {
        return false;
      }
    }
    return true;
  }

  static bool _isWordChar(int unit) =>
      (unit >= 0x30 && unit <= 0x39) ||
      (unit >= 0x41 && unit <= 0x5A) ||
      (unit >= 0x61 && unit <= 0x7A) ||
      unit == 0x5F; // _

  /// 反向：哪些笔记的正文提到了 [target]。
  ///
  /// 判定用的就是正向那套规则（[findIn] 的同一份代码区与双链规则），所以
  /// 「预览里渲染成链接」和「这里列出来」永远是同一批字。两边各写一套
  /// 规则的话，用户会看到一篇笔记在预览里是链接，却在反链面板里查不到它。
  ///
  /// [bodies] 是候选正文的集合：路径 → 正文。**它必须是全库**，而不是
  /// 「看起来可能提到我的那些」——反向查找的方向本身就是「不知道谁提到了
  /// 我」，靠关键词先筛一遍会把漏掉的又漏一遍。
  ///
  /// [titles] 是路径 → 标题，用来给面板显示来源笔记的名字。
  List<Backlink> findBacklinks({
    required MentionTarget target,
    required Map<String, String> bodies,
    Map<String, String> titles = const <String, String>{},
  }) => findBacklinksIn(
        target: target,
        bodies: bodies,
        titles: titles,
        allTargets: targets,
      );

  /// 反向查找的独立入口：自己建索引，不依赖实例。
  ///
  /// 单独一个入口，是为了让它能整个搬到后台 isolate 里跑：反查要扫全库
  /// 正文，在界面上做会让 App 卡住——用户点了一下，整个界面就冻住，
  /// 而这只是一个他还没决定要不要看的列表。
  static List<Backlink> findBacklinksIn({
    required MentionTarget target,
    required Map<String, String> bodies,
    required List<MentionTarget> allTargets,
    Map<String, String> titles = const <String, String>{},
  }) {
    final index = MentionIndex(allTargets);
    // 这篇笔记能被叫出来的那些词。反查只能从这些词找起——别的词指向的
    // 一定是别的笔记。
    final keywords = _keywordsOf(target)
        .map((k) => k.toLowerCase())
        .toList(growable: false);
    if (keywords.isEmpty) return const <Backlink>[];

    final out = <Backlink>[];
    final seen = <String>{};
    for (final entry in bodies.entries) {
      final path = entry.key;
      if (path == target.path) continue; // 不提自己
      final body = entry.value;
      if (body.isEmpty) continue;

      // 便宜的剪枝：正文里根本没有这些词，就不可能提到这篇。
      //
      // 这个判断必须**放宽**而不是收紧——它只用来决定「要不要跑一遍完整
      // 规则」，跑完才算数。收紧了就等于在这里先判一次案，而这里的规则
      // 和 [findIn] 的规则不是同一套（大小写、边界、代码区都还没算），
      // 两边一旦不一致，预览和反链面板就会对不上。
      if (!_mayContain(body, keywords)) continue;

      final masked = codeRegions(body);
      final mentions = index.findIn(body, selfPath: path, masked: masked);
      if (mentions.isEmpty) continue;

      // 用户自己写的双链优先：那段字已经是链接了，不能再套一个自动提及。
      final links = userLinkSpans(body, masked: masked);
      for (final m in mentions) {
        if (m.target.path != target.path) continue;
        if (links.any((l) => spansOverlap(l, (m.start, m.end)))) continue;
        // 同一篇笔记提到我几次都只算一条：一篇笔记在列表里出现两次，
        // 说的是同一件事，用户要的是「谁提到了我」，不是「提到了几次」。
        // 留第一次命中——正文里先出现的那处。
        if (seen.contains(path)) break;
        seen.add(path);
        out.add(_backlinkOf(
          sourcePath: path,
          sourceTitle: titles[path] ?? path,
          body: body,
          mention: m,
        ));
      }
    }
    out.sort((a, b) => a.sourcePath.compareTo(b.sourcePath));
    return out;
  }

  /// 正文里可能含有这些词吗（放宽的判断）。
  ///
  /// 原样和小写都查：完整规则里大小写不敏感的情形，`toLowerCase()` 之后
  /// 长度变了会退回大小写敏感匹配，那时候原样才是对的。两个都查才既不
  /// 漏、也不把候选剪掉。
  static bool _mayContain(String body, List<String> lowerKeywords) {
    final lowered = body.toLowerCase();
    for (final kw in lowerKeywords) {
      if (body.contains(kw) || lowered.contains(kw)) return true;
    }
    return false;
  }

  /// 把一次命中变成一条反向关联，并把所在的那一行摘出来。
  ///
  /// 摘行而不是摘全文：面板要能一眼看出「它在哪儿提到了我」，一整篇正文
  /// 摆在列表里反而什么都看不清。
  static Backlink _backlinkOf({
    required String sourcePath,
    required String sourceTitle,
    required String body,
    required Mention mention,
  }) {
    var lineStart = 0;
    if (mention.start > 0) {
      final nl = body.lastIndexOf('\n', mention.start - 1);
      lineStart = nl < 0 ? 0 : nl + 1;
    }
    var lineEnd = body.indexOf('\n', mention.end);
    lineEnd = lineEnd < 0 ? body.length : lineEnd;
    var line = body.substring(lineStart, lineEnd);

    // 缩进和行尾空白不是内容：摘出来的那一行要能直接读。
    final lead = line.length - line.trimLeft().length;
    line = line.trim();
    var keywordStart = mention.start - lineStart - lead;
    if (keywordStart < 0) keywordStart = 0;

    return Backlink(
      sourcePath: sourcePath,
      sourceTitle: sourceTitle,
      keyword: mention.keyword,
      excerpt: line,
      excerptKeywordStart: keywordStart,
    );
  }
}

class _Candidate {
  const _Candidate(this.start, this.end, this.keyword, this.target);

  final int start;
  final int end;
  final String keyword;
  final MentionTarget target;
}
