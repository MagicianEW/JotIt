import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../app/providers.dart';
import '../app/sync_controller.dart';
import '../data/db/sync_root_store.dart';
import '../domain/sync/conflict_writer.dart';
import 'remote_form.dart';
import 'theme.dart';

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
          // Each section is a sheet of paper with a hairline edge: grouping by
          // cards instead of bare dividers is what makes a long settings page
          // scannable, and it matches the shelf on the first screen.
          padding: const EdgeInsets.only(bottom: JotItTokens.s5),
          children: [
            _SectionHeader('本机'),
            _GroupCard(children: [
              _InfoRow('库位置', vault.vaultRoot),
              _InfoRow('笔记目录', vault.notesPath),
              _InfoRow('索引数据库', vault.databasePath),
              _InfoRow('冲突副本', vault.conflictsPath),
            ]),

            _SectionHeader('同步'),
            const _GroupCard(children: [_SyncRootsSection()]),

            _SectionHeader('待处理'),
            _GroupCard(children: [
              _ConflictsSection(vaultRoot: vault.vaultRoot),
              const _DeadLettersSection(),
            ]),

            _SectionHeader('安全'),
            const _GroupCard(children: [_LockSection()]),

            _SectionHeader('维护'),
            const _GroupCard(children: [_RebuildIndexTile()]),
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
        // Left edge aligns with the text inside the group cards below, not
        // with the cards themselves.
        padding: const EdgeInsets.fromLTRB(
            JotItTokens.s5, JotItTokens.s5, JotItTokens.s5, JotItTokens.s1),
        child: Text(
          text,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w600,
                letterSpacing: 1,
              ),
        ),
      );
}

/// A rounded sheet of paper holding one section's rows.
class _GroupCard extends StatelessWidget {
  const _GroupCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    // 用 Material 而不是带底色的 DecoratedBox：ListTile 的水波纹只能画在最近的
    // Material 祖先上，中间夹一层有底色的盒子会把水波纹盖住并触发断言。
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: JotItTokens.s4, vertical: JotItTokens.s1),
      child: Material(
        color: c.surfaceContainerLow,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(JotItTokens.rMd),
          side: BorderSide(color: c.outlineVariant),
        ),
        child: Column(children: children),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: JotItTokens.s4, vertical: 0),
      title: Text(
        label,
        style: theme.textTheme.bodyMedium
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
      // Selectable on purpose: a vault path is something people copy into a
      // terminal, and a label that looks like text but cannot be selected is
      // worse than a plain one.
      subtitle: SelectableText(value, style: theme.textTheme.bodySmall),
    );
  }
}

/// Lists configured remotes and their backoff state, and is the only place a
/// remote can be created, edited or synced from.
class _SyncRootsSection extends ConsumerWidget {
  const _SyncRootsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final roots = ref.watch(syncRootsProvider);
    // Watched, not read: the controller's state carries "a round is
    // running", and a page that does not rebuild on it never shows the
    // spinner.
    final syncState = ref.watch(syncControllerProvider);
    final report = syncState.report;
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
    final theme = Theme.of(context);
    final c = theme.colorScheme;
    final running = controller.isRunning(root.id);
    final blocked = root.nextAttemptAt >
        DateTime.now().millisecondsSinceEpoch;
    final ready = root.isReadyAt(DateTime.now().millisecondsSinceEpoch);
    return ListTile(
      contentPadding:
          const EdgeInsets.symmetric(horizontal: JotItTokens.s3, vertical: 4),
      // The same tone-on-tone disc as the shelf: a remote is a thing in this
      // library, not a form row.
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: c.secondaryContainer,
          shape: BoxShape.circle,
        ),
        child: Icon(
          ready ? Icons.cloud_done_outlined : Icons.cloud_queue_outlined,
          size: 20,
          color: c.onSecondaryContainer,
        ),
      ),
      title: Text(root.name, style: theme.textTheme.titleMedium),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            root.baseUrl,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
          Text(
            // Green for "fine", error red for "not fine": the two states a
            // person actually scans this page for.
            root.lastError == null ? '正常' : '上次错误：${root.lastError}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: root.lastError == null ? c.primary : c.error,
            ),
          ),
        ],
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
              style: IconButton.styleFrom(
                backgroundColor: c.primaryContainer,
                foregroundColor: c.onPrimaryContainer,
              ),
              onPressed: blocked
                  ? null
                  : () async {
                      final result = await controller.run(root.id);
                      if (!context.mounted) return;
                      if (result == null) {
                        // The tap did nothing. Saying so is the difference
                        // between a button that is busy and a button that is
                        // broken.
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(controller.anyRunning
                              ? '已经有一轮同步在跑了'
                              : '这个远端现在无法同步'),
                        ));
                        return;
                      }
                      if (result.result.error != null) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text('同步失败：${result.result.error}'),
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

  final result = await showDialog<RemoteDialogResult>(
    context: context,
    builder: (context) => _RemoteDialog(existing: existing),
  );
  if (result == null) return;

  // Every write below can fail — SQLite locked, disk full, the credential
  // cipher failing to seal — and a failure that is not reported is the worst
  // kind: the dialog is already closed, so the user believes the remote was
  // saved, and it was not. Every path therefore reports, and the list is
  // re-read afterwards so what is on screen is what is really stored.
  if (result.delete) {
    try {
      await session.roots.remove(existing!.id);
      invalidateSyncRoots(ref);
    } on Object catch (e) {
      if (!context.mounted) return;
      _reportError(context, '删除远端失败：$e');
    }
    return;
  }

  final raw = result.url.trim();
  // buildRemoteRecord (not a fresh constructor): editing used to wipe the
  // saved password — and the CTag, backoff state and last error with it —
  // because the record it upserted carried none of them. See remote_form.dart.
  final record = buildRemoteRecord(
    existing: existing,
    name: result.name.trim(),
    url: raw,
    username: result.username.trim().isEmpty ? null : result.username.trim(),
  );

  try {
    if (result.password.isEmpty) {
      await session.roots.upsert(record);
    } else {
      // Seal first, then write once. The two-step version wrote the record
      // and *then* the password, so a failure between them left a remote
      // with an address and no credentials — half-configured, and the next
      // sync fails against it for a reason the settings page cannot show.
      final sealed = await session.cipher.seal(result.password);
      await session.roots.upsert(record.copyWith(credentialBlob: sealed));
    }
    invalidateSyncRoots(ref);
  } on Object catch (e) {
    invalidateSyncRoots(ref);
    if (!context.mounted) return;
    _reportError(context, '保存远端失败：$e');
  }
}

/// Says what went wrong, in the only place the user is looking.
///
/// The alternative — letting the exception escape — leaves an unhandled
/// async error that no dialog is showing any more: the form is closed, the
/// page is unchanged, and the user has no idea that their PIN or their
/// remote was not saved.
void _reportError(BuildContext context, String message) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// What [_RemoteDialog] hands back.
class RemoteDialogResult {
  const RemoteDialogResult.save({
    required this.name,
    required this.url,
    required this.username,
    required this.password,
  }) : delete = false;

  const RemoteDialogResult.delete()
      : delete = true,
        name = '',
        url = '',
        username = '',
        password = '';

  final bool delete;
  final String name;
  final String url;
  final String username;

  /// Empty means "leave the saved password alone", which is different from
  /// saving an empty one.
  final String password;
}

/// The add/edit remote form.
///
/// A widget rather than an inline `AlertDialog` so its four controllers are
/// disposed with it. Owned from the calling method they were simply never
/// released at all, once per dialog.
class _RemoteDialog extends StatefulWidget {
  const _RemoteDialog({this.existing});

  final SyncRootRecord? existing;

  @override
  State<_RemoteDialog> createState() => _RemoteDialogState();
}

class _RemoteDialogState extends State<_RemoteDialog> {
  late final TextEditingController _name =
      TextEditingController(text: widget.existing?.name ?? '');
  late final TextEditingController _url =
      TextEditingController(text: widget.existing?.baseUrl ?? '');
  late final TextEditingController _user =
      TextEditingController(text: widget.existing?.username ?? '');
  final TextEditingController _pass = TextEditingController();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  void _save() {
    if (_formKey.currentState?.validate() != true) return;
    Navigator.of(context).pop(RemoteDialogResult.save(
      name: _name.text,
      url: _url.text,
      username: _user.text,
      password: _pass.text,
    ));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.existing == null ? '添加远端' : '编辑远端'),
        content: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                key: const ValueKey('root-name'),
                controller: _name,
                decoration: const InputDecoration(labelText: '名称'),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? '给这个远端起个名字' : null,
              ),
              TextFormField(
                key: const ValueKey('root-url'),
                controller: _url,
                decoration: const InputDecoration(
                  labelText: 'WebDAV 地址',
                  hintText: 'http://nas.example.com:35115/webDAV/JotIt/',
                ),
                validator: validateWebDavUrl,
              ),
              TextFormField(
                key: const ValueKey('root-user'),
                controller: _user,
                decoration: InputDecoration(
                  labelText: '用户名（可留空）',
                  helperText: widget.existing == null
                      ? null
                      : '留空表示不改动已保存的用户名',
                ),
              ),
              TextFormField(
                key: const ValueKey('root-pass'),
                controller: _pass,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: '密码',
                  helperText: widget.existing?.credentialBlob == null
                      ? '会加密后保存'
                      : '留空表示不改动已保存的密码',
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (widget.existing != null)
            TextButton(
              onPressed: () =>
                  Navigator.of(context).pop(const RemoteDialogResult.delete()),
              child: const Text('删除'),
            ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(onPressed: _save, child: const Text('保存')),
        ],
      );
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
    // Watched, not built here. A `FutureBuilder` whose `future` is created
    // inside `build` asks again every time the tree rebuilds — and the
    // settings page rebuilds on its own state changes. The snapshot resets
    // to "loading" each time, so the block flickers, and the same queries
    // run again and again for the same answer.
    final dead = ref.watch(_deadLettersProvider);
    return dead.maybeWhen(
      orElse: () => const SizedBox.shrink(),
      data: (entries) {
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
  }
}

/// The queued operations no device can make progress on any more.
///
/// Watched for the note version as well: a dead letter appears when a
/// queued operation runs out of retries, which happens *during* a round — so
/// without this the list would keep showing the state from before the round
/// that produced it.
final _deadLettersProvider = FutureProvider<List<_DeadLetter>>((ref) async {
  final session = await ref.watch(vaultProvider.future);
  ref.watch(notesVersionProvider);
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
});

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
    // The read can fail for the same reason the write did — a locked or
    // damaged database. Letting that escape would leave the section showing
    // whatever it last knew, which is exactly the "thinks the PIN is set when
    // it is not" state this section exists to rule out.
    try {
      final session = await ref.read(vaultProvider.future);
      final value = await session.lock.isConfigured();
      if (mounted) setState(() => _configured = value);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _configured = false);
      _reportError(context, '读取应用锁状态失败：$e');
    }
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

    // The dialog returns the PIN itself, so its two controllers die with the
    // dialog. Built here, they would outlive it.
    final pin = await showDialog<String>(
      context: context,
      builder: (context) => const _PinDialog(),
    );
    if (pin == null) return;

    // A new PIN resets the failure state: it is a new start, not a
    // continuation of whatever the old one was being brute-forced against.
    // Through the session, so Android's FLAG_SECURE is set in the same breath
    // (§8.3) — a lock that arms without protecting the screen protects nothing.
    //
    // A failure here is the one this page must never swallow: the dialog is
    // closed, the user walks away believing the lock is armed, and it is
    // not — the screenshots are still allowed and nothing on the page says
    // so. The error is reported and the real state is re-read.
    try {
      await session.setPin(pin);
    } on Object catch (e) {
      if (!mounted) return;
      _reportError(context, '设置 PIN 失败：$e');
    }
    await _load();
  }

  Future<void> _remove() async {
    final session = await ref.read(vaultProvider.future);
    try {
      await session.clearPin();
    } on Object catch (e) {
      if (!mounted) return;
      _reportError(context, '关闭应用锁失败：$e');
    }
    await _load();
  }
}

/// Asks for a PIN twice and hands back a value only when the two agree.
class _PinDialog extends StatefulWidget {
  const _PinDialog();

  @override
  State<_PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<_PinDialog> {
  final TextEditingController _pin = TextEditingController();
  final TextEditingController _confirm = TextEditingController();
  String? _problem;

  @override
  void dispose() {
    _pin.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _save() {
    if (_pin.text.length < 4) {
      setState(() => _problem = '至少 4 位');
      return;
    }
    if (_pin.text != _confirm.text) {
      setState(() => _problem = '两次输入不一样');
      return;
    }
    Navigator.of(context).pop(_pin.text);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('设置 PIN'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('new-pin'),
              controller: _pin,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 32,
              textAlign: TextAlign.center,
              // Wide tracking makes a short numeric secret easy to count
              // instead of easy to mistype twice.
              style: const TextStyle(letterSpacing: 6, fontSize: 20),
              decoration: const InputDecoration(
                labelText: '新 PIN',
                counterText: '',
              ),
            ),
            const SizedBox(height: JotItTokens.s2),
            TextField(
              key: const ValueKey('new-pin-confirm'),
              controller: _confirm,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 32,
              textAlign: TextAlign.center,
              style: const TextStyle(letterSpacing: 6, fontSize: 20),
              decoration: const InputDecoration(
                labelText: '再输一次',
                counterText: '',
              ),
            ),
            if (_problem != null)
              Text(
                _problem!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(onPressed: _save, child: const Text('保存')),
        ],
      );
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