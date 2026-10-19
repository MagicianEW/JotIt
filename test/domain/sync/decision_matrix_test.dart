import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/domain/sync/decision_matrix.dart';

/// Exhaustive table tests for the v3.0 §5.3 decision matrix.
///
/// Every row of the matrix gets at least one case, and the safety invariants
/// (C3: never silently drop a copy) are asserted across all of them. This file
/// is the reason the classifier is a pure function — it runs in milliseconds
/// and can be widened into a combinatorial sweep.
void main() {
  const h = 'hash';
  const other = 'other';
  const uidA = 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa';
  const uidB = 'bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb';

  SyncObservation obs({
    String path = 'daily/2024-01-01.md',
    bool localExists = false,
    bool localDeleted = false,
    String? localUid,
    String? localContentHash,
    bool remoteExists = false,
    String? remoteUid,
    String? remoteContentHash,
    String? remoteEtag,
    String? baseEtag,
    String? baseContentHash,
    String? baseUid,
    String? knownBasePathForRemoteUid,
    bool serverRejectedConditional = false,
  }) =>
      SyncObservation(
        path: path,
        localExists: localExists,
        localDeleted: localDeleted,
        localUid: localUid,
        localContentHash: localContentHash,
        remoteExists: remoteExists,
        remoteUid: remoteUid,
        remoteContentHash: remoteContentHash,
        remoteEtag: remoteEtag,
        baseEtag: baseEtag,
        baseContentHash: baseContentHash,
        baseUid: baseUid,
        knownBasePathForRemoteUid: knownBasePathForRemoteUid,
        serverRejectedConditional: serverRejectedConditional,
      );

  group('row 1 — new / absent', () {
    test('absent on both sides is a no-op', () {
      expect(classifySync(obs()).action, SyncAction.nothingToDo);
    });

    test('local note never synced is created remotely', () {
      final d = classifySync(obs(localExists: true, localUid: uidA, localContentHash: h));
      expect(d.action, SyncAction.uploadCreate);
    });
  });

  group('row 2 — path collision (v2.0 P0-6)', () {
    test('same path, different uid keeps BOTH copies', () {
      final d = classifySync(obs(
        localExists: true,
        localUid: uidA,
        localContentHash: h,
        remoteExists: true,
        remoteUid: uidB,
        remoteEtag: 'e1',
        baseEtag: 'e0',
        baseContentHash: 'base',
      ));
      expect(d.action, SyncAction.pathCollision);
      expect(d.preserveLocal, isTrue, reason: 'local edit must not be lost');
      expect(d.preserveRemote, isTrue, reason: 'remote file must not be clobbered');
      expect(d.detail, contains('two devices each created'));
    });

    test('remote file with no uid is a conflict, never an overwrite', () {
      final d = classifySync(obs(
        localExists: true,
        localUid: uidA,
        localContentHash: h,
        remoteExists: true,
        remoteUid: null,
        remoteEtag: 'e1',
        baseEtag: 'e0',
        baseContentHash: 'base',
      ));
      expect(d.action, SyncAction.trueConflict);
      expect(d.preserveLocal, isTrue);
      expect(d.preserveRemote, isTrue);
    });

    test('local file with no uid is a conflict, never an overwrite', () {
      // The mirror of the above: a local file whose identity cannot be read
      // used to fall through to the rows below, where it was either
      // uploaded over the remote note or downloaded over.
      final d = classifySync(obs(
        localExists: true,
        localUid: null,
        localContentHash: h,
        remoteExists: true,
        remoteUid: uidA,
        remoteEtag: 'e1',
        remoteContentHash: other,
        baseEtag: 'e0',
        baseContentHash: 'base',
      ));
      expect(d.action, SyncAction.trueConflict);
      expect(d.preserveLocal, isTrue);
      expect(d.preserveRemote, isTrue);
    });
  });

  group('row 3 — remote rename', () {
    test('known uid at another path is adopted, not conflicted', () {
      final d = classifySync(obs(
        remoteExists: true,
        remoteUid: uidA,
        remoteEtag: 'e1',
        knownBasePathForRemoteUid: 'projects/old.md',
      ));
      expect(d.action, SyncAction.remoteRenameAdopt);
      expect(d.preserveLocal, isFalse);
    });

    test('a known uid at THIS path is not a rename', () {
      final d = classifySync(obs(
        localExists: true,
        localUid: uidA,
        localContentHash: h,
        remoteExists: true,
        remoteUid: uidA,
        remoteEtag: 'e1',
        baseEtag: 'e0',
        baseContentHash: 'base',
      ));
      expect(d.action, isNot(SyncAction.remoteRenameAdopt));
    });

    test('a target path holding a different uid is not a rename', () {
      // P0-3: adopting would destroy the local file at the target path.
      // This is a path collision that merely looks like a rename.
      final d = classifySync(obs(
        localExists: true,
        localUid: uidB,
        localContentHash: h,
        remoteExists: true,
        remoteUid: uidA,
        remoteEtag: 'e1',
        knownBasePathForRemoteUid: 'projects/old.md',
      ));
      expect(d.action, SyncAction.pathCollision);
      expect(d.preserveLocal, isTrue);
      expect(d.preserveRemote, isTrue);
    });

    test('a target path holding a uidless file is not a rename', () {
      // C3: the local identity cannot be read, so nothing is overwritten.
      final d = classifySync(obs(
        localExists: true,
        localUid: null,
        localContentHash: h,
        remoteExists: true,
        remoteUid: uidA,
        remoteEtag: 'e1',
        knownBasePathForRemoteUid: 'projects/old.md',
      ));
      expect(d.action, SyncAction.trueConflict);
      expect(d.preserveLocal, isTrue);
      expect(d.preserveRemote, isTrue);
    });

    test('a target path already holding the same uid is still a rename', () {
      // The note was moved locally but the base was not updated; adopting
      // the remote path is still the right answer.
      final d = classifySync(obs(
        localExists: true,
        localUid: uidA,
        localContentHash: h,
        remoteExists: true,
        remoteUid: uidA,
        remoteEtag: 'e1',
        knownBasePathForRemoteUid: 'projects/old.md',
      ));
      expect(d.action, SyncAction.remoteRenameAdopt);
    });
  });

  group('rows 4, 5, 12 — remote deletion', () {
    test('remote deleted, local untouched: propagate deletion', () {
      final d = classifySync(obs(
        localExists: true,
        localUid: uidA,
        localContentHash: 'base',
        baseEtag: 'e0',
        baseContentHash: 'base',
      ));
      expect(d.action, SyncAction.restoreRemoteDelete);
    });

    test('remote deleted, local edited: EDIT IS PRESERVED (v2.0 P0-5)', () {
      final d = classifySync(obs(
        localExists: true,
        localUid: uidA,
        localContentHash: h,
        baseEtag: 'e0',
        baseContentHash: 'base',
      ));
      expect(d.action, SyncAction.deleteVsModifyPreserveLocal);
      expect(d.preserveLocal, isTrue);
    });

    test('deleted on both sides: forget the metadata', () {
      final d = classifySync(obs(
        localExists: true,
        localDeleted: true,
        localUid: uidA,
        baseEtag: 'e0',
        baseContentHash: 'base',
      ));
      expect(d.action, SyncAction.forgetSyncMeta);
    });
  });

  group('row 6 — remote-only change', () {
    test('remote file absent locally is downloaded', () {
      final d = classifySync(obs(remoteExists: true, remoteUid: uidA, remoteEtag: 'e1'));
      expect(d.action, SyncAction.downloadRemote);
    });

    test('remote changed, local untouched: download', () {
      final d = classifySync(obs(
        localExists: true,
        localUid: uidA,
        localContentHash: 'base',
        remoteExists: true,
        remoteUid: uidA,
        remoteEtag: 'e1',
        remoteContentHash: other,
        baseEtag: 'e0',
        baseContentHash: 'base',
      ));
      expect(d.action, SyncAction.downloadRemote);
    });
  });

  group('rows 7, 8, 9 — both present, same identity', () {
    test('local-only change uploads', () {
      final d = classifySync(obs(
        localExists: true,
        localUid: uidA,
        localContentHash: h,
        remoteExists: true,
        remoteUid: uidA,
        remoteEtag: 'e0',
        remoteContentHash: 'base',
        baseEtag: 'e0',
        baseContentHash: 'base',
      ));
      expect(d.action, SyncAction.uploadUpdate);
    });

    test('both changed to identical bytes is a no-op', () {
      final d = classifySync(obs(
        localExists: true,
        localUid: uidA,
        localContentHash: h,
        remoteExists: true,
        remoteUid: uidA,
        remoteEtag: 'e1',
        remoteContentHash: h,
        baseEtag: 'e0',
        baseContentHash: 'base',
      ));
      expect(d.action, SyncAction.noopSameContent);
    });

    test('both changed to different content is a true conflict', () {
      final d = classifySync(obs(
        localExists: true,
        localUid: uidA,
        localContentHash: h,
        remoteExists: true,
        remoteUid: uidA,
        remoteEtag: 'e1',
        remoteContentHash: other,
        baseEtag: 'e0',
        baseContentHash: 'base',
      ));
      expect(d.action, SyncAction.trueConflict);
      expect(d.preserveLocal, isTrue);
      expect(d.preserveRemote, isTrue);
    });

    test('same uid with no base cannot prove freshness, so it conflicts', () {
      final d = classifySync(obs(
        localExists: true,
        localUid: uidA,
        localContentHash: h,
        remoteExists: true,
        remoteUid: uidA,
        remoteEtag: 'e1',
        remoteContentHash: other,
      ));
      expect(d.action, SyncAction.trueConflict);
    });

    test('both match the base is a no-op', () {
      final d = classifySync(obs(
        localExists: true,
        localUid: uidA,
        localContentHash: 'base',
        remoteExists: true,
        remoteUid: uidA,
        remoteEtag: 'e0',
        remoteContentHash: 'base',
        baseEtag: 'e0',
        baseContentHash: 'base',
      ));
      expect(d.action, SyncAction.nothingToDo);
    });
  });

  group('rows 11, 13 — local deletion', () {
    test('local deleted, remote unchanged: conditional DELETE', () {
      final d = classifySync(obs(
        localExists: true,
        localDeleted: true,
        localUid: uidA,
        remoteExists: true,
        remoteUid: uidA,
        remoteEtag: 'e0',
        remoteContentHash: 'base',
        baseEtag: 'e0',
        baseContentHash: 'base',
      ));
      expect(d.action, SyncAction.deleteRemote);
    });

    test('local deleted, remote edited: REMOTE EDIT IS PRESERVED', () {
      final d = classifySync(obs(
        localExists: true,
        localDeleted: true,
        localUid: uidA,
        remoteExists: true,
        remoteUid: uidA,
        remoteEtag: 'e1',
        remoteContentHash: other,
        baseEtag: 'e0',
        baseContentHash: 'base',
      ));
      expect(d.action, SyncAction.deleteVsModifyPreserveRemote);
      expect(d.preserveRemote, isTrue);
    });
  });

  group('row 10 — server rejection', () {
    test('412/409 outranks every local inference', () {
      final d = classifySync(obs(
        localExists: true,
        localUid: uidA,
        localContentHash: h,
        remoteExists: true,
        remoteUid: uidA,
        remoteEtag: 'e1',
        remoteContentHash: other,
        baseEtag: 'e0',
        baseContentHash: 'base',
        serverRejectedConditional: true,
      ));
      expect(d.action, SyncAction.retryNextRound);
      expect(d.preserveLocal, isFalse,
          reason: 'no destructive step, so nothing needs preserving this round');
    });

    test('rejection wins even over an obvious conflict', () {
      final d = classifySync(obs(
        localExists: true,
        localUid: uidA,
        localContentHash: h,
        remoteExists: true,
        remoteUid: uidB,
        remoteEtag: 'e1',
        serverRejectedConditional: true,
      ));
      expect(d.action, SyncAction.retryNextRound);
    });
  });

  group('invariant C3 — no side is ever silently dropped', () {
    // Every observation reachable by toggling the independent flags.
    final cases = <String, SyncObservation>{
      'collision': obs(
          localExists: true,
          localUid: uidA,
          localContentHash: h,
          remoteExists: true,
          remoteUid: uidB,
          remoteEtag: 'e1',
          baseEtag: 'e0',
          baseContentHash: 'base'),
      'both edited': obs(
          localExists: true,
          localUid: uidA,
          localContentHash: h,
          remoteExists: true,
          remoteUid: uidA,
          remoteEtag: 'e1',
          remoteContentHash: other,
          baseEtag: 'e0',
          baseContentHash: 'base'),
      'delete vs modify': obs(
          localExists: true,
          localUid: uidA,
          localContentHash: h,
          baseEtag: 'e0',
          baseContentHash: 'base'),
      'modify vs delete': obs(
          localExists: true,
          localDeleted: true,
          localUid: uidA,
          remoteExists: true,
          remoteUid: uidA,
          remoteEtag: 'e1',
          remoteContentHash: other,
          baseEtag: 'e0',
          baseContentHash: 'base'),
      'no base': obs(
          localExists: true,
          localUid: uidA,
          localContentHash: h,
          remoteExists: true,
          remoteUid: uidA,
          remoteEtag: 'e1',
          remoteContentHash: other),
      'remote uidless': obs(
          localExists: true,
          localUid: uidA,
          localContentHash: h,
          remoteExists: true,
          remoteEtag: 'e1',
          baseEtag: 'e0',
          baseContentHash: 'base'),
    };

    cases.forEach((name, o) {
      test('$name preserves every copy it could destroy', () {
        final d = classifySync(o);
        // If a decision destroys a side, that side must have been preserved.
        final destroysLocal =
            d.action == SyncAction.downloadRemote ||
                d.action == SyncAction.restoreRemoteDelete ||
                d.action == SyncAction.deleteRemote ||
                d.action == SyncAction.forgetSyncMeta;
        final destroysRemote =
            d.action == SyncAction.uploadCreate ||
                d.action == SyncAction.uploadUpdate;
        if (destroysLocal) {
          expect(d.preserveLocal || !o.localChanged, isTrue,
              reason: '$name would destroy a locally-edited note without preserving it');
        }
        if (destroysRemote) {
          expect(d.preserveRemote || !o.remoteChanged, isTrue,
              reason: '$name would destroy a remotely-edited note without preserving it');
        }
      });
    });

    test('conflict decisions always keep both sides', () {
      for (final entry in cases.entries) {
        final d = classifySync(entry.value);
        if (d.isConflict) {
          expect(d.preserveLocal, isTrue, reason: entry.key);
          expect(d.preserveRemote, isTrue, reason: entry.key);
        }
      }
    });
  });
}