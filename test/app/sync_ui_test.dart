import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/app/vault_session.dart';
import 'package:path/path.dart' as p;

import '../support/boot_app.dart';
import '../support/dav_harness.dart';

/// The wiring, end to end, against a real server and a real sync engine.
///
/// Everything below the UI already had tests; nothing *above* it did. A
/// settings screen that lists remotes it cannot create, or a sync button wired
/// to nothing, passes every other test in the repository and does nothing at
/// runtime — which is exactly the state this file was written after finding it.
///
/// **Every real I/O happens inside `tester.runAsync`** — the pumps, the taps,
/// and the assertions that read the database back. `testWidgets` drives a fake
/// clock; the real event loop does not advance while it is in control, so the
/// sqflite ffi isolate never answers and a `Future` awaited in the test body
/// simply never completes. The failure mode is a hang with no message rather
/// than an error, and `--timeout` cannot interrupt it once the code is inside
/// `runAsync`.
///
/// Never `pumpAndSettle` either: a `CircularProgressIndicator` is on screen
/// while a round runs and it animates forever.
Future<void> act(WidgetTester tester, Future<void> Function() body,
    {int pumps = 20}) async {
  await tester.runAsync(() async {
    await body();
    for (var i = 0; i < pumps; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  });
}

/// Runs a real-I/O read from a test body and returns its value.
Future<T> read<T>(WidgetTester tester, Future<T> Function() body) async {
  late T out;
  await tester.runAsync(() async => out = await body());
  return out;
}

/// Pumps until [finder] matches, on the real clock.
///
/// A fixed number of pumps is a guess: a refused connection answers in
/// milliseconds while a real round against a real server takes longer, and a
/// test that guesses short asserts against a report that has not been written
/// yet. It then finishes with the controller still holding a `Ref` to a
/// disposed container, which surfaces as an UnmountedRefException long after
/// the test has passed or failed.
Future<void> waitFor(
  WidgetTester tester,
  Finder finder, {
  int seconds = 25,
}) async {
  await tester.runAsync(() async {
    final deadline = DateTime.now().add(Duration(seconds: seconds));
    while (finder.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 50));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  });
}

Widget boot(VaultSession vault, Directory root) => bootApp(vault: vault, root: root);

void main() {
  late Directory root;
  late Directory priv;
  late VaultSession vault;
  late DavHarness dav;

  setUp(() async {
    // `flutter_test` installs an `HttpOverrides` that answers every request
    // with 400 and prints a warning nobody reads. A widget test cannot reach a
    // real socket until that is taken back off, and a sync round that never
    // leaves the machine is not a sync round.
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = null);

    dav = await DavHarness.start();
    // The harness starts with an empty directory, and the engine's very first
    // move is an OPTIONS on the collection it was pointed at. A server that
    // answers 400 for a collection it has never heard of fails the round
    // before any note is looked at. The real deployment creates this folder
    // when the vault is set up, so the test creates it too.
    Directory(p.join(dav.root.path, 'notes')).createSync(recursive: true);

    root = await Directory.systemTemp.createTemp('jotit_sync_ui_');
    // The master key lives in private app data, resolved through
    // `path_provider` by default. A widget test has no platform channel to
    // answer it, so the directory is supplied the way the production hook
    // would supply it.
    priv = await Directory.systemTemp.createTemp('jotit_sync_ui_priv_');
    vault = await VaultSession.open(root.path, appDataDir: priv);
  });

  tearDown(() async {
    await vault.close();
    if (root.existsSync()) await root.delete(recursive: true);
    if (priv.existsSync()) await priv.delete(recursive: true);
    await dav.dispose();
  });

  /// Seeds a note **through [act]**, because reindex talks to the database and
  /// a plain `await` in the test body never completes.
  Future<void> seedNote(WidgetTester tester, String notePath, String uid,
      String body) async {
    await act(tester, () async {
      final f = File(p.join(root.path, p.joinAll(notePath.split('/'))));
      await f.parent.create(recursive: true);
      await f.writeAsBytes(
        utf8.encode('---\nuid: $uid\ntitle: T\n---\n\n$body\n'),
        flush: true,
      );
      await vault.reindex();
    }, pumps: 5);
  }

  Future<void> openSettings(WidgetTester tester) async {
    // The settings page is a ListView, which only builds what is on screen.
    // The sync report sits below the root list, so on the default 800x600 test
    // surface it is never constructed and `find.text` cannot see it. A tall
    // window is the honest fix; scrolling would work too but only for the
    // first assertion in each test.
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await act(tester, () async {
      await tester.pumpWidget(boot(vault, root));
      for (var i = 0; i < 30 && find.text('JotIt').evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await tester.tap(find.byIcon(Icons.settings_outlined));
    }, pumps: 30);
  }

  /// Drives the "添加远端" dialog rather than inserting a row directly. A
  /// dialog that cannot be filled in is exactly the kind of breakage this file
  /// is here to catch.
  Future<void> addRemote(WidgetTester tester, String url,
      {String user = 'testuser', String pass = 'test'}) async {
    await act(tester, () async {
      await tester.tap(find.text('添加远端'));
      for (var i = 0;
          i < 20 && find.byKey(const ValueKey('root-pass')).evaluate().isEmpty;
          i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      // Located by key rather than by type: the dialog mixes TextFormField
      // and TextField, and `find.byType(TextFormField)` would only ever see
      // half of them.
      await tester.enterText(find.byKey(const ValueKey('root-name')), '测试 NAS');
      await tester.enterText(find.byKey(const ValueKey('root-url')), url);
      await tester.enterText(find.byKey(const ValueKey('root-user')), user);
      await tester.enterText(find.byKey(const ValueKey('root-pass')), pass);
      await tester.tap(find.text('保存'));
    }, pumps: 30);
  }

  testWidgets('a remote can be created through the settings dialog',
      (tester) async {
    await openSettings(tester);
    expect(find.text('尚未配置远端'), findsOneWidget);

    await addRemote(tester, '${dav.baseUri()}');

    // Persisted, not merely held in a field.
    final roots = await read(tester, () => vault.roots.enabled());
    expect(roots, hasLength(1));
    expect(roots.single.name, '测试 NAS');
    expect(roots.single.baseUrl.endsWith('/'), isTrue,
        reason: 'a base without a trailing slash makes Uri.resolve drop the '
            'last segment and write every note one level too high');
    expect(await read(tester, () => vault.passwordFor(roots.single)), 'test');
  });

  testWidgets('the password is never stored in the clear', (tester) async {
    await openSettings(tester);
    await addRemote(tester, '${dav.baseUri()}');

    final roots = await read(tester, () => vault.roots.enabled());
    final blob = roots.single.credentialBlob;
    expect(blob, isNotNull);
    expect(blob, isNot(contains('test')));
  });

  testWidgets('a failed write is reported instead of swallowed', (tester) async {
    // P1-3: the settings page wrote to the database without a try/catch. A
    // failure — a locked database, a full disk, a cipher that cannot seal —
    // was an unhandled async error: the dialog had closed, the page looked
    // unchanged, and the user believed the remote was saved when it was not.
    await openSettings(tester);

    // The database stops accepting writes.
    await read(tester, () => vault.db.execute('PRAGMA query_only = 1'));

    await addRemote(tester, '${dav.baseUri()}');

    expect(find.textContaining('保存远端失败'), findsOneWidget,
        reason: 'a write that did not happen has to say so');
  });

  testWidgets('a PIN that could not be saved says so', (tester) async {
    // The same hole on the other side of the page. A PIN that failed to
    // write leaves the lock unarmed — the screen is still photographable —
    // and the user walks away believing the app is locked.
    await openSettings(tester);
    await read(tester, () => vault.db.execute('PRAGMA query_only = 1'));

    await act(tester, () async {
      await tester.tap(find.widgetWithText(TextButton, '设置'));
      for (var i = 0;
          i < 20 && find.byKey(const ValueKey('new-pin')).evaluate().isEmpty;
          i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await tester.enterText(find.byKey(const ValueKey('new-pin')), '4815');
      await tester
          .enterText(find.byKey(const ValueKey('new-pin-confirm')), '4815');
      await tester.tap(find.text('保存'));
    }, pumps: 10);
    // The PIN is hashed with 600k PBKDF2 rounds before it reaches the
    // database, so the failure arrives a second or two later.
    await waitFor(tester, find.textContaining('设置 PIN 失败'));

    expect(find.textContaining('设置 PIN 失败'), findsOneWidget,
        reason: 'a lock that was not armed has to say so');
    expect(await read(tester, () => vault.lock.isConfigured()), isFalse,
        reason: 'and the truth is checked against the database, not the page');
  });

  testWidgets('a sync run uploads the vault and reports what it did',
      (tester) async {
    await seedNote(tester, 'notes/a.md', 'u-a', 'first body');

    await openSettings(tester);
    await addRemote(tester, '${dav.baseUri()}');

    await act(tester, () => tester.tap(find.byIcon(Icons.sync)), pumps: 2);
    await waitFor(tester, find.textContaining('上次同步'));

    expect(find.text('上传 1'), findsOneWidget);
    final remote = await read(tester, () => dav.readRemote('notes/a.md'));
    expect(utf8.decode(remote!), contains('first body'));
  });

  testWidgets('a second run with nothing changed reports no change',
      (tester) async {
    await seedNote(tester, 'notes/a.md', 'u-a', 'first body');

    await openSettings(tester);
    await addRemote(tester, '${dav.baseUri()}');
    await act(tester, () => tester.tap(find.byIcon(Icons.sync)), pumps: 2);
    await waitFor(tester, find.text('上传 1'));

    await act(tester, () => tester.tap(find.byIcon(Icons.sync)), pumps: 2);
    // Waiting on "上次同步" here would return instantly: it is already on
    // screen from the first round. Wait for this round's verdict instead.
    await waitFor(tester, find.text('没有变化'));
    expect(find.text('上传 1'), findsNothing);
  });

  testWidgets('an unreachable server is reported, not swallowed',
      (tester) async {
    await seedNote(tester, 'notes/a.md', 'u-a', 'body');

    await openSettings(tester);
    // A port nothing listens on. The failure is a connection error, which is
    // what a user with a typo in the address will actually see.
    await addRemote(tester, 'http://127.0.0.1:1/dav/');

    await act(tester, () => tester.tap(find.byIcon(Icons.sync)), pumps: 2);
    await waitFor(tester, find.textContaining('上次同步'));

    // "上次同步" is the report's own heading and appears nowhere else, so it
    // cannot be confused with the error snackbar, which says 同步失败 and would
    // match a looser search for 失败.
    expect(find.textContaining('上次同步'), findsOneWidget);
    final roots = await read(tester, () => vault.roots.enabled());
    expect(roots.single.lastError, isNotNull,
        reason: 'a failure the user cannot see is a failure that never gets '
            'retried on purpose');
    expect(find.text('没有变化'), findsNothing);
  });

  testWidgets('removing a remote takes it out of the list', (tester) async {
    await openSettings(tester);
    await addRemote(tester, '${dav.baseUri()}');
    expect(find.text('测试 NAS'), findsOneWidget);

    await act(tester, () async {
      await tester.tap(find.text('测试 NAS'));
      for (var i = 0; i < 20 && find.text('编辑远端').evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await tester.tap(find.text('删除'));
    }, pumps: 40);

    expect(find.text('尚未配置远端'), findsOneWidget);
    expect(await read(tester, () => vault.roots.enabled()), isEmpty);
  });

  /// Opens the edit dialog of the one configured remote.
  Future<void> editRemote(WidgetTester tester) async {
    await act(tester, () async {
      await tester.tap(find.text('测试 NAS'));
      for (var i = 0;
          i < 20 && find.text('编辑远端').evaluate().isEmpty;
          i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }, pumps: 10);
  }

  testWidgets('editing a remote without typing a password keeps the saved one',
      (tester) async {
    await openSettings(tester);
    await addRemote(tester, '${dav.baseUri()}');

    await editRemote(tester);
    await act(tester, () async {
      // A URL fix is the edit the user came to make; the password field is
      // deliberately left empty.
      await tester.enterText(
          find.byKey(const ValueKey('root-url')), 'http://127.0.0.1:9/dav/');
      await tester.tap(find.text('保存'));
    }, pumps: 30);

    final roots = await read(tester, () => vault.roots.enabled());
    expect(roots, hasLength(1));
    expect(roots.single.baseUrl, 'http://127.0.0.1:9/dav/',
        reason: 'the edit itself must have taken effect');
    expect(await read(tester, () => vault.passwordFor(roots.single)), 'test',
        reason: '"留空表示不改动已保存的密码" is the helper text the dialog '
            'itself prints; wiping the credential here is the bug');
  });

  testWidgets('a malformed URL is stopped at the form, not on the wire',
      (tester) async {
    await openSettings(tester);

    await act(tester, () async {
      await tester.tap(find.text('添加远端'));
      for (var i = 0;
          i < 20 && find.byKey(const ValueKey('root-pass')).evaluate().isEmpty;
          i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await tester.enterText(find.byKey(const ValueKey('root-name')), '坏地址');
      // The exact input a real user typed: a doubled scheme. It parses as a
      // Uri with host `http`, which is why the old validator let it through.
      await tester.enterText(find.byKey(const ValueKey('root-url')),
          'http://http//nas.example.com:35115/webDAV');
      await tester.enterText(find.byKey(const ValueKey('root-user')), 'testuser');
      await tester.enterText(find.byKey(const ValueKey('root-pass')), 'x');
      await tester.tap(find.text('保存'));
      // Give the validation pass a pump to surface the inline error.
      await tester.pump(const Duration(milliseconds: 50));
    }, pumps: 5);

    // The dialog stayed open and said why, in the user's language.
    expect(find.textContaining('地址格式不对'), findsOneWidget);
    expect(find.byKey(const ValueKey('root-pass')), findsOneWidget);
    expect(await read(tester, () => vault.roots.enabled()), isEmpty,
        reason: 'nothing may be persisted from a form that refused to save');

    // Fixing the address lets the same dialog through.
    await act(tester, () async {
      await tester.enterText(find.byKey(const ValueKey('root-url')),
          '${dav.baseUri()}');
      await tester.tap(find.text('保存'));
    }, pumps: 30);

    final roots = await read(tester, () => vault.roots.enabled());
    expect(roots, hasLength(1));
  });
}