import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/app/screen_security.dart';
import 'package:jotit/app/vault_session.dart';

/// §8.3's `FLAG_SECURE`, from the Dart side.
///
/// These cannot prove the flag reaches the window — that needs a device — so
/// they pin the two halves this side is actually responsible for: what gets
/// pushed, and when. The rule being tested is that a configured PIN protects
/// the screen and an absent one does not, because the failure mode of getting
/// it backwards is invisible: screenshots silently stop working for a user who
/// never asked for a lock, and there is no setting anywhere to undo it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(ScreenSecurity.channelName);
  final calls = <MethodCall>[];
  Object? failWith;

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final failure = failWith;
      if (failure != null) throw failure;
      return null;
    });
  }

  setUp(() {
    calls.clear();
    failWith = null;
    install();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('a configured lock pushes the flag on, and an absent one off', () async {
    final security = ScreenSecurity();

    await security.applyForLock(lockConfigured: true);

    expect(calls, hasLength(1));
    expect(calls.single.method, 'setFlagSecure');
    expect(calls.single.arguments, <String, Object?>{'enabled': true});

    calls.clear();
    await security.applyForLock(lockConfigured: false);

    expect(calls.single.arguments, <String, Object?>{'enabled': false},
        reason: 'removing the PIN has to give screenshots back, or the user '
            'is left with a note app they cannot screenshot and cannot fix');
  });

  test('the same state twice pushes once', () async {
    // Startup and the settings screen both report "locked". A duplicate push
    // is not harmful, but if this ever stops being true the channel is being
    // driven from somewhere that never told anyone.
    final security = ScreenSecurity();
    await security.applyForLock(lockConfigured: true);
    await security.applyForLock(lockConfigured: true);
    await security.applyForLock(lockConfigured: false);
    await security.applyForLock(lockConfigured: false);

    expect(calls.map((c) => (c.arguments as Map)['enabled']), [true, false]);
  });

  test('a platform with no such flag is not an error', () async {
    // Windows and macOS have no `FLAG_SECURE`, and neither does a widget test.
    // Windows is a first-class target, so this path runs for real, every run.
    failWith = MissingPluginException('no implementation for setFlagSecure');
    await expectLater(
      ScreenSecurity().applyForLock(lockConfigured: true),
      completes,
    );
  });

  test('a platform that does have it and refuses reports instead of throwing',
      () async {
    // The flag is not worth failing a vault open over, but "silently ignored"
    // is how a lock ends up photographing itself. `onUnavailable` is how the
    // caller finds out.
    final errors = <Object>[];
    failWith = PlatformException(code: 'boom');

    await expectLater(
      ScreenSecurity().applyForLock(
        lockConfigured: true,
        onUnavailable: errors.add,
      ),
      completes,
    );
    expect(errors, hasLength(1));
    expect((errors.single as PlatformException).code, 'boom');
  });

  group('through the session', () {
    late Directory root;
    late VaultSession vault;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('jotit_secure_');
      vault = await VaultSession.open(
        root.path,
        screenSecurity: ScreenSecurity(),
      );
    });

    tearDown(() async {
      await vault.close();
      if (root.existsSync()) await root.delete(recursive: true);
    });

    List<Object?> enabledValues() => calls
        .where((c) => c.method == 'setFlagSecure')
        .map((c) => (c.arguments as Map)['enabled'])
        .toList();

    test('setting a PIN arms the screen, clearing it disarms', () async {
      calls.clear();
      await vault.setPin('4815');
      expect(enabledValues(), [true],
          reason: 'the PIN was just written, so the screen must already be '
              'protected before the user can reach the notes');

      await vault.clearPin();
      expect(enabledValues(), [true, false]);

      // And the invariant itself: the flag tracks the row, not a separate
      // memory of what the UI last did. After clearing, the lock really is
      // gone, so re-reading it must not re-protect the screen.
      expect(await vault.lock.isConfigured(), isFalse);
      calls.clear();
      await vault.syncScreenSecurity();
      expect(enabledValues(), isEmpty);
    });

    test('a lock that was already there is applied at startup', () async {
      // The path that matters most: the process that set the PIN is gone, the
      // recents thumbnail is about to be taken, and the only chance to have
      // protected it is the launch that reads the row back.
      await vault.setPin('4815');

      final reopened = await VaultSession.open(
        root.path,
        screenSecurity: ScreenSecurity(),
      );
      addTearDown(reopened.close);
      calls.clear();

      await reopened.syncScreenSecurity();
      expect(enabledValues(), [true]);
    });

    test('a vault with no PIN is explicitly left unprotected', () async {
      // §8.3 asks for the flag; it does not ask for it unconditionally. A
      // user who never set a lock gets screenshots, and asserting `false` is
      // pushed is what stops this from quietly becoming "always on" later.
      calls.clear();
      await vault.syncScreenSecurity();
      expect(enabledValues(), [false]);
    });
  });
}
