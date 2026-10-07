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
  }) async {
    await NoteFileStore.ensureLayout(vaultRoot);
    final database = await JotItDatabase.open(
      filePath: p.join(VaultPaths.appRoot(vaultRoot), 'jotit.db'),
    );
    final files = NoteFileStore(vaultRoot: vaultRoot);
    final session = VaultSession._(
      vaultRoot: vaultRoot,
      database: database,
      files: files,
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

  /// Writes edited text back and returns the new content hash.
  ///
  /// Null means nothing was written, because the bytes came out identical. The
  /// sync engine reads that hash as "the user edited this note", so a save
  /// that produces the same file must not look like an edit.
  Future<String?> save(String notePath, String text) async {
    final before = await files.readBytesIfPresent(notePath);
    if (before != null && NoteFileStore.isValidUtf8(before)) {
      final stripped = before.length >= 3 &&
              before[0] == 0xEF &&
              before[1] == 0xBB &&
              before[2] == 0xBF
          ? before.sublist(3)
          : before;
      if (utf8.decode(stripped) == text) return null;
    }

    final bytes = before == null
        ? utf8.encode(text)
        : await files.encodeLike(originalBytes: before, text: text);
    await files.writeAtomic(notePath, bytes);
    // ADR-2: identity lives in the file, so a note the user created here must
    // carry one before it is ever offered to the sync engine.
    await files.ensureUid(notePath, _uuid.v4());
    await reindex();

    final after = await files.readBytesIfPresent(notePath);
    return after == null ? null : ContentHash.ofBytes(after);
  }

  /// Creates a new note and returns its `notes/`-prefixed path.
  Future<String> createNote({String? title, String? directory}) async {
    final raw = (title ?? '').trim();
    final name = _safeFileName(raw.isEmpty ? 'untitled' : raw);
    final dir = (directory ?? '').trim();
    final notePath = dir.isEmpty
        ? '${VaultPaths.notesDirName}/$name.md'
        : '${VaultPaths.notesDirName}/$dir/$name.md';

    await files.writeAtomic(notePath, utf8.encode('# $name\n\n'));
    await files.ensureUid(notePath, _uuid.v4());
    await reindex();
    return notePath;
  }

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