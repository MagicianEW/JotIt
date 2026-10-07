import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common/sqlite_api.dart';
import 'package:uuid/uuid.dart';

import '../core/content_hash.dart';
import '../core/vault_paths.dart';
import '../data/db/jotit_database.dart';
import '../data/db/note_dao.dart';
import '../data/db/pending_queue.dart';
import '../data/db/sync_meta_store.dart';
import '../data/db/sync_root_store.dart';
import '../data/search/note_search.dart';
import '../data/vault/note_file_store.dart';
import '../domain/entities/front_matter_patcher.dart';
import '../domain/vault/vault_scanner.dart';

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
  });

  final String vaultRoot;
  final JotItDatabase database;
  final NoteFileStore files;
  final NoteDao notes;
  final NoteSearch search;
  final SyncMetaStore meta;
  final SyncRootStore roots;
  final PendingQueue queue;

  Database get db => database.db;

  static const Uuid _uuid = Uuid();

  /// Opens (or creates) the vault at [vaultRoot] and brings the derived index
  /// up to date with the files on disk.
  ///
  /// Reindex runs at startup because ADR-1 makes the database disposable:
  /// whatever is on disk is the truth, the index is only whatever we last
  /// managed to derive from it. Skipping this would open the app showing an
  /// index that may not match the vault at all.
  static Future<VaultSession> open(String vaultRoot) async {
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
  static Future<String> defaultVaultRoot() async {
    final docs = await getApplicationDocumentsDirectory();
    return p.join(docs.path, 'JotIt');
  }

  Future<ReindexResult> reindex() =>
      VaultScanner(database: db, fileStore: files).reindex();

  /// Paths the settings screen shows so the user can find their data.
  String get databasePath => p.join(VaultPaths.appRoot(vaultRoot), 'jotit.db');
  String get conflictsPath => VaultPaths.conflictsRoot(vaultRoot);
  String get notesPath => VaultPaths.notesRoot(vaultRoot);

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

  static String _safeFileName(String raw) =>
      VaultPaths.sanitizeFileName(raw.replaceAll(RegExp(r'[\\/]'), '_'));
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