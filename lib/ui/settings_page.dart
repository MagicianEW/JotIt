import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../app/providers.dart';
import '../app/sync_controller.dart';
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

            _SectionHeader('安全'),
            const _LockSection(),
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

/// Lists configured remotes and their backoff state, and is the only place a
/// remote can be created, edited or synced from.
class _SyncRootsSection extends ConsumerWidget {
  const _SyncRootsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final roots = ref.watch(syncRootsProvider);
    final report = ref.watch(syncControllerProvider);
    final controller = ref.read(syncControllerProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        roots.when(
          loading: () => const LinearProgressIndicator(),
          error: (e, _) => ListTile(dense: true, title: Text('读取失败：$e')),
          data: (list) => list.isEmpty
              ? const ListTile(
                  dense: true,
                  leading: Icon(Icons.cloud_off_outlined),
                  title: Text('尚未配置远端'),
                  subtitle: Text('JotIt 会完全在本机工作，不会有任何上传'),
                )
              : Column(
                  children: [
                    for (final root in list) _rootTile(context, ref, root, controller),
                  ],
                ),
        ),
        ListTile(
          dense: true,
          leading: const Icon(Icons.add_link),
          title: const Text('添加远端'),
          subtitle: const Text('WebDAV 地址、账号与密码；密码加密后保存'),
          onTap: () => _editRoot(context, ref, null),
        ),
        if (report != null) _ReportTile(report: report),
      ],
    );
  }

  Widget _rootTile(
    BuildContext context,
    WidgetRef ref,
    SyncRootRecord root,
    SyncController controller,
  ) {
    final running = controller.isRunning(root.id);
    final blocked = root.nextAttemptAt >
        DateTime.now().millisecondsSinceEpoch;
    return ListTile(
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
      trailing: running
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : IconButton(
              tooltip: blocked ? '退避等待中' : '立即同步',
              icon: Icon(blocked ? Icons.timer_outlined : Icons.sync),
              onPressed: blocked
                  ? null
                  : () async {
                      final result = await controller.run(root.id);
                      if (!context.mounted) return;
                      if (result?.result.error != null) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text('同步失败：${result!.result.error}'),
                        ));
                      }
                    },
            ),
      onTap: () => _editRoot(context, ref, root),
    );
  }
}

/// The outcome of the last round, in full.
///
/// Conflicts and refusals get their own lines rather than being summarised
/// into "N files synced": §C3 is a promise that a divergence is never quietly
/// resolved, and a count is exactly what makes it quiet.
class _ReportTile extends StatelessWidget {
  const _ReportTile({required this.report});

  final SyncRunReport report;

  @override
  Widget build(BuildContext context) {
    final r = report.result;
    final when = report.finishedAt.toLocal().toString().substring(0, 16);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('上次同步（$when）',
              style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 4),
          Text(report.headline),
          if (r.conflicts.isNotEmpty)
            _detail(context, Icons.warning_amber_outlined,
                '冲突，两份都留在 _conflicts/ 等你决定：\n${r.conflicts.join('\n')}'),
          if (r.preconditionFailed.isNotEmpty)
            _detail(context, Icons.block, '服务器拒绝了这些写入，下一轮会重新判定：\n'
                '${r.preconditionFailed.join('\n')}'),
        ],
      ),
    );
  }

  Widget _detail(BuildContext context, IconData icon, String text) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: Theme.of(context).colorScheme.error),
            const SizedBox(width: 6),
            Expanded(
              child: SelectableText(
                text,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      );
}

/// Creates or edits one remote.
///
/// The URL is normalised to end with a slash here rather than at use: a base
/// without one makes `Uri.resolve` drop the last segment, which silently
/// writes every note one directory too high.
Future<void> _editRoot(
    BuildContext context, WidgetRef ref, SyncRootRecord? existing) async {
  final session = await ref.read(vaultProvider.future);
  if (!context.mounted) return;

  final name = TextEditingController(text: existing?.name ?? '');
  final url = TextEditingController(text: existing?.baseUrl ?? '');
  final user = TextEditingController(text: existing?.username ?? '');
  final pass = TextEditingController();
  final formKey = GlobalKey<FormState>();
  var deleteRequested = false;

  final saved = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(existing == null ? '添加远端' : '编辑远端'),
      content: Form(
        key: formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: name,
              decoration: const InputDecoration(labelText: '名称'),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? '给这个远端起个名字' : null,
            ),
            TextFormField(
              controller: url,
              decoration: const InputDecoration(
                labelText: 'WebDAV 地址',
                hintText: 'http://192.168.1.100:35115/webDAV/JotIt/',
              ),
              validator: (v) {
                final u = Uri.tryParse(v?.trim() ?? '');
                if (u == null || !u.hasScheme || u.host.isEmpty) {
                  return '需要一个完整的 http/https 地址';
                }
                return null;
              },
            ),
            TextFormField(
              controller: user,
              decoration: const InputDecoration(
                labelText: '用户名（可留空）',
              ),
            ),
            TextFormField(
              controller: pass,
              obscureText: true,
              decoration: InputDecoration(
                labelText: '密码',
                helperText: existing?.credentialBlob == null
                    ? '会加密后保存'
                    : '留空表示不改动已保存的密码',
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (existing != null)
          TextButton(
            onPressed: () {
              deleteRequested = true;
              Navigator.of(context).pop(false);
            },
            child: const Text('删除'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            if (formKey.currentState?.validate() != true) return;
            Navigator.of(context).pop(true);
          },
          child: const Text('保存'),
        ),
      ],
    ),
  );

  if (deleteRequested && existing != null) {
    await session.roots.remove(existing.id);
    invalidateSyncRoots(ref);
    return;
  }

  if (saved != true) return;

  final raw = url.text.trim();
  final normalised = raw.endsWith('/') ? raw : '$raw/';
  final record = SyncRootRecord(
    id: existing?.id ?? const Uuid().v4(),
    name: name.text.trim(),
    baseUrl: normalised,
    username: user.text.trim().isEmpty ? null : user.text.trim(),
    capabilities: existing?.capabilities ?? const <String, Object?>{},
    enabled: existing?.enabled ?? true,
  );

  await session.roots.upsert(record);
  final typed = pass.text;
  if (typed.isNotEmpty) await session.setPassword(record, typed);
  invalidateSyncRoots(ref);
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

/// §8.3 — the application lock.
///
/// The lock is optional by design. Demanding a secret before the user has seen
/// a single note is how lock screens get switched off for good, so this offers
/// one and says plainly what forgetting it costs.
class _LockSection extends ConsumerStatefulWidget {
  const _LockSection();

  @override
  ConsumerState<_LockSection> createState() => _LockSectionState();
}

class _LockSectionState extends ConsumerState<_LockSection> {
  bool? _configured;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final session = await ref.read(vaultProvider.future);
    final value = await session.lock.isConfigured();
    if (mounted) setState(() => _configured = value);
  }

  @override
  Widget build(BuildContext context) {
    if (_configured == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          dense: true,
          leading: Icon(_configured!
              ? Icons.lock_outline
              : Icons.lock_open_outlined),
          title: Text(_configured! ? '已设置 PIN' : '未设置 PIN'),
          subtitle: Text(_configured!
              ? '打开 JotIt 时需要输入'
              : '可以随时设置；忘记 PIN 就无法再打开这个库'),
          trailing: TextButton(
            onPressed: _edit,
            child: Text(_configured! ? '修改' : '设置'),
          ),
        ),
        if (_configured!)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextButton(
              onPressed: _remove,
              child: const Text('关闭应用锁'),
            ),
          ),
      ],
    );
  }

  Future<void> _edit() async {
    final session = await ref.read(vaultProvider.future);
    if (!mounted) return;

    final pin = TextEditingController();
    final confirm = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('设置 PIN'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: pin,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 32,
              decoration: const InputDecoration(labelText: '新 PIN', counterText: ''),
            ),
            TextField(
              controller: confirm,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 32,
              decoration:
                  const InputDecoration(labelText: '再输一次', counterText: ''),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (pin.text.length < 4) return;
              if (pin.text != confirm.text) return;
              Navigator.of(context).pop(true);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );

    if (ok == true) {
      // A new PIN resets the failure state: it is a new start, not a
      // continuation of whatever the old one was being brute-forced against.
      await session.lock.setPin(pin.text);
      await _load();
    }
  }

  Future<void> _remove() async {
    final session = await ref.read(vaultProvider.future);
    await session.lock.clear();
    await _load();
  }
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