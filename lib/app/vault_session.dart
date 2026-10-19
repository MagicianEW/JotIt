import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common/sqlite_api.dart';
import 'package:uuid/uuid.dart';

import '../core/content_hash.dart';
import '../core/vault_paths.dart';
import '../data/dav/dav_capabilities.dart';
import '../data/dav/dav_client.dart';
import '../data/db/jotit_database.dart';
import '../data/db/note_dao.dart';
import '../data/db/pending_queue.dart';
import '../data/db/sync_meta_store.dart';
import '../data/db/sync_root_store.dart';
import '../data/search/note_search.dart';
import '../data/sync/sync_engine.dart';
import '../data/vault/note_file_store.dart';
import '../domain/entities/front_matter_patcher.dart';
import '../domain/vault/attachment_writer.dart';
import '../domain/vault/link_resolver.dart';
import '../domain/vault/vault_scanner.dart';
import 'app_lock.dart';
import 'credential_cipher.dart';
import 'screen_security.dart';
import 'vault_locator.dart';

/// Everything one open vault needs, assembled once at startup.
///
/// Deliberately a plain object rather than a pile of global singletons: the UI
/// takes one of these, the tests build one over a temp directory, and nothing
/// reaches for a path or a database on its own.
class VaultSession {
  VaultSession._({
    required this.vaultRoot,
    required this.database,
    required this.files,
    required this.notes,
    required this.search,
    required this.meta,
    required this.roots,
    required this.queue,
    required this.lock,
    required this.cipher,
    required this.screenSecurity,
    required this.attachments,
  });

  final String vaultRoot;
  final JotItDatabase database;
  final NoteFileStore files;
  final NoteDao notes;
  final NoteSearch search;
  final SyncMetaStore meta;
  final SyncRootStore roots;
  final PendingQueue queue;

  /// §8.3. Reached from the UI, not just the tests — a lock that exists only in
  /// a library is not a lock.
  final AppLock lock;

  /// Where sealed WebDAV credentials live. Resolved on first use, so opening a
  /// vault does not depend on a platform plugin being available.
  final CredentialCipher cipher;

  /// Android `FLAG_SECURE`, driven by whether a PIN exists. See
  /// [ScreenSecurity] for why it is bound to the lock rather than always on.
  final ScreenSecurity screenSecurity;

  /// Copies files into the vault as attachments (v3.0 §9.3).
  final AttachmentWriter attachments;

  Database get db => database.db;

  static const Uuid _uuid = Uuid();

  /// Opens (or creates) the vault at [vaultRoot] and brings the derived index
  /// up to date with the files on disk.
  ///
  /// Reindex runs at startup because ADR-1 makes the database disposable:
  /// whatever is on disk is the truth, the index is only whatever we last
  /// managed to derive from it. Skipping this would open the app showing an
  /// index that may not match the vault at all.
  static Future<VaultSession> open(
    String vaultRoot, {
    Directory? appDataDir,
    ScreenSecurity? screenSecurity,
    NoteFileStore? files,
  }) async {
    await NoteFileStore.ensureLayout(vaultRoot);
    // 启动恢复先于首次 reindex：上次写入中途被杀会留下
    // `.jotit-tmp.*`（未提交，删）与 `.jotit-bak.*`（唯一副本，搬回）。
    // 索引必须从恢复之后的文件状态建立，否则一篇笔记会带着旧路径的
    // 幽灵行出现，或者干脆消失。
    await NoteFileStore.recoverInterruptedWrites(vaultRoot);
    final database = await JotItDatabase.open(
      filePath: p.join(VaultPaths.appRoot(vaultRoot), 'jotit.db'),
    );
    final fileStore = files ?? NoteFileStore(vaultRoot: vaultRoot);
    final session = VaultSession._(
      vaultRoot: vaultRoot,
      database: database,
      files: fileStore,
      notes: NoteDao(database.db),
      search: NoteSearch(database.db),
      meta: SyncMetaStore(database.db),
      roots: SyncRootStore(database.db),
      queue: PendingQueue(database.db),
      lock: AppLock(database.db),
      cipher: CredentialCipher(() async {
        if (appDataDir != null) return appDataDir;
        final support = await getApplicationSupportDirectory();
        return Directory(p.join(support.path, 'JotIt'));
      }),
      screenSecurity: screenSecurity ?? ScreenSecurity(),
      attachments: AttachmentWriter(vaultRoot: vaultRoot),
    );
    await session.reindex();
    return session;
  }

  /// The default vault location on this platform.
  ///
  /// Documents rather than app support: this is a folder of Markdown the user
  /// is meant to open, edit and back up alongside everything else they own.
  /// Burying it in AppData is what makes a note app feel like it is keeping
  /// secrets from them.
  ///
  /// Honours a previously chosen location, and refuses to adopt a folder that
  /// already belongs to something else — see [VaultLocator]. Kept as a static
  /// so non-UI callers (tests, tools) can resolve the same location the app
  /// does without going through a provider.
  static Future<String> defaultVaultRoot({required VaultLocator locator}) async =>
      (await locator.resolve()).path;
  Future<ReindexResult> reindex() =>
      VaultScanner(database: db, fileStore: files).reindex();

  /// Link graph snapshot for the preview's wiki-link resolution.
  ///
  /// One query, no reindex: the preview only needs path<->uid tables, and a
  /// stale-by-one-save index shows at worst a wrong "未找到笔记" snackbar,
  /// never wrong bytes.
  Future<LinkIndex> loadLinkIndex() =>
      VaultScanner(database: db, fileStore: files).loadLinkIndex();

  /// Inserts a file into the vault as an attachment of [notePath] (v3.0 §9.3)
  /// and reindexes so the new file is known immediately.
  ///
  /// The reindex is not optional tidiness: without it the attachment has no
  /// row, and the sync engine — which deliberately only pushes files a note
  /// actually references — would not transfer it until some later scan
  /// happened to notice. "I inserted a picture and it never synced" with
  /// nothing wrong on screen is the exact failure this whole feature exists to
  /// avoid.
  Future<AttachmentInsertion> insertAttachment({
    required String notePath,
    required String sourcePath,
  }) async {
    final insertion =
        await attachments.attach(notePath: notePath, sourcePath: sourcePath);
    await reindex();
    return insertion;
  }

  /// Paths the settings screen shows so the user can find their data.
  String get databasePath => p.join(VaultPaths.appRoot(vaultRoot), 'jotit.db');
  String get conflictsPath => VaultPaths.conflictsRoot(vaultRoot);
  String get notesPath => VaultPaths.notesRoot(vaultRoot);

  // ---------------------------------------------------------------- §8.3 lock

  /// Sets the PIN, and tells the platform that the screen is now protected.
  ///
  /// The two are one action on purpose. Wiring `FLAG_SECURE` to the UI instead
  /// would leave exactly one call site to forget, and forgetting it produces a
  /// lock that looks armed and photographs nothing — the screenshot is taken
  /// long after the gate is gone, so the user never learns it failed.
  Future<void> setPin(String pin) async {
    await lock.setPin(pin);
    await syncScreenSecurity();
  }

  /// Removes the PIN, and gives screenshots back.
  Future<void> clearPin() async {
    await lock.clear();
    await syncScreenSecurity();
  }

  /// Pushes the current lock state to the platform.
  ///
  /// Called at startup as well as from the two mutations above, because the
  /// native side caches this value for process restarts and a cache that is
  /// never refreshed drifts from the database the moment it is wrong.
  Future<void> syncScreenSecurity() async =>
      screenSecurity.applyForLock(lockConfigured: await lock.isConfigured());

  /// Reads a note for editing, or null when there is nothing editable there.
  ///
  /// Non-UTF-8 bytes return null rather than a lossy decode: opening a GBK
  /// note in an editor and letting the user save would replace every
  /// undecodable byte with U+FFFD, and that damage then syncs to every device.
  Future<EditableNote?> readForEdit(String notePath) async {
    final bytes = await files.readBytesIfPresent(notePath);
    if (bytes == null || !NoteFileStore.isValidUtf8(bytes)) return null;

    var body = bytes;
    final hadBom = body.length >= 3 &&
        body[0] == 0xEF &&
        body[1] == 0xBB &&
        body[2] == 0xBF;
    if (hadBom) body = body.sublist(3);

    final text = utf8.decode(body);
    return EditableNote(
      notePath: notePath,
      text: text,
      hadBom: hadBom,
      usedCrlf: text.contains('\r\n'),
      uid: FrontMatterPatcher.readString(text, 'uid'),
      title: FrontMatterPatcher.readString(text, 'title'),
    );
  }

  /// Rolling backup for rich-text saves: copies the file exactly as it is on
  /// disk to `.jotit/backups/<note-path>.bak`, overwriting the previous
  /// backup. After this call the backup always holds the *previous* save —
  /// one file, always the version before the one being written now. The
  /// `.jotit` tree is local-only, so backups never sync.
  ///
  /// Returns a warning for the UI to surface separately when the backup could
  /// not be written, or null when it succeeded (or there was nothing on disk
  /// to keep). **Never throws:** a failed backup must not abort the save it
  /// precedes — the user's edit lives only in memory until that save lands,
  /// so losing the save to protect a convenience copy is the worse trade.
  /// The write itself is atomic (tmp + rename) for the same reason note
  /// writes are: a half-written backup looks like a recovery point and is not.
  Future<String?> backupBeforeRichSave(String notePath) async {
    List<int> bytes;
    try {
      final read = await files.readBytesIfPresent(notePath);
      if (read == null) return null; // nothing on disk yet — nothing to keep
      bytes = read;
    } on Object catch (e) {
      return '备份上一版本失败（读不到原文件）：$e';
    }

    final rel = VaultPaths.stripNotesPrefix(notePath) ?? notePath;
    final bak = File(p.join(VaultPaths.appRoot(vaultRoot), 'backups',
        '$rel.bak'));
    try {
      await files.writeFileAtomic(bak, bytes);
      return null;
    } on Object catch (e) {
      return '备份上一版本失败：$e';
    }
  }

  /// Set by [saveRich] when [backupBeforeRichSave] could not write the backup.
  /// The save still happens; the UI surfaces this separately so a failed
  /// backup is neither silent nor mistaken for a failed save.
  String? lastBackupWarning;

  /// A rich-text save: back up the current file first, then write. The
  /// serialiser normalises formatting (the agreed waiver), so this is the
  /// one save path where the previous version is kept around on purpose.
  ///
  /// A no-op save (the composed text matches the file byte for byte) writes
  /// nothing and rolls nothing — the backup keeps holding the version before
  /// the last real save.
  Future<String?> saveRich(String notePath, String text) async {
    if (await _composedSaveText(notePath, text) == null) return null;
    lastBackupWarning = await backupBeforeRichSave(notePath);
    return save(notePath, text);
  }

  /// Writes edited text back and returns the new content hash.
  ///
  /// Null means nothing was written, because the bytes came out identical. The
  /// sync engine reads that hash as "the user edited this note", so a save
  /// that produces the same file must not look like an edit.
  Future<String?> save(String notePath, String text) async {
    // 整个读-改-写序列持有该路径的写锁：与扫描器的 uid 回填互斥，否则
    // 回填铸出的 uid 会被保存凭旧读点写出的无 uid 文本覆盖、再由
    // ensureUid 铸一个新 uid —— 身份静默漂移（ADR-2）。reindex 放在锁外：
    // 它会为其它路径取锁，嵌套取锁可能成环死锁。
    final written = await files.exclusive(notePath, () async {
      final composed = await _composedSaveText(notePath, text);
      if (composed == null) return false;
      final before = await files.readBytesIfPresent(notePath);

      final bytes = before == null
          ? utf8.encode(composed)
          : await files.encodeLike(originalBytes: before, text: composed);
      await files.writeAtomic(notePath, bytes);
      // ADR-2: identity lives in the file, so a note the user created here must
      // carry one before it is ever offered to the sync engine. ensureUid 只
      // 在没有 uid 时补写；并发回填已写过的 uid 会被它原样尊重。
      await files.ensureUid(notePath, _uuid.v4());
      return true;
    });
    if (!written) return null;

    await reindex();

    final after = await files.readBytesIfPresent(notePath);
    return after == null ? null : ContentHash.ofBytes(after);
  }

  /// Composes the text a save would write — inheriting the file's existing
  /// uid when the incoming text lacks one — and returns null when writing it
  /// would change nothing (a no-op save).
  ///
  /// Throws [StateError] when the file on disk is not valid UTF-8. Letting
  /// that case through would send [NoteFileStore.encodeLike]'s
  /// `allowMalformed: true` to work, which replaces every undecodable byte
  /// with U+FFFD and syncs the damage to every device — the same refusal
  /// [readForEdit] already applies on the read side.
  Future<String?> _composedSaveText(String notePath, String text) async {
    final before = await files.readBytesIfPresent(notePath);
    if (before == null) return text;
    if (!NoteFileStore.isValidUtf8(before)) {
      throw StateError('文件不是 UTF-8，拒绝保存以免损坏原文件');
    }

    final stripped = before.length >= 3 &&
            before[0] == 0xEF &&
            before[1] == 0xBB &&
            before[2] == 0xBF
        ? before.sublist(3)
        : before;
    final beforeText = utf8.decode(stripped);
    if (beforeText == text) return null;
    // ADR-2: identity lives in the file. A save whose text carries no
    // front matter (or no uid key) must not destroy the note's existing
    // uid — otherwise every such save mints a fresh identity and the
    // sync engine sees a brand-new note.
    final existingUid = FrontMatterPatcher.readString(beforeText, 'uid');
    if (existingUid == null || existingUid.trim().isEmpty) return text;
    if (FrontMatterPatcher.readString(text, 'uid') != null) return text;
    final outText = FrontMatterPatcher.withUid(text, existingUid.trim());
    return outText == beforeText ? null : outText;
  }

  /// Creates a new note and returns its `notes/`-prefixed path.
  ///
  /// 同名不覆盖：目标已存在时自动找 `name-1.md`、`name-2.md`… 第一个空闲名。
  /// 直接覆盖会把旧内容换成 `# name` 存根，且没有任何恢复途径 —— 那是一次
  /// 静默的数据丢失。选取在路径写锁内完成，两个并发的同名创建不会选中同一个
  /// 空闲名。
  Future<String> createNote({String? title, String? directory}) async {
    final raw = (title ?? '').trim();
    final name = _safeFileName(raw.isEmpty ? 'untitled' : raw);
    final dir = (directory ?? '').trim();
    final prefix = dir.isEmpty
        ? '${VaultPaths.notesDirName}/'
        : '${VaultPaths.notesDirName}/$dir/';

    for (var attempt = 0;; attempt++) {
      final notePath = attempt == 0
          ? '$prefix$name.md'
          : '$prefix$name-$attempt.md';
      // 在锁内"检查是否存在并落盘"：检查和 claim 之间没有让出点，并发
      // 的同名创建会串行地看到彼此写下的文件。
      final claimed = await files.exclusive(notePath, () async {
        final existing = files.fileFor(notePath);
        if (existing != null && await existing.exists()) return false;
        await files.writeAtomic(notePath, utf8.encode('# $name\n\n'));
        await files.ensureUid(notePath, _uuid.v4());
        return true;
      });
      if (claimed) {
        await reindex();
        return notePath;
      }
      if (attempt >= _maxNameAttempts) {
        throw StateError('找不到可用的笔记文件名：$name');
      }
    }
  }

  /// Ceiling on the `name-N.md` search. A vault with ten thousand same-named
  /// notes has a different problem; refusing loudly beats spinning forever.
  static const int _maxNameAttempts = 10000;

  /// Creates a note without touching the index — for fixtures and for the
  /// "what the other device did" tests.
  Future<void> writeRaw(String notePath, List<int> bytes) =>
      files.writeAtomic(notePath, bytes);

  Future<void> close() => database.close();

  /// Builds a client for [root] with the capability profile §6.2 negotiated and
  /// persisted earlier, so a Synology box is not asked for a CTag it will
  /// never send on every cold start.
  DavClient clientFor(SyncRootRecord root, String password) => DavClient(
        baseUri: Uri.parse(root.baseUrl),
        username: root.username,
        password: password,
        capabilities: DavCapabilities.fromJson(root.capabilities),
      );

  /// Everything one round needs: the client, the engine, and the close that
  /// releases the HTTP connection.
  ///
  /// A round gets its own client rather than sharing one, because
  /// `capabilities` is mutable state that `probe()` rewrites. Two rounds on two
  /// roots would otherwise fight over the same object.
  Future<SyncHandle> openSync(SyncRootRecord root, String password) async {
    final client = clientFor(root, password);
    return SyncHandle(
      client: client,
      engine: SyncEngine(
        dav: client,
        files: files,
        notes: notes,
        meta: meta,
        roots: roots,
        queue: queue,
        vaultRoot: vaultRoot,
      ),
    );
  }

  /// The stored password for [root], or null when there is none to unseal.
  Future<String?> passwordFor(SyncRootRecord root) =>
      cipher.open(root.credentialBlob);

  /// Replaces [root]'s credentials. An empty password clears the blob rather
  /// than sealing an empty string, so "no password" stays distinguishable from
  /// "the password is an empty string".
  Future<void> setPassword(SyncRootRecord root, String password) async {
    await roots.upsert(password.isEmpty
        ? root.copyWith(clearCredential: true)
        : root.copyWith(credentialBlob: await cipher.seal(password)));
  }

  static String _safeFileName(String raw) =>
      VaultPaths.sanitizeFileName(raw.replaceAll(RegExp(r'[\\/]'), '_'));
}

/// One configured remote plus the objects needed to run a round against it.
class SyncHandle {
  SyncHandle({required this.client, required this.engine});

  final DavClient client;
  final SyncEngine engine;

  Future<void> close() => client.close();
}

/// A note as the editor sees it, with the byte conventions it must hand back.
class EditableNote {
  const EditableNote({
    required this.notePath,
    required this.text,
    required this.hadBom,
    required this.usedCrlf,
    required this.uid,
    required this.title,
  });

  final String notePath;
  final String text;

  /// The file started with a UTF-8 BOM; [VaultSession.save] keeps it.
  final bool hadBom;

  /// The file used CRLF; the save path re-expands to it.
  final bool usedCrlf;

  final String? uid;
  final String? title;

  bool get hasUid => uid != null && uid!.isNotEmpty;
}