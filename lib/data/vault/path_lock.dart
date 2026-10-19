/// A per-key asynchronous mutex.
///
/// **Why this exists.** Two read-modify-write sequences on the same note file
/// can interleave in Dart despite single-threadedness, because every `await` is
/// a yield point:
///
///  * a **save** composes the new text (inheriting the file's uid), writes the
///    file, then calls `ensureUid` — and if both read points saw no uid, the
///    save writes uid-less text and mints a *fresh* uid afterwards;
///  * the **scanner's uid backfill** does the same shape: read, mint, write.
///
/// Interleaved, the backfill stamps uid A while the save's earlier read (which
/// saw no uid) clobbers the file and mints uid B. The note's identity (ADR-2)
/// has silently drifted, and nothing on screen says so. The only cure is to
/// make the two sequences mutually exclusive per path — re-reading before the
/// write narrows the window but leaves it open.
///
/// The lock is keyed per path so two notes being saved at once do not queue
/// behind each other, and the scanner's backfill of note B never waits on a
/// save of note A.
///
/// **Not reentrant.** A body that calls [synchronized] again on the same key
/// deadlocks. Callers therefore take the lock around the *whole* sequence and
/// leave the primitives (`ensureUid`, `writeAtomic`) lock-free.
library;

import 'dart:async';

class PathLock {
  final Map<String, Future<void>> _tails = <String, Future<void>>{};

  /// Runs [body] while holding the lock for [key].
  ///
  /// Bodies run one at a time in call order. A body that throws does not
  /// poison the lock: the error reaches its own caller, and the next waiter
  /// starts from a clean slate.
  Future<T> synchronized<T>(String key, Future<T> Function() body) async {
    // Synchronous section — no await between reading and installing the
    // completer, so two callers with the same key cannot both think they are
    // first. Dart runs this without interruption.
    final previous = _tails.putIfAbsent(key, () => Future<void>.value());
    final done = Completer<void>();
    _tails[key] = done.future;

    try {
      await previous;
      return await body();
    } finally {
      done.complete();
      // Drop the bookkeeping once nobody else has queued behind this holder,
      // so a long-lived vault does not accumulate one entry per note ever
      // saved. If someone *did* queue, their future is now the tail and the
      // key must stay.
      if (identical(_tails[key], done.future)) _tails.remove(key);
    }
  }

  /// Number of keys currently tracked. Exposed for tests and diagnostics.
  int get trackedKeys => _tails.length;
}
