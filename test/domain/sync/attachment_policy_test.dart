import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/core/vault_paths.dart';
import 'package:jotit/domain/sync/attachment_policy.dart';

/// v3.0 §5.5, as a table.
///
/// Pure and therefore exhaustively testable in milliseconds, for the same
/// reason `decision_matrix_test.dart` exists for the note matrix: this
/// classifier is the last gate before the engine starts writing and deleting
/// immutable files, and it must be readable as a table rather than discovered
/// through a live server.
///
/// The two rows that carry the most weight are the last two. There is
/// deliberately **no action that resolves differing bytes**, because ADR-11
/// says that state cannot exist and C3 says the answer to "I am not sure" is
/// never overwrite. If someone later adds a last-writer-wins branch here, the
/// test named after §5.5 should be the thing that notices.
void main() {
  const path = 'notes/attachments/6f1a.png';
  const hashA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const hashB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

  AttachmentObservation obs({
    bool localExists = false,
    String? localHash,
    bool remoteExists = false,
    String? remoteHash,
    String? baseHash,
    bool referenced = true,
    bool known = false,
  }) =>
      AttachmentObservation(
        path: path,
        localExists: localExists,
        localHash: localHash ?? (localExists ? hashA : null),
        remoteExists: remoteExists,
        remoteHash: remoteHash ?? (remoteExists ? hashA : null),
        baseHash: baseHash,
        referencedByANote: referenced,
        knownToVault: known,
      );

  group('both absent', () {
    test('is nothing to do', () {
      expect(classifyAttachment(obs()), AttachmentAction.nothingToDo);
    });
  });

  group('remote only', () {
    test('a path this vault has never seen is downloaded', () {
      // The other device created it. This is new content arriving, not a
      // deletion, and refusing it would be how a second device ends up with
      // every note and none of the pictures.
      expect(classifyAttachment(obs(remoteExists: true)),
          AttachmentAction.download);
    });

    test('a path this vault has seen before is a deletion', () {
      // Same observable state as the row above — file missing here, present
      // there — and the opposite action. The index row is the only thing that
      // distinguishes them, which is exactly why §4.4 keeps metadata for files
      // that have disappeared.
      expect(
        classifyAttachment(obs(remoteExists: true, known: true)),
        AttachmentAction.deleteRemote,
      );
    });

    test('a known path with a base row also deletes', () {
      expect(
        classifyAttachment(obs(remoteExists: true, known: true, baseHash: hashA)),
        AttachmentAction.deleteRemote,
      );
    });
  });

  group('local only', () {
    test('a referenced file is uploaded', () {
      expect(
        classifyAttachment(obs(localExists: true)),
        AttachmentAction.upload,
      );
    });

    test('it is uploaded even when a base exists', () {
      // The remote lost it. ADR-11 means there is nothing to merge, so this is
      // a create as far as the server is concerned and must not be skipped.
      expect(
        classifyAttachment(obs(localExists: true, baseHash: hashA)),
        AttachmentAction.upload,
      );
    });

    test('an unreferenced file is left alone', () {
      expect(
        classifyAttachment(obs(localExists: true, referenced: false)),
        AttachmentAction.orphan,
      );
    });
  });

  group('both present', () {
    test('identical checksums do nothing', () {
      expect(
        classifyAttachment(obs(
            localExists: true, remoteExists: true, baseHash: hashA)),
        AttachmentAction.nothingToDo,
      );
    });

    test('differing checksums are reported, never resolved', () {
      final decision = classifyAttachment(obs(
        localExists: true,
        remoteExists: true,
        remoteHash: hashB,
        baseHash: hashA,
      ));
      expect(decision, AttachmentAction.immutableViolation);
      // Stated as an enum exhaustiveness check, not just a value check: this
      // is the property that §5.5's "不存在附件内容冲突" actually depends on.
      expect(
        AttachmentAction.values.map((a) => a.name),
        isNot(contains('overwrite')),
        reason: 'no action may exist that resolves differing bytes on an '
            'immutable path',
      );
    });

    test('an unknown remote checksum is not treated as a difference', () {
      // The engine must resolve the remote hash before asking, but if it ever
      // fails to, the answer has to be "do nothing" rather than "every
      // attachment in the vault is in violation, every round".
      expect(
        classifyAttachment(obs(
            localExists: true, remoteExists: true, remoteHash: null)),
        AttachmentAction.nothingToDo,
      );
    });
  });

  group('the pre-filter that decides whether to download at all', () {
    test('an unsynced path is always worth fetching', () {
      expect(
        remoteChecksumNeedsFetching(
          remoteExists: true,
          baseHash: null,
          remoteContentLength: 10,
          baseContentLength: null,
          remoteEtag: '"a"',
          baseEtag: null,
        ),
        isTrue,
      );
    });

    test('a different size is proof on its own, and it is free', () {
      expect(
        remoteChecksumNeedsFetching(
          remoteExists: true,
          baseHash: hashA,
          remoteContentLength: 11,
          baseContentLength: 10,
          remoteEtag: '"a"',
          baseEtag: '"a"',
        ),
        isTrue,
      );
    });

    test('the same size under a different token still has to be checked', () {
      // Same length, different ETag: a rewrite to the same length, which is
      // precisely the case a size check alone would miss.
      expect(
        remoteChecksumNeedsFetching(
          remoteExists: true,
          baseHash: hashA,
          remoteContentLength: 10,
          baseContentLength: 10,
          remoteEtag: '"b"',
          baseEtag: '"a"',
        ),
        isTrue,
      );
    });

    test('nothing the server said has moved, so nothing is fetched', () {
      // Without this, a vault with a few hundred photographs downloads itself
      // in full on every single round to confirm that nothing changed.
      expect(
        remoteChecksumNeedsFetching(
          remoteExists: true,
          baseHash: hashA,
          remoteContentLength: 10,
          baseContentLength: 10,
          remoteEtag: '"a"',
          baseEtag: '"a"',
        ),
        isFalse,
      );
    });

    test('a remote that is not there needs no checksum', () {
      expect(
        remoteChecksumNeedsFetching(
          remoteExists: false,
          baseHash: hashA,
          remoteContentLength: null,
          baseContentLength: 10,
          remoteEtag: null,
          baseEtag: '"a"',
        ),
        isFalse,
      );
    });
  });

  group('path classification, which three call sites must agree on', () {
    test('a file under an attachments directory is an attachment', () {
      expect(VaultPaths.isAttachmentPath('notes/attachments/x.png'), isTrue);
      expect(VaultPaths.isAttachmentPath('notes/a/attachments/x.png'), isTrue);
      expect(VaultPaths.isAttachmentPath('notes/a/b/attachments/deep/x.png'),
          isTrue);
    });

    test('the directory decides, not the extension', () {
      // A note can legitimately be called `.png`, and a picture can
      // legitimately have no extension. Keying off the extension is how a
      // document gets uploaded as an image and a screenshot gets indexed as a
      // note.
      expect(VaultPaths.isAttachmentPath('notes/a/diagram.png'), isFalse);
      expect(VaultPaths.isAttachmentPath('notes/attachments/pasted'), isTrue);
    });

    test('notes and things outside the vault are not attachments', () {
      expect(VaultPaths.isAttachmentPath('notes/a.md'), isFalse);
      expect(VaultPaths.isAttachmentPath('notes/daily/2024.md'), isFalse);
      expect(VaultPaths.isAttachmentPath('_conflicts/a/local.md'), isFalse);
      expect(VaultPaths.isAttachmentPath('.jotit/jotit.db'), isFalse);
      expect(VaultPaths.isAttachmentPath('../escape/attachments/x.png'),
          isFalse);
    });
  });

  group('mime types', () {
    test('an image is not labelled as markdown', () {
      // The exact reason this table exists next to the classifier: a hardcoded
      // `text/markdown` on every PUT made the server store the type and hand
      // it to every other client reading the vault.
      expect(mimeTypeFor('notes/attachments/x.png'), 'image/png');
      expect(mimeTypeFor('x.JPEG'), 'image/jpeg');
      expect(mimeTypeFor('x.Pdf'), 'application/pdf');
    });

    test('the extension may be missing entirely', () {
      expect(mimeTypeFor('notes/attachments/pasted'), isNotEmpty);
      expect(mimeTypeFor('notes/attachments/pasted'),
          'application/octet-stream');
    });

    test('an unknown extension is honestly unknown', () {
      // Better than a wrong-but-specific type, which makes a server treat the
      // file as something it is not.
      expect(mimeTypeFor('x.qqq'), 'application/octet-stream');
    });
  });

  group('the 10 MB boundary §5.5 names', () {
    test('is where it says it is', () {
      expect(kLargeAttachmentBytes, 10 * 1024 * 1024);
      expect(isLargeAttachment(kLargeAttachmentBytes - 1), isFalse);
      expect(isLargeAttachment(kLargeAttachmentBytes), isTrue);
    });
  });

  group('progress ticks', () {
    test('round-trip through the wire format', () {
      const tick = AttachmentProgress(
        path: 'notes/attachments/x.png',
        transferred: 512,
        total: 2048,
        direction: 'upload',
      );
      final back = AttachmentProgress.fromJson(jsonEncode(tick.toJson()));
      expect(back?.path, tick.path);
      expect(back?.transferred, 512);
      expect(back?.fraction, 0.25);
    });

    test('an unknown total does not pretend to know a fraction', () {
      const tick = AttachmentProgress(
        path: 'x',
        transferred: 10,
        total: -1,
        direction: 'download',
      );
      expect(tick.fraction, -1);
    });

    test('garbage in the persisted queue is not fatal', () {
      expect(AttachmentProgress.fromJson('not json'), isNull);
      expect(AttachmentProgress.fromJson('[1,2,3]'), isNull);
    });
  });
}
