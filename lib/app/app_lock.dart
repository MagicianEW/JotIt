import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sqflite_common/sqlite_api.dart';

/// The application lock of v3.0 §8.3.
///
/// Its reason for existing is P2-18: **the PIN backoff has to be persistent.**
/// A lockout counter held in memory resets the instant the process is killed,
/// which is precisely what somebody trying four-digit PINs wants — try, quit,
/// restart, try again. Everything else here (PBKDF2, no plaintext, no logging)
/// is table stakes; the persisted deadline is the fix.
///
/// Biometric unlock is a shortcut, never a requirement: §8.3 says a device
/// without a working sensor falls back to the PIN, so the PIN always remains
/// the way in and can never be disabled from here.
class AppLock {
  AppLock(this._db, {Random? random, this.iterations = kIterations})
      : _random = random ?? Random.secure();

  final DatabaseExecutor _db;
  final Random _random;

  /// §8.3: PBKDF2-HMAC-SHA256, at least 600k iterations.
  static const int kIterations = 600000;

  static const int kSaltBytes = 16;
  static const int kKeyBytes = 32;

  /// The published ladder: nothing before the third attempt, then
  /// 30s, 1min, 5min, 15min, and 60min forever after.
  static const List<Duration> kLadder = <Duration>[
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 5),
    Duration(minutes: 15),
    Duration(minutes: 60),
  ];

  final int iterations;

  /// The row as stored, or null when no PIN has been set.
  Future<LockState?> read() async {
    final rows = await _db.query('app_lock', where: 'id = 1', limit: 1);
    if (rows.isEmpty) return null;
    final r = rows.first;
    return LockState(
      pinHash: r['pin_hash']! as String,
      salt: r['salt']! as String,
      iterations: r['iterations']! as int,
      failedAttempts: r['failed_attempts'] as int? ?? 0,
      lockedUntil: r['locked_until'] as int? ?? 0,
      biometricOn: (r['biometric_on'] as int? ?? 0) == 1,
      updatedAt: r['updated_at'] as int? ?? 0,
    );
  }

  Future<bool> isConfigured() async => await read() != null;

  /// Sets or replaces the PIN. Wipes the failure state, because a new PIN is a
  /// new start rather than a continuation of whatever the old one was.
  Future<void> setPin(String pin) async {
    final salt = _randomSalt();
    final hash = derivePin(pin, salt: salt, iterations: iterations);
    await _db.insert(
      'app_lock',
      {
        'id': 1,
        'pin_hash': hash,
        'salt': hex(salt),
        'iterations': iterations,
        'failed_attempts': 0,
        'locked_until': 0,
        'biometric_on': 0,
        'updated_at': _nowMs(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Turns the lock off, for a user who set one and then changed their mind.
  ///
  /// Removes the row rather than blanking the columns: a lock whose hash is
  /// the empty string is a lock that every PIN opens.
  Future<void> clear() async {
    await _db.delete('app_lock', where: 'id = 1');
  }

  Future<void> setBiometricEnabled(bool enabled) async {
    await _db.update('app_lock', {'biometric_on': enabled ? 1 : 0},
        where: 'id = 1');
  }

  /// Attempts to unlock. Returns what the caller should do next.
  ///
  /// [nowMs] is injected so the backoff can be tested without waiting an
  /// actual minute.
  Future<UnlockResult> unlock(String pin, {required int nowMs}) async {
    final state = await read();
    if (state == null) {
      return const UnlockResult(UnlockOutcome.notConfigured);
    }

    if (state.lockedUntil > nowMs) {
      // The deadline is read from the database, so a process restart cannot
      // buy extra guesses.
      return UnlockResult(
        UnlockOutcome.lockedOut,
        retryAfter: Duration(milliseconds: state.lockedUntil - nowMs),
        lockedUntil: state.lockedUntil,
        failedAttempts: state.failedAttempts,
      );
    }

    final expected = state.pinHash;
    final actual = derivePin(
      pin,
      salt: Uint8List.fromList(_unhex(state.salt)),
      iterations: state.iterations,
    );

    if (_constantTimeEquals(expected, actual)) {
      await _db.update(
        'app_lock',
        {'failed_attempts': 0, 'locked_until': 0, 'updated_at': nowMs},
        where: 'id = 1',
      );
      return const UnlockResult(UnlockOutcome.ok);
    }

    final attempts = state.failedAttempts + 1;
    final delay = backoffFor(attempts);
    final lockedUntil = delay == null ? 0 : nowMs + delay.inMilliseconds;
    await _db.update(
      'app_lock',
      {
        'failed_attempts': attempts,
        'locked_until': lockedUntil,
        'updated_at': nowMs,
      },
      where: 'id = 1',
    );
    return UnlockResult(
      UnlockOutcome.wrongPin,
      retryAfter: delay,
      lockedUntil: lockedUntil,
      failedAttempts: attempts,
    );
  }

  /// How long the lockout lasts after [attempts] failures, or null when the
  /// attempt is still free.
  ///
  /// Nothing is imposed for the first two tries — locking a person out for
  /// thirty seconds over one fat-fingered tap is how lock screens get turned
  /// off permanently.
  static Duration? backoffFor(int attempts) {
    if (attempts < 3) return null;
    final index = attempts - 3;
    return index >= kLadder.length ? kLadder.last : kLadder[index];
  }

  /// True when the lock is active at [nowMs].
  static bool isLockedOut(LockState state, int nowMs) =>
      state.lockedUntil > nowMs;

  /// PBKDF2-HMAC-SHA256, hex-encoded.
  ///
  /// Implemented here rather than pulled in as a dependency because the spec
  /// pins the exact function, and a library would add a transitive crypto
  /// surface to a note app for no other reason.
  ///
  /// [length] is a parameter of the primitive, not of the feature: a stored PIN
  /// is always [kKeyBytes], but pinning it to one block means the block
  /// counter's big-endian encoding is never executed, and that encoding is
  /// exactly the sort of thing that is wrong until proven otherwise.
  static String derivePin(
    String pin, {
    required Uint8List salt,
    required int iterations,
    int length = kKeyBytes,
  }) {
    final out = _pbkdf2(
      utf8.encode(pin),
      salt: salt,
      iterations: iterations,
      length: length,
    );
    return hex(out);
  }

  static Uint8List _pbkdf2(
    List<int> password, {
    required Uint8List salt,
    required int iterations,
    required int length,
  }) {
    // The HMAC key is the PIN; the message is the PBKDF2 block. Swapping those
    // two is the classic way to write a KDF that is self-consistent and wrong:
    // it still verifies against itself, it just is not PBKDF2.
    //
    // `convert` on a crypto Hmac is a pure function of the message, so one
    // instance serves all 600k rounds.
    final mac = Hmac(sha256, password);

    final blockCount = (length + 31) ~/ 32;
    final out = Uint8List(blockCount * 32);

    for (var block = 1; block <= blockCount; block++) {
      final input = Uint8List(salt.length + 4)
        ..setRange(0, salt.length, salt)
        ..[salt.length] = (block >> 24) & 0xff
        ..[salt.length + 1] = (block >> 16) & 0xff
        ..[salt.length + 2] = (block >> 8) & 0xff
        ..[salt.length + 3] = block & 0xff;

      var u = Uint8List.fromList(mac.convert(input).bytes);
      final acc = Uint8List.fromList(u);

      for (var i = 1; i < iterations; i++) {
        u = Uint8List.fromList(mac.convert(u).bytes);
        for (var j = 0; j < acc.length; j++) {
          acc[j] ^= u[j];
        }
      }
      out.setRange((block - 1) * 32, block * 32, acc);
    }

    // Copy first, wipe second. `sublistView` aliases rather than copies, so
    // zeroing `out` through a view of `out` would hand back a row of zeros —
    // and every PIN would then hash to the same thing and verify against
    // every other PIN.
    final result = Uint8List.fromList(Uint8List.sublistView(out, 0, length));
    for (var i = 0; i < out.length; i++) {
      out[i] = 0;
    }
    // The PIN arrived as a Dart String and is unreachable from here; what we
    // can clear is the derived key material, and that is now zeroed.
    return result;
  }

  Uint8List _randomSalt() {
    final salt = Uint8List(kSaltBytes);
    for (var i = 0; i < kSaltBytes; i++) {
      salt[i] = _random.nextInt(256);
    }
    return salt;
  }

  static int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  /// Compares two hex strings without an early exit.
  ///
  /// `==` on two short strings leaks the match position through timing. For a
  /// four-digit PIN checked a few times an hour that is academic, but the cost
  /// of doing this properly is four lines and there is no reason not to.
  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}

/// The persisted lock state.
class LockState {
  const LockState({
    required this.pinHash,
    required this.salt,
    required this.iterations,
    required this.failedAttempts,
    required this.lockedUntil,
    required this.biometricOn,
    required this.updatedAt,
  });

  final String pinHash;
  final String salt;
  final int iterations;
  final int failedAttempts;

  /// Epoch ms. Non-zero while a lockout is armed.
  final int lockedUntil;

  final bool biometricOn;
  final int updatedAt;
}

enum UnlockOutcome {
  /// No PIN has been set; the app is open.
  notConfigured,

  ok,
  wrongPin,

  /// Refused before the PIN was even checked.
  lockedOut,
}

class UnlockResult {
  const UnlockResult(
    this.outcome, {
    this.retryAfter,
    this.lockedUntil = 0,
    this.failedAttempts = 0,
  });

  final UnlockOutcome outcome;

  /// How long until the lockout expires, when one is in force.
  final Duration? retryAfter;

  final int lockedUntil;
  final int failedAttempts;

  bool get isOk => outcome == UnlockOutcome.ok ||
      outcome == UnlockOutcome.notConfigured;
}

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

List<int> _unhex(String s) {
  final out = <int>[];
  for (var i = 0; i + 1 < s.length; i += 2) {
    out.add(int.parse(s.substring(i, i + 2), radix: 16));
  }
  return out;
}
