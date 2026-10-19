import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/data/vault/path_lock.dart';

/// The lock exists to make a save and the scanner's uid backfill mutually
/// exclusive per path. What that means in observable terms: bodies on the same
/// key never interleave, bodies on different keys do not queue behind each
/// other, and a throwing body neither poisons the lock nor leaks bookkeeping.
void main() {
  late PathLock lock;

  setUp(() => lock = PathLock());

  test('bodies on the same key run one at a time, in call order', () async {
    final log = <String>[];
    Future<void> body(String name) => lock.synchronized('k', () async {
          log.add('$name-start');
          await Future<void>.delayed(const Duration(milliseconds: 20));
          log.add('$name-end');
        });

    await Future.wait<void>([body('a'), body('b'), body('c')]);

    expect(log, ['a-start', 'a-end', 'b-start', 'b-end', 'c-start', 'c-end'],
        reason: 'any interleaving here is the uid-drift race, widened');
  });

  test('different keys do not queue behind each other', () async {
    final both = Completer<void>();
    Future<void> hold(String key) => lock.synchronized(key, () => both.future);

    final a = hold('a');
    final b = hold('b');
    // 两条不同路径的持有者必须同时在场：任一等在另一条前面都会让
    // "两篇笔记同时保存"变成串行，锁就失去了按路径隔离的意义。
    await Future<void>.delayed(const Duration(milliseconds: 50));
    both.complete();
    await Future.wait<void>([a, b]);
    expect(lock.trackedKeys, 0);
  });

  test('a throwing body reaches its caller and frees the key', () async {
    final first = Completer<void>();
    final second = Completer<void>();

    final failing = lock.synchronized('k', () async {
      await first.future;
      throw StateError('boom');
    });
    final waiting = lock.synchronized('k', () async {
      await second.future;
      return 'ok';
    });

    first.complete();
    second.complete();

    await expectLater(failing, throwsA(isA<StateError>()));
    expect(await waiting, 'ok',
        reason: 'the next waiter must start from a clean slate');
    expect(lock.trackedKeys, 0,
        reason: 'an unused key must not accumulate in the map');
  });

  test('many sequential users of one key leave no bookkeeping', () async {
    for (var i = 0; i < 50; i++) {
      await lock.synchronized('k', () async => i);
    }
    expect(lock.trackedKeys, 0);
  });
}
