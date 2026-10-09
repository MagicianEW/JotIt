import 'dart:async';

import 'package:flutter/material.dart';
import 'package:super_editor/super_editor.dart';

import '../domain/entities/rich_note_codec.dart';

/// The WYSIWYG pane: a super_editor document over the note body.
///
/// The pane owns nothing about file layout — it receives the body after the
/// front matter was split off, and streams serialised markdown back through
/// [onChanged]. Every change the user makes eventually lands in the same
/// text buffer the source view and the preview read, so saving stays one
/// code path and the three views can never disagree about what is on disk.
///
/// The format toolbar lives inside the pane on purpose: every action it
/// offers is an operation on the super_editor document and selection, which
/// nothing outside this State can reach. The link button joins when the
/// wiki-link stage wires custom syntax into the serialiser.
class RichEditorPane extends StatefulWidget {
  const RichEditorPane({
    super.key,
    required this.body,
    required this.onChanged,
  });

  final String body;
  final void Function(String markdown) onChanged;

  @override
  State<RichEditorPane> createState() => RichEditorPaneState();
}

class RichEditorPaneState extends State<RichEditorPane> {
  late final MutableDocument _doc;
  late final Editor _editor;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _doc = deserializeNoteBody(widget.body);
    _editor = createDefaultDocumentEditor(document: _doc);
    // Serialising on every keystroke is wasteful; a short debounce keeps the
    // buffer fresh for saving while letting rapid typing stay cheap.
    _doc.addListener(_onDocumentChanged);
  }

  @override
  void dispose() {
    _doc.removeListener(_onDocumentChanged);
    _debounce?.cancel();
    super.dispose();
  }

  void _onDocumentChanged(DocumentChangeLog changeLog) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      widget.onChanged(serializeNoteBody(_doc));
    });
  }

  // ------------------------------------------------------------- formatting
  //
  // Every action acts on the live selection. A collapsed caret cannot style
  // a range, so the inline buttons arm the composer preference instead: the
  // characters typed next carry the style until the button is hit again.

  DocumentSelection? get _selection => _editor.composer.selectionNotifier.value;

  /// The document, exposed for tests to drive selections precisely.
  Document get document => _doc;

  /// Places a selection programmatically — the same entry point the tests
  /// use instead of synthesising the SuperEditor gesture pipeline.
  void select(DocumentSelection selection) {
    _editor.execute([
      ChangeSelectionRequest(
          selection, SelectionChangeType.placeCaret, 'toolbar'),
    ]);
  }

  void toggleInline(Attribution attribution) {
    final sel = _selection;
    if (sel == null) return;
    if (sel.isCollapsed) {
      _editor.composer.preferences.toggleStyle(attribution);
      return;
    }
    _editor.execute([
      ToggleTextAttributionsRequest(
          documentRange: sel, attributions: {attribution}),
    ]);
  }

  /// Body -> H1 -> H2 -> H3 -> body, mirroring the source-mode button.
  void cycleHeading() {
    final node = _selectedNode();
    if (node is! ParagraphNode) return;
    final Attribution? next = switch (node.metadata['blockType']) {
      header1Attribution => header2Attribution,
      header2Attribution => header3Attribution,
      header3Attribution => null,
      _ => header1Attribution,
    };
    _editor.execute([
      ChangeParagraphBlockTypeRequest(nodeId: node.id, blockType: next),
    ]);
  }

  void toggleQuote() {
    final node = _selectedNode();
    if (node is! ParagraphNode) return;
    final isQuote = node.metadata['blockType'] == blockquoteAttribution;
    _editor.execute([
      ChangeParagraphBlockTypeRequest(
          nodeId: node.id, blockType: isQuote ? null : blockquoteAttribution),
    ]);
  }

  /// Toggles a list item, switches between bullet and ordered, or converts
  /// a plain paragraph — whichever transition the node needs.
  void toggleList(ListItemType type) {
    final node = _selectedNode();
    if (node is ListItemNode) {
      if (node.type == type) {
        _editor.execute([ConvertListItemToParagraphRequest(nodeId: node.id)]);
      } else {
        _editor.execute([
          ConvertListItemToParagraphRequest(nodeId: node.id),
          ConvertParagraphToListItemRequest(nodeId: node.id, type: type),
        ]);
      }
      return;
    }
    if (node is ParagraphNode) {
      _editor.execute([
        ConvertParagraphToListItemRequest(nodeId: node.id, type: type),
      ]);
    }
  }

  DocumentNode? _selectedNode() {
    final sel = _selection;
    if (sel == null) return null;
    for (var i = 0; i < _doc.nodeCount; i++) {
      final node = _doc.getNodeAt(i);
      if (node != null && node.id == sel.extent.nodeId) return node;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    // The default stylesheet is dark-mode aware through the theme; a custom
    // theme pass comes later.
    return Column(
      children: [
        Expanded(child: SuperEditor(editor: _editor)),
        _toolbar(context),
      ],
    );
  }

  Widget _toolbar(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          IconButton(
            key: const ValueKey('rich-fmt-bold'),
            tooltip: '加粗',
            icon: const Icon(Icons.format_bold),
            onPressed: () => toggleInline(boldAttribution),
          ),
          IconButton(
            key: const ValueKey('rich-fmt-italic'),
            tooltip: '斜体',
            icon: const Icon(Icons.format_italic),
            onPressed: () => toggleInline(italicsAttribution),
          ),
          IconButton(
            key: const ValueKey('rich-fmt-strike'),
            tooltip: '删除线',
            icon: const Icon(Icons.strikethrough_s),
            onPressed: () => toggleInline(strikethroughAttribution),
          ),
          IconButton(
            key: const ValueKey('rich-fmt-code'),
            tooltip: '行内代码',
            icon: const Icon(Icons.code),
            onPressed: () => toggleInline(codeAttribution),
          ),
          IconButton(
            key: const ValueKey('rich-fmt-heading'),
            tooltip: '标题',
            icon: const Icon(Icons.title),
            onPressed: cycleHeading,
          ),
          IconButton(
            key: const ValueKey('rich-fmt-ul'),
            tooltip: '无序列表',
            icon: const Icon(Icons.format_list_bulleted),
            onPressed: () => toggleList(ListItemType.unordered),
          ),
          IconButton(
            key: const ValueKey('rich-fmt-ol'),
            tooltip: '有序列表',
            icon: const Icon(Icons.format_list_numbered),
            onPressed: () => toggleList(ListItemType.ordered),
          ),
          IconButton(
            key: const ValueKey('rich-fmt-quote'),
            tooltip: '引用',
            icon: const Icon(Icons.format_quote),
            onPressed: toggleQuote,
          ),
        ]),
      ),
    );
  }
}
