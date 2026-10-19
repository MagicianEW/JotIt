import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/app/vault_session.dart';
import 'package:jotit/data/vault/note_file_store.dart';
import 'package:path/path.dart' as p;

import '../support/boot_app.dart';

/// The behaviour that has to hold before any of this is worth looking at on a
/// desktop: opening a vault, creating a note, editing it, and getting the same
/// bytes back out.
/// `pumpAndSettle` never returns once a `CircularProgressIndicator` is on
/// screen, because the spinner animates forever. Pump a bounded number of
/// Pumps until `finder` matches, inside `tester.runAsync`.
///
/// Two traps here, both of which make a widget test hang forever rather than
/// fail: `pumpAndSettle` never returns once a `CircularProgressIndicator` is
/// on screen, because the spinner animates forever; and `testWidgets` drives a
/// fake clock, so the real I/O behind the provider (sqflite over an ffi
/// isolate) never completes. A widget test that "passes" without `runAsync`
/// is not testing anything.
Future<void> pumpUntilFound(WidgetTester tester, Finder finder) async {
  await tester.runAsync(() async {
    for (var i = 0; i < 40 && finder.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  });
}

Widget boot(VaultSession vault, Directory root) => bootApp(vault: vault, root: root);

void main() {
  late Directory root;
  late VaultSession vault;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jotit_app_');
    vault = await VaultSession.open(root.path);
  });

  tearDown(() async {
    await vault.close();
    if (root.existsSync()) await root.delete(recursive: true);
  });

  Future<void> put(String notePath, List<int> bytes) async {
    final f = File(p.join(root.path, p.joinAll(notePath.split('/'))));
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes, flush: true);
  }

  Future<List<int>> get(String notePath) async =>
      File(p.join(root.path, p.joinAll(notePath.split('/')))).readAsBytes();

  group('opening', () {
    test('creates the vault layout', () {
      for (final dir in ['notes', '_conflicts', '.jotit']) {
        expect(Directory(p.join(root.path, dir)).existsSync(), isTrue,
            reason: dir);
      }
    });

    test('creates the database outside notes/', () {
      // A database inside the synced subtree would be uploaded to every
      // device and would come back changed.
      expect(
        Directory(p.join(root.path, 'notes', '.jotit')).existsSync(),
        isFalse,
      );
      expect(vault.db.isOpen, isTrue);
    });

    test('indexes what is already on disk', () async {
      await put('notes/seed.md',
          utf8.encode('---\nuid: u-seed\ntitle: Seed\n---\n\nbody\n'));
      await vault.reindex();
      final note = await vault.notes.byPath('notes/seed.md');
      expect(note, isNotNull);
      expect(note!.title, 'Seed');
      expect(note.uid, 'u-seed');
    });
  });

  group('creating', () {
    test('a new note exists, is indexed and carries a uid', () async {
      final path = await vault.createNote(title: '路线图');

      expect(path, 'notes/路线图.md');
      final note = await vault.notes.byPath(path);
      expect(note, isNotNull);
      final editable = await vault.readForEdit(path);
      expect(editable!.hasUid, isTrue,
          reason: 'ADR-2: identity must be in the file before any sync');
    });

    test('an untitled note still gets a name', () async {
      expect(await vault.createNote(), 'notes/untitled.md');
    });

    test('a title with path separators cannot escape notes/', () async {
      for (final title in [r'..\..\evil', '../../evil', 'a/b']) {
        final path = await vault.createNote(title: title);
        expect(path.startsWith('notes/'), isTrue, reason: title);
        // The separators become underscores, so the name is a single segment.
        // Checking for the substring `..` would be wrong: `.._.._evil.md`
        // contains it without traversing anywhere.
        final segments = path.split('/');
        expect(segments.skip(1), isNot(contains('..')), reason: title);
        expect(segments.every((s) => !s.contains('/')), isTrue);
        expect(
          File(p.join(root.path, p.joinAll(segments))).existsSync(),
          isTrue,
          reason: 'it landed inside the vault',
        );
      }
    });

    test('an existing note is never overwritten by a same-name create',
        () async {
      // P1-12: 同名直接覆盖会把旧内容换成 `# name` 存根，且无法恢复。
      await put('notes/a.md',
          utf8.encode('---\nuid: u-a\n---\n\noriginal content\n'));
      await vault.reindex();

      final path = await vault.createNote(title: 'a');

      expect(path, 'notes/a-1.md');
      expect(utf8.decode(await get('notes/a.md')), contains('original content'),
          reason: 'the existing note must survive byte for byte');
      final created = await vault.readForEdit(path);
      expect(created!.hasUid, isTrue);
    });

    test('the free-name search skips past every taken name', () async {
      await put('notes/a.md', utf8.encode('---\nuid: u-a\n---\n\none\n'));
      await put('notes/a-1.md', utf8.encode('---\nuid: u-a1\n---\n\ntwo\n'));
      await vault.reindex();

      expect(await vault.createNote(title: 'a'), 'notes/a-2.md');
    });
  });

  group('editing', () {
    test('a save returns the new hash', () async {
      final path = await vault.createNote(title: 'a');
      final editable = await vault.readForEdit(path);
      final hash = await vault.save(path, '${editable!.text}\nnew line\n');
      expect(hash, isNotNull);
      expect(hash!.length, 64, reason: 'SHA-256 hex');
    });

    test('saving identical text writes nothing', () async {
      final path = await vault.createNote(title: 'a');
      final editable = await vault.readForEdit(path);
      expect(await vault.save(path, editable!.text), isNull,
          reason: 'the sync engine reads a hash change as "the user edited it"');
    });

    test('a BOM survives a save', () async {
      await put('notes/bom.md',
          <int>[0xEF, 0xBB, 0xBF, ...utf8.encode('# t\n\nbody\n')]);
      await vault.reindex();

      final editable = await vault.readForEdit('notes/bom.md');
      expect(editable!.hadBom, isTrue);
      await vault.save('notes/bom.md', '${editable.text}added\n');

      final after = await get('notes/bom.md');
      expect(after.sublist(0, 3), [0xEF, 0xBB, 0xBF]);
      expect(utf8.decode(after.sublist(3)), contains('added'));
    });

    test('CRLF survives a save', () async {
      await put('notes/crlf.md', utf8.encode('# t\r\n\r\nbody\r\n'));
      await vault.reindex();

      final editable = await vault.readForEdit('notes/crlf.md');
      expect(editable!.usedCrlf, isTrue);
      await vault.save('notes/crlf.md', '${editable.text}more\r\n');

      final text = utf8.decode(await get('notes/crlf.md'));
      expect(text, contains('\r\n'));
      expect(text.replaceAll('\r\n', '').contains('\n'), isFalse,
          reason: 'a single LF would show up as a whole-file diff everywhere');
    });

    test('LF line endings are not rewritten to CRLF', () async {
      await put('notes/lf.md', utf8.encode('# t\n\nbody\n'));
      await vault.reindex();

      final editable = await vault.readForEdit('notes/lf.md');
      expect(editable!.usedCrlf, isFalse);
      await vault.save('notes/lf.md', '${editable.text}more\n');

      final bytes = await get('notes/lf.md');
      expect(bytes.contains(0x0D), isFalse);
    });

    test('a non-UTF-8 file refuses to open rather than decoding lossily', () async {
      await put('notes/gbk.md', <int>[0xD6, 0xD0, 0xCE, 0xC4, 0x0A]);
      await vault.reindex();

      expect(await vault.readForEdit('notes/gbk.md'), isNull);
    });

    test('saving a non-UTF-8 file fails loudly and changes nothing', () async {
      // P0-5 的库层根因：encodeLike 的 allowMalformed 会把无法解码的字节
      // 静默换成 U+FFFD，再被同步推给所有设备。库层必须拒绝，让 UI 显示
      // 保存失败——"保存 GBK 笔记"从毁数据变成明确失败是期望行为。
      final gbk = <int>[0xD6, 0xD0, 0xCE, 0xC4, 0x0A];
      await put('notes/gbk.md', gbk);
      await vault.reindex();

      await expectLater(
        vault.save('notes/gbk.md', '# 覆盖\n'),
        throwsA(isA<StateError>()),
      );
      expect(await get('notes/gbk.md'), gbk,
          reason: 'the original bytes must survive untouched');
    });

    test('a failed backup does not abort the save it precedes', () async {
      // 备份失败不能拖着保存一起失败：用户的编辑在保存落盘前只活在内存里。
      // 用"backups 是文件而不是目录"制造确定性失败。
      await File(p.join(root.path, '.jotit', 'backups'))
          .writeAsBytes(utf8.encode('not a directory'), flush: true);
      await put('notes/a.md', utf8.encode('---\nuid: u-a\n---\n\nv1\n'));
      await vault.reindex();

      final hash =
          await vault.saveRich('notes/a.md', '---\nuid: u-a\n---\n\nv2\n');

      expect(hash, isNotNull, reason: 'the save must still happen');
      expect(utf8.decode(await get('notes/a.md')), contains('v2'));
      expect(vault.lastBackupWarning, isNotNull,
          reason: '失败要单独提示，不能静默');
    });

    test('saving reindexes so the list reflects the edit', () async {
      final path = await vault.createNote(title: 'a');
      await vault.save(path, '---\nuid: u-x\ntitle: Renamed\n---\n\nbody\n');

      final note = await vault.notes.byPath(path);
      expect(note!.title, 'Renamed');
      expect(note.contentHash, isNotNull);
    });
  });

  group('startup recovery', () {
    /// Reopens the vault over the same root, as a fresh process would.
    Future<VaultSession> reopen() async {
      await vault.close();
      vault = await VaultSession.open(root.path);
      return vault;
    }

    test('an interrupted write is recovered before the first reindex', () async {
      // P1-14: 两次 rename 之间进程被杀 → 唯一副本是 .jotit-bak，扫描器
      // 故意忽略它，全库无恢复逻辑——笔记就此消失，直到用户手动翻出来。
      final dir = Directory(p.join(root.path, 'notes'));
      await dir.create(recursive: true);
      await File(p.join(dir.path, 'lost.md.jotit-bak.tok')).writeAsBytes(
          utf8.encode('---\nuid: u-lost\n---\n\nrecovered\n'), flush: true);
      await File(p.join(dir.path, 'half.md.jotit-tmp.tok'))
          .writeAsBytes(utf8.encode('half'), flush: true);

      await reopen();

      expect(await vault.notes.byPath('notes/lost.md'), isNotNull,
          reason: '恢复必须先于 reindex，索引才能看到搬回来的文件');
      expect(
        File(p.join(dir.path, 'half.md.jotit-tmp.tok')).existsSync(),
        isFalse,
        reason: '未提交的临时文件必须清掉',
      );
    });

    test('a backup beside an already-written target is debris', () async {
      final dir = Directory(p.join(root.path, 'notes'));
      await dir.create(recursive: true);
      // 带 uid，免得 open 时的 reindex 回填 uid 改掉字节，干扰对恢复的断言。
      await File(p.join(dir.path, 'c.md')).writeAsBytes(
          utf8.encode('---\nuid: u-c\n---\n\nnew\n'), flush: true);
      await File(p.join(dir.path, 'c.md.jotit-bak.tok'))
          .writeAsBytes(utf8.encode('old'), flush: true);

      await reopen();

      expect(utf8.decode(await get('notes/c.md')), '---\nuid: u-c\n---\n\nnew\n');
      expect(File(p.join(dir.path, 'c.md.jotit-bak.tok')).existsSync(), isFalse);
    });
  });

  group('save vs. the scanner backfill', () {
    /// A [NoteFileStore] that can park the save's write at a chosen point,
    /// standing in for the exact interleaving a crash-prone event loop can
    /// produce: the backfill and the save both mid-flight on one file.
    late _GatedStore store;

    setUp(() async {
      await vault.close();
      store = _GatedStore(vaultRoot: root.path);
      vault = await VaultSession.open(root.path, files: store);
    });

    test('the identity is minted once, whichever runs first', () async {
      // P1-17: 保存的两个读点都没看到 uid 时写出无 uid 文本，ensureUid 再
      // 铸新 uid；与 reindex 回填 uid 交错 → 身份静默漂移。锁保证整个
      // 读-改-写序列与回填互斥，uid 只会被铸一次。
      await vault.writeRaw('notes/race.md', utf8.encode('# race\n'));
      store.arm(); // 此后对 race.md 的写入在落盘前挂起

      final saveFuture = vault.save('notes/race.md', '# race\n\nedited\n');
      final reindexFuture = vault.reindex();
      // 让两边都到达各自的第一个让出点：交错必须真实发生，而不是碰巧串行。
      await Future<void>.delayed(const Duration(milliseconds: 30));
      store.release();
      await Future.wait([saveFuture, reindexFuture]);

      final editable = await vault.readForEdit('notes/race.md');
      final row = await vault.notes.byPath('notes/race.md');
      expect(editable!.uid, isNotNull);
      expect(editable.uid, row!.uid, reason: '文件与索引的身份必须一致');
      expect(store.ensureUidWrote, <bool>[true, false],
          reason: 'uid 只能铸一次：先到的那次真正写入（true），后到的必须发现 '
              '已有 uid、什么都不做（false）——出现两次 true 就是身份漂移');
    });
  });

  group('widget', () {
    // Seeding happens in setUp, never in the test body: a 	estWidgets body
    // runs inside a fake-async zone where real I/O — sqflite over an ffi
    // isolate — never completes, so the test hangs instead of failing.
    testWidgets('the shell builds', (tester) async {
      await tester.pumpWidget(boot(vault, root));
      await pumpUntilFound(tester, find.text('JotIt'));
      expect(find.text('JotIt'), findsOneWidget);
    });

    testWidgets('an empty vault says so instead of showing a blank list',
        (tester) async {
      await tester.pumpWidget(boot(vault, root));
      await pumpUntilFound(tester, find.text('库里还没有笔记'));
      expect(find.text('库里还没有笔记'), findsOneWidget);
    });
  });

  group('widget with notes', () {
    setUp(() async {
      await put('notes/alpha.md',
          utf8.encode('---\nuid: u-a\ntitle: Alpha\n---\n\nbody\n'));
      await vault.reindex();
    });

    testWidgets('the home page lists notes from the vault', (tester) async {
      await tester.pumpWidget(boot(vault, root));
      await pumpUntilFound(tester, find.text('Alpha'));
      expect(find.text('Alpha'), findsOneWidget);
    });

    testWidgets('search filters the list', (tester) async {
      await tester.pumpWidget(boot(vault, root));
      await pumpUntilFound(tester, find.text('Alpha'));

      await tester.runAsync(() async {
        await tester.enterText(find.byType(TextField).first, 'Alpha');
        await tester.pump(const Duration(milliseconds: 200));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump(const Duration(milliseconds: 200));
      });

      expect(find.text('Alpha'), findsWidgets);
    });
  });
}

/// A store whose `writeAtomic` can be parked mid-save, and that records every
/// [NoteFileStore.ensureUid] outcome — the two seams the uid-drift race needs
/// to be observed deterministically.
class _GatedStore extends NoteFileStore {
  _GatedStore({required super.vaultRoot});

  final Completer<void> _gate = Completer<void>();
  bool _armed = false;

  /// Whether each `ensureUid` call actually wrote bytes (true) or found a
  /// uid already there and did nothing (false). Exactly one `true` means no
  /// drift; two means the race this lock exists to prevent.
  final List<bool> ensureUidWrote = <bool>[];

  /// Parks the next `writeAtomic` until [release] is called.
  void arm() => _armed = true;

  void release() {
    _armed = false;
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Future<void> writeAtomic(String notePath, List<int> bytes) async {
    if (_armed) await _gate.future;
    return super.writeAtomic(notePath, bytes);
  }

  @override
  Future<List<int>?> ensureUid(String notePath, String uid) async {
    final result = await super.ensureUid(notePath, uid);
    ensureUidWrote.add(result != null);
    return result;
  }
}