import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/app/vault_locator.dart';
import 'package:path/path.dart' as p;

/// The vault location, and the check that stops it being adopted silently.
///
/// This exists because of a real machine: the author's Documents folder held
/// `JotIt/` — the development project — and the app opened it as a vault
/// without a word. Nothing was destroyed, because JotIt only ever reads
/// `notes/`, but a user's first note landed inside their source tree.
void main() {
  late Directory root;
  late Directory support;
  late Directory docs;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jotit_locator_');
    support = Directory(p.join(root.path, 'support'));
    docs = Directory(p.join(root.path, 'docs'));
    await docs.create(recursive: true);
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  VaultLocator locator() => VaultLocator(support, documentsDir: docs);

  test('with nothing stored the default is Documents/JotIt', () async {
    final chosen = await locator().resolve();
    expect(p.basename(chosen.path), 'JotIt');
    expect(Directory(chosen.path).parent.path, docs.path);
    // Nothing has been agreed to, so the default is still up for question.
    expect(chosen.fromPreference, isFalse);
  });

  test('a stored location wins over the default', () async {
    final wanted = Directory(p.join(root.path, 'notes-here'));
    await locator().store(wanted);

    // A brand new locator, as after a restart.
    final chosen = await locator().resolve();
    expect(chosen.path, wanted.path);
    expect(chosen.fromPreference, isTrue);
  });

  test('keeping the busy default still counts as having chosen it', () async {
    // The whole point of the flag: answering "仍然使用 JotIt" must stop the
    // question coming back on every single launch.
    final busy = Directory(p.join(docs.path, 'JotIt'));
    await Directory(p.join(busy.path, 'lib')).create(recursive: true);
    expect(VaultLocator.inspect(busy), VaultVerdict.occupied);

    await locator().store(busy);
    final chosen = await locator().resolve();

    expect(chosen.path, busy.path);
    expect(chosen.fromPreference, isTrue);
  });

  test('an unreadable settings file falls back to the default', () async {
    // A half-written or foreign file must not be a reason not to start.
    await support.create(recursive: true);
    await File(p.join(support.path, 'jotit.json')).writeAsString('{not json');

    final chosen = await locator().resolve();
    expect(p.basename(chosen.path), 'JotIt');
    expect(chosen.fromPreference, isFalse);
  });

  test('a settings file with a blank path is not a location', () async {
    // Otherwise `""` resolves to the current directory and the app opens
    // whatever the process was launched from.
    await support.create(recursive: true);
    await File(p.join(support.path, 'jotit.json')).writeAsString(
      '{"vault_path": "   "}',
    );

    expect((await locator().resolve()).fromPreference, isFalse);
  });

  group('inspecting a candidate', () {
    test('a folder that does not exist is fresh', () {
      expect(
        VaultLocator.inspect(Directory(p.join(root.path, 'nope'))),
        VaultVerdict.fresh,
      );
    });

    test('an empty folder is safe to create', () async {
      final empty = Directory(p.join(root.path, 'empty'));
      await empty.create();
      expect(VaultLocator.inspect(empty), VaultVerdict.emptyFolder);
    });

    test('a folder that already holds a vault is just a vault', () async {
      final vault = Directory(p.join(root.path, 'vault'));
      await Directory(p.join(vault.path, '.jotit')).create(recursive: true);
      expect(VaultLocator.inspect(vault), VaultVerdict.existingVault);
    });

    test('a folder holding somebody else’s files is occupied', () async {
      // The exact situation: a source tree called JotIt sitting in Documents.
      final busy = Directory(p.join(docs.path, 'JotIt'));
      await Directory(p.join(busy.path, 'lib')).create(recursive: true);

      expect(VaultLocator.inspect(busy), VaultVerdict.occupied);
    });
  });

  test('the .jotit marker alone is what makes a folder a vault', () async {
    // Not `notes/`: a user may well have a notes folder of their own in
    // there, and calling that a vault would be the same mistake in miniature.
    final withNotes = Directory(p.join(root.path, 'has-notes'));
    await Directory(p.join(withNotes.path, 'notes')).create(recursive: true);
    expect(VaultLocator.inspect(withNotes), VaultVerdict.occupied);
    expect(VaultLocator.isVault(withNotes), isFalse);
  });

  group('picking the default directory', () {
    // The Android branch cannot be reached from this machine — `Platform
    // .isAndroid` is false here, and so it is in CI. Pulling the decision out
    // into a function of its arguments is the only way these lines ever get
    // executed by a test. The reason that matters is not theoretical: the
    // Android release APK shipped without an INTERNET permission and without
    // a cleartext policy, and both of those only misbehave on a device.
    Directory docs() => Directory(p.join(root.path, 'internal'));
    Directory ext() => Directory(p.join(root.path, 'external'));

    test('desktop uses the documents directory', () {
      expect(
        chooseDefaultDir(isAndroid: false, documents: docs(), external: ext()).path,
        p.join(docs().path, 'JotIt'),
      );
    });

    test('android uses the external directory', () {
      expect(
        chooseDefaultDir(isAndroid: true, documents: docs(), external: ext()).path,
        p.join(ext().path, 'JotIt'),
      );
    });

    test('android without external storage falls back rather than refusing',
        () {
      // An unmounted volume must not stop the user reaching their notes.
      expect(
        chooseDefaultDir(isAndroid: true, documents: docs(), external: null).path,
        p.join(docs().path, 'JotIt'),
      );
    });

    test('desktop ignores an external directory it was handed', () {
      // Guards against a future caller passing the external one on desktop and
      // quietly moving every existing user's vault.
      expect(
        chooseDefaultDir(isAndroid: false, documents: docs(), external: ext()).path,
        isNot(startsWith(ext().path)),
      );
    });
  });
}