import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/db/sync_root_store.dart';
import '../data/sync/sync_engine.dart';
import 'providers.dart';

/// What the UI shows about one round.
///
/// The shape is deliberately a snapshot rather than a stream of updates: a
/// sync either finishes or fails, and a half-finished round has no honest
/// intermediate state to show. `conflicts` and `preconditionFailed` are listed
/// separately because C3 says a conflict must never be quietly dropped, and a
/// number that is folded into "synced N files" is exactly that.
class SyncRunReport {
  const SyncRunReport({
    required this.rootId,
    required this.rootName,
    required this.result,
    required this.finishedAt,
  });

  final String rootId;
  final String rootName;
  final SyncBatchResult result;
  final DateTime finishedAt;

  bool get needsAttention =>
      result.conflicts.isNotEmpty || result.preconditionFailed.isNotEmpty;

  String get headline {
    if (result.error != null) return '失败：${result.error}';
    final parts = <String>[
      if (result.downloaded.isNotEmpty) '下载 ${result.downloaded.length}',
      if (result.uploaded.isNotEmpty) '上传 ${result.uploaded.length}',
      if (result.deleted.isNotEmpty) '删除 ${result.deleted.length}',
      if (result.conflicts.isNotEmpty) '冲突 ${result.conflicts.length}',
      if (result.preconditionFailed.isNotEmpty)
        '被拒 ${result.preconditionFailed.length}',
    ];
    return parts.isEmpty ? '没有变化' : parts.join(' · ');
  }
}

/// What the settings page needs to know about the controller: the last
/// report, and whether a round is running right now.
///
/// The running flag used to be a plain field on the controller. A field is
/// invisible to the widget tree, so the page never rebuilt when a round
/// started and the spinner never appeared — the button looked broken while
/// it was working. It is state now, and state is what makes a widget
/// rebuild.
class SyncControllerState {
  const SyncControllerState({this.report, this.runningRootId});

  /// The last round that finished, or null when none has.
  final SyncRunReport? report;

  /// The remote a round is running against, or null when nothing runs.
  final String? runningRootId;

  bool isRunning(String rootId) => runningRootId == rootId;

  bool get anyRunning => runningRootId != null;

  SyncControllerState copyWith({
    SyncRunReport? report,
    String? runningRootId,
    bool clearRunning = false,
  }) =>
      SyncControllerState(
        report: report ?? this.report,
        runningRootId:
            clearRunning ? null : (runningRootId ?? this.runningRootId),
      );
}

/// Holds the one round that may be in flight.
///
/// Single-flight is the engine's job, but the engine only knows about its own
/// sessions; the UI needs to know whether *any* round is running so it can
/// disable the button instead of queueing a second tap.
class SyncController extends Notifier<SyncControllerState> {
  @override
  SyncControllerState build() => const SyncControllerState();

  bool isRunning(String rootId) => state.isRunning(rootId);

  bool get anyRunning => state.anyRunning;

  /// Runs one round against the remote [rootId].
  ///
  /// Returns null when there is no usable credential, rather than opening a
  /// connection that is guaranteed to answer 401. Re-entrancy is refused here
  /// as well as in the engine so a double tap does not open two clients.
  Future<SyncRunReport?> run(String rootId) async {
    if (state.anyRunning) return null;

    // Announced *before* the first await, not after it. The guard above only
    // holds for as long as nothing is running; a second tap landing in the
    // window between the check and the announcement would pass the check,
    // and two rounds would run at once — the second one clearing the
    // "running" flag while the first is still going, so the spinner would
    // vanish in the middle of a round.
    _set(state.copyWith(runningRootId: rootId));
    SyncRootRecord? found;
    try {
      final session = await ref.read(vaultProvider.future);
      found = await session.roots.byId(rootId);
      final root = found;
      if (root == null) return null;

      final password = await session.passwordFor(root);
      if (password == null) {
        final report = SyncRunReport(
          rootId: root.id,
          rootName: root.name,
          result: const SyncBatchResult(error: '尚未保存这个远端的密码'),
          finishedAt: DateTime.now(),
        );
        _set(state.copyWith(report: report));
        return report;
      }

      final handle = await session.openSync(root, password);
      final now = DateTime.now().millisecondsSinceEpoch;
      try {
        final result = await handle.engine.run(syncRootId: rootId, nowMs: now);
        if (result.error != null) {
          _attempts++;
          await handle.engine.recordFailure(
            syncRootId: rootId,
            nowMs: now,
            retryCount: _attempts,
            error: result.error!,
          );
        } else {
          // A good round resets the escalation. Keeping the old count would
          // mean one transient failure a month apart backs off as if the
          // server had been refusing for days.
          _attempts = 0;
          await handle.engine.recordSuccess(
            syncRootId: rootId,
            nowMs: now,
          );
        }

        // Notes moved on disk; the derived index and the list have to follow.
        //
        // 整库 reindex 而不是对 result.touched 逐路径增量 upsert：引擎的
        // downloadRemote / rename adopt 只写文件和 sync_meta，从不写 notes
        // 行——同步下载 10 篇，首页一篇没有，重启才出现。增量的正确做法要
        // 在这里重新推导改名、删除和冲突副本，而这些恰是扫描器已经处理对
        // 的情形；扫描器的快路径按内容哈希逐文件比对，没有变化时整轮只是
        // 一次读遍历（1000 篇约 165ms），可接受。
        if (!result.isEmpty) {
          await session.reindex();
        }
        // The container can be torn down while a round is in flight — a test's
        // teardown, a hot restart. Reading a disposed ref throws, and the
        // throw would land in the catch below and be reported as a failed
        // round, which is the one thing this round is not.
        if (ref.mounted) invalidateNotesFromRef(ref);

        final report = SyncRunReport(
          rootId: rootId,
          rootName: root.name,
          result: result,
          finishedAt: DateTime.now(),
        );
        _set(state.copyWith(report: report));
        return report;
      } finally {
        await handle.close();
      }
    } on Object catch (e) {
      _attempts++;
      final report = SyncRunReport(
        rootId: rootId,
        // The root may not have been read at all — the vault itself may have
        // failed to open. The id is the best name available then, and it is
        // enough to identify the remote in the error line.
        rootName: found?.name ?? rootId,
        result: SyncBatchResult(error: '$e'),
        finishedAt: DateTime.now(),
      );
      _set(state.copyWith(report: report));
      return report;
    } finally {
      _set(state.copyWith(clearRunning: true));
    }
  }

  /// Consecutive failed rounds. The backoff deadline itself is persisted on
  /// `sync_roots.next_attempt_at` by the engine, so a restart does not reset
  /// the wait — this counter only has to feed the formula.
  int _attempts = 0;

  /// Writes the state, unless the provider has been disposed underneath us.
  ///
  /// A round outlives the provider that started it whenever the container is
  /// torn down mid-flight — a test's teardown, a hot restart. Writing to a
  /// disposed provider's state throws, and that throw comes out of the
  /// `finally` that was only meant to clear a flag, so the round's real
  /// result is lost behind a disposal error. There is nothing to say to a
  /// provider that no longer exists.
  void _set(SyncControllerState next) {
    if (!ref.mounted) return;
    state = next;
  }
}

final syncControllerProvider =
    NotifierProvider<SyncController, SyncControllerState>(SyncController.new);

/// The configured remotes, re-read whenever [syncRootsVersionProvider] moves.
final syncRootsProvider = FutureProvider<List<SyncRootRecord>>((ref) async {
  final session = await ref.watch(vaultProvider.future);
  ref.watch(syncRootsVersionProvider);
  return session.roots.enabled();
});

/// Bumped after a root is added, edited or removed.
class SyncRootsVersion extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state = state + 1;
}

final syncRootsVersionProvider =
    NotifierProvider<SyncRootsVersion, int>(SyncRootsVersion.new);

void invalidateSyncRoots(WidgetRef ref) =>
    ref.read(syncRootsVersionProvider.notifier).bump();