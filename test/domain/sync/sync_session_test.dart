import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/domain/sync/sync_session.dart';

/// §5.2 — the session state machine, tested as the table it is.
///
/// The v2.0 machine this replaces had three dead-end states and no transition
/// out of a network error at all. Both are structural, so they are asserted
/// structurally here rather than hoped for in an integration test.
void main() {
  late SyncStateMachine m;

  setUp(() => m = SyncStateMachine());

  group('structural invariants', () {
    test('no state is a dead end', () {
      final deadEnds = <SyncState>[];
      for (final s in SyncState.values) {
        var out = 0;
        for (final e in SyncEvent.values) {
          // A fresh machine per event: applying a mutating event first would
          // leave the next probe looking at a different state than the one
          // being audited.
          final probe = SyncStateMachine()..seedForTest(s);
          if (probe.apply(e).to != s) out++;
        }
        if (out == 0) deadEnds.add(s);
      }
      expect(deadEnds, isEmpty,
          reason: 'v2.0 shipped SkipSync / MergingMetadata / RetryLater — '
              'states nothing could ever leave');
    });

    test('every state can be reached from idle', () {
      final reached = <SyncState>{};
      final frontier = <SyncState>[SyncState.idle];
      while (frontier.isNotEmpty) {
        final s = frontier.removeLast();
        for (final e in SyncEvent.values) {
          final probe = SyncStateMachine()..seedForTest(s);
          final next = probe.apply(e);
          if (!reached.contains(next.to)) {
            reached.add(next.to);
            frontier.add(next.to);
          }
        }
      }
      expect(reached.toSet(), SyncState.values.toSet(),
          reason: 'a state nothing can reach is dead code');
    });

    test('every network-touching state has a way into backoff', () {
      for (final s in const [
        SyncState.probing,
        SyncState.remoteScan,
        SyncState.queueDrain,
        SyncState.syncBatch,
      ]) {
        final machine = SyncStateMachine()..seedForTest(s);
        expect(machine.apply(SyncEvent.networkError).to, SyncState.backoff,
            reason: '${s.name} has no network-error transition');
      }
    });

    test('every session can unwind to idle', () {
      // Breadth-first, not single-step: `probing` needs `networkError` then
      // `backoffElapsed`. The property that matters is that no state can trap a
      // session, not that it takes exactly one event.
      for (final s in SyncState.values) {
        final seen = <SyncState>{s};
        var frontier = <SyncState>[s];
        var reached = s == SyncState.idle;

        for (var depth = 0; depth < 12 && !reached && frontier.isNotEmpty; depth++) {
          final next = <SyncState>[];
          for (final from in frontier) {
            for (final e in SyncEvent.values) {
              final probe = SyncStateMachine()..seedForTest(from);
              final to = probe.apply(e).to;
              if (to == SyncState.idle) {
                reached = true;
                break;
              }
              if (seen.add(to)) next.add(to);
            }
            if (reached) break;
          }
          frontier = next;
        }
        expect(reached, isTrue, reason: '${s.name} cannot unwind');
      }
    });
  });

  group('single-flight', () {
    test('a trigger starts a session', () {
      final t = m.apply(SyncEvent.trigger);
      expect(t.to, SyncState.probing);
      expect(t.running, isTrue);
      expect(m.isRunning, isTrue);
    });

    test('a second trigger is refused while a session runs', () {
      m.apply(SyncEvent.trigger);
      m.apply(SyncEvent.probed);
      m.apply(SyncEvent.remoteScanned);
      m.apply(SyncEvent.localScanned);
      final running = m.state;
      expect(running, isNot(SyncState.idle));

      final t = m.apply(SyncEvent.trigger);
      expect(t.to, running, reason: 'the trigger changed nothing');
      expect(t.reason, contains('ignored'));
    });

    test('a rejected trigger leaves idle alone', () {
      final t = m.apply(SyncEvent.triggerRejected);
      expect(t.to, SyncState.idle);
      expect(m.isRunning, isFalse);
    });

    test('a trigger is accepted again once the session unwinds', () {
      m.apply(SyncEvent.trigger);
      m.apply(SyncEvent.probed);
      m.apply(SyncEvent.remoteScanned);
      m.apply(SyncEvent.localScanned);
      m.apply(SyncEvent.diffBuilt);
      m.apply(SyncEvent.batchCompleted);
      m.apply(SyncEvent.reindexed);
      expect(m.state, SyncState.idle);

      expect(m.apply(SyncEvent.trigger).to, SyncState.probing);
    });
  });

  group('happy path', () {
    test('idle -> probing -> remoteScan -> localScan -> diffBuild -> '
        'syncBatch -> reindex -> idle', () {
      expect(m.apply(SyncEvent.trigger).to, SyncState.probing);
      expect(m.apply(SyncEvent.probed).to, SyncState.remoteScan);
      expect(m.apply(SyncEvent.remoteScanned).to, SyncState.localScan);
      expect(m.apply(SyncEvent.localScanned).to, SyncState.diffBuild);
      expect(m.apply(SyncEvent.diffBuilt).to, SyncState.syncBatch);
      expect(m.apply(SyncEvent.batchCompleted).to, SyncState.reindex);
      final done = m.apply(SyncEvent.reindexed);
      expect(done.to, SyncState.idle);
      expect(done.running, isFalse);
    });
  });

  group('remote scan', () {
    test('a server without CTag degrades instead of stopping', () {
      m.apply(SyncEvent.trigger);
      m.apply(SyncEvent.probed);
      final t = m.apply(SyncEvent.remoteScanDegraded);
      expect(t.to, SyncState.remoteScan,
          reason: 'the full depth=1 walk continues in the same round');
    });
  });

  group('queue backlog', () {
    test('an unchanged remote still drains a non-empty queue', () {
      // The edge v2.0 did not have: CTag unchanged meant "skip", so work queued
      // while offline never reached the server.
      m.apply(SyncEvent.trigger);
      m.apply(SyncEvent.probed);
      m.apply(SyncEvent.remoteScanned);
      expect(m.apply(SyncEvent.queueReady).to, SyncState.queueDrain);
    });

    test('nothing local and nothing queued goes straight to idle', () {
      m.apply(SyncEvent.trigger);
      m.apply(SyncEvent.probed);
      m.apply(SyncEvent.remoteScanned);
      expect(m.apply(SyncEvent.queueEmpty).to, SyncState.idle);
    });

    test('replay can feed the ordinary diff path', () {
      m.apply(SyncEvent.trigger);
      m.apply(SyncEvent.probed);
      m.apply(SyncEvent.remoteScanned);
      m.apply(SyncEvent.queueReady);
      expect(m.apply(SyncEvent.diffBuilt).to, SyncState.diffBuild);
    });

    test('replay can reach conflict handling', () {
      m.apply(SyncEvent.trigger);
      m.apply(SyncEvent.probed);
      m.apply(SyncEvent.remoteScanned);
      m.apply(SyncEvent.queueReady);
      final t = m.apply(SyncEvent.conflictWritten);
      expect(t.to, SyncState.conflictWrite);
      expect(m.apply(SyncEvent.conflictWritten).to, SyncState.syncBatch);
    });

    test('one failure schedules a retry, exhaustion dead-letters', () {
      SyncStateMachine atQueueDrain() {
        final mm = SyncStateMachine();
        mm.apply(SyncEvent.trigger);
        mm.apply(SyncEvent.probed);
        mm.apply(SyncEvent.remoteScanned);
        mm.apply(SyncEvent.queueReady);
        expect(mm.state, SyncState.queueDrain);
        return mm;
      }

      final retry = atQueueDrain();
      expect(retry.apply(SyncEvent.opFailedRetryable).to,
          SyncState.retryScheduled);
      expect(retry.apply(SyncEvent.backoffElapsed).to, SyncState.queueDrain);

      final dead = atQueueDrain();
      expect(dead.apply(SyncEvent.opExhausted).to, SyncState.deadLetter);
      expect(dead.apply(SyncEvent.queueEmpty).to, SyncState.idle);
    });
  });

  group('error handling', () {
    test('bad credentials back off rather than looping', () {
      m.apply(SyncEvent.trigger);
      final t = m.apply(SyncEvent.authFailed);
      expect(t.to, SyncState.backoff);
      expect(t.reason, contains('credentials'));
    });

    test('an interrupted transfer keeps what already landed', () {
      m.apply(SyncEvent.trigger);
      m.apply(SyncEvent.probed);
      m.apply(SyncEvent.remoteScanned);
      m.apply(SyncEvent.localScanned);
      m.apply(SyncEvent.diffBuilt);
      final t = m.apply(SyncEvent.transferInterrupted);
      expect(t.to, SyncState.backoff);
      expect(t.reason, contains('keeping landed work'));
    });

    test('backoff unwinds to idle when the window elapses', () {
      m.apply(SyncEvent.trigger);
      m.apply(SyncEvent.networkError);
      expect(m.apply(SyncEvent.backoffElapsed).to, SyncState.idle);
    });

    test('reset unwinds from anywhere', () {
      for (final s in SyncState.values) {
        final mm = SyncStateMachine()..seedForTest(s);
        expect(mm.reset().to, SyncState.idle, reason: s.name);
        expect(mm.isRunning, isFalse);
      }
    });
  });

  group('irrelevant events', () {
    test('are ignored rather than throwing', () {
      // A timer can fire after its session finished; that must not derail a
      // healthy round.
      expect(m.apply(SyncEvent.batchCompleted).to, SyncState.idle);
      expect(m.apply(SyncEvent.opExhausted).to, SyncState.idle);
      expect(m.apply(SyncEvent.reindexed).to, SyncState.idle);
    });

    test('an ignored event leaves the state untouched', () {
      m.apply(SyncEvent.trigger);
      m.apply(SyncEvent.probed);
      m.apply(SyncEvent.remoteScanned);
      final before = m.state;
      final t = m.apply(SyncEvent.reindexed);
      expect(m.state, before);
      expect(t.isNoop, isFalse, reason: 'an ignored event still says why');
    });
  });

  group('backoff schedule', () {
    test('doubles from 30s and stops at 30min', () {
      expect(SyncBackoff.delayFor(0, jitterFactor: 1.0),
          const Duration(seconds: 30));
      expect(SyncBackoff.delayFor(1, jitterFactor: 1.0),
          const Duration(seconds: 60));
      expect(SyncBackoff.delayFor(2, jitterFactor: 1.0),
          const Duration(minutes: 2));
      expect(SyncBackoff.delayFor(3, jitterFactor: 1.0),
          const Duration(minutes: 4));
      expect(SyncBackoff.delayFor(6, jitterFactor: 1.0),
          const Duration(minutes: 30));
      expect(SyncBackoff.delayFor(60, jitterFactor: 1.0),
          const Duration(minutes: 30));
    });

    test('jitter scales the window without exceeding the ceiling', () {
      expect(SyncBackoff.delayFor(0, jitterFactor: 0.5),
          const Duration(seconds: 15));
      expect(SyncBackoff.delayFor(0, jitterFactor: 1.5),
          const Duration(seconds: 45));
      expect(SyncBackoff.delayFor(0, jitterFactor: 0.0), Duration.zero);
      expect(SyncBackoff.delayFor(99, jitterFactor: 1.5),
          const Duration(minutes: 30));
    });

    test('nextAttemptAt is an absolute deadline', () {
      expect(SyncBackoff.nextAttemptAt(1000, 0, jitterFactor: 1.0),
          1000 + 30000);
      expect(SyncBackoff.nextAttemptAt(1000, 1, jitterFactor: 1.5),
          1000 + 90000);
    });

    test('a negative retry count is rejected', () {
      expect(() => SyncBackoff.delayFor(-1, jitterFactor: 1.0),
          throwsArgumentError);
    });
  });
}

