import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../app/vault_session.dart';
import '../domain/vault/attachment_writer.dart';

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

  bool _loaded = false;
  bool _dirty = false;
  bool _attaching = false;
  String? _status;

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
            title: Text(_titleOf(path), overflow: TextOverflow.ellipsis),
            actions: [
              IconButton(
                icon: const Icon(Icons.attach_file),
                tooltip: '插入附件',
                onPressed: _loaded && !_attaching ? _attachFile : null,
              ),
              IconButton(
                icon: const Icon(Icons.save_outlined),
                tooltip: '保存 (Ctrl+S)',
                onPressed: _loaded ? _save : null,
              ),
            ],
          ),
          body: async.when(
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

    if (!_loaded) {
      _controller.text = note.text;
      _loaded = true;
    }

    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
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
          ),
        ),
        _StatusBar(
          status: _status,
          note: note,
          onSave: _save,
        ),
      ],
    );
  }

  String _titleOf(String? path) {
    if (path == null) return 'JotIt';
    final slash = path.lastIndexOf('/');
    return slash < 0 ? path : path.substring(slash + 1);
  }

  Future<void> _save() async {
    final path = ref.watch(openNoteProvider);
    if (path == null) return;

    final session = await ref.read(vaultProvider.future);
    try {
      final hash = await session.save(path, _controller.text);
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