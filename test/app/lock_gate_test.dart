import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/app/app_lock.dart';
import 'package:jotit/app/providers.dart';
import 'package:jotit/app/vault_session.dart';
import 'package:jotit/ui/lock_gate.dart';

/// §8.3, from the outside.
///
/// The AppLock tests prove the backoff is persisted. These prove the thing the
/// user actually touches is in front of the vault: a configured PIN really
/// blocks, a wrong PIN says nothing useful to an attacker, and the countdown
/// comes from the stored deadline rather than from when this process happened
/// to start.
///
/// **Everything below runs inside `tester.runAsync`, including `pumpWidget`
/// itself.** That is not tidiness. `testWidgets` drives a fake clock, and the
/// real event loop never advances while it is in control, so the sqflite ffi
/// isolate behind `isConfigured()` never answers and the gate sits on its
/// spinner forever. Pumping *inside* `runAsync` builds the subtree with the
/// real clock running. The same applies to every write here.
///
/// The PIN is set through a fast [AppLock] rather than the session's own,
/// which runs the full 600k PBKDF2 rounds §8.3 mandates. The iteration count
/// is read back out of the row, so verification is fast too. Nothing here
/// tests the iteration count; `app_lock_test.dart` does, against vectors.
Future<void> bootLocked(WidgetTester tester, VaultSession vault) async {
  await tester.runAsync(() async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [vaultProvider.overrideWith((ref) async => vault)],
        child: const MaterialApp(
          home: LockGate(child: Text('THE VAULT')),
        ),
      ),
    );
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  });
}

/// Returns whether the unlock button was actually there to tap. Once a lockout
/// is armed the widget relabels itself to a countdown, and "there is no button
/// to press" is itself the proof — callers assert on that rather than being
/// handed a silent no-op.
Future<bool> tapUnlock(WidgetTester tester, String pin) async {
  var tapped = false;
  await tester.runAsync(() async {
    await tester.enterText(find.byType(TextField), pin);

    // The countdown is a *real* `Timer.periodic` while we are inside
    // runAsync, so it can rebuild the tree between finding the button and
    // tapping it, leaving the finder holding a deactivated element. Settle
    // first, then locate and tap back to back.
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await tester.pump();

    final button = find.byType(FilledButton);
    if (find.text('解锁').evaluate().isEmpty) return;
    tapped = true;
    await tester.tap(button, warnIfMissed: false);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  });
  return tapped;
}

/// Runs [body] on the real clock and returns its value.
///
/// A plain `await` on anything that touches the disk inside a `testWidgets`
/// body never completes — the continuation is queued in the fake zone, and
/// nothing flushes it once the test has stopped pumping. The failure mode is
/// not an error; the test simply stops, and `flutter test` hangs with the
/// suite looking like it passed. Every such await in this file goes through
/// here.
Future<T> read<T>(WidgetTester tester, Future<T> Function() body) async {
  late T out;
  await tester.runAsync(() async => out = await body());
  return out;
}

/// Unmounts the gate so its countdown timer is cancelled.
///
/// LockGate runs a Timer.periodic while a lockout is armed and cancels it
/// in dispose(). A widget test that ends with the gate still mounted leaves
/// that timer pending, and the test framework waits on it — the suite passes
/// every test and then hangs instead of exiting.
Future<void> unmount(WidgetTester tester) async {
  await tester.runAsync(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  });
}

void main() {
  late Directory root;
  late VaultSession vault;
  late AppLock fast;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jotit_lock_ui_');
    vault = await VaultSession.open(root.path);
    fast = AppLock(vault.db, iterations: 1000);
  });

  tearDown(() async {
    await vault.close();
    if (root.existsSync()) await root.delete(recursive: true);
  });

  testWidgets('with no PIN the vault opens straight away', (tester) async {
    await bootLocked(tester, vault);
    expect(find.text('THE VAULT'), findsOneWidget);
    expect(find.text('JotIt 已锁定'), findsNothing);
  });

  testWidgets('a configured PIN puts a gate in front of it', (tester) async {
    await tester.runAsync(() => fast.setPin('4815'));
    await bootLocked(tester, vault);

    expect(find.text('THE VAULT'), findsNothing,
        reason: 'the whole point of the gate is that the vault is unreachable');
    expect(find.text('JotIt 已锁定'), findsOneWidget);
  });

  testWidgets('the right PIN opens it', (tester) async {
    await tester.runAsync(() => fast.setPin('4815'));
    await bootLocked(tester, vault);

    await tapUnlock(tester, '4815');
    expect(find.text('THE VAULT'), findsOneWidget);
  });

  testWidgets('a wrong PIN is refused and imposes nothing yet',
      (tester) async {
    await tester.runAsync(() => fast.setPin('4815'));
    await bootLocked(tester, vault);

    await tapUnlock(tester, '0000');

    expect(find.text('THE VAULT'), findsNothing);
    expect(find.textContaining('PIN 不对'), findsOneWidget);
    // §8.3 imposes nothing for the first two attempts. Locking a person out
    // for thirty seconds over one fat-fingered tap is how lock screens get
    // turned off for good.
    expect(find.text('请稍候'), findsNothing);
  });

  testWidgets('the third wrong attempt arms the lock', (tester) async {
    await tester.runAsync(() => fast.setPin('4815'));
    await bootLocked(tester, vault);

    for (var i = 0; i < 3; i++) {
      await tapUnlock(tester, '0000');
    }

    expect(find.textContaining('已锁定'), findsOneWidget);
    expect(find.text('THE VAULT'), findsNothing);

    // The button becomes a countdown rather than a second chance. Tapping
    // "解锁" a fourth time is not something the widget tree even offers, so
    // the lock cannot be hurried along by one more impatient tap.
    expect(find.textContaining('请稍候'), findsOneWidget);
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
    await unmount(tester);
  });

  testWidgets('a lockout armed before the restart still holds',
      (tester) async {
    // Arm the lock in a previous "process", then open a second session over
    // the same database. If the gate derived its state from when the widget
    // mounted, the screen would be decorative.
    //
    // The three attempts are timestamped from the real clock. A literal like
    // `1000 + i` reads tidier and is worthless: the gate checks `locked_until`
    // against the real wall clock, so a deadline thirty seconds after 1970 is
    // long expired by the time the widget reads it, the countdown never
    // appears, and the correct PIN walks straight in — a test that passes for
    // the opposite of the reason it exists.
    final base = DateTime.now().millisecondsSinceEpoch;
    await tester.runAsync(() async {
      await fast.setPin('4815');
      for (var i = 0; i < 3; i++) {
        await fast.unlock('0000', nowMs: base + i);
      }
    });
    final stored = await read(tester, fast.read);
    expect(AppLock.isLockedOut(stored!, base), isTrue);
    expect(AppLock.isLockedOut(stored, DateTime.now().millisecondsSinceEpoch),
        isTrue,
        reason: 'a 30s backoff started now has not expired yet');

    final reopened = await read(tester, () => VaultSession.open(root.path));
    addTearDown(reopened.close);

    await bootLocked(tester, reopened);

    // The gate is showing "locked" because it read `locked_until` out of the
    // database, not because this widget happens to be mounted. Without this
    // assertion the rest of the test could pass on a gate that ignored the
    // persisted state entirely.
    expect(find.textContaining('已锁定'), findsOneWidget);

    await tapUnlock(tester, '4815');
    expect(find.text('THE VAULT'), findsNothing,
        reason: 'the correct PIN must not open a lock that is still armed');
    await unmount(tester);
  });
}