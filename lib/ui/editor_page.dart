import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../app/vault_session.dart';
import '../app/voice_recorder.dart';
import '../domain/entities/markdown_parser.dart';
import '../domain/entities/rich_note_codec.dart';
import '../domain/vault/attachment_writer.dart';
import '../domain/vault/mention_index.dart';
import 'note_preview.dart';
import 'related_notes_panel.dart';
import 'rich_editor.dart';
import 'theme.dart';

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

  /// Reaches the rich pane's state for one thing: flushing a serialisation
  /// that is still inside its debounce before the page tears the pane down or
  /// writes the buffer (P1-10). It replaces a per-note [ValueKey] because the
  /// pane now survives note jumps — [RichEditorPane.didUpdateWidget] reloads
  /// the document when the body changes — and a widget can carry only one
  /// key.
  final _richPaneKey = GlobalKey<RichEditorPaneState>();

  /// Where the next preview-tap lookup starts. Blocks are matched against
  /// source lines in document order, so tapping successive paragraphs walks
  /// the file downward instead of always matching the first occurrence.
  int _matchCursor = 0;

  bool _dirty = false;
  bool _attaching = false;

  /// 提到本篇的笔记（反向关联），以及它属于哪一篇。
  ///
  /// 跟着 [openNoteProvider] 一起换：换了笔记，旧的反链就是**别的笔记**
  /// 的反链了，留着比清空更糟——用户会以为那是新笔记的反链。
  ///
  /// 算好的结果存在这里而不是每次重建时重算：反查要扫全库正文，而编辑器
  /// 每敲一个字都会重建。
  List<Backlink> _backlinks = const <Backlink>[];
  String? _backlinksFor;
  /// The recorder, while a recording is in flight.
  ///
  /// Null the rest of the time. The recorder itself lives in a provider — it
  /// is a device resource, and the plugin does not want one per editor — but
  /// *this* reference is what says "a recording is happening right now", and
  /// it is the thing the stop button acts on.
  VoiceRecorder? _recorder;

  /// Where the recording is being written.
  ///
  /// A temporary directory, not the vault: the recording is copied into the
  /// vault by the same attachment path every other file takes, and the
  /// temporary copy is deleted afterwards. A cancelled recording must leave
  /// nothing behind.
  RecordingWorkspace? _recordingWorkspace;

  /// Whether a recording is in flight.
  bool _recording = false;

  /// Ticks once a second so the elapsed time on screen moves.
  ///
  /// A timer rather than a rebuild loop: the status line shows the time, and
  /// a `setState` every frame for that is a battery cost for a number that
  /// changes once a second.
  Timer? _recordingTicker;

  /// When the current recording started.
  DateTime? _recordingStartedAt;

  /// Opened in preview, because most opens are reads, not edits.
  EditorView _view = EditorView.preview;

  String? _status;

  /// A backup that failed before a rich save that still succeeded. Kept
  /// apart from [_status] so the two facts never blur: the edit landed, the
  /// safety copy did not, and showing that as "保存失败" would send the user
  /// looking for an edit that is safely on disk.
  String? _backupWarning;

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
    // A recording that is still running when the page goes away has to be
    // stopped: the microphone stays open, and the file the platform is
    // writing is left half-finished in the temp directory. The page cannot
    // ask the user anything at this point, so it does the only thing that is
    // correct — throw the recording away.
    _recordingTicker?.cancel();
    _recordingTicker = null;
    final recorder = _recorder;
    final workspace = _recordingWorkspace;
    _recorder = null;
    _recordingWorkspace = null;
    if (recorder != null) unawaited(recorder.cancel());
    if (workspace != null) unawaited(workspace.dispose());
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
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
            //
            // A note that cannot be opened has no title and no text, and the
            // refusal page names the *current* path. The header has to name
            // it too, or the title says A while the body says B.
            title: _appBarTitle(
              async.asData?.value == null && !async.isLoading
                  ? path
                  : (_loadedPath ?? path),
            ),
            actions: [
              // 「谁提到了本篇」——反向关联的入口。
              //
              // 放在视图菜单旁边而不是塞进状态栏：状态栏是给机器细节
              // （uid、BOM、CRLF）看的，而这是一个要看的东西。图标上的
              // 数字是提到本篇的笔记数，用户不用点开就知道有没有。
              IconButton(
                key: const ValueKey('editor-related-notes'),
                tooltip: '提到本篇的笔记',
                icon: _relatedNotesIcon(),
                onPressed: editable ? _showRelatedNotes : null,
              ),
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
              // The microphone button turns into the stop button rather than
              // gaining a second one beside it. A row of icons where one of
              // them changes meaning is how a user ends up recording twice —
              // and a second recording is not a thing they can undo.
              IconButton(
                key: const ValueKey('editor-record'),
                icon: Icon(_recording
                    ? Icons.stop_circle_outlined
                    : Icons.mic_none),
                color: _recording ? Theme.of(context).colorScheme.error : null,
                tooltip: _recording ? '停止录音' : '录音',
                // While a recording is running the button stays live whatever
                // the note is doing. Tying it to `editable` would disable the
                // stop button the moment the note stopped being editable —
                // and a recording the user cannot stop is a recording that
                // keeps the microphone open until the app is closed.
                onPressed: _recording
                    ? _stopRecording
                    : (editable && !_attaching ? _startRecording : null),
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
      return Column(
        children: [
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  path == null ? '没有选中笔记' : '这个文件不能以 UTF-8 打开',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
          // The refusal page has no note to describe, but a save rejected
          // here still has to say so: the Ctrl+S/Cmd+S binding reaches _save
          // without passing the app bar's editable gate (P0-5), and a status
          // with nowhere to render is indistinguishable from a save that
          // silently worked.
          _StatusBar(status: _status, onSave: _save),
        ],
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
      // A backup warning belongs to the note it was raised for; carrying it
      // onto the next one would blame an unrelated file.
      _backupWarning = null;
      // The app bar above was built from the pre-refill pair (title reads as
      // a build-time side effect otherwise). One post-frame rebuild lets it
      // show the new note's title.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }

    // Keyed by path so a jumped-to note rebuilds the preview from scratch —
    // including its link index, which belongs to the note being shown.
    final theme = Theme.of(context);
    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Phones get 16 px of margin, desktop windows 24: the same
              // content needs more breathing room when it has more room.
              final gutter = JotItTokens.gutter(constraints.maxWidth);
              return Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: gutter,
                  vertical: JotItTokens.s3,
                ),
                child: switch (_view) {
                  // Reading column: on a wide window a full-width paragraph
                  // is unreadable — the eye loses the line. 680 px is where
                  // 16 px text lands in the 45–75 characters-per-line band.
                  //
                  // Top-aligned, not centred: the preview scrolls when the
                  // note is taller than the window, and a centred column
                  // would start halfway down the first page — the reader
                  // opens the note and sees its middle.
                  EditorView.preview => Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                            maxWidth: JotItTokens.readingWidth),
                        child: NotePreview(
                          key: ValueKey('preview-${note.notePath}'),
                          text: _controller.text,
                          // The path of the note on screen, so a relative link
                          // is resolved against the note it was written in.
                          sourcePath: note.notePath,
                          onOpenNote: _openLinkedNote,
                          onTapBlock: _locateAndEdit,
                        ),
                      ),
                    ),
                  EditorView.rich => RichEditorPane(
                      key: _richPaneKey,
                      body: const MarkdownParser()
                          .splitFrontMatter(_controller.text)
                          .body,
                      onChanged: _onRichChanged,
                      // The debounce delays the *serialisation*; the dirty flag
                      // must not wait for it (P1-10).
                      onEditStarted: _markEdited,
                    ),
                  EditorView.source => TextField(
                      key: const ValueKey('editor-body'),
                      controller: _controller,
                      focusNode: _focus,
                      maxLines: null,
                      expands: true,
                      textAlignVertical: TextAlignVertical.top,
                      // Monospace with a real fallback chain: Consolas alone
                      // exists only on Windows, and CJK text needs the Noto
                      // face at the end of the stack to keep its columns.
                      style: TextStyle(
                        fontFamily: 'Consolas',
                        fontFamilyFallback: JotItTokens.monoFallback,
                        fontSize: 14,
                        height: 1.6,
                        color: theme.colorScheme.onSurface,
                      ),
                      cursorColor: theme.colorScheme.primary,
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        // The theme fills inputs to read as "paper"; a full-
                        // screen editing surface must not be a grey slab.
                        filled: false,
                        hintText: '正文',
                      ),
                      onChanged: (_) {
                        if (!_dirty) setState(() => _dirty = true);
                      },
                    ),
                },
              );
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
          backupWarning: _backupWarning,
          onSave: _save,
          recording: _recording,
          onCancelRecording: _cancelRecording,
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

    // A rich edit still inside the 250 ms debounce has not reached the
    // controller yet. The jump reloads the pane's document, so anything left
    // on the timer would be dropped with it (P1-10) — deliver it first, and
    // let the discard dialog below decide with the full picture.
    _richPaneKey.currentState?.flush();

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
      _backupWarning = null;
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

  /// Two lines: the note's title, and where the file actually lives.
  ///
  /// The path line is the app's promise made visible — notes are files in a
  /// folder — and at 11 px it answers "where is this?" without competing with
  /// the title. The `notes/` prefix every vault path carries is noise up here,
  /// so it is stripped for display only; nothing is rewritten on disk.
  Widget _appBarTitle(String? path) {
    final theme = Theme.of(context);
    final title = _titleOf(path, _controller.text);
    final where = path?.replaceFirst(RegExp(r'^notes/'), '');
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        if (where != null && where.isNotEmpty)
          Text(
            where,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
      ],
    );
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

  /// Marks the note as edited **and** rebuilds the page.
  ///
  /// The format toolbar is reachable in preview mode, where nothing listens
  /// to the controller — there is no `EditableText` to trigger a rebuild, and
  /// the provider does not bump either. The rendered page therefore only
  /// redrew when something else happened to rebuild it, which is why the
  /// first format operation looked like it worked (it flipped [_dirty] from
  /// false to true) and every one after it was invisible: the buffer really
  /// changed and really got written to disk, but the screen showed the old
  /// text the whole time.
  ///
  /// The rebuild is unconditional rather than tied to the dirty flag for
  /// exactly that reason.
  void _markEditedAndRebuild() {
    setState(() => _dirty = true);
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
    // Leaving the rich view unmounts the pane, and its debounce dies with it:
    // without this flush, an edit made in the last 250 ms is silently lost
    // (P1-10).
    if (_view == EditorView.rich) _richPaneKey.currentState?.flush();
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
    final c = theme.colorScheme;
    Widget button(IconData icon, String tooltip, VoidCallback onPressed) =>
        IconButton(
          tooltip: tooltip,
          iconSize: 20,
          color: c.onSurfaceVariant,
          icon: Icon(icon),
          onPressed: onPressed,
        );
    // One hairline between inline formatting and block formatting: the two
    // groups answer different questions — "how does this text look" versus
    // "what kind of block is this" — and a bare row of eight icons blurs them.
    Widget separator() => Container(
          width: 1,
          height: 18,
          margin: const EdgeInsets.symmetric(horizontal: JotItTokens.s1),
          color: c.outlineVariant,
        );

    return Container(
      decoration: BoxDecoration(
        color: c.surfaceContainerLow,
        border: Border(top: BorderSide(color: c.outlineVariant)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            button(Icons.format_bold, '加粗', () => _wrapSelection('**', '**')),
            button(Icons.format_italic, '斜体', () => _wrapSelection('*', '*')),
            button(Icons.strikethrough_s, '删除线',
                () => _wrapSelection('~~', '~~')),
            button(Icons.code, '行内代码', () => _wrapSelection('`', '`')),
            button(Icons.link, '链接', _insertLink),
            separator(),
            button(Icons.format_list_bulleted, '列表',
                () => _toggleLinePrefix('- ')),
            button(Icons.format_quote, '引用', () => _toggleLinePrefix('> ')),
            button(Icons.title, '标题', _cycleHeading),
            const SizedBox(width: JotItTokens.s2),
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
      _markEditedAndRebuild();
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
      _markEditedAndRebuild();
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
    _markEditedAndRebuild();
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
    _markEditedAndRebuild();
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
    _markEditedAndRebuild();
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
    _markEditedAndRebuild();
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

  /// The path a save may write to, or null when writing would be wrong.
  ///
  /// `openNoteProvider` alone is not the controller's pair (P0-5): during a
  /// wiki-link jump it already names the *new* note while the controller still
  /// holds the old one, and a note that could not be decoded as UTF-8 never
  /// fills the controller at all. Writing then puts one note's text under
  /// another note's path — or empties a file the editor was never allowed to
  /// touch. `_loadedPath` is the path the text on screen belongs to, so a save
  /// is legitimate only while the two agree and the note is editable.
  String? _writablePath() {
    final path = _loadedPath;
    if (path == null) return null;
    if (path != ref.read(openNoteProvider)) return null;
    // The provider is briefly loading after every save — the version bump
    // re-runs it — and during that window there is no data to read, even
    // though the note is perfectly editable. Refusing the save then turns a
    // second Ctrl+S into "当前笔记不可保存": the user pressed the key twice
    // and the app said the note cannot be saved.
    final editable = ref.read(editableNoteProvider);
    final value = editable.asData?.value;
    if (value == null && !editable.isLoading) return null;
    return path;
  }

  Future<void> _save() async {
    // P0-5: the write path must be the one the controller's text belongs to.
    // The Ctrl+S/Cmd+S binding reaches this method without passing the app
    // bar's `editable` gate, so the check lives here rather than at the
    // call sites.
    final path = _writablePath();
    if (path == null) {
      setState(() => _status = '当前笔记不可保存');
      return;
    }

    // A rich edit still inside the pane's 250 ms debounce has not reached the
    // controller; saving without flushing it would write the text from before
    // the user's last burst (P1-10).
    _richPaneKey.currentState?.flush();

    final session = await ref.read(vaultProvider.future);
    // The pairing rule, checked again because time has passed. The path was
    // resolved *before* the wait, and a wait is a window: the vault can be
    // reopened, a note jumped to, the provider recomputed. Writing now
    // would put this note's text under the previous note's path — the P0-5
    // failure, one step later.
    if (_writablePath() != path) {
      if (mounted) setState(() => _status = '笔记已经切换，这次没有保存');
      return;
    }
    try {
      final hash = _view == EditorView.rich
          ? await session.saveRich(path, _controller.text)
          : await session.save(path, _controller.text);
      if (!mounted) return;
      // Only a real write invalidates. A save that changed nothing leaves
      // the file as it was, and bumping the version anyway sends the
      // editor's provider back to loading for no reason — which is what
      // turned a second Ctrl+S into "当前笔记不可保存".
      if (hash != null) invalidateNotes(ref);
      setState(() {
        _dirty = false;
        // saveRich is the only path that rolls a backup, and a no-op rich
        // save returns before attempting one — so the field is read only
        // after a real write, where it still belongs to *this* save. A
        // stale warning from an earlier note would otherwise re-surface.
        _backupWarning = hash != null && _view == EditorView.rich
            ? session.lastBackupWarning
            : null;
        _status = hash == null ? '内容没有变化' : '已保存';
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _status = '保存失败：$e');
    }
  }

  /// Runs the save path directly.
  ///
  /// The Ctrl+S/Cmd+S binding and the save button both end at [_save], and
  /// the guard that keeps them honest lives there too. A test that synthesises
  /// a key press has to first win a focus-tree fight that has nothing to do
  /// with saving; calling the guarded method itself is the honest equivalent.
  ///
  /// Public for the same reason as [insertFile]: it is the test's entry
  /// point into a flow whose only other front door is a platform channel.
  Future<void> saveForTesting() => _save();

  /// §9.3: pick a file, copy it into the note's own `attachments/` folder, and
  /// write the normalised relative link into the text.
  ///
  /// Every failure here says what went wrong, because the alternative — a
  /// button that does nothing when there is no note, or a refused path, or a
  /// missing plugin — is indistinguishable to the user from a broken app.
  /// 算「谁提到了本篇」。
  ///
  /// 扫全库正文，慢。**只在用户真的要看的时候才算**——打开一篇笔记就
  /// 扫一遍全库，是把一次明确的点击换成一次没人要求的等待。
  Future<void> _loadBacklinks(String path) async {
    // 先记下算的是哪一篇：算的途中用户又跳走了，结果回来时才知道该扔掉。
    _backlinksFor = path;
    final session = await ref.read(vaultProvider.future);
    final backlinks = await session.loadBacklinks(path);
    if (!mounted || _backlinksFor != path) return;
    setState(() => _backlinks = backlinks);
  }

  /// 应用栏上的图标：提到本篇的笔记。
  ///
  /// 没有角标数字：数字要靠预先算一遍才有，而预先算一遍正是上面
  /// 刻意不做的事。用户点开面板就看到了。
  Widget _relatedNotesIcon() {
    return const Icon(Icons.hub_outlined);
  }

  /// 打开「提到本篇的笔记」面板。
  ///
  /// 面板里点一条就跳到那篇笔记——和预览里点自动提及出来的链接一样，
  /// 换的是笔记，不是开一个新页面。
  Future<void> _showRelatedNotes() async {
    final path = _loadedPath ?? ref.read(openNoteProvider);
    if (path == null) return;
    if (_backlinksFor != path) await _loadBacklinks(path);
    if (!mounted) return;
    await showRelatedNotesPanel(
      context,
      backlinks: _backlinks,
      onOpen: _openLinkedNote,
    );
  }

  Future<void> insertFile(String sourcePath) async {
    // P0-5: insert against the paired path, not whatever the open-note
    // provider happens to say — during a jump the two disagree, and the copy
    // would be filed under a note whose text is not on screen.
    final notePath = _writablePath();
    if (notePath == null) {
      setState(() => _status = '先打开一篇可编辑的笔记，再插入附件');
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

      // The copy is asynchronous: a wiki-link jump taken while it ran leaves
      // the controller holding a *different* note than the one the attachment
      // belongs to — the P0-5 pairing rule, checked again because time has
      // passed. The copied file stays behind as an orphan, exactly as it does
      // when the user simply never saves.
      if (_writablePath() != notePath) {
        setState(() {
          _attaching = false;
          _status = '笔记已经切换，这次插入没有链接进去';
        });
        return;
      }

      // The splice below edits the buffer by path and offset, so it needs the
      // controller to hold the latest text: anything still on the rich pane's
      // debounce is delivered first (P1-10), otherwise the insert would be
      // layered over a stale buffer and the user's last burst rolled back.
      _richPaneKey.currentState?.flush();

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
        if (_view == EditorView.rich && !_richAllowed) {
          // An attachment link is `![[...]]` — wiki syntax the rich serialiser
          // cannot round-trip, so the note may no longer be shown in rich
          // mode. Leaving the user there would let the pane's next
          // serialisation wipe the link that was just inserted (P1-11).
          _view = EditorView.source;
          _status = '附件链接暂不受富文本支持，已切回源码视图';
        } else {
          _status = '已插入 ${insertion.linkTarget}（${_humanSize(insertion.size)}），'
              '保存后同步';
        }
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

  Future<void> _attachFile() async {
    // Same pairing rule as a save (P0-5): the copy is about to be referenced
    // from the text on screen, which only belongs to a note that is actually
    // loaded and editable.
    if (_writablePath() == null) {
      setState(() => _status = '先打开一篇可编辑的笔记，再插入附件');
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
    await insertFile(picked.path);
  }

  /// Starts recording a voice memo.
  ///
  /// The microphone is asked for at the moment the button is pressed, not at
  /// startup: a permission prompt the user cannot see the point of is a
  /// prompt they deny, and the app is much more persuasive about it when it
  /// explains what the recording is for.
  Future<void> _startRecording() async {
    // Same pairing rule as a save (P0-5): the recording is about to be
    // referenced from the text on screen, which only belongs to a note that
    // is actually loaded and editable.
    if (_writablePath() == null) {
      setState(() => _status = '先打开一篇可编辑的笔记，再录音');
      return;
    }

    final recorder = ref.read(voiceRecorderProvider);

    final bool granted;
    try {
      granted = await recorder.requestPermission();
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _status = '麦克风打不开：$e');
      return;
    }
    if (!mounted) return;
    if (!granted) {
      setState(() => _status = '没有麦克风权限，无法录音');
      return;
    }

    final workspace = await RecordingWorkspace.create();
    if (!mounted) {
      await workspace.dispose();
      return;
    }

    try {
      await recorder.start(path: workspace.filePath);
    } on Object catch (e) {
      await workspace.dispose();
      if (!mounted) return;
      setState(() => _status = '录音失败：$e');
      return;
    }
    if (!mounted) {
      // The page went away between the permission prompt and the recording.
      // The microphone must not be left open.
      await recorder.cancel();
      await workspace.dispose();
      return;
    }

    setState(() {
      _recorder = recorder;
      _recordingWorkspace = workspace;
      _recording = true;
      _recordingStartedAt = DateTime.now();
      _status = '录音中 00:00';
    });
    _recordingTicker?.cancel();
    _recordingTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _status = '录音中 ${_recordingElapsed()}');
    });
  }

  /// Stops the recording and puts the clip into the note.
  Future<void> _stopRecording() async {
    final recorder = _recorder;
    final workspace = _recordingWorkspace;
    _recordingTicker?.cancel();
    _recordingTicker = null;
    if (!mounted) return;
    setState(() {
      _recording = false;
      _recorder = null;
      _recordingWorkspace = null;
      _status = '正在保存录音…';
    });
    if (recorder == null || workspace == null) return;

    final String? recorded;
    try {
      recorded = await recorder.stop();
    } on Object catch (e) {
      await workspace.dispose();
      if (!mounted) return;
      setState(() => _status = '录音失败：$e');
      return;
    }

    // The platform may have named the file itself; what matters is the file
    // that exists, not the name it was asked for. A recording that produced
    // no file is not an error — the user stopped it before it began.
    final file = await workspace.producedFile(preferred: recorded);
    if (file == null) {
      await workspace.dispose();
      if (!mounted) return;
      setState(() => _status = '没有录到内容');
      return;
    }

    if (!mounted) {
      await workspace.dispose();
      return;
    }
    // The copy into the vault happens before the workspace is deleted: the
    // file being copied *is* the workspace's file. The `finally` is what
    // guarantees the temporary directory goes away even when the insert
    // fails — a leftover recording in the temp folder is a file the user
    // never asked for.
    try {
      await insertFile(file.path);
    } finally {
      await workspace.dispose();
    }
  }

  /// Throws the recording away.
  Future<void> _cancelRecording() async {
    final recorder = _recorder;
    final workspace = _recordingWorkspace;
    _recordingTicker?.cancel();
    _recordingTicker = null;
    if (!mounted) return;
    setState(() {
      _recording = false;
      _recorder = null;
      _recordingWorkspace = null;
      _status = '已取消录音';
    });
    if (recorder != null) await recorder.cancel();
    if (workspace != null) await workspace.dispose();
  }

  /// `mm:ss` of how long the current recording has been running.
  String _recordingElapsed() {
    final started = _recordingStartedAt;
    if (started == null) return '00:00';
    final total = DateTime.now().difference(started).inSeconds;
    final m = total ~/ 60;
    final s = total % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
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
    this.note,
    this.backupWarning,
    required this.onSave,
    this.recording = false,
    this.onCancelRecording,
  });

  final String? status;

  /// Null on the refusal page, where there is no note to describe.
  final EditableNote? note;

  /// A failed backup preceding a successful rich save, shown as its own line
  /// so it is neither mistaken for a failed save nor lost under the status.
  final String? backupWarning;

  final Future<void> Function() onSave;

  /// Whether a recording is in flight. The bar grows a cancel button while
  /// it is — a recording the user cannot stop is a recording they have to
  /// close the app to end, and the microphone keeps running after the window
  /// goes away.
  final bool recording;

  final Future<void> Function()? onCancelRecording;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final facts = <String>[
      if (note?.usedCrlf ?? false) 'CRLF',
      if (note?.hadBom ?? false) 'BOM',
      if (note?.hasUid ?? false) 'uid ${_abbreviate(note!.uid!)}' else '无 uid',
    ];

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  // With no note there are no facts to fall back to, and the
                  // body above already says why nothing is loaded.
                  status ?? (note == null ? '' : facts.join(' · ')),
                  // Facts are machine detail (uid, BOM, CRLF), so they get the
                  // monospace face and the smallest label size — present,
                  // readable, never in the way.
                  style: JotItTokens.monoBase.copyWith(
                    fontSize: 11,
                    height: 1.4,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (recording && onCancelRecording != null)
                TextButton(
                  key: const ValueKey('editor-cancel-recording'),
                  onPressed: onCancelRecording,
                  style: TextButton.styleFrom(
                    textStyle: theme.textTheme.labelSmall,
                    visualDensity: VisualDensity.compact,
                    minimumSize: const Size(0, 28),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    foregroundColor: theme.colorScheme.error,
                  ),
                  child: const Text('取消录音'),
                ),
              if (note != null && !note!.hasUid)
                TextButton(
                  onPressed: onSave,
                  style: TextButton.styleFrom(
                    textStyle: theme.textTheme.labelSmall,
                    visualDensity: VisualDensity.compact,
                    minimumSize: const Size(0, 28),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  child: const Text('补写 uid'),
                ),
            ],
          ),
          if (backupWarning != null) ...[
            const SizedBox(height: 2),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_outlined,
                    size: 14, color: theme.colorScheme.error),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    backupWarning!,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.error),
                  ),
                ),
              ],
            ),
          ],
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