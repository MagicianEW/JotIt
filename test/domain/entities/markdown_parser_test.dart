import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/domain/entities/front_matter_patcher.dart';
import 'package:jotit/domain/entities/markdown_parser.dart';

void main() {
  const parser = MarkdownParser();

  group('front matter splitting', () {
    test('extracts a well-formed block', () {
      final note = parser.parse(
        '---\ntitle: Hello\nuid: abc-123\n---\n\nBody here.',
        fallbackTitle: 'file',
      );
      expect(note.frontMatter['title'], 'Hello');
      expect(note.uid, 'abc-123');
      expect(note.body.trim(), 'Body here.');
      expect(note.frontMatterMalformed, isFalse);
    });

    test('handles a file with no front matter', () {
      final note = parser.parse('Just a body.', fallbackTitle: 'file');
      expect(note.frontMatter, isEmpty);
      expect(note.uid, isNull);
      expect(note.body, 'Just a body.');
    });

    test('unterminated block does not swallow the document', () {
      final note = parser.parse('---\ntitle: x\n\nbody', fallbackTitle: 'file');
      expect(note.body, contains('body'));
      expect(note.frontMatterMalformed, isFalse,
          reason: 'no closing fence means there is no block, not a broken one');
    });

    test('malformed YAML degrades instead of throwing', () {
      final note = parser.parse(
        '---\ntitle: "unterminated\n  bad: [1, 2\n---\n\nBody',
        fallbackTitle: 'file',
      );
      expect(note.frontMatterMalformed, isTrue);
      expect(note.body, contains('Body'),
          reason: 'the user must still get their note back');
    });

    test('a lone "---" on the first line is not a fence', () {
      final note = parser.parse('--- not a fence\nbody', fallbackTitle: 'file');
      expect(note.frontMatterMalformed, isFalse);
    });
  });

  group('title fallback chain (§4.4)', () {
    test('front matter wins', () {
      final n = parser.parse('---\ntitle: FM\n---\n# Heading', fallbackTitle: 'f');
      expect(n.title, 'FM');
    });

    test('then the first H1', () {
      final n = parser.parse('# Heading\n\ntext', fallbackTitle: 'file');
      expect(n.title, 'Heading');
    });

    test('then the filename', () {
      final n = parser.parse('no heading', fallbackTitle: 'file');
      expect(n.title, 'file');
    });
  });

  group('wiki links (§9.1)', () {
    test('plain link', () {
      final n = parser.parse('See [[design]] for details.', fallbackTitle: 'f');
      expect(n.links, hasLength(1));
      expect(n.links.single.target, 'design');
      expect(n.links.single.isEmbed, isFalse);
    });

    test('alias is display-only, never part of the target', () {
      final n = parser.parse('[[projects/jotit|Design Doc]]', fallbackTitle: 'f');
      expect(n.links.single.target, 'projects/jotit');
      expect(n.links.single.alias, 'Design Doc');
    });

    test('heading anchor', () {
      final n = parser.parse('[[note#Section Two]]', fallbackTitle: 'f');
      expect(n.links.single.target, 'note');
      expect(n.links.single.anchor, 'Section Two');
    });

    test('block reference', () {
      final n = parser.parse('[[note#^b17e2a]]', fallbackTitle: 'f');
      expect(n.links.single.target, 'note');
      expect(n.links.single.blockId, 'b17e2a');
      expect(n.links.single.anchor, isNull);
    });

    test('embed', () {
      final n = parser.parse('![[note]]', fallbackTitle: 'f');
      expect(n.links.single.isEmbed, isTrue);
      expect(n.links.single.isAttachmentLike, isFalse);
    });

    test('attachment embed', () {
      final n = parser.parse('![[diagram.png]]', fallbackTitle: 'f');
      expect(n.links.single.isAttachmentLike, isTrue);
    });

    test('empty link yields nothing (it means "create note")', () {
      final n = parser.parse('[[]] and [[  ]]', fallbackTitle: 'f');
      expect(n.links, isEmpty);
    });

    test('anchor plus alias together', () {
      final n = parser.parse('[[note#Head|Shown]]', fallbackTitle: 'f');
      expect(n.links.single.target, 'note');
      expect(n.links.single.anchor, 'Head');
      expect(n.links.single.alias, 'Shown');
    });

    test('uid escape hatch keeps the full uid as the target', () {
      final n = parser.parse('[[uid:550e8400-e29b-41d4-a716-446655440000]]',
          fallbackTitle: 'f');
      expect(n.links.single.target, 'uid:550e8400-e29b-41d4-a716-446655440000');
    });
  });

  group('code regions are not links', () {
    test('fenced block', () {
      final n = parser.parse(
        'Real: [[actual]]\n\n```\n[[example]]\n```\n',
        fallbackTitle: 'f',
      );
      expect(n.links.map((l) => l.target), ['actual']);
    });

    test('tilde fence', () {
      final n = parser.parse('~~~\n[[example]]\n~~~\n', fallbackTitle: 'f');
      expect(n.links, isEmpty);
    });

    test('inline code span', () {
      final n = parser.parse('Write `[[not a link]]` like this.', fallbackTitle: 'f');
      expect(n.links, isEmpty);
    });

    test('double-backtick span containing a backtick', () {
      final n = parser.parse('``a ` b [[x]] ``', fallbackTitle: 'f');
      expect(n.links, isEmpty);
    });

    test('unbalanced fence stays open to end of file', () {
      final n = parser.parse('[[before]]\n```\n[[after]]', fallbackTitle: 'f');
      expect(n.links.map((l) => l.target), ['before']);
    });

    test('one-line fence', () {
      final n = parser.parse('```[[x]]``` and [[y]]', fallbackTitle: 'f');
      expect(n.links.map((l) => l.target), ['y']);
    });
  });

  group('tags', () {
    test('list form', () {
      final n = parser.parse('---\ntags:\n  - alpha\n  - beta\n---\nx',
          fallbackTitle: 'f');
      expect(n.tags, ['alpha', 'beta']);
    });

    test('comma string with hash prefixes', () {
      final n = parser.parse('---\ntags: "#one, two"\n---\nx', fallbackTitle: 'f');
      expect(n.tags, ['one', 'two']);
    });

    test('inline list', () {
      final n = parser.parse('---\ntags: [a, b, c]\n---\nx', fallbackTitle: 'f');
      expect(n.tags, ['a', 'b', 'c']);
    });

    test('absent tags', () {
      expect(parser.parse('body', fallbackTitle: 'f').tags, isEmpty);
    });
  });

  group('FrontMatterPatcher (§9.2)', () {
    test('adds uid to a file with no front matter', () {
      final out = FrontMatterPatcher.withUid('Body text', 'uid-1');
      expect(out, startsWith('---\nuid: uid-1\n---\n\nBody text'));
      expect(parser.parse(out, fallbackTitle: 'f').uid, 'uid-1');
    });

    test('replaces an existing uid in place', () {
      final out = FrontMatterPatcher.withUid('---\nuid: old\n---\nbody', 'new');
      expect(out, contains('uid: new'));
      expect(out, isNot(contains('uid: old')));
    });

    test('preserves unknown keys, comments and ordering', () {
      const original = '''---
title: My Note
# a comment the author wrote
custom_field: keep me
uid: old
review_interval: 30
---

Body
''';
      final out = FrontMatterPatcher.withUid(original, 'brand-new');
      expect(out, contains('# a comment the author wrote'));
      expect(out, contains('custom_field: keep me'));
      expect(out, contains('review_interval: 30'));
      expect(out, contains('uid: brand-new'));
      expect(out, contains('Body'));
      expect(
        out.indexOf('title: My Note'),
        lessThan(out.indexOf('uid: brand-new')),
        reason: 'the new key must land in the original position, not at the end',
      );
    });

    test('keeps CRLF line endings', () {
      final out = FrontMatterPatcher.withUid('---\r\nuid: old\r\n---\r\nbody', 'new');
      expect(out, contains('\r\n'));
      expect(out, isNot(contains('\n\n')), reason: 'no bare LF introduced');
    });

    test('respects existing quoting style', () {
      final out = FrontMatterPatcher.withStringValue(
          '---\nuid: "old"\n---\nb', 'uid', 'new');
      expect(out, contains('uid: "new"'));
    });

    test('quotes values that plain YAML would misread', () {
      final out = FrontMatterPatcher.withStringValue(
          '---\ntitle: old\n---\nb', 'title', '#hash');
      expect(out, contains('title: "#hash"'));
      expect(parser.parse(out, fallbackTitle: 'f').frontMatter['title'], '#hash');
    });

    test('readString and hasUid agree with the parser', () {
      const t = '---\ntitle: Hi\nuid: u-1\n---\nbody';
      expect(FrontMatterPatcher.readString(t, 'title'), 'Hi');
      expect(FrontMatterPatcher.hasUid(t, 'u-1'), isTrue);
      expect(FrontMatterPatcher.hasUid(t, 'other'), isFalse);
    });
  });
}