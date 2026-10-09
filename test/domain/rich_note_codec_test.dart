import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/domain/entities/rich_note_codec.dart';

/// The rich-text codec: what may enter the WYSIWYG editor, and what the
/// round trip through a super_editor document preserves.
///
/// The waiver agreed for rich saves is that *formatting is normalised* —
/// so the round-trip test asserts content survives (every paragraph, list
/// item, table cell), not that the bytes come back identical. Serialisation
/// must, however, stay inside standard markdown: the superEditor dialect's
/// `¬underline¬` and `:---` alignment notation would corrupt the file for
/// every other tool the user owns.
void main() {
  group('detectUnsupportedSyntax', () {
    test('plain markdown passes', () {
      expect(
        detectUnsupportedSyntax('# 标题\n\n**粗**和*斜*。\n\n- 甲\n\n> 引用\n'),
        isNull,
      );
    });

    test('HTML blocks are refused', () {
      expect(detectUnsupportedSyntax('<div>\nhtml\n</div>\n'), 'HTML 块');
      expect(detectUnsupportedSyntax('<!-- comment -->\n'), 'HTML 块');
    });

    test('footnotes are refused', () {
      expect(detectUnsupportedSyntax('文字[^1]。\n\n[^1]: 注释\n'), '脚注');
    });

    test('definition lists are refused', () {
      expect(detectUnsupportedSyntax('术语\n: 定义\n'), '定义列表');
    });

    test('wiki links are refused until stage 2 wires them in', () {
      expect(detectUnsupportedSyntax('跳到[[b]]。\n'), '双链语法');
      expect(detectUnsupportedSyntax('![[pic.png]]\n'), '双链语法');
    });

    test('wiki syntax inside a code fence does not trigger the fallback',
        () {
      expect(
        detectUnsupportedSyntax('```md\n[[a]] 是文档不是链接\n```\n'),
        isNull,
      );
    });
  });

  group('deserialize / serialize round trip', () {
    const sample = '# 计划\n\n'
        '这是**加粗**、*斜体*、~~删除~~与`代码`。\n\n'
        '- 甲\n- 乙\n- 丙\n\n'
        '1. one\n2. two\n\n'
        '> 一段引用\n\n'
        '| 列A | 列B |\n'
        '|-----|-----|\n'
        '| 1 | 2 |\n\n'
        '结尾段落。\n';

    test('content survives the round trip', () {
      final doc = deserializeNoteBody(sample);
      final md = serializeNoteBody(doc);
      final doc2 = deserializeNoteBody(md);

      expect(doc2.nodeCount, doc.nodeCount,
          reason: 'round trip must not add or drop blocks');
      for (var i = 0; i < doc.nodeCount; i++) {
        expect(doc2.getNodeAt(i)!.runtimeType, doc.getNodeAt(i)!.runtimeType,
            reason: 'block ${doc.getNodeAt(i)} changed kind through the trip');
      }
      // Content spot checks on the re-serialised markdown. The serializer
      // writes asterisk bullets with a two-space indent — accepted form.
      expect(md, contains('**加粗**'));
      expect(md, contains('*斜体*'));
      expect(md, contains('~~删除~~'));
      expect(md, matches(RegExp(r'^\s*[-*] 甲', multiLine: true)));
      expect(md, matches(RegExp(r'^\s*1\. one', multiLine: true)));
      expect(md, contains('| 列A | 列B |'));
      expect(md, contains('结尾段落。'));
    });

    test('serialisation stays inside standard markdown', () {
      final md = serializeNoteBody(deserializeNoteBody(sample));
      expect(md, isNot(contains('¬')),
          reason: 'the superEditor underline notation must never leak');
      expect(md, isNot(contains(':---')),
          reason: 'the superEditor alignment notation must never leak');
    });

    test('strikethrough serialises to standard double tildes', () {
      // super_editor writes a single tilde; GFM tools ignore it.
      final md = serializeNoteBody(deserializeNoteBody('~删除~'));
      expect(md, contains('~~删除~~'));
      expect(md, isNot(RegExp(r'(?<!~)~[^~]+~(?!~)')),
          reason: 'no single-tilde strike may survive serialisation');
    });

    test('literal tildes inside code are left alone', () {
      final md = serializeNoteBody(deserializeNoteBody('记号 `~x~` 与文字\n'));
      expect(md, contains('`~x~`'));
      expect(md, isNot(contains('~~x~~')));
    });

    test('empty and whitespace-only bodies produce an editable document',
        () {
      final doc = deserializeNoteBody('');
      expect(doc.nodeCount, isNonZero,
          reason: 'super_editor needs at least one node to place a caret');
      final md = serializeNoteBody(doc);
      expect(md.trim(), isEmpty);
    });
  });
}
