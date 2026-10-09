import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../app/vault_session.dart';
import '../domain/entities/markdown_parser.dart';
import '../domain/entities/rich_note_codec.dart';
import '../domain/vault/attachment_writer.dart';
import 'note_preview.dart';
import 'rich_editor.dart';

/// The three ways a note can be shown. [EditorView.rich] is the WYSIWYG pane
/// (super_editor) — entered only when the note carries no syntax the rich
/// editor would mangle on save.
enum EditorView { preview, rich, source }

/// The note editor.
///
/// The text area shows the file verbatim, front matter included. JotIt does
/// not re-serialize Markdown: a note written by another tool comes back
/// byte-identical apart from the fields it owns, and pretending otherwise
/// would silently delete unknown keys and comments.
class EditorPage extends ConsumerStatefulWidget {
  const EditorPage({super.key});

  @override
  ConsumerState<EditorPage> createState() => EditorPageState();
}

class EditorPageState extends ConsumerState<EditorPage> {
  final _controller = TextEditingController();

  /// Needed for one thing only: where the cursor is, so a pasted attachment
  /// lands where the user was typing rather than at the top of the file.
  final _focus = FocusNode();

  /// The note path the text in [_controller] belongs to. The controller and
  /// this path are always a consistent pair; a null path means nothing is
  /// loaded yet. A boolean "loaded" flag cannot express the dangerous
  /// in-between state: during a jump, the provider re-runs for the new path
  /// but `skipLoadingOnReload` still hands the OLD note to `data:`, and a
  /// flag-based refill would happily fill the new page with the old note.
  String? _loadedPath;

  /// Where the next preview-tap lookup starts. Blocks are matched against
  /// source lines in document order, so tapping successive paragraphs walks
  /// the file downward instead of always matching the first occurrence.
  int _matchCursor = 0;

  bool _dirty = false;
  bool _attaching = false;

  /// Opened in preview, because most opens are reads, not edits.
  EditorView _view = EditorView.preview;

  String? _status;

  /// Whether this note may enter the rich-text editor. Notes carrying syntax
  /// the rich editor cannot round-trip (wiki links until they are wired in,
  /// HTML blocks, footnotes) fall back to the source view — a save there
  /// would rewrite text the rich pane never understood.
  bool get _richAllowed {
    if (_loadedPath == null) return false;
    final body = const MarkdownParser().splitFrontMatter(_controller.text).body;
    return detectUnsupportedSyntax(body) == null;
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final path = ref.watch(openNoteProvider);
    final async = ref.watch(editableNoteProvider);

    // Derived from the async state, NOT from a flag assigned inside `_body`:
    // `_body` runs *after* the app bar below was already built, so gating on
    // a build-time side effect here would show last frame's value. In
    // preview mode nothing else triggers a rebuild, and the toggle would
    // stay dead until the user edited something they cannot reach.
    final editable = async.asData?.value != null;

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final leave = await _confirmDiscard();
        if (leave && context.mounted) Navigator.of(context).pop();
      },
      // The save button's tooltip says "保存 (Ctrl+S)", so Ctrl+S has to
      // exist. It did not: a tooltip promising a shortcut nothing listens for
      // is worse than no tooltip, because the user is told to press something
      // and nothing happens. Meta is bound alongside Control for the macOS
      // build, where Control is not the primary modifier.
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
          const SingleActivator(LogicalKeyboardKey.keyS, meta: true): _save,
        },
        child: Scaffold(
          appBar: AppBar(
            // Controller and `_loadedPath` are one consistent pair, so the
            // title tracks what is actually on screen — including a jump's
            // brief reload window, where it keeps showing the old note rather
            // than mixing the new path with the old text.
            title: Text(
              _titleOf(_loadedPath ?? path, _controller.text),
              overflow: TextOverflow.ellipsis,
            ),
            actions: [
              PopupMenuButton<EditorView>(
                key: const ValueKey('editor-view-menu'),
                tooltip: '切换视图',
                icon: Icon(_iconOf(_view)),
                onSelected: _switchView,
                enabled: editable,
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: EditorView.preview,
                    child: _viewRow(
                        Icons.visibility_outlined, '预览', _view == EditorView.preview),
                  ),
                  PopupMenuItem(
                    value: EditorView.rich,
                    enabled: _richAllowed,
                    child: _viewRow(
                        Icons.article_outlined,
                        _richAllowed
                            ? '富文本编辑'
                            : '富文本编辑（含不支持语法）',
                        _view == EditorView.rich),
                  ),
                  PopupMenuItem(
                    value: EditorView.source,
                    child: _viewRow(
                        Icons.edit_outlined, '源码', _view == EditorView.source),
                  ),
                ],
              ),
              IconButton(
                icon: const Icon(Icons.attach_file),
                tooltip: '插入附件',
                onPressed: editable && !_attaching ? _attachFile : null,
              ),
              IconButton(
                icon: const Icon(Icons.save_outlined),
                tooltip: '保存 (Ctrl+S)',
                onPressed: editable ? _save : null,
              ),
            ],
          ),
          body: async.when(
            // Rebuilding this provider is normal while the page is open —
            // every save bumps the version the provider now watches. Keep the
            // previous note on screen through those rebuilds instead of
            // flashing a spinner over the text the user is typing; the
            // controller only refills when the note *path* changes (see
            // _loadedPath).
            skipLoadingOnReload: true,
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('打不开：$e')),
            data: (note) => _body(note, path),
          ),
        ),
      ),
    );
  }

  Widget _body(EditableNote? note, String? path) {
    if (note == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            path == null ? '没有选中笔记' : '这个文件不能以 UTF-8 打开',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    // Refill only when the loaded note changes. During a jump the provider
    // re-runs for the new path, but `skipLoadingOnReload` still delivers the
    // OLD note here first; refilling on a boolean would pour that old text
    // into the new page and then ignore the real data when it arrives.
    if (_loadedPath != note.notePath) {
      _controller.text = note.text;
      _loadedPath = note.notePath;
      _matchCursor = 0;
      // The app bar above was built from the pre-refill pair (title reads as
      // a build-time side effect otherwise). One post-frame rebuild lets it
      // show the new note's title.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }

    // Keyed by path so a jumped-to note rebuilds the preview from scratch —
    // including its link index, which belongs to the note being shown.
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: switch (_view) {
              EditorView.preview => NotePreview(
                  key: ValueKey('preview-${note.notePath}'),
                  text: _controller.text,
                  onOpenNote: _openLinkedNote,
                  onTapBlock: _locateAndEdit,
                ),
              EditorView.rich => RichEditorPane(
                  key: ValueKey('rich-${note.notePath}'),
                  body:
                      const MarkdownParser().splitFrontMatter(_controller.text).body,
                  onChanged: _onRichChanged,
                ),
              EditorView.source => TextField(
                  key: const ValueKey('editor-body'),
                  controller: _controller,
                  focusNode: _focus,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  style: const TextStyle(fontFamily: 'Consolas', height: 1.5),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    hintText: '正文',
                  ),
                  onChanged: (_) {
                    if (!_dirty) setState(() => _dirty = true);
                  },
                ),
            },
          ),
        ),
        // The toolbar lives in preview and source. In preview it acts on the
        // caret last placed by a tap on the rendered text; rich mode carries
        // its own toolbar inside the pane, because its buttons operate on
        // the super_editor document and selection that only the pane holds.
        if (_view != EditorView.rich) _formatBar(),
        _StatusBar(
          status: _status,
          note: note,
          onSave: _save,
        ),
      ],
    );
  }

  /// A tapped wiki link resolved to a note that exists in the vault. Swap this
  /// page over to it instead of pushing: a stack of editors per link click
  /// makes "back" mean "the note I was on", but it also means the user can
  /// wander five notes deep and the system back gesture then reverses a
  /// reading path they no longer remember.
  Future<void> _openLinkedNote(String targetPath) async {
    final current = ref.read(openNoteProvider);
    if (targetPath == current) return;

    // Unsaved edits live only in this controller; jumping away is a navigation
    // the user asked for, but losing the text silently is not part of the
    // bargain. Same dialog, same wording, as leaving through the back button.
    if (_dirty) {
      final leave = await _confirmDiscard();
      if (!leave || !mounted) return;
    }

    ref.read(openNoteProvider.notifier).open(targetPath);
    setState(() {
      _dirty = false;
      _status = null;
      _view = EditorView.preview;
    });
  }

  String _titleOf(String? path, String? text) {
    if (path == null) return 'JotIt';
    final base = path.split('/').last;
    final stem = base.endsWith('.md') ? base.substring(0, base.length - 3) : base;
    // Same three-step resolution as the shelf list (§4.4): a file name parked
    // in the app bar reads as "this is my title" when it is only storage.
    return MarkdownParser.resolveTitle(text ?? '', fallback: stem);
  }

  // ------------------------------------------------------------- formatting
  //
  // For people who never learned Markdown. Every edit goes through the
  // controller's value (text + selection together), because setting `text`
  // alone would dump the caret at offset 0 and make consecutive clicks
  // unusable. Each helper is public for the tests; the buttons are their only
  // production callers.

  void _markEdited() {
    if (!_dirty) setState(() => _dirty = true);
  }

  IconData _iconOf(EditorView view) => switch (view) {
        EditorView.preview => Icons.visibility_outlined,
        EditorView.rich => Icons.article_outlined,
        EditorView.source => Icons.edit_outlined,
      };

  Widget _viewRow(IconData icon, String label, bool current) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon,
              size: 18,
              color: current ? Theme.of(context).colorScheme.primary : null),
          const SizedBox(width: 8),
          Text(label),
        ],
      );

  void _switchView(EditorView view) {
    if (view == _view) return;
    if (view == EditorView.rich && !_richAllowed) {
      // Saying why beats a silently disabled item: the user knows to open
      // the source and look for the offending syntax.
      setState(() => _status =
          '该笔记包含富文本暂不支持的语法（双链/HTML/脚注等），请用源码模式编辑');
      return;
    }
    setState(() => _view = view);
  }

  /// The rich editor's markdown streams back here. The front matter is
  /// stitched back on exactly as it was read — the pane never sees it, and
  /// no serialiser ever rewrites it.
  void _onRichChanged(String body) {
    final split = const MarkdownParser().splitFrontMatter(_controller.text);
    final full = split.hasBlock ? '${split.raw}\n\n$body' : body;
    if (full == _controller.text) return;
    _controller.text = full;
    _markEdited();
  }

  /// The format toolbar shown under the text field in edit mode.
  Widget _formatBar() {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            IconButton(
              tooltip: '加粗',
              icon: const Icon(Icons.format_bold),
              onPressed: () => _wrapSelection('**', '**'),
            ),
            IconButton(
              tooltip: '斜体',
              icon: const Icon(Icons.format_italic),
              onPressed: () => _wrapSelection('*', '*'),
            ),
            IconButton(
              tooltip: '删除线',
              icon: const Icon(Icons.strikethrough_s),
              onPressed: () => _wrapSelection('~~', '~~'),
            ),
            IconButton(
              tooltip: '行内代码',
              icon: const Icon(Icons.code),
              onPressed: () => _wrapSelection('`', '`'),
            ),
            IconButton(
              tooltip: '链接',
              icon: const Icon(Icons.link),
              onPressed: _insertLink,
            ),
            IconButton(
              tooltip: '列表',
              icon: const Icon(Icons.format_list_bulleted),
              onPressed: () => _toggleLinePrefix('- '),
            ),
            IconButton(
              tooltip: '引用',
              icon: const Icon(Icons.format_quote),
              onPressed: () => _toggleLinePrefix('> '),
            ),
            IconButton(
              tooltip: '标题',
              icon: const Icon(Icons.title),
              onPressed: _cycleHeading,
            ),
          ],
        ),
      ),
    );
  }

  /// Wraps the selection in [prefix]/[suffix], or inserts an empty pair with
  /// the caret between them when nothing is selected.
  ///
  /// Toggling off works the way users expect: a selection already wrapped
  /// (with or without the markers inside it) loses the markers.
  void _wrapSelection(String prefix, String suffix) {
    final text = _controller.text;
    var sel = _controller.selection;
    if (!sel.isValid) sel = TextSelection.collapsed(offset: text.length);
    final start = sel.start;
    final end = sel.end;

    // Markers sit just outside the selection -> strip them.
    if (start >= prefix.length &&
        end + suffix.length <= text.length &&
        text.substring(start - prefix.length, start) == prefix &&
        text.substring(end, end + suffix.length) == suffix) {
      _controller.value = TextEditingValue(
        text: text.substring(0, start - prefix.length) +
            text.substring(start, end) +
            text.substring(end + suffix.length),
        selection: TextSelection(
          baseOffset: start - prefix.length,
          extentOffset: end - prefix.length,
        ),
      );
      _markEdited();
      return;
    }

    // Markers sit inside the selection (the user selected the whole thing) ->
    // strip those instead.
    if (end - start >= prefix.length + suffix.length &&
        text.substring(start, start + prefix.length) == prefix &&
        text.substring(end - suffix.length, end) == suffix) {
      _controller.value = TextEditingValue(
        text: text.substring(0, start) +
            text.substring(start + prefix.length, end - suffix.length) +
            text.substring(end),
        selection: TextSelection(
          baseOffset: start,
          extentOffset: end - prefix.length - suffix.length,
        ),
      );
      _markEdited();
      return;
    }

    final inner = text.substring(start, end);
    _controller.value = TextEditingValue(
      text: text.substring(0, start) + prefix + inner + suffix + text.substring(end),
      selection: inner.isEmpty
          ? TextSelection.collapsed(offset: start + prefix.length)
          : TextSelection(
              baseOffset: start + prefix.length,
              extentOffset: end + prefix.length,
            ),
    );
    _markEdited();
  }

  /// `[selection](url)` with the caret on the url; `[]()` with the caret in
  /// the brackets when nothing is selected.
  void _insertLink() {
    final text = _controller.text;
    var sel = _controller.selection;
    if (!sel.isValid) sel = TextSelection.collapsed(offset: text.length);
    final inner = text.substring(sel.start, sel.end);
    final innerEmpty = inner.isEmpty;
    final newText = '${text.substring(0, sel.start)}'
        '[$inner](url)'
        '${text.substring(sel.end)}';
    // Caret on "url" so typing the target replaces the placeholder.
    final urlOffset = sel.start + 1 + inner.length + 2;
    _controller.value = TextEditingValue(
      text: newText,
      selection: innerEmpty
          ? TextSelection.collapsed(offset: sel.start + 1)
          : TextSelection.collapsed(offset: urlOffset),
    );
    _markEdited();
  }

  /// The character range covering the selected lines: the line holding
  /// [sel.start] through the line holding [sel.end]. A selection ending
  /// exactly after a newline does not claim the line that merely begins
  /// there — selecting "a\n" toggles line one, not line two.
  (int, int) _selectedLineBlock(String text, TextSelection sel) {
    int lineStartOf(int offset) =>
        offset <= 0 ? 0 : text.lastIndexOf('\n', offset - 1) + 1;
    int lineEndOf(int offset) {
      final nl = text.indexOf('\n', offset);
      return nl < 0 ? text.length : nl;
    }

    final blockStart = lineStartOf(sel.start);
    if (sel.end > sel.start && text.substring(sel.end - 1, sel.end) == '\n') {
      return (blockStart, sel.end - 1);
    }
    return (blockStart, lineEndOf(sel.end));
  }

  /// Adds [prefix] to every selected line, or removes it when all of them
  /// already carry it. Empty lines are left alone — a `- ` on a blank line is
  /// noise, not a list item.
  void _toggleLinePrefix(String prefix) {
    final text = _controller.text;
    var sel = _controller.selection;
    if (!sel.isValid) sel = TextSelection.collapsed(offset: text.length);

    final (bs, be) = _selectedLineBlock(text, sel);
    final lines = text.substring(bs, be).split('\n');
    final allHave = lines
        .where((l) => l.trim().isNotEmpty)
        .every((l) => l.startsWith(prefix));
    if (lines.every((l) => l.trim().isEmpty)) return; // nothing to do

    final newBlock = lines.map((l) {
      if (l.trim().isEmpty) return l;
      if (allHave) {
        return l.startsWith(prefix) ? l.substring(prefix.length) : l;
      }
      return l.startsWith(prefix) ? l : '$prefix$l';
    }).join('\n');

    _controller.value = TextEditingValue(
      text: text.substring(0, bs) + newBlock + text.substring(be),
      selection: TextSelection(
        baseOffset: bs,
        extentOffset: bs + newBlock.length,
      ),
    );
    _markEdited();
  }

  /// Rotates the selected lines through 正文 → H1 → H2 → H3 → 正文.
  ///
  /// Level comes from the first non-empty line, so a click on a mixed block
  /// normalises the whole block — which is what "make this a heading" means.
  void _cycleHeading() {
    final text = _controller.text;
    var sel = _controller.selection;
    if (!sel.isValid) sel = TextSelection.collapsed(offset: text.length);

    final (bs, be) = _selectedLineBlock(text, sel);
    final lines = text.substring(bs, be).split('\n');
    final marker = RegExp(r'^(#{1,6})\s');
    int levelOf(String l) =>
        l.trim().isEmpty ? -1 : (marker.firstMatch(l)?.group(1)!.length ?? 0);

    final current = lines.map(levelOf).firstWhere((l) => l >= 0, orElse: () => 0);
    final next = (current + 1) % 4;

    final newBlock = lines.map((l) {
      final stripped = l.replaceFirst(RegExp(r'^#{1,6}\s+'), '');
      if (l.trim().isEmpty) return l;
      return next == 0 ? stripped : '${'#' * next} $stripped';
    }).join('\n');

    _controller.value = TextEditingValue(
      text: text.substring(0, bs) + newBlock + text.substring(be),
      selection: TextSelection(
        baseOffset: bs,
        extentOffset: bs + newBlock.length,
      ),
    );
    _markEdited();
  }

  // ------------------------------------------------ preview-tap positioning
  //
  // The rendered page cannot be edited in place (the renderer has no editing
  // model), but a tap on a paragraph identifies it, and the paragraph's text
  // survives into the source line that produced it — markdown markers sit
  // *around* the characters, they do not replace them. So a tap jumps to that
  // line in the source view with the content selected, and the toolbar acts
  // on exactly what the user was looking at.

  /// A tap on the rendered preview: jump to the matching source line, select
  /// its content, and switch to the source view so the toolbar and keyboard
  /// act on it immediately.
  void _locateAndEdit(String blockText) {
    final text = _controller.text;
    // One line of the block is enough of an anchor, and keeps the needle
    // meaningful even for blocks the renderer joined across soft breaks.
    final needle = _bareText(blockText.split('\n').first);
    if (needle.isEmpty) return;

    final hit = _findBareLine(text, needle, from: _matchCursor) ??
        _findBareLine(text, needle, from: 0);
    if (hit == null) {
      // No matching line (e.g. the text was edited after rendering). Fall
      // back to showing the source at the current caret rather than
      // pretending the tap did something.
      setState(() => _view = EditorView.source);
      return;
    }

    final (lineStart, contentStart, lineEnd) = hit;
    _matchCursor = lineEnd;
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection(baseOffset: contentStart, extentOffset: lineEnd),
    );
    setState(() => _view = EditorView.source);
    _focus.requestFocus();
  }

  /// Strips everything the markdown syntax adds around the real characters:
  /// markers, brackets, emphasis and whitespace. What survives is the prose
  /// itself, identical in source and in the rendered block.
  static String _bareText(String s) =>
      s.replaceAll(RegExp(r'[\s#*_`>~\-!\[\]()|]'), '');

  /// The first source line after [from] whose bare form contains [needle].
  /// Returns (lineStart, contentStart, lineEnd) — contentStart skips a
  /// leading line marker like `# ` / `- ` / `> ` so the selection covers the
  /// text, not the syntax.
  (int, int, int)? _findBareLine(String text, String needle,
      {required int from}) {
    final marker = RegExp(r'^\s*(?:[#>\-*]+\s+)?');
    var offset = 0;
    for (final line in text.split('\n')) {
      final lineStart = offset;
      final lineEnd = offset + line.length;
      offset = lineEnd + 1;
      if (lineEnd < from) continue;
      if (line.trim().isEmpty) continue;
      if (_bareText(line).contains(needle)) {
        return (lineStart, lineStart + marker.firstMatch(line)!.end, lineEnd);
      }
    }
    return null;
  }

  Future<void> _save() async {
    final path = ref.watch(openNoteProvider);
    if (path == null) return;

    final session = await ref.read(vaultProvider.future);
    try {
      final hash = _view == EditorView.rich
          ? await session.saveRich(path, _controller.text)
          : await session.save(path, _controller.text);
      if (!mounted) return;
      invalidateNotes(ref);
      setState(() {
        _dirty = false;
        _status = hash == null ? '内容没有变化' : '已保存';
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _status = '保存失败：$e');
    }
  }

  /// §9.3: pick a file, copy it into the note's own `attachments/` folder, and
  /// write the normalised relative link into the text.
  ///
  /// Every failure here says what went wrong, because the alternative — a
  /// button that does nothing when there is no note, or a refused path, or a
  /// missing plugin — is indistinguishable to the user from a broken app.
  Future<void> _attachFile() async {
    final notePath = ref.read(openNoteProvider);
    if (notePath == null) {
      setState(() => _status = '先打开一篇笔记，再插入附件');
      return;
    }

    final XFile? picked;
    try {
      picked = await openFile(acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(label: '附件'),
      ]);
    } on Object catch (e) {
      // No picker on this platform, or the user dismissed a native dialog
      // that reported an error. Either way the app has to keep working.
      if (!mounted) return;
      setState(() => _status = '打不开文件选择器：$e');
      return;
    }
    // A cancelled dialog returns null. That is not an error and must not
    // leave a message on screen that looks like one.
    if (picked == null) return;
    await attachForTesting(picked.path);
  }

  /// Everything after the file has been chosen.
  ///
  /// Split out from [_attachFile] so the whole insert — copy, reindex, splice,
  /// caret — is reachable in a test without a platform channel standing in
  /// the way. The picker is the only part that cannot be exercised headlessly,
  /// and it is also the part with nothing in it to get wrong.
  ///
  /// Public because the test drives it directly. There is nothing for a caller
  /// outside this file to gain by invoking it, and the alternative — mocking
  /// `file_selector`'s pigeon channels — tests the mock.
  Future<void> attachForTesting(String sourcePath) async {
    final notePath = ref.read(openNoteProvider);
    if (notePath == null) {
      setState(() => _status = '先打开一篇笔记，再插入附件');
      return;
    }

    setState(() {
      _attaching = true;
      _status = '正在插入…';
    });

    try {
      final session = await ref.read(vaultProvider.future);
      final insertion = await session.insertAttachment(
        notePath: notePath,
        sourcePath: sourcePath,
      );
      if (!mounted) return;

      final spliced = AttachmentWriter.spliceInto(
        _controller.text,
        _focus.hasFocus ? _controller.selection.baseOffset : _controller.text.length,
        insertion,
      );
      setState(() {
        _controller.text = spliced;
        // Put the caret after what was just inserted, so typing continues
        // below the picture rather than in the middle of the link.
        _controller.selection = TextSelection.collapsed(
          offset: spliced.indexOf(insertion.markdown) + insertion.markdown.length,
        );
        _dirty = true;
        _attaching = false;
        _status = '已插入 ${insertion.linkTarget}（${_humanSize(insertion.size)}），'
            '保存后同步';
      });
      invalidateNotes(ref);
    } on AttachmentRefused catch (e) {
      if (!mounted) return;
      setState(() {
        _attaching = false;
        _status = '插入失败：${e.reason}';
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _attaching = false;
        _status = '插入失败：$e';
      });
    }
  }

  static String _humanSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<bool> _confirmDiscard() async {    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('放弃修改？'),
        content: const Text('这篇笔记有未保存的改动。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('继续编辑'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('放弃'),
          ),
        ],
      ),
    );
    return result ?? false;
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({
    required this.status,
    required this.note,
    required this.onSave,
  });

  final String? status;
  final EditableNote note;
  final Future<void> Function() onSave;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final facts = <String>[
      if (note.usedCrlf) 'CRLF',
      if (note.hadBom) 'BOM',
      if (note.hasUid) 'uid ${_abbreviate(note.uid!)}' else '无 uid',
    ];

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              status ?? facts.join(' · '),
              style: theme.textTheme.bodySmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (!note.hasUid)
            TextButton(
              onPressed: onSave,
              child: const Text('补写 uid'),
            ),
        ],
      ),
    );
  }
}

/// First eight characters of an identifier, or all of it when there are fewer.
///
/// The obvious `uid.substring(0, 8)` throws a `RangeError` on any note whose
/// uid is shorter than that — and `uid` comes out of front matter, which the
/// user edits by hand. `uid: abc` is legal, takes effect on the next scan, and
/// used to take the whole editor down on open: a crash before the note is even
/// displayed, with the user's own text as the cause.
String _abbreviate(String value) =>
    value.length <= 8 ? value : value.substring(0, 8);