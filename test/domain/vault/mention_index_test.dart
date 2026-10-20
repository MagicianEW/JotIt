import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/domain/vault/link_resolver.dart';
import 'package:jotit/domain/vault/mention_index.dart';

/// 认出正文里的「另一篇笔记」。
///
/// 这些规则每一条都对应一种真实的错法：把「录音功能」认成「录音」，
/// 把 `API` 认成 `rapid` 里的东西，把文档里写的 `[[链接]]` 当成提到一篇
/// 笔记，把笔记提到自己。少一条，链接就会指错地方——而指错的链接比没有
/// 链接更糟，因为用户会信它。
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
  group('MentionIndex', () {
    test('正文里出现另一篇笔记的标题，就是一次命中', () {
      final index = MentionIndex([
        _target('notes/录音.md', title: '录音'),
      ]);

      final found = index.findIn('这里说到了录音这件事。');

      expect(found, hasLength(1));
      expect(found.single.keyword, '录音');
      expect(found.single.target.path, 'notes/录音.md');
      expect(found.single.start, 5);
      expect(found.single.end, 7);
    });

    test('英文大小写不敏感', () {
      final index = MentionIndex([
        _target('notes/API.md', title: 'API'),
      ]);

      expect(index.findIn('we use api here'), hasLength(1));
      expect(index.findIn('we use Api here'), hasLength(1));
      expect(index.findIn('we use API here'), hasLength(1));
    });

    test('英文不匹配词中间', () {
      final index = MentionIndex([
        _target('notes/API.md', title: 'API'),
      ]);

      expect(index.findIn('rapid growth'), isEmpty,
          reason: 'rapid 里的 api 不是 api');
      expect(index.findIn('the API is here'), hasLength(1));
    });

    test('长的优先：录音功能 不是 录音', () {
      final index = MentionIndex([
        _target('notes/录音.md', title: '录音'),
        _target('notes/录音功能.md', title: '录音功能'),
      ]);

      final found = index.findIn('我们做录音功能很久了');

      expect(found, hasLength(1));
      expect(found.single.target.path, 'notes/录音功能.md');
    });

    test('代码里的字样不算提到笔记', () {
      final index = MentionIndex([
        _target('notes/录音.md', title: '录音'),
      ]);
      const body = '看代码：\n`录音`\n';

      // 行内代码在 [5, 9)。
      expect(index.findIn(body, masked: const <(int, int)>[(5, 9)]), isEmpty);
      expect(index.findIn(body), hasLength(1),
          reason: '没有遮罩时它就是一次普通命中');
    });

    test('不提自己', () {
      final index = MentionIndex([
        _target('notes/录音.md', title: '录音'),
      ]);

      expect(index.findIn('这是录音的笔记', selfPath: 'notes/录音.md'), isEmpty);
      expect(index.findIn('这是录音的笔记', selfPath: 'notes/别的.md'), hasLength(1));
    });

    test('一个字的标题不当作关键词', () {
      final index = MentionIndex([
        _target('notes/书.md', title: '书'),
      ]);

      expect(index.findIn('这是一本书'), isEmpty,
          reason: '一个字出现在任何一句话里，那不叫关联，那叫噪音');
    });

    test('纯标点的标题不当作关键词', () {
      final index = MentionIndex([
        _target('notes/破折号.md', title: '——'),
      ]);

      expect(index.findIn('这里有个——符号'), isEmpty);
    });

    test('匹配不跨行', () {
      final index = MentionIndex([
        _target('notes/录音功能.md', title: '录音功能'),
      ]);

      expect(index.findIn('录音\n功能'), isEmpty,
          reason: '跨行的命中会拼出正文里根本不存在的词');
    });

    test('同名笔记只留一篇，顺序稳定', () {
      final index = MentionIndex([
        _target('notes/b/同名.md', title: '同名'),
        _target('notes/a/同名.md', title: '同名'),
      ]);

      final found = index.findIn('提到了同名');

      expect(found, hasLength(1));
      expect(found.single.target.path, 'notes/a/同名.md',
          reason: '按路径排序：同一台机器上每次都要链到同一篇');
    });

    test('标题和文件名主干都能命中', () {
      final index = MentionIndex([
        _target('notes/功能/old-name.md', title: '新名字'),
      ]);

      expect(index.findIn('说 old-name 吧'), hasLength(1),
          reason: '文件名是用户看得见的那个名字');
      expect(index.findIn('说 新名字 吧'), hasLength(1),
          reason: '标题也认');
    });

    test('命中保持正文里的原样，包括大小写', () {
      final index = MentionIndex([
        _target('notes/API.md', title: 'API'),
      ]);

      final found = index.findIn('we use Api here');

      expect(found.single.keyword, 'Api',
          reason: '显示的是用户写的那几个字，不是库里的名字');
    });

    test('空索引不认任何东西', () {
      expect(MentionIndex.empty.findIn('随便什么文字'), isEmpty);
      expect(MentionIndex.empty.targets, isEmpty);
    });

    test('关键词短于两个字的一律不算', () {
      final index = MentionIndex([
        _target('notes/a.md', title: 'A'),
      ]);

      expect(index.findIn('a single letter'), isEmpty);
    });
  });
}
