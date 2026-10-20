import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/domain/vault/link_resolver.dart';
import 'package:jotit/domain/vault/mention_index.dart';

/// 反向关联：谁提到了我。
///
/// 这些规则和正向的（`mention_index_test.dart`）**必须是同一套**。两边
/// 各写一套的话，用户会看到一篇笔记在预览里是链接，却在反链面板里查不到
/// 它——而那正是同一个事实。
///
/// 所以这里的每一条都在问同一个问题：**如果我把这段正文交给正向匹配器，
/// 它会不会链到这篇笔记？**
MentionTarget _target(
  String path, {
  required String title,
  String? stem,
}) =>
    MentionTarget(
      path: path,
      uid: 'uid:$path',
      title: title,
      stem: stem ?? LinkIndex.stemOf(path),
    );

void main() {
  group('MentionIndex.findBacklinks', () {
    test('另一篇笔记的正文提到了我，它就是一条反向关联', () {
      final index = MentionIndex([
        _target('notes/录音.md', title: '录音'),
      ]);

      final found = index.findBacklinks(
        target: index.targets.first,
        bodies: {
          'notes/a.md': '这里提到了录音这个功能。',
        },
        titles: {'notes/a.md': 'A'},
      );

      expect(found, hasLength(1));
      expect(found.single.sourcePath, 'notes/a.md');
      expect(found.single.sourceTitle, 'A');
      expect(found.single.keyword, '录音');
    });

    test('摘录是提到我的那一行，命中词的位置对得上', () {
      final index = MentionIndex([
        _target('notes/录音.md', title: '录音'),
      ]);

      final found = index.findBacklinks(
        target: index.targets.first,
        bodies: {
          'notes/a.md': '第一行。\n第二行提到了录音。\n第三行。\n',
        },
      );

      expect(found, hasLength(1));
      expect(found.single.excerpt, '第二行提到了录音。');
      expect(
        found.single.excerpt.substring(
          found.single.excerptKeywordStart,
          found.single.excerptKeywordStart + found.single.keyword.length,
        ),
        '录音',
      );
    });

    test('不提自己', () {
      final index = MentionIndex([
        _target('notes/录音.md', title: '录音'),
      ]);

      final found = index.findBacklinks(
        target: index.targets.first,
        bodies: {
          'notes/录音.md': '这是录音的笔记',
        },
      );

      expect(found, isEmpty,
          reason: '一篇笔记提到自己不算「提到我」');
    });

    test('代码里的字样不算提到我', () {
      final index = MentionIndex([
        _target('notes/录音.md', title: '录音'),
      ]);

      final found = index.findBacklinks(
        target: index.targets.first,
        bodies: {
          'notes/a.md': '看代码：\n`录音`\n',
        },
      );

      expect(found, isEmpty,
          reason: '代码里写的是变量名，不是提到一篇笔记');
    });

    test('用户自己写的双链不算自动提及', () {
      final index = MentionIndex([
        _target('notes/录音.md', title: '录音'),
      ]);

      final found = index.findBacklinks(
        target: index.targets.first,
        bodies: {
          'notes/a.md': '见 [[录音]] 这篇。',
        },
      );

      expect(found, isEmpty,
          reason: '那段字已经是用户写的链接了，不能再算一次自动提及');
    });

    test('长的优先：正文里写「录音功能」，提到的是录音功能不是录音', () {
      final index = MentionIndex([
        _target('notes/录音.md', title: '录音'),
        _target('notes/录音功能.md', title: '录音功能'),
      ]);

      final rec = index.targets.firstWhere((t) => t.path == 'notes/录音.md');
      final recFeature =
          index.targets.firstWhere((t) => t.path == 'notes/录音功能.md');

      expect(
        index.findBacklinks(
          target: rec,
          bodies: {'notes/a.md': '我们做录音功能很久了'},
        ),
        isEmpty,
        reason: '正文里那几个字指的是「录音功能」这篇',
      );
      expect(
        index.findBacklinks(
          target: recFeature,
          bodies: {'notes/a.md': '我们做录音功能很久了'},
        ),
        hasLength(1),
      );
    });

    test('同名笔记只认一篇，和正向链到的那篇一致', () {
      final index = MentionIndex([
        _target('notes/b/同名.md', title: '同名'),
        _target('notes/a/同名.md', title: '同名'),
      ]);

      final a = index.targets.firstWhere((t) => t.path == 'notes/a/同名.md');
      final b = index.targets.firstWhere((t) => t.path == 'notes/b/同名.md');

      // 正向：正文里那句「同名」链到 a（按路径排序）。
      expect(index.findIn('提到了同名').single.target.path, 'notes/a/同名.md');

      // 反向：a 有这条反链，b 没有。
      expect(
        index.findBacklinks(target: a, bodies: {'notes/x.md': '提到了同名'}),
        hasLength(1),
      );
      expect(
        index.findBacklinks(target: b, bodies: {'notes/x.md': '提到了同名'}),
        isEmpty,
      );
    });

    test('英文大小写不敏感，正反一致', () {
      final index = MentionIndex([
        _target('notes/API.md', title: 'API'),
      ]);

      final found = index.findBacklinks(
        target: index.targets.first,
        bodies: {'notes/a.md': 'we use api here'},
      );

      expect(found, hasLength(1));
      expect(found.single.keyword, 'api',
          reason: '显示的是正文里写的那几个字');
    });

    test('一个字的标题反查不到——它根本就不是关键词', () {
      final index = MentionIndex([
        _target('notes/书.md', title: '书'),
      ]);

      expect(
        index.findBacklinks(
          target: index.targets.first,
          bodies: {'notes/a.md': '这是一本书'},
        ),
        isEmpty,
      );
    });

    test('结果按来源路径排序，同一篇笔记的多次命中只留一条', () {
      final index = MentionIndex([
        _target('notes/录音.md', title: '录音'),
      ]);

      final found = index.findBacklinks(
        target: index.targets.first,
        bodies: {
          'notes/z.md': '提到了录音。',
          'notes/a.md': '提到了录音，又提到了录音。',
        },
      );

      expect(found.map((b) => b.sourcePath), ['notes/a.md', 'notes/z.md']);
      expect(found.first.excerpt, '提到了录音，又提到了录音。');
    });
  });
}
