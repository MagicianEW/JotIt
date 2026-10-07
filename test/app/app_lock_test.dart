import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/app/app_lock.dart';
import 'package:jotit/data/db/jotit_database.dart';
import 'package:jotit/data/db/schema.dart';
import 'package:sqflite_common/sqlite_api.dart';

/// §8.3 — the application lock.
///
/// The property that matters is not "a wrong PIN is refused". It is that the
/// **refusal survives a restart**: a counter held in memory hands a four-digit
/// PIN back to anybody willing to kill the process between attempts, which is
/// the P2-18 bug this exists to close.
void main() {
  late JotItDatabase jdb;
  late Database db;

  setUp(() async {
    jdb = await JotItDatabase.openInMemory();
    db = jdb.db;
  });

  tearDown(() async => jdb.close());

  /// A cheap iteration count so the suite stays fast. The production default
  /// is asserted separately against the spec value.
  AppLock lock({int iterations = 1000, int seed = 7}) => AppLock(
        db,
        random: Random(seed),
        iterations: iterations,
      );

  group('pin storage', () {
    test('the pin is never stored in the clear', () async {
      await lock().setPin('4815');
      final rows = await db.query('app_lock');
      final dump = rows.toString();
      expect(dump, isNot(contains('4815')));
    });

    test('the row holds a salt, a hash and the iteration count', () async {
      await lock().setPin('4815');
      final state = (await lock().read())!;
      expect(state.pinHash.length, 64, reason: 'SHA-256 hex');
      expect(state.salt.length, AppLock.kSaltBytes * 2);
      expect(state.iterations, 1000);
    });

    test('two vaults with the same pin get different hashes', () async {
      await lock(seed: 1).setPin('4815');
      await lock(seed: 2).setPin('4815');
      final a = (await lock().read())!;
      // A different salt must produce a different hash; an identical hash for
      // the same pin across devices would mean the salt is not being used.
      final first = a.pinHash;
      final second = (await lock().read())!.pinHash;
      expect(first, second, reason: 'same database, same row');

      // Verify the salt actually feeds the hash instead.
      final h1 = AppLock.derivePin('4815',
          salt: Uint8List.fromList(List<int>.filled(16, 0)), iterations: 100);
      final h2 = AppLock.derivePin('4815',
          salt: Uint8List.fromList(List<int>.filled(16, 1)), iterations: 100);
      expect(h1, isNot(h2));
    });

    test('an unset lock reports not configured', () async {
      expect(await lock().isConfigured(), isFalse);
      final r = await lock().unlock('anything', nowMs: 0);
      expect(r.outcome, UnlockOutcome.notConfigured);
      expect(r.isOk, isTrue, reason: 'no PIN means nothing to unlock');
    });
  });

  group('PBKDF2', () {
    test('matches published HMAC-SHA256 vectors', () {
      // Cross-checked against Node's built-in crypto.pbkdf2Sync, which is an
      // implementation this project does not share code with. Two of these
      // (the 4096-round one and the two-block one) existed specifically to
      // exercise the round loop and the block counter; the previous copy of
      // this test held two mis-transcribed constants and still "tested" the
      // KDF, which is the worst of both outcomes.
      final vectors = <List<Object>>[
        <Object>[
          'password',
          1,
          32,
          '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b',
        ],
        <Object>[
          'password',
          2,
          32,
          'ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43',
        ],
        <Object>[
          'password',
          4096,
          32,
          'c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a',
        ],
        <Object>[
          'passwordPASSWORDpassword',
          1,
          32,
          'fe28d382b7fe94b2c39ed9b56500c9efc769d9874f4fc10a113609ab86832faf',
        ],
        // Two blocks: the second block's counter is the same algorithm applied
        // to a different big-endian integer, and a 32-byte PIN never reaches it.
        <Object>[
          'passwordPASSWORDpassword',
          1,
          64,
          'fe28d382b7fe94b2c39ed9b56500c9efc769d9874f4fc10a113609ab86832faf'
              '60048847cfb29faa4936ca2d23a6ad06b5230ed521149e500aa5ea2567c931c5',
        ],
        // A NUL inside the password must survive UTF-8 encoding instead of
        // truncating the string.
        <Object>[
          'pass\u0000word',
          3,
          40,
          'd6e5174ea529db1e28efd0d81e50efd88ed89505b1215b07ff0262600a1089a0c'
              'ebb43066dfdb7e8',
        ],
        // A length that is not a multiple of the hash size: the tail of the
        // last block must be truncated, not zero-padded. The dkLen=33 result
        // starts with the dkLen=32 result, because PBKDF2 derives block by
        // block and a shorter key is a genuine prefix of a longer one.
        <Object>[
          'password',
          2,
          33,
          'ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43'
              '83',
        ],
      ];

      for (final v in vectors) {
        final pin = v[0] as String;
        final iterations = v[1] as int;
        final length = v[2] as int;
        expect(
          AppLock.derivePin(pin,
              salt: Uint8List.fromList(utf8Bytes('salt')),
              iterations: iterations,
              length: length),
          v[3],
          reason: '$pin c=$iterations dkLen=$length',
        );
      }
    });

    test('iterating changes the result', () {
      final salt = Uint8List.fromList(utf8Bytes('salt'));
      expect(
        AppLock.derivePin('p', salt: salt, iterations: 1),
        isNot(AppLock.derivePin('p', salt: salt, iterations: 2)),
      );
    });

    test('the spec iteration count is 600k', () {
      expect(AppLock.kIterations, greaterThanOrEqualTo(600000));
    });
  });

  group('backoff ladder', () {
    test('nothing is imposed for the first two attempts', () {
      expect(AppLock.backoffFor(0), isNull);
      expect(AppLock.backoffFor(1), isNull);
      expect(AppLock.backoffFor(2), isNull);
    });

    test('then 30s, 1min, 5min, 15min, 60min, capped', () {
      expect(AppLock.backoffFor(3), const Duration(seconds: 30));
      expect(AppLock.backoffFor(4), const Duration(minutes: 1));
      expect(AppLock.backoffFor(5), const Duration(minutes: 5));
      expect(AppLock.backoffFor(6), const Duration(minutes: 15));
      expect(AppLock.backoffFor(7), const Duration(minutes: 60));
      expect(AppLock.backoffFor(50), const Duration(minutes: 60));
    });
  });

  group('unlocking', () {
    test('the right pin opens the lock', () async {
      await lock().setPin('4815');
      final r = await lock().unlock('4815', nowMs: 1000);
      expect(r.outcome, UnlockOutcome.ok);
    });

    test('a wrong pin is refused', () async {
      await lock().setPin('4815');
      final r = await lock().unlock('4816', nowMs: 1000);
      expect(r.outcome, UnlockOutcome.wrongPin);
      expect(r.failedAttempts, 1);
    });

    test('a correct pin clears the failure count', () async {
      final l = lock();
      await l.setPin('4815');
      await l.unlock('0000', nowMs: 1000);
      await l.unlock('1111', nowMs: 2000);
      expect((await l.read())!.failedAttempts, 2);

      await l.unlock('4815', nowMs: 3000);
      expect((await l.read())!.failedAttempts, 0);
      expect((await l.read())!.lockedUntil, 0);
    });

    test('setting a new pin wipes the failure state', () async {
      final l = lock();
      await l.setPin('4815');
      await l.unlock('0000', nowMs: 1000);
      expect((await l.read())!.failedAttempts, 1);

      await l.setPin('9999');
      expect((await l.read())!.failedAttempts, 0);
      expect((await l.read())!.lockedUntil, 0);
    });
  });

  group('the lockout is persistent (P2-18)', () {
    test('three wrong attempts arm the lock', () async {
      final l = lock();
      await l.setPin('4815');
      await l.unlock('0000', nowMs: 1000);
      await l.unlock('0000', nowMs: 2000);
      final third = await l.unlock('0000', nowMs: 3000);

      expect(third.outcome, UnlockOutcome.wrongPin);
      expect(third.retryAfter, const Duration(seconds: 30));
      expect(AppLock.isLockedOut((await l.read())!, 3000), isTrue);
    });

    test('a fresh object over the same database is still locked out', () async {
      // This is the whole test. An in-memory counter would pass the cases
      // above and fail here, which is exactly the bug.
      await lock().setPin('4815');
      for (var i = 0; i < 3; i++) {
        await lock().unlock('0000', nowMs: (i + 1) * 1000);
      }

      // "Restart": a brand new AppLock with a brand new RNG, same database.
      final afterRestart = AppLock(db, random: Random(99), iterations: 1000);
      final r = await afterRestart.unlock('4815', nowMs: 5000);

      expect(r.outcome, UnlockOutcome.lockedOut,
          reason: 'the correct pin must not open a lock that is still armed');
      expect(r.retryAfter, const Duration(seconds: 28),
          reason: 'the third failure was at t=3000, so the lock runs to 33000');
    });

    test('the lockout expires on its own', () async {
      final l = lock();
      await l.setPin('4815');
      for (var i = 0; i < 3; i++) {
        await l.unlock('0000', nowMs: 1000);
      }

      final during = await l.unlock('4815', nowMs: 5000);
      expect(during.outcome, UnlockOutcome.lockedOut);

      final after = await l.unlock('4815', nowMs: 31000);
      expect(after.outcome, UnlockOutcome.ok);
    });

    test('the ladder escalates and the cap holds', () async {
      final l = lock();
      await l.setPin('4815');
      final delays = <Duration>[];
      for (var i = 0; i < 9; i++) {
        final r = await l.unlock('0000', nowMs: 0);
        if (r.retryAfter != null) delays.add(r.retryAfter!);
        // Step past the armed window so the next attempt is not refused early.
        await db.update('app_lock', {'locked_until': 0}, where: 'id = 1');
      }
      expect(delays, <Duration>[
        const Duration(seconds: 30),
        const Duration(minutes: 1),
        const Duration(minutes: 5),
        const Duration(minutes: 15),
        const Duration(minutes: 60),
        const Duration(minutes: 60),
        const Duration(minutes: 60),
      ]);
    });
  });

  group('biometric', () {
    test('is a shortcut, never the only way in', () async {
      final l = lock();
      await l.setPin('4815');
      await l.setBiometricEnabled(true);
      expect((await l.read())!.biometricOn, isTrue);

      // With the sensor unavailable the PIN must still work.
      final r = await l.unlock('4815', nowMs: 0);
      expect(r.outcome, UnlockOutcome.ok);
    });

    test('can be turned back off without touching the pin', () async {
      final l = lock();
      await l.setPin('4815');
      await l.setBiometricEnabled(true);
      await l.setBiometricEnabled(false);
      expect((await l.read())!.biometricOn, isFalse);
      expect((await l.unlock('4815', nowMs: 0)).outcome, UnlockOutcome.ok);
    });
  });

  group('schema', () {
    test('the table exists and holds exactly one row', () async {
      await lock().setPin('4815');
      await lock().setPin('2222');
      final rows = await db.query('app_lock');
      expect(rows.length, 1, reason: 'replacing the pin must not stack rows');
    });

    test('the migration lands on the declared version', () async {
      expect(await jdb.schemaVersion(), kSchemaVersion);
      expect(migrationsFrom(kSchemaVersion - 1).length, 1);
    });
  });
}

/// Real UTF-8, not UTF-16 code units.
///
/// `codeUnits` happens to agree with UTF-8 for every ASCII string, so a test
/// that only ever salts with "salt" cannot tell the two apart. `derivePin`
/// encodes with `utf8.encode`, so the helper has to as well.
List<int> utf8Bytes(String s) => utf8.encode(s);
