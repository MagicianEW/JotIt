import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../app/vault_session.dart';

/// The note editor.
///
/// The text area shows the file verbatim, front matter included. JotIt does
/// not re-serialize Markdown: a note written by another tool comes back
/// byte-identical apart from the fields it owns, and pretending otherwise
/// would silently delete unknown keys and comments.
class EditorPage extends ConsumerStatefulWidget {
  const EditorPage({super.key});

  @override
  ConsumerState<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends ConsumerState<EditorPage> {
  final _controller = TextEditingController();
  bool _loaded = false;
  bool _dirty = false;
  String? _status;

  @override
  void dispose() {
    _controller.dispose();
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
      child: Scaffold(
        appBar: AppBar(
          title: Text(_titleOf(path), overflow: TextOverflow.ellipsis),
          actions: [
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
              controller: _controller,
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

  Future<bool> _confirmDiscard() async {
    final result = await showDialog<bool>(
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
      if (note.hasUid) 'uid ${note.uid!.substring(0, 8)}' else '无 uid',
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