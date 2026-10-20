import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// Finds where a link sits on the screen, so a test can tap it.
///
/// `find.text` only finds a *whole* paragraph, and a link in the middle of
/// a sentence is never a whole paragraph. So the span tree is walked down
/// to the span that carries the recognizer, the offset is accumulated on
/// the way (a `TextSpan` does not know its own place in the paragraph —
/// the layout does), and the paragraph's own boxes turn that into a point
/// on the screen.
///
/// The result is in global coordinates, because that is what a tap wants.
Offset? linkOffset(WidgetTester tester, Finder paragraph, String label) {
  final widget = tester.widget<Text>(paragraph);
  final span = widget.textSpan;
  if (span is! TextSpan) return null;
  final link = _findLinkSpan(span, label);
  if (link == null) return null;
  final render = tester.renderObject<RenderParagraph>(paragraph);
  final boxes = render.getBoxesForSelection(
    TextSelection(baseOffset: link.start, extentOffset: link.end),
  );
  if (boxes.isEmpty) return null;
  final box = boxes.first;
  // The box is in the paragraph's own coordinates; the tap has to be
  // given in the screen's.
  final local = Offset((box.left + box.right) / 2, (box.top + box.bottom) / 2);
  return render.localToGlobal(local);
}

/// The link span called [label], with where it starts and ends.
({int start, int end})? _findLinkSpan(
  TextSpan span,
  String label, [
  int offset = 0,
]) {
  final text = span.text;
  if (text != null) {
    if (text == label && span.recognizer != null) {
      return (start: offset, end: offset + text.length);
    }
    return null;
  }
  var cursor = offset;
  for (final child in span.children ?? const <InlineSpan>[]) {
    if (child is! TextSpan) continue;
    final found = _findLinkSpan(child, label, cursor);
    if (found != null) return found;
    cursor += child.toPlainText().length;
  }
  return null;
}
