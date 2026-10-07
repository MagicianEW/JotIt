import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/app/providers.dart';
import 'package:jotit/app/vault_locator.dart';
import 'package:jotit/app/vault_session.dart';
import 'package:jotit/ui/vault_location_gate.dart';
import 'package:path/path.dart' as p;

/// The first-run question, end to end.
///
/// `vault_locator_test.dart` covers the decision. This covers the part a user
/// actually meets: the dialog, the two answers, and — the one that matters —
/// the promise that it is asked exactly once.
///
/// **Every tap happens inside `runAsync`.** Both answers record the choice by
/// writing a file, and `testWidgets` drives a fake clock on which that write
/// never completes — so a tap performed in the fake zone looks like it did
/// nothing, and the test then fails on an assertion instead of on the real
/// problem. Same trap, same reason, as `sync_ui_test.dart` is written around.
void main() {
  late Directory root;
  late Directory docs;
  late Directory support;
  late VaultLocator locator;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jotit_gate_');
    docs = Directory(p.join(root.path, 'docs'))..createSync(recursive: true);
    support = Directory(p.join(root.path, 'support'))
      ..createSync(recursive: true);
    locator = VaultLocator(support, documentsDir: docs);
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  /// Puts somebody's files where the default vault location will be.
  Directory occupyDefault() {
    final busy = Directory(p.join(docs.path, 'JotIt'));
    Directory(p.join(busy.path, 'lib')).createSync(recursive: true);
    return busy;
  }

  Widget gate({VaultLocator? over}) => ProviderScope(
        overrides: [
          vaultLocatorProvider.overrideWith((ref) async => over ?? locator),
          // The gate invalidates the vault when the location changes. Nothing
          // in this file reads it, and a provider that never answers costs
          // nothing — whereas a real one would open a database behind a test
          // that has no business opening one.
          vaultProvider.overrideWith((ref) => Completer<VaultSession>().future),
        ],
        child: const MaterialApp(
          home: VaultLocationGate(child: _Child()),
        ),
      );

  /// Taps [body] on the fake clock, then pumps until [finder] matches on the
  /// real one.
  ///
  /// The split matters. The dialog's handlers do real file I/O to record the
  /// answer, and that I/O only makes progress while the test is inside
  /// `runAsync`. The tap itself must not be: dispatching a pointer event and
  /// then waiting for the real event loop deadlocks, because the event loop is
  /// exactly what the tap is waiting on.
  ///
  /// The loop alternates a pump (which flushes the fake microtasks the tap
  /// queued, letting the handler reach its first `await`) with a real delay
  /// (which lets the write itself finish). Neither half alone is enough.
  Future<void> act(
    WidgetTester tester,
    Finder finder, {
    Future<void> Function()? body,
    int seconds = 15,
  }) async {
    if (body != null) await body();
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(Duration(seconds: seconds));
      while (finder.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
  }

  /// Runs [body] on the real clock and returns its value.
  Future<T> read<T>(WidgetTester tester, Future<T> Function() body) async {
    late T out;
    await tester.runAsync(() async => out = await body());
    return out;
  }

  /// Reads the stored location back.
  ///
  /// Same trap as above, one level down: `resolve()` touches the disk, and a
  /// plain `await` on it inside the test body queues its continuation in the
  /// fake zone where nothing ever flushes it. The test does not fail — it
  /// stops, silently, which is the worst possible failure mode and cost an
  /// hour to find.
  Future<VaultLocation> stored(WidgetTester tester) =>
      read(tester, locator.resolve);

  final dialog = find.text('这个文件夹已经有别的东西');
  final child = find.byKey(_Child.marker);

  testWidgets('a busy default is asked about before anything is written',
      (tester) async {
    final busy = occupyDefault();
    await tester.pumpWidget(gate());
    await act(tester, dialog);

    expect(dialog, findsOneWidget);
    // The question names the folder and says why it is a problem, so the
    // answer is about that folder.
    expect(find.textContaining('它不是空的'), findsOneWidget);
    expect(
      tester.widget<SelectableText>(find.byType(SelectableText)).data,
      startsWith(busy.path),
    );
    // A fresh location is offered rather than made up from nothing.
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      p.join(docs.path, 'JotIt 笔记'),
    );
    // And nothing has been adopted yet.
    expect(child, findsNothing);
    expect(Directory(p.join(busy.path, 'notes')).existsSync(), isFalse);
  });

  testWidgets('accepting the offered location stores it and opens the app',
      (tester) async {
    occupyDefault();
    await tester.pumpWidget(gate());
    await act(tester, dialog);

    final offered = p.join(docs.path, 'JotIt 笔记');
    await act(tester, child, body: () => tester.tap(find.text('用这个位置')));

    expect(child, findsOneWidget);
    expect((await stored(tester)).path, offered);
  });

  testWidgets('typing another path is what gets stored', (tester) async {
    occupyDefault();
    await tester.pumpWidget(gate());
    await act(tester, dialog);

    final wanted = p.join(root.path, 'elsewhere');
    await act(tester, child, body: () async {
      await tester.enterText(find.byType(TextField), wanted);
      await tester.tap(find.text('用这个位置'));
    });

    expect(child, findsOneWidget);
    expect((await stored(tester)).path, wanted);
  });

  testWidgets('keeping the busy default is remembered and never asked again',
      (tester) async {
    final busy = occupyDefault();
    await tester.pumpWidget(gate());
    await act(tester, dialog);
    await act(tester, child,
        body: () => tester.tap(find.text('仍然使用 JotIt')));
    expect(child, findsOneWidget);

    // A fresh launch with a brand new locator, exactly as after a restart.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
        gate(over: VaultLocator(support, documentsDir: docs)));
    await act(tester, child);

    expect(dialog, findsNothing);
    expect(child, findsOneWidget);
    expect((await stored(tester)).path, busy.path);
  });

  testWidgets('an empty path is refused rather than stored', (tester) async {
    occupyDefault();
    await tester.pumpWidget(gate());
    await act(tester, dialog);

    await act(tester, dialog, body: () async {
      await tester.enterText(find.byType(TextField), '   ');
      await tester.tap(find.text('用这个位置'));
    });

    // Still asking, and still nothing stored: `Directory('')` would have
    // pointed the vault at whatever directory the process was launched from.
    expect(dialog, findsOneWidget);
    expect((await stored(tester)).fromPreference, isFalse);
  });

  testWidgets('an empty default is not worth a question', (tester) async {
    await tester.pumpWidget(gate());
    await act(tester, child);

    expect(dialog, findsNothing);
    expect(child, findsOneWidget);
  });

  testWidgets('an existing vault is just opened', (tester) async {
    Directory(p.join(docs.path, 'JotIt', '.jotit')).createSync(recursive: true);
    await tester.pumpWidget(gate());
    await act(tester, child);

    expect(dialog, findsNothing);
    expect(child, findsOneWidget);
  });

  testWidgets('a locator that cannot answer opens the door anyway',
      (tester) async {
    // The gate stands in front of the user's own notes. A platform channel
    // that is not answering must not leave them staring at a spinner — and
    // the failure is still reported, not swallowed.
    final errors = <Object>[];
    final previous = FlutterError.onError;
    FlutterError.onError = (details) => errors.add(details.exception);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        vaultLocatorProvider.overrideWith(
          (ref) async => throw StateError('no platform channel here'),
        ),
      ],
      child: const MaterialApp(home: VaultLocationGate(child: _Child())),
    ));
    await act(tester, child);

    FlutterError.onError = previous;

    expect(child, findsOneWidget);
    expect(dialog, findsNothing);
    expect(errors, isNotEmpty);
  });
}

class _Child extends StatelessWidget {
  const _Child();

  static const marker = ValueKey('the real app');

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Text('笔记列表', key: marker));
}
