import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/domain/entities/rich_note_codec.dart';
import 'package:jotit/ui/rich_editor.dart';
import 'package:super_editor/super_editor.dart';

/// P1-10 and P1-11, at the pane's own boundary.
///
/// The pane debounces its serialisation by 250 ms. Everything here is about
/// what happens to an edit that is still inside that window when something
/// else happens: the page flushes it (P1-10), or the buffer the pane reads
/// from changes underneath it (P1-11).
///
/// The "edit" is a toolbar action rather than synthesised typing: it travels
/// the same document-change path — listener, debounce, serialisation — and
/// the toolbar is the entry point these tests already have without a gesture
/// pipeline standing in the way.
void main() {
  late String lastEmitted;
  late int editStartedCalls;

  Future<RichEditorPaneState> mountPane(WidgetTester tester, String body) async {
    lastEmitted = '';
    editStartedCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RichEditorPane(
            body: body,
            onChanged: (md) => lastEmitted = md,
            onEditStarted: () => editStartedCalls++,
          ),
        ),
      ),
    );
    await tester.pump();
    return tester.state<RichEditorPaneState>(find.byType(RichEditorPane));
  }

  /// A collapsed caret somewhere inside the first paragraph — the selection
  /// the toolbar acts on.
  void placeCaret(RichEditorPaneState pane, {int offset = 0}) {
    final node = pane.document.getNodeAt(0)!;
    pane.select(DocumentSelection(
      base: DocumentPosition(
          nodeId: node.id, nodePosition: TextNodePosition(offset: offset)),
      extent: DocumentPosition(
          nodeId: node.id, nodePosition: TextNodePosition(offset: offset)),
    ));
  }

  testWidgets('a pending serialisation waits for the debounce, then fires',
      (tester) async {
    final pane = await mountPane(tester, '一段正文。\n');
    placeCaret(pane);
    pane.toggleQuote();

    expect(pane.hasPendingChange, isTrue,
        reason: 'the edit is inside the 250 ms window');
    expect(lastEmitted, isEmpty,
        reason: 'the debounce has not delivered anything yet');

    await tester.pump(const Duration(milliseconds: 400));

    expect(lastEmitted, contains('> 一段正文。'),
        reason: 'once the window passes, the serialisation lands');
    expect(pane.hasPendingChange, isFalse);
  });

  testWidgets('flush delivers the pending serialisation immediately',
      (tester) async {
    final pane = await mountPane(tester, '一段正文。\n');
    placeCaret(pane);
    pane.toggleQuote();

    pane.flush();

    expect(lastEmitted, contains('> 一段正文。'),
        reason: 'P1-10: this is what the editor page calls before it tears '
            'the pane down — the alternative was cancelling the timer and '
            'losing the edit');
    expect(pane.hasPendingChange, isFalse);
  });

  testWidgets('flush is a no-op when nothing is pending', (tester) async {
    final pane = await mountPane(tester, '一段正文。\n');
    pane.flush();

    expect(lastEmitted, isEmpty,
        reason: 'a flush with no pending change must not fabricate an edit');
  });

  testWidgets('an edit marks the note dirty before the debounce decides the '
      'text', (tester) async {
    final pane = await mountPane(tester, '一段正文。\n');
    placeCaret(pane);
    pane.toggleQuote();

    expect(editStartedCalls, 1,
        reason: 'the unsaved-changes guards must not wait 250 ms to learn '
            'there is something to guard');
    expect(lastEmitted, isEmpty,
        reason: 'dirty-now is not the same as serialised-now');
  });

  testWidgets('an external change to the body reloads the document',
      (tester) async {
    // P1-11: the buffer can change under a mounted pane — the editor page
    // splices an attachment link into it — and a pane that keeps editing its
    // old document would wipe that link on its next serialisation.
    final pane = await mountPane(tester, '一段正文。\n');
    expect(serializeNoteBody(pane.document), contains('一段正文'));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RichEditorPane(
            body: '一段正文。\n\n![[attachments/6f1a.png]]\n',
            onChanged: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(serializeNoteBody(pane.document), contains('![[attachments/6f1a.png]]'),
        reason: 'the pane must not keep serialising a document the buffer no '
            'longer matches');
  });

  testWidgets('the pane\'s own serialisation looping back is not an external '
      'change', (tester) async {
    // The editor page rebuilds the pane's body from the shared buffer on every
    // frame, and the debounced serialisation travels through that buffer:
    // without the serialisation comparison, every pause in typing would look
    // like an external edit and reload the document under the caret.
    final pane = await mountPane(tester, '一段正文。\n');
    placeCaret(pane);
    pane.toggleQuote();
    expect(pane.hasPendingChange, isTrue);

    // Exactly the shape the editor page hands back: the front matter stitched
    // on with a blank line, so the body comes back with an extra leading
    // newline around the very same text.
    final emitted = serializeNoteBody(pane.document);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RichEditorPane(
            body: '\n$emitted',
            onChanged: (md) => lastEmitted = md,
            onEditStarted: () => editStartedCalls++,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(pane.hasPendingChange, isTrue,
        reason: 'the pending edit must survive its own serialisation coming '
            'back through the body prop');

    await tester.pump(const Duration(milliseconds: 400));
    expect(lastEmitted, contains('> 一段正文。'));
  });

  testWidgets('an external change drops a pending edit that describes a '
      'document the user can no longer see', (tester) async {
    final pane = await mountPane(tester, '一段正文。\n');
    placeCaret(pane);
    pane.toggleQuote();
    expect(pane.hasPendingChange, isTrue);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RichEditorPane(body: '另一篇笔记。\n', onChanged: (_) {}),
        ),
      ),
    );
    await tester.pump();

    expect(pane.hasPendingChange, isFalse,
        reason: 'the old debounce describes the old document; the editor page '
            'flushes before it mutates the buffer, so nothing typed is lost');
    expect(serializeNoteBody(pane.document), contains('另一篇笔记。'));
    expect(lastEmitted, isEmpty);
  });
}
