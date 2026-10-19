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
    this.onEditStarted,
  });

  final String body;
  final void Function(String markdown) onChanged;

  /// Fired the instant the document changes, before [onChanged]'s debounce
  /// decides what the text is.
  ///
  /// The editor page needs it for its unsaved-changes guards (the leave
  /// dialog, the back gesture): an edit still inside the 250 ms debounce is
  /// invisible to them, and leaving would then happen without asking about
  /// text the user typed half a second ago.
  final VoidCallback? onEditStarted;

  @override
  State<RichEditorPane> createState() => RichEditorPaneState();
}

class RichEditorPaneState extends State<RichEditorPane> {
  // Not final: an external change to [RichEditorPane.body] (an attachment
  // spliced into the buffer, a jump to another note) reloads both from
  // scratch — see [didUpdateWidget]. `SuperEditor` is built to take a swapped
  // `Editor`; its own `didUpdateWidget` re-wires the composer and layout.
  late MutableDocument _doc;
  late Editor _editor;
  Timer? _debounce;

  /// The `widget.body` value the document is currently in sync with. Compared
  /// by value, never by reference: the parent rebuilds the body string on
  /// every frame, so identity would report a change that never happened.
  String _knownBody = '';

  @override
  void initState() {
    super.initState();
    _loadDocument(widget.body);
    // Serialising on every keystroke is wasteful; a short debounce keeps the
    // buffer fresh for saving while letting rapid typing stay cheap.
    _doc.addListener(_onDocumentChanged);
  }

  /// Rebuilds the document — and the editor over it — from [body].
  void _loadDocument(String body) {
    _doc = deserializeNoteBody(body);
    _editor = createDefaultDocumentEditor(document: _doc);
    _knownBody = body;
  }

  @override
  void didUpdateWidget(covariant RichEditorPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.body == _knownBody) return;

    // "A different string" is not by itself an external edit: the parent hands
    // the pane a body derived from the shared text buffer on every rebuild,
    // and this pane's own debounced serialisation loops back through that
    // buffer — treating it as external would reload the document under the
    // user's caret on every pause in typing. Compare the *serialised
    // document* against the incoming body instead: equal means the change
    // originated here and the document already agrees with the buffer.
    //
    // The comparison trims because the stitching is not byte-exact: the parent
    // re-attaches the front matter with a blank line, so the body that comes
    // back carries an extra leading newline around the very same text.
    if (widget.body.trim() == serializeNoteBody(_doc).trim()) {
      _knownBody = widget.body;
      return;
    }

    // A genuinely external edit: reload. Anything still on the debounce
    // describes a document the user can no longer see, so it is dropped —
    // the editor page flushes before it mutates the buffer, so nothing the
    // user typed is lost in the process.
    _debounce?.cancel();
    _doc.removeListener(_onDocumentChanged);
    _loadDocument(widget.body);
    _doc.addListener(_onDocumentChanged);
  }

  @override
  void dispose() {
    _doc.removeListener(_onDocumentChanged);
    // Deliberately no flush here. A pending serialisation is delivered by the
    // editor page *before* it removes the pane (view switch, save, jump —
    // see [EditorPage]); reaching back into the parent's state from a
    // dispose that can run mid-teardown is the setState-after-dispose class
    // of bug this codebase avoids. The one removal the parent cannot pre-empt
    // — leaving the page — is covered by PopScope, which learns about the
    // edit through [RichEditorPane.onEditStarted] and asks before discarding.
    _debounce?.cancel();
    super.dispose();
  }

  void _onDocumentChanged(DocumentChangeLog changeLog) {
    // Mark the note dirty before the debounce: the guards that ask "are there
    // unsaved changes?" must not wait 250 ms to learn the answer.
    widget.onEditStarted?.call();
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      widget.onChanged(serializeNoteBody(_doc));
    });
  }

  /// True while a serialisation is still waiting on the debounce.
  bool get hasPendingChange => _debounce?.isActive ?? false;

  /// Delivers a pending serialisation now instead of on the debounce.
  ///
  /// The editor page calls this before it tears the pane down or writes the
  /// buffer: without it, an edit made in the last 250 ms before a view switch
  /// was cancelled with the timer and silently lost.
  void flush() {
    final pending = _debounce?.isActive ?? false;
    _debounce?.cancel();
    _debounce = null;
    if (pending) widget.onChanged(serializeNoteBody(_doc));
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
