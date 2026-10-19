import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../data/db/note_dao.dart';
import '../data/search/note_search.dart';
import 'editor_page.dart';
import 'settings_page.dart';
import 'theme.dart';

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
        // Tonal, not a solid block of accent: the "new note" button should be
        // findable without being the loudest thing on a page of reading.
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
        foregroundColor: Theme.of(context).colorScheme.onPrimaryContainer,
        elevation: 3,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(JotItTokens.rLg),
        ),
        icon: const Icon(Icons.add),
        label: const Text('新建'),
      ),
      body: Column(
        children: [
          _SearchBar(
            controller: _searchController,
            onChanged: (v) => ref.read(searchQueryProvider.notifier).set(v),
          ),
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

class _SearchBar extends StatefulWidget {
  const _SearchBar({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  State<_SearchBar> createState() => _SearchBarState();
}

class _SearchBarState extends State<_SearchBar> {
  @override
  void initState() {
    super.initState();
    // Rebuild for the clear button: its presence tracks whether there is text,
    // and a TextField gives no notification to the widget that owns it.
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    super.dispose();
  }

  void _onTextChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          JotItTokens.s4, JotItTokens.s3, JotItTokens.s4, JotItTokens.s2),
      child: TextField(
        controller: widget.controller,
        onChanged: widget.onChanged,
        textAlignVertical: TextAlignVertical.center,
        decoration: InputDecoration(
          hintText: '搜索…',
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: widget.controller.text.isEmpty
              ? null
              : IconButton(
                  tooltip: '清除',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () {
                    widget.controller.clear();
                    widget.onChanged('');
                  },
                ),
          // A full-radius pill reads as "search", which is the one place in
          // this app where a rounded shape carries meaning.
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(999),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(999),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(999),
            borderSide: BorderSide(color: theme.colorScheme.primary, width: 1.5),
          ),
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),
    );
  }
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
        return ListView.builder(
          // Room at the bottom so the extended FAB never covers the last
          // note's row.
          padding: const EdgeInsets.only(top: 4, bottom: 96),
          itemCount: state.notes.length,
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
              padding: const EdgeInsets.all(JotItTokens.s5),
              child: Text(
                '没有匹配「$query」的内容',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.only(top: 4, bottom: 96),
          itemCount: hits.length,
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
    return _ShelfCard(
      icon: Icons.description_outlined,
      title: hit.title.isEmpty ? hit.path : hit.title,
      subtitle: hit.snippet.isEmpty ? hit.path : hit.snippet,
      onTap: () {
        ref.read(openNoteProvider.notifier).open(hit.path);
        Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const EditorPage()),
        );
      },
    );
  }
}

/// One row on the shelf.
///
/// A card, not a table row: the icon disc gives every note the same visual
/// anchor, and 8 px of paper between cards is what makes the list read as
/// separate things rather than as one long ledger. The icon is deliberately
/// `description_outlined` and not `article_outlined` — the latter means the
/// rich-text view in the editor's own menu.
class _ShelfCard extends StatelessWidget {
  const _ShelfCard({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = theme.colorScheme;
    final radius = BorderRadius.circular(JotItTokens.rMd);
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: JotItTokens.s4, vertical: 4),
      child: Material(
        color: c.surfaceContainerLow,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(
                horizontal: JotItTokens.s3, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(color: c.outlineVariant),
            ),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: c.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, size: 20, color: c.onPrimaryContainer),
                ),
                const SizedBox(width: JotItTokens.s3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium,
                      ),
                      if (subtitle != null && subtitle!.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NoteTile extends ConsumerWidget {
  const _NoteTile({required this.note, required this.showPath});

  final NoteRecord note;
  final bool showPath;

  /// The first line of the body that carries meaning: markers stripped, code
  /// fences and rules skipped. Purely a display transform — the index row is
  /// not touched, and a note whose body is empty simply has no second line.
  String _excerpt(String body) {
    for (final raw in body.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('```') || line.startsWith('---')) continue;
      final cleaned = line
          .replaceFirst(RegExp(r'^#{1,6}\s+'), '')
          .replaceFirst(RegExp(r'^([-*+]|\d+\.)\s+'), '');
      if (cleaned.isEmpty) continue;
      return cleaned.length > 60 ? '${cleaned.substring(0, 60)}…' : cleaned;
    }
    return '';
  }

  /// "今天 09:12" is more use on a shelf than a full timestamp, and "3 天前"
  /// is more use than a date nobody converts in their head.
  String _relativeTime(int epochMs) {
    if (epochMs <= 0) return '';
    final at = DateTime.fromMillisecondsSinceEpoch(epochMs);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final thatDay = DateTime(at.year, at.month, at.day);
    final days = today.difference(thatDay).inDays;
    String two(int v) => v.toString().padLeft(2, '0');
    if (days <= 0) return '今天 ${two(at.hour)}:${two(at.minute)}';
    if (days == 1) return '昨天';
    if (days < 7) return '$days 天前';
    return '${two(at.month)}-${two(at.day)}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final title = note.title.trim().isEmpty ? note.path : note.title;
    final subtitle = showPath
        ? note.path
        : <String>[_excerpt(note.body), _relativeTime(note.updatedAt)]
            .where((s) => s.isNotEmpty)
            .join(' · ');
    return _ShelfCard(
      icon: Icons.description_outlined,
      title: title,
      subtitle: subtitle,
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(JotItTokens.s6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: theme.colorScheme.secondaryContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.inbox_outlined,
                size: 36,
                color: theme.colorScheme.onSecondaryContainer,
              ),
            ),
            const SizedBox(height: JotItTokens.s4),
            Text('库里还没有笔记', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text('点右下角新建一篇', style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(JotItTokens.s5),
        child: Container(
          padding: const EdgeInsets.all(JotItTokens.s4),
          decoration: BoxDecoration(
            color: theme.colorScheme.errorContainer,
            borderRadius: BorderRadius.circular(JotItTokens.rMd),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.error_outline,
                  size: 18, color: theme.colorScheme.onErrorContainer),
              const SizedBox(width: JotItTokens.s2),
              Flexible(
                child: Text(
                  '出错了：$message',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onErrorContainer),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}