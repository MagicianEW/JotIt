import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../data/db/note_dao.dart';
import '../data/search/note_search.dart';
import 'editor_page.dart';
import 'settings_page.dart';

/// The note list, with search and the sync-root status.
class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = ref.watch(searchQueryProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('JotIt'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '设置',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createNote,
        icon: const Icon(Icons.add),
        label: const Text('新建'),
      ),
      body: Column(
        children: [
          _SearchBar(
            controller: _searchController,
            onChanged: (v) => ref.read(searchQueryProvider.notifier).set(v),
          ),
          const Divider(height: 1),
          Expanded(
            child: query.trim().isEmpty
                ? const _NoteList()
                : const _SearchResults(),
          ),
        ],
      ),
    );
  }

  Future<void> _createNote() async {
    final session = await ref.read(vaultProvider.future);
    if (!mounted) return;

    // The controller belongs to the dialog, not to this method.
    // `showDialog` completes the moment `pop` is called — not when the route
    // has finished animating out — so disposing a controller here tears it
    // down while the dialog's `TextField` is still mounted and rebuilding,
    // and Flutter rightly complains that a disposed controller is being
    // used. That fires on every single note created on a real device.
    final title = await showDialog<String>(
      context: context,
      builder: (context) => const _NewNoteDialog(),
    );
    if (title == null || !mounted) return;

    final path = await session.createNote(title: title);
    invalidateNotes(ref);
    if (!mounted) return;
    ref.read(openNoteProvider.notifier).open(path);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const EditorPage()),
    );
  }
}

/// "New note", as its own widget so its text controller has the same lifetime
/// as the field that uses it. See [_HomePageState._createNote].
class _NewNoteDialog extends StatefulWidget {
  const _NewNoteDialog();

  @override
  State<_NewNoteDialog> createState() => _NewNoteDialogState();
}

class _NewNoteDialogState extends State<_NewNoteDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('新建笔记'),
        content: TextField(
          key: const ValueKey('new-note-title'),
          controller: _controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '标题'),
          onSubmitted: (v) => Navigator.of(context).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(_controller.text),
            child: const Text('创建'),
          ),
        ],
      );
}

class _SearchBar extends StatelessWidget {
  const _SearchBar({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: TextField(
          controller: controller,
          onChanged: onChanged,
          decoration: InputDecoration(
            hintText: '搜索…',
            prefixIcon: const Icon(Icons.search),
            border:
                OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            isDense: true,
          ),
        ),
      );
}

class _NoteList extends ConsumerWidget {
  const _NoteList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(noteListProvider);
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _ErrorBox(message: '$e'),
      data: (state) {
        if (state.notes.isEmpty) return const _EmptyVault();
        return ListView.separated(
          itemCount: state.notes.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) =>
              _NoteTile(note: state.notes[i], showPath: false),
        );
      },
    );
  }
}

class _SearchResults extends ConsumerWidget {
  const _SearchResults();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final query = ref.watch(searchQueryProvider);
    final async = ref.watch(searchResultsProvider(query));

    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _ErrorBox(message: '$e'),
      data: (hits) {
        if (hits.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                '没有匹配「$query」的内容',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          );
        }
        return ListView.separated(
          itemCount: hits.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) => _SearchTile(hit: hits[i]),
        );
      },
    );
  }
}

class _SearchTile extends ConsumerWidget {
  const _SearchTile({required this.hit});

  final SearchHit hit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return ListTile(
      title: Text(
        hit.title.isEmpty ? hit.path : hit.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        hit.snippet.isEmpty ? hit.path : hit.snippet,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      onTap: () {
        ref.read(openNoteProvider.notifier).open(hit.path);
        Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const EditorPage()),
        );
      },
    );
  }
}

class _NoteTile extends ConsumerWidget {
  const _NoteTile({required this.note, required this.showPath});

  final NoteRecord note;
  final bool showPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final title = note.title.trim().isEmpty ? note.path : note.title;
    return ListTile(
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: showPath
          ? Text(note.path,
              style: theme.textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis)
          : null,
      onTap: () {
        ref.read(openNoteProvider.notifier).open(note.path);
        Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const EditorPage()),
        );
      },
    );
  }
}

class _EmptyVault extends StatelessWidget {
  const _EmptyVault();

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.inbox_outlined,
                  size: 48, color: Theme.of(context).disabledColor),
              const SizedBox(height: 12),
              const Text('库里还没有笔记'),
              SizedBox(height: 4),
              Text('点右下角新建一篇',
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      );
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '出错了：$message',
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      );
}