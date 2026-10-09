import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/domain/entities/rich_note_codec.dart';
import 'package:jotit/ui/rich_editor.dart';
import 'package:super_editor/super_editor.dart';

/// The rich pane's format toolbar: the buttons a boss without Markdown
/// vocabulary actually presses, and the markdown each one writes.
///
/// Assertions read the document back through the codec — the same serialiser
/// the save path uses — so a button that styles the document without
/// producing standard markdown still fails here.
void main() {
  late String lastEmitted;

  Future<RichEditorPaneState> openPane(
      WidgetTester tester, String body) async {
    lastEmitted = '';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RichEditorPane(
            body: body,
            onChanged: (md) => lastEmitted = md,
          ),
        ),
      ),
    );
    await tester.pump();
    return tester.state<RichEditorPaneState>(find.byType(RichEditorPane));
  }

  void selectParagraphRange(RichEditorPaneState pane,
      {required int nodeIndex, required int start, required int end}) {
    final node = pane.document.getNodeAt(nodeIndex)!;
    pane.select(DocumentSelection(
      base: DocumentPosition(
          nodeId: node.id, nodePosition: TextNodePosition(offset: start)),
      extent: DocumentPosition(
          nodeId: node.id, nodePosition: TextNodePosition(offset: end)),
    ));
  }

  testWidgets('the toolbar offers the everyday formats', (tester) async {
    await openPane(tester, '一段正文。\n');

    for (final key in [
      'rich-fmt-bold',
      'rich-fmt-italic',
      'rich-fmt-strike',
      'rich-fmt-code',
      'rich-fmt-heading',
      'rich-fmt-ul',
      'rich-fmt-ol',
      'rich-fmt-quote',
    ]) {
      expect(find.byKey(ValueKey(key)), findsOneWidget,
          reason: 'the rich toolbar must carry $key');
    }
  });

  testWidgets('bold wraps the selected text in asterisks', (tester) async {
    final pane = await openPane(tester, '一段正文。\n');
    selectParagraphRange(pane, nodeIndex: 0, start: 0, end: 3);

    await tester.tap(find.byKey(const ValueKey('rich-fmt-bold')));
    await tester.pump();

    expect(serializeNoteBody(pane.document), contains('**一段正**文。'));
  });

  testWidgets('strike-through and italics mark the selected text',
      (tester) async {
    final pane = await openPane(tester, '一段正文。\n');
    selectParagraphRange(pane, nodeIndex: 0, start: 0, end: 2);

    await tester.tap(find.byKey(const ValueKey('rich-fmt-italic')));
    await tester.pump();

    selectParagraphRange(pane, nodeIndex: 0, start: 2, end: 4);
    await tester.tap(find.byKey(const ValueKey('rich-fmt-strike')));
    await tester.pump();

    final md = serializeNoteBody(pane.document);
    expect(md, contains('*一段*'));
    expect(md, contains('~~正文~~'));
  });

  testWidgets('the heading button cycles body through the levels',
      (tester) async {
    final pane = await openPane(tester, '一段正文。\n');
    selectParagraphRange(pane, nodeIndex: 0, start: 0, end: 0);

    await tester.tap(find.byKey(const ValueKey('rich-fmt-heading')));
    await tester.pump();
    expect(serializeNoteBody(pane.document), startsWith('# 一段正文'));

    await tester.tap(find.byKey(const ValueKey('rich-fmt-heading')));
    await tester.pump();
    expect(serializeNoteBody(pane.document), startsWith('## 一段正文'));

    await tester.tap(find.byKey(const ValueKey('rich-fmt-heading')));
    await tester.pump();
    expect(serializeNoteBody(pane.document), startsWith('### 一段正文'));

    await tester.tap(find.byKey(const ValueKey('rich-fmt-heading')));
    await tester.pump();
    expect(serializeNoteBody(pane.document), startsWith('一段正文'));
  });

  testWidgets('the list buttons convert a paragraph and toggle back',
      (tester) async {
    final pane = await openPane(tester, '一段正文。\n');
    selectParagraphRange(pane, nodeIndex: 0, start: 0, end: 0);

    await tester.tap(find.byKey(const ValueKey('rich-fmt-ul')));
    await tester.pump();
    expect(serializeNoteBody(pane.document),
        matches(RegExp(r'^\s*[-*] 一段正文', multiLine: true)));

    // Same button again: the item becomes a plain paragraph.
    await tester.tap(find.byKey(const ValueKey('rich-fmt-ul')));
    await tester.pump();
    final md = serializeNoteBody(pane.document);
    expect(md, isNot(matches(RegExp(r'^\s*[-*] ', multiLine: true))));
    expect(md, contains('一段正文'));

    // Ordered, and a switch between the two flavours.
    await tester.tap(find.byKey(const ValueKey('rich-fmt-ol')));
    await tester.pump();
    expect(serializeNoteBody(pane.document),
        matches(RegExp(r'^\s*1\. 一段正文', multiLine: true)));

    await tester.tap(find.byKey(const ValueKey('rich-fmt-ul')));
    await tester.pump();
    expect(serializeNoteBody(pane.document),
        matches(RegExp(r'^\s*[-*] 一段正文', multiLine: true)));
  });

  testWidgets('the quote button toggles a block quote', (tester) async {
    final pane = await openPane(tester, '一段正文。\n');
    selectParagraphRange(pane, nodeIndex: 0, start: 0, end: 0);

    await tester.tap(find.byKey(const ValueKey('rich-fmt-quote')));
    await tester.pump();
    expect(serializeNoteBody(pane.document), startsWith('> 一段正文'));

    await tester.tap(find.byKey(const ValueKey('rich-fmt-quote')));
    await tester.pump();
    final md = serializeNoteBody(pane.document);
    expect(md, isNot(startsWith('>')));
    expect(md, contains('一段正文'));
  });

  testWidgets('a collapsed caret arms the style instead of mangling text',
      (tester) async {
    final pane = await openPane(tester, '一段正文。\n');
    selectParagraphRange(pane, nodeIndex: 0, start: 2, end: 2);

    await tester.tap(find.byKey(const ValueKey('rich-fmt-bold')));
    await tester.pump();

    // Nothing selected, so nothing changes on disk yet.
    expect(serializeNoteBody(pane.document), contains('一段正文。'));
  });

  testWidgets('toolbar edits reach the onChanged stream', (tester) async {
    await openPane(tester, '一段正文。\n');
    final pane = tester.state<RichEditorPaneState>(find.byType(RichEditorPane));
    selectParagraphRange(pane, nodeIndex: 0, start: 0, end: 3);

    await tester.tap(find.byKey(const ValueKey('rich-fmt-bold')));
    // The pane debounces serialisation by 250 ms.
    await tester.pump(const Duration(milliseconds: 400));

    expect(lastEmitted, contains('**一段正**文。'),
        reason: 'the toolbar must feed the same buffer the save path reads');
  });
}
