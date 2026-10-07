/// Session-level sync state machine (v3.0 §5.2).
///
/// This describes the life of **one sync session**. The per-file verdict lives
/// in `DecisionMatrix`; keeping the two apart is the point of v3.0 — v2.0
/// treated a single file's decision as the whole round's state, which is why
/// its machine had states like `SkipSync` that nothing could ever leave.
///
/// Three properties the tests pin down, all of them v2.0 bugs:
///
///  * every state has at least one out-edge (no dead ends),
///  * every state that touches the network has a way into [SyncState.backoff],
///  * a session that is already running rejects a second trigger instead of
///    starting a concurrent one.
library;

import 'package:meta/meta.dart';

/// Where a session currently is.
enum SyncState {
  idle,
  probing,
  remoteScan,
  localScan,
  queueDrain,
  diffBuild,
  syncBatch,
  conflictWrite,
  reindex,

  /// A single queued op failed but is still retryable.
  retryScheduled,

  /// The whole session is waiting out a backoff window.
  backoff,

  /// A queued op exhausted its retries and needs a person.
  deadLetter,
}

/// Something that happened, in terms the machine understands.
enum SyncEvent {
  /// A sync was requested. Rejected if one is already running.
  trigger,

  /// The trigger arrived while a session was already in flight.
  triggerRejected,

  /// Capability negotiation finished.
  probed,

  /// The remote side was enumerated.
  remoteScanned,

  /// The remote has no CTag; this round is a full depth=1 walk.
  remoteScanDegraded,

  /// The local side was enumerated.
  localScanned,

  /// This round has a non-empty change set to exchange.
  diffBuilt,

  /// Transfers finished.
  batchCompleted,

  /// A transfer failed mid-batch. Completed work keeps its committed base.
  transferInterrupted,

  /// Copies for a conflict were written to `_conflicts/`.
  conflictWritten,

  /// The derived index was refreshed.
  reindexed,

  /// The queue has entries ready to replay.
  queueReady,

  /// A queued op failed and still has retries left.
  opFailedRetryable,

  /// A queued op ran out of retries.
  opExhausted,

  /// The queue drained.
  queueEmpty,

  /// A backoff window elapsed.
  backoffElapsed,

  /// The server or the network refused us.
  networkError,

  /// Credentials were rejected.
  authFailed,

  /// A local file changed outside JotIt's knowledge.
  fileDriftDetected,
}

/// The outcome of feeding one event to the machine.
class SyncTransition {
  const SyncTransition({
    required this.from,
    required this.to,
    required this.event,
    this.reason = '',
    this.running = false,
  });

  final SyncState from;
  final SyncState to;
  final SyncEvent event;

  /// Why the machine went there, in words a sync log can print.
  final String reason;

  /// Whether a session is now in flight. False in [SyncState.idle].
  final bool running;

  /// True when the event changed nothing — a rejected trigger, or an event
  /// that does not apply to the current state.
  bool get isNoop => from == to && reason.isEmpty;
}

/// The session machine.
///
/// Deliberately pure and synchronous: it holds no I/O, no clock and no client.
/// Everything it needs arrives as an event and everything it says goes out as a
/// [SyncTransition], so the whole §5.2 diagram can be tested as a table instead
/// of inferred from integration runs that only ever exercise one path.
class SyncStateMachine {
  SyncStateMachine() : _state = SyncState.idle;

  SyncState _state;

  SyncState get state => _state;

  bool get isRunning => _state != SyncState.idle;

  /// Places the machine in [state] without walking there.
  ///
  /// Exists so the transition table can be tested row by row. Production code
  /// always starts from [SyncState.idle] and only ever moves via [apply].
  @visibleForTesting
  void seedForTest(SyncState state) => _state = state;

  /// Reset to [SyncState.idle] and report it. Used after `backoffElapsed` or a
  /// new trigger when the previous session has fully unwound.
  SyncTransition reset() {
    final from = _state;
    _state = SyncState.idle;
    return SyncTransition(
      from: from,
      to: _state,
      event: SyncEvent.backoffElapsed,
      reason: 'session unwound',
    );
  }

  SyncTransition apply(SyncEvent event) {
    final from = _state;
    final to = _next(from, event);
    if (to == null) {
      // An event that does not apply here is not an error: a timer can fire
      // after its session already finished, and a stale trigger must not take
      // down a healthy round.
      return SyncTransition(
        from: from,
        to: from,
        event: event,
        reason: 'ignored: not applicable in ${from.name}',
      );
    }
    _state = to;
    return SyncTransition(
      from: from,
      to: to,
      event: event,
      reason: _reason(from, to, event),
      running: to != SyncState.idle,
    );
  }

  static SyncState? _next(SyncState from, SyncEvent event) {
    switch (from) {
      case SyncState.idle:
        if (event == SyncEvent.trigger) return SyncState.probing;
        // A second trigger while a session runs is refused here rather than
        // starting a concurrent one. §5.2 single-flight.
        if (event == SyncEvent.triggerRejected) return SyncState.idle;
        return null;

      case SyncState.probing:
        switch (event) {
          case SyncEvent.probed:
            return SyncState.remoteScan;
          case SyncEvent.authFailed:
          case SyncEvent.networkError:
            return SyncState.backoff;
          default:
            return null;
        }

      case SyncState.remoteScan:
        switch (event) {
          case SyncEvent.remoteScanned:
            return SyncState.localScan;
          // No CTag means this round is the full walk; stay put and keep going.
          case SyncEvent.remoteScanDegraded:
            return SyncState.remoteScan;
          case SyncEvent.networkError:
            return SyncState.backoff;
          default:
            return null;
        }

      case SyncState.localScan:
        switch (event) {
          case SyncEvent.localScanned:
            return SyncState.diffBuild;
          // Backlog must survive an unchanged remote: this is the edge v2.0
          // dropped, leaving queued work stranded forever.
          case SyncEvent.queueReady:
            return SyncState.queueDrain;
          case SyncEvent.fileDriftDetected:
            return SyncState.reindex;
          case SyncEvent.queueEmpty:
            return SyncState.idle;
          default:
            return null;
        }

      case SyncState.queueDrain:
        switch (event) {
          // Replaying an op can itself move the remote, which feeds the
          // ordinary diff path.
          case SyncEvent.diffBuilt:
            return SyncState.diffBuild;
          // Or land on a file that already exists: conflict handling, not a
          // retry. v2.0's replay could not even reach conflict handling.
          case SyncEvent.conflictWritten:
            return SyncState.conflictWrite;
          case SyncEvent.networkError:
            return SyncState.backoff;
          case SyncEvent.opFailedRetryable:
            return SyncState.retryScheduled;
          case SyncEvent.opExhausted:
            return SyncState.deadLetter;
          case SyncEvent.queueEmpty:
            return SyncState.idle;
          default:
            return null;
        }

      case SyncState.diffBuild:
        if (event == SyncEvent.diffBuilt) return SyncState.syncBatch;
        return null;

      case SyncState.syncBatch:
        switch (event) {
          case SyncEvent.batchCompleted:
            return SyncState.reindex;
          // What already landed keeps its committed base; only the rest is
          // retried. Backing out without committing would re-transfer it.
          //
          // `networkError` is accepted alongside `transferInterrupted` because
          // mid-batch they are the same event seen from two angles: the §5.2
          // diagram names the transfer, the transport reports the socket.
          case SyncEvent.transferInterrupted:
          case SyncEvent.networkError:
            return SyncState.backoff;
          default:
            return null;
        }

      case SyncState.conflictWrite:
        if (event == SyncEvent.conflictWritten) return SyncState.syncBatch;
        return null;

      case SyncState.reindex:
        if (event == SyncEvent.reindexed) return SyncState.idle;
        return null;

      case SyncState.retryScheduled:
        if (event == SyncEvent.backoffElapsed) return SyncState.queueDrain;
        return null;

      case SyncState.backoff:
        if (event == SyncEvent.backoffElapsed) return SyncState.idle;
        return null;

      case SyncState.deadLetter:
        if (event == SyncEvent.queueEmpty) return SyncState.idle;
        return null;
    }
  }

  static String _reason(SyncState from, SyncState to, SyncEvent event) {
    if (from == SyncState.idle && event == SyncEvent.trigger) {
      return 'sync triggered';
    }
    if (to == SyncState.backoff) {
      return switch (event) {
        SyncEvent.authFailed => 'credentials rejected; backing off',
        SyncEvent.transferInterrupted => 'transfer interrupted; keeping landed work',
        _ => 'network error; backing off',
      };
    }
    if (to == SyncState.deadLetter) return 'retries exhausted; needs a person';
    if (to == SyncState.retryScheduled) return 'single op failed; will retry';
    if (to == SyncState.reindex) {
      return event == SyncEvent.fileDriftDetected
          ? 'file drift detected; refreshing index'
          : 'transfers done; refreshing index';
    }
    if (to == SyncState.idle) return 'session complete';
    return '${event.name} -> ${to.name}';
  }
}

/// §5.2 — `delay = min(30min, 30s x 2^retry_count) x jitter(0.5~1.5)`.
///
/// Pure, with the jitter drawn from an injected source, so a test can pin both
/// ends of the range instead of asserting that a random number was "somewhere
/// near" thirty seconds. `next_attempt_at` is persisted on `sync_roots`, which
/// is what makes the window survive a restart.
abstract final class SyncBackoff {
  static const Duration base = Duration(seconds: 30);
  static const Duration ceiling = Duration(minutes: 30);

  /// The window before attempt [retryCount] (0-based: the first failure is 0).
  ///
  /// [jitterFactor] must already be in the 0.5..1.5 band the spec asks for; it
  /// is passed in rather than drawn here so this stays pure.
  static Duration delayFor(int retryCount, {required double jitterFactor}) {
    if (retryCount < 0) {
      throw ArgumentError.value(retryCount, 'retryCount', 'must be >= 0');
    }
    // 2^retry overflows a 32-bit shift long before the ceiling matters, so
    // stop doubling once the uncapped value already exceeds it.
    final uncappedMs = retryCount >= 16
        ? ceiling.inMilliseconds
        : base.inMilliseconds * (1 << retryCount);
    final cappedMs =
        uncappedMs > ceiling.inMilliseconds ? ceiling.inMilliseconds : uncappedMs;
    return Duration(
      milliseconds: (cappedMs * jitterFactor).round().clamp(0, ceiling.inMilliseconds),
    );
  }

  /// Absolute wall-clock deadline, ready for `sync_roots.next_attempt_at`.
  static int nextAttemptAt(
    int nowMs,
    int retryCount, {
    required double jitterFactor,
  }) =>
      nowMs + delayFor(retryCount, jitterFactor: jitterFactor).inMilliseconds;
}