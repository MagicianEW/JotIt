import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../app/providers.dart';
import '../app/vault_session.dart';
import '../data/db/sync_root_store.dart';
import '../domain/sync/conflict_writer.dart';

/// Settings: where the vault is, which remotes exist, and what is waiting.
///
/// The three "waiting" lists — unresolved conflicts, parked queue entries, and
/// notes missing an index — are the reason this page exists. Anything the sync
/// engine cannot resolve on its own has to be visible to a person, or it is
/// silently lost.
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(vaultProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: session.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('打不开库：$e')),
        data: (vault) => ListView(
          children: [
            _SectionHeader('本机'),
            _InfoRow('库位置', vault.vaultRoot),
            _InfoRow('笔记目录', vault.notesPath),
            _InfoRow('索引数据库', vault.databasePath),
            _InfoRow('冲突副本', vault.conflictsPath),
            const Divider(),

            _SectionHeader('同步'),
            const _SyncRootsSection(),
            const Divider(),

            _SectionHeader('待处理'),
            _ConflictsSection(vaultRoot: vault.vaultRoot),
            _DeadLettersSection(),
            const Divider(),

            _SectionHeader('维护'),
            _RebuildIndexTile(),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(
          text,
          style: Theme.of(context)
              .textTheme
              .labelLarge
              ?.copyWith(color: Theme.of(context).colorScheme.primary),
        ),
      );
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => ListTile(
        dense: true,
        title: Text(label),
        subtitle: SelectableText(value),
      );
}

/// Lists configured remotes and their backoff state.
class _SyncRootsSection extends ConsumerWidget {
  const _SyncRootsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vault = ref.watch(vaultProvider);
    return vault.maybeWhen(
      orElse: () => const SizedBox.shrink(),
      data: (session) => FutureBuilder<List<SyncRootRecord>>(
        future: session.roots.enabled(),
        builder: (context, AsyncSnapshot<List<SyncRootRecord>> snap) {
          final roots = snap.data ?? const <SyncRootRecord>[];
          if (roots.isEmpty) {
            return const ListTile(
              dense: true,
              leading: Icon(Icons.cloud_off_outlined),
              title: Text('尚未配置远端'),
              subtitle: Text('JotIt 会完全在本机工作，不会有任何上传'),
            );
          }
          return Column(
            children: [
              for (final root in roots)
                ListTile(
                  dense: true,
                  leading: Icon(
                    root.isReadyAt(DateTime.now().millisecondsSinceEpoch)
                        ? Icons.cloud_done_outlined
                        : Icons.cloud_queue_outlined,
                  ),
                  title: Text(root.name),
                  subtitle: Text(
                    '${root.baseUrl}\n'
                    '${root.lastError == null ? '正常' : '上次错误：${root.lastError}'}',
                  ),
                  isThreeLine: root.lastError != null,
                ),
            ],
          );
        },
      ),
    );
  }
}

/// §7.3 — conflicts still awaiting a decision.
class _ConflictsSection extends StatelessWidget {
  const _ConflictsSection({required this.vaultRoot});

  final String vaultRoot;

  @override
  Widget build(BuildContext context) {
    final dirs = ConflictWriter.pending(vaultRoot);
    if (dirs.isEmpty) {
      return const ListTile(
        dense: true,
        leading: Icon(Icons.check_circle_outline),
        title: Text('没有未解决的冲突'),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          dense: true,
          leading: const Icon(Icons.warning_amber_outlined),
          title: Text('${dirs.length} 处冲突待你决定'),
          subtitle: Text(dirs.join('\n')),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            '两份内容都原样保存在 _conflicts/ 里，JotIt 不会替你选。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

/// §5.4 — queued operations that ran out of retries.
class _DeadLettersSection extends ConsumerWidget {
  const _DeadLettersSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vault = ref.watch(vaultProvider);
    return vault.maybeWhen(
      orElse: () => const SizedBox.shrink(),
      data: (session) => FutureBuilder<List<SyncRootRecord>>(
        future: session.roots.enabled(),
        builder: (context, AsyncSnapshot<List<SyncRootRecord>> snap) {
          final roots = snap.data ?? const <SyncRootRecord>[];
          if (roots.isEmpty) return const SizedBox.shrink();

          return FutureBuilder(
            future: _collectDeadLetters(session),
            builder: (context, dead) {
              final entries = dead.data ?? const [];
              if (entries.isEmpty) return const SizedBox.shrink();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.error_outline),
                    title: Text('${entries.length} 条操作已停止重试'),
                    subtitle: Text(entries
                        .map((e) => '${e.path}\n${e.lastError ?? ''}')
                        .join('\n')),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Future<List<_DeadLetter>> _collectDeadLetters(VaultSession session) async {
    final out = <_DeadLetter>[];
    for (final root in await session.roots.enabled()) {
      for (final op in await session.queue.deadLetters(root.id)) {
        out.add(_DeadLetter(
          path: op.targetPath,
          lastError: op.lastError,
        ));
      }
    }
    return out;
  }
}

class _DeadLetter {
  const _DeadLetter({required this.path, required this.lastError});

  final String path;
  final String? lastError;
}

/// §4.5 — rebuild the derived index without touching a single user file.
class _RebuildIndexTile extends ConsumerStatefulWidget {
  const _RebuildIndexTile();

  @override
  ConsumerState<_RebuildIndexTile> createState() => _RebuildIndexTileState();
}

class _RebuildIndexTileState extends ConsumerState<_RebuildIndexTile> {
  bool _busy = false;
  String? _result;

  @override
  Widget build(BuildContext context) => ListTile(
        leading: const Icon(Icons.refresh),
        title: const Text('重建索引'),
        subtitle: Text(_result ?? '按磁盘上的文件重新生成索引，不改动任何笔记'),
        trailing: _busy
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : TextButton(
                onPressed: _rebuild,
                child: const Text('执行'),
              ),
      );

  Future<void> _rebuild() async {
    setState(() {
      _busy = true;
      _result = null;
    });
    final session = await ref.read(vaultProvider.future);
    final result = await session.reindex();
    invalidateNotes(ref);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _result = '完成：${result.notesIndexed} 篇，'
          '${result.missingPaths.length} 处缺失待确认';
    });
  }
}

/// Opens the vault folder in the platform file manager.
void revealInFileManager(String path) {
  final dir = Directory(path);
  if (!dir.existsSync()) return;
  if (Platform.isWindows) {
    Process.run('explorer', <String>[path]);
  } else if (Platform.isMacOS) {
    Process.run('open', <String>[path]);
  } else {
    Process.run('xdg-open', <String>[p.normalize(path)]);
  }
}