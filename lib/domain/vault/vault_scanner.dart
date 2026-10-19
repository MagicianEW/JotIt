import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../core/content_hash.dart';
import '../../core/vault_paths.dart';
import '../../data/db/note_dao.dart';
import '../../data/vault/note_file_store.dart';
import '../entities/markdown_parser.dart';
import '../entities/parsed_note.dart';
import '../sync/attachment_policy.dart';
import 'link_resolver.dart';

/// What one pass of [VaultScanner.reindex] found.
///
/// The point of returning a report rather than silently reconciling is that
/// most surprises in a vault are *someone else's* doing — a file copied in by
/// Finder, a sync client that half-finished, a duplicate pasted from another
/// note. A scanner that quietly "fixes" those produces an index the user
/// cannot explain, and the sync engine then propagates the surprise to every
/// device.
@immutable
class ReindexResult {
  const ReindexResult({
    this.filesSeen = 0,
    this.notesIndexed = 0,
    this.notesUnchanged = 0,
    this.attachmentsIndexed = 0,
    this.linksIndexed = 0,
    this.ambiguousLinks = 0,
    this.danglingLinks = 0,
    this.externalLinks = 0,
    this.uidBackfilled = const <String>[],
    this.duplicateUids = const <String>[],
    this.restoredFromDisk = const <String>[],
    this.missingPaths = const <String>[],
    this.missingAttachments = const <String>[],
    this.skipped = const <String>[],
    this.unreadable = const <String>[],
    this.malformedFrontMatter = const <String>[],
  });

  final int filesSeen;

  /// Notes whose derived rows this pass actually wrote.
  final int notesIndexed;

  /// Notes that were read, hashed, found byte-identical to what the index
  /// already described, and therefore left alone.
  ///
  /// A non-zero value means the fast path ran and found the vault already in
  /// sync. It is not a count of work skipped by guessing: every one of these
  /// files was read and its SHA-256 compared.
  final int notesUnchanged;

  final int attachmentsIndexed;
  final int linksIndexed;
  final int ambiguousLinks;
  final int danglingLinks;
  final int externalLinks;

  /// Paths whose front matter had no `uid` and got one written back.
  final List<String> uidBackfilled;

  /// Paths that claim a `uid` another file already claimed. Only the first
  /// path per uid is indexed; the rest are reported and left alone.
  final List<String> duplicateUids;

  /// Paths whose file is present again after having been soft-deleted.
  final List<String> restoredFromDisk;

  /// Index rows with no file behind them. **Not** deleted here: see
  /// [Reindex] on why that call belongs to the sync engine.
  final List<String> missingPaths;

  /// Attachment rows whose file is no longer on disk.
  ///
  /// §4.4 is explicit that these are reported and kept: the metadata is the
  /// only record that the note ever referenced that file, and deleting it
  /// turns "this attachment is missing" into "this note never had one".
  /// The sync engine — which knows what should be on the remote — decides
  /// whether the deletion is real.
  final List<String> missingAttachments;

  /// Files deliberately not indexed, with the reason.
  final List<String> skipped;

  /// Files that could not be read (permissions, locks, vanished mid-scan).
  final List<String> unreadable;

  final List<String> malformedFrontMatter;

  bool get hasProblems =>
      duplicateUids.isNotEmpty ||
      unreadable.isNotEmpty ||
      malformedFrontMatter.isNotEmpty ||
      missingPaths.isNotEmpty ||
      missingAttachments.isNotEmpty;

  @override
  String toString() => 'ReindexResult(notes=$notesIndexed, '
      'unchanged=$notesUnchanged, '
      'links=$linksIndexed, backfilled=${uidBackfilled.length}, '
      'duplicates=${duplicateUids.length}, missing=${missingPaths.length}, '
      'missingAttachments=${missingAttachments.length}, '
      'skipped=${skipped.length}, unreadable=${unreadable.length})';
}

/// Rebuilds the derived index from the files on disk.
///
/// This is invariant I1 (v3.0 ADR-1): the database is disposable. Deleting
/// `jotit.db` and calling [reindex] must reproduce the whole index with zero
/// data loss. Everything here is therefore written so that the *only* input
/// is the filesystem plus the identity already carried inside the files.
class VaultScanner {
  VaultScanner({
    required Database database,
    required NoteFileStore fileStore,
    MarkdownParser? parser,
    Uuid? uuid,
    DateTime Function()? clock,
  })  : _db = database,
        _files = fileStore,
        _parser = parser ?? MarkdownParser(),
        _uuid = uuid ?? const Uuid(),
        _now = clock ?? DateTime.now;

  final Database _db;
  final NoteFileStore _files;
  final MarkdownParser _parser;
  final Uuid _uuid;
  final DateTime Function() _now;

  /// Extensions treated as notes. `.markdown` is included because every
  /// Markdown editor writes it and refusing to index those files means the
  /// user's existing vault appears half-empty on first run.
  static const Set<String> noteExtensions = {'.md', '.markdown'};

  /// Directory name whose contents are attachments rather than notes
  /// (v3.0 §9.3). The predicate lives in [VaultPaths.isAttachmentPath]
  /// because the sync engine has to answer the same question, and two
  /// disagreeing copies of it is how an image ends up in `_conflicts/`.
  static const String attachmentsDirName = VaultPaths.attachmentsDirName;

  static const Set<String> _ignoredExtensions = {
    '.tmp', '.temp', '.part', '.partial', '.crdownload', '.download',
    '.swp', '.swo', '.lock', '.bak', '.jotit-tmp', '.jotit-bak',
  };

  static const Set<String> _ignoredNames = {
    'thumbs.db', 'desktop.ini', '.ds_store',
  };

  /// Walks `notes/`, mirrors every note into the index, and reports what did
  /// not add up.
  ///
  /// [knownPaths] is the caller's expectation of what exists — normally every
  /// path the sync engine believes is on the remote. It turns "this row has no
  /// file" into [ReindexResult.missingPaths] instead of a deletion, which is
  /// what stops a partially-downloaded vault from mass-deleting its notes.
  Future<ReindexResult> reindex({Set<String>? knownPaths}) async {
    final root = Directory(_files.notesRoot());
    final files = <String, _ScannedFile>{};
    final attachments = <String, _ScannedFile>{};
    final skipped = <String>[];
    final unreadable = <String>[];
    var filesSeen = 0;

    if (await root.exists()) {
      await for (final entity in root.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final path = _files.notePathFor(entity.path);
        if (path == null) continue; // not inside notes/ — should not happen
        final rel = path.substring('notes/'.length);

        if (_ignoredNames.contains(p.posix.basename(rel).toLowerCase())) {
          skipped.add('$rel: system file');
          continue;
        }
        if (rel.split('/').any((s) => s.startsWith('.'))) {
          skipped.add('$rel: hidden');
          continue;
        }

        filesSeen++;

        final ext = p.posix.extension(rel).toLowerCase();
        if (_ignoredExtensions.contains(ext)) {
          skipped.add('$rel: temporary file');
          continue;
        }

        _ScannedFile? scanned;
        try {
          final stat = await entity.stat();
          final bytes = await entity.readAsBytes();
          scanned = _ScannedFile(path: path, bytes: bytes, size: stat.size,
              mtimeMs: stat.modified.millisecondsSinceEpoch.toInt());
        } on FileSystemException catch (e) {
          // A file that vanished mid-scan, or one another process holds
          // locked. Either way it is *not* evidence of a deletion — that is
          // reported as missing, never as removed.
          unreadable.add('$rel: ${e.message}');
          continue;
        } on Object catch (e) {
          unreadable.add('$rel: $e');
          continue;
        }

        if (VaultPaths.isAttachmentPath(path)) {
          attachments[path] = scanned;
          continue;
        }
        if (noteExtensions.contains(ext)) {
          files[path] = scanned;
        } else {
          skipped.add('$rel: not a note extension');
        }
      }
    }

    // Fast path — see [_alreadyMatchesDisk]. When the index already describes
    // these exact bytes, all the writing below produces rows identical to the
    // ones already there, and on a real vault that is the overwhelming
    // majority of the work: measured on 1000 Chinese notes (1 MB), reading and
    // hashing every file costs 165ms while the write pass costs 2.7s. §11.2
    // budgets 1.5s from launch to editable, and `VaultSession.open` runs this
    // on every start, so a vault a month old would not open in time.
    final noop = await _alreadyMatchesDisk(
      notes: files,
      attachments: attachments,
      skipped: skipped,
      knownPaths: knownPaths,
    );
    if (noop != null) return noop;

    // Pass 1 — parse every note so the link index sees the whole vault before
    // a single link is resolved. Resolving against a half-built index is how
    // backlinks silently go missing after a rename.
    final parsed = <String, _ParsedNote>{};
    final backfilled = <String>[];
    final malformed = <String>[];
    final uidOwner = <String, String>{};
    final duplicates = <String>[];

    for (final path in files.keys.toList()..sort()) {
      final file = files[path]!;
      var bytes = file.bytes;

      var note = _parser.parse(
        utf8.decode(bytes, allowMalformed: true),
        fallbackTitle: _stemOf(path),
      );
      if (note.uid == null) {
        final uid = _uuid.v4();
        // 回填持有该路径的写锁：它和一次保存是同形状的读-改-写序列，
        // 交错会让保存凭"没看到 uid"的旧读点铸出新 uid，身份静默漂移
        // （ADR-2）。锁的粒度是单路径，不会让整库扫描串行化。
        final rewritten =
            await _files.exclusive(path, () => _files.ensureUid(path, uid));
        if (rewritten != null) {
          backfilled.add(path);
          bytes = rewritten;
          // Re-parse against the rewritten bytes. Hashing the pre-patch bytes
          // would make the very act of indexing look like a user edit, and the
          // sync engine would upload a change nobody made.
          note = _parser.parse(
            utf8.decode(bytes, allowMalformed: true),
            fallbackTitle: _stemOf(path),
          );
        }
      }
      if (note.frontMatterMalformed) malformed.add(path);

      final uid = note.uid;
      if (uid == null) {
        skipped.add('$path: no uid could be assigned');
        continue;
      }
      final owner = uidOwner[uid];
      if (owner != null) {
        // Two files claiming one identity means the note was copied outside
        // JotIt. Indexing the second would rewrite the first note's row —
        // title, body and hash — under the same primary key, and the sync
        // engine would then see the "first" note change without the user
        // touching it. Report it and index only one.
        duplicates.add('$path (uid already used by $owner)');
        continue;
      }
      uidOwner[uid] = path;

      parsed[path] = _ParsedNote(
        file: file,
        parsed: note,
        bytes: bytes,
      );
    }

    final index = _buildLinkIndex(parsed, aliasRows: await _loadAliases());

    final indexedPaths = <String>{};
    var linksIndexed = 0;
    var ambiguous = 0;
    var dangling = 0;
    var externals = 0;
    final restored = <String>[];

    // Pass 2 — write. One transaction for the whole pass: a crash halfway
    // through must not leave the index describing a vault that does not exist.
    final dao = NoteDao(_db);
    late final List<String> missingAttachments;
    await dao.runInTransaction((txn) async {
      final tnotes = NoteDao.on(txn);

      // 2a — every note row, before any link row.
      //
      // `links.target_note_id` is a real foreign key, so a note that links to
      // a note whose path happens to sort *later* (`a.md` -> `b.md`) would fail
      // the constraint: the target row does not exist yet. Deferring all link
      // writes to a second sweep makes the ordering irrelevant, and the sweep
      // still lands in this one transaction so the index is never half-built.
      final writtenPaths = <String>[];
      for (final path in parsed.keys) {
        final entry = parsed[path]!;
        final uid = entry.parsed.uid!;

        final existing = await tnotes.byPath(path, includeDeleted: true);
        if (existing != null && existing.isDeleted) restored.add(path);

        await tnotes.upsert(NoteRecord(
          uid: uid,
          path: path,
          title: entry.parsed.title,
          body: entry.parsed.body,
          // Over the *current* bytes, never over the text we parsed before a
          // uid was written back.
          contentHash: ContentHash.ofBytes(entry.bytes),
          fileSize: entry.bytes.length,
          fileMtimeMs: entry.file.mtimeMs,
          updatedAt: _now().millisecondsSinceEpoch,
          isDeleted: false,
        ));
        indexedPaths.add(path);
        writtenPaths.add(path);
      }

      // 2b — derived rows that reference note ids. Safe now that every
      // `notes` row in this transaction exists.
      for (final path in writtenPaths) {
        final entry = parsed[path]!;
        final uid = entry.parsed.uid!;

        final counts = await _rebuildLinks(txn, path, uid, entry, index);
        linksIndexed += counts.total;
        ambiguous += counts.ambiguous;
        dangling += counts.dangling;
        externals += counts.external;

        await _rebuildTags(txn, uid, entry.parsed);
        await _rebuildAttachments(txn, path, uid, entry, attachments);
      }

      missingAttachments = await _reportMissingAttachments(txn, attachments);
    });

    // Anything indexed but absent from disk. Reported, never deleted here.
    final missing = <String>[];
    for (final row in await dao.allActive(limit: 1000000)) {
      if (!indexedPaths.contains(row.path)) missing.add(row.path);
    }
    if (knownPaths != null) {
      // Callers that know the remote truth can widen the picture, but they do
      // not get to skip it: a file the remote has and the disk lacks is
      // exactly what the conflict matrix needs to see.
      for (final expected in knownPaths) {
        if (!indexedPaths.contains(expected) && !missing.contains(expected)) {
          missing.add(expected);
        }
      }
    }
    missing.sort();

    return ReindexResult(
      filesSeen: filesSeen,
      notesIndexed: parsed.length,
      attachmentsIndexed: attachments.length,
      linksIndexed: linksIndexed,
      ambiguousLinks: ambiguous,
      danglingLinks: dangling,
      externalLinks: externals,
      uidBackfilled: backfilled,
      duplicateUids: duplicates,
      restoredFromDisk: restored,
      missingPaths: missing,
      missingAttachments: missingAttachments,
      skipped: skipped,
      unreadable: unreadable,
      malformedFrontMatter: malformed,
    );
  }

  /// True when every one of these files is already indexed under exactly these
  /// bytes, and the index holds nothing else.
  ///
  /// The comparison is on the **content hash**, not on the modification time.
  /// A mtime shortcut would be cheaper and is the obvious thing to write, but
  /// it is wrong in a way that matters here: a sync engine rewriting identical
  /// bytes, a `touch`, a backup tool restoring an unchanged copy — all move the
  /// mtime without changing anything, and a mtime rule would re-index the
  /// whole vault for them. More importantly it is wrong in the *other*
  /// direction: two edits inside one timestamp tick, or an editor that
  /// preserves mtime, would be missed, and the whole point of ADR-1 is that the
  /// index cannot lag the disk. Reading the bytes costs a sixth of what writing
  /// them does, so it is not even the expensive half.
  ///
  /// Returns the [ReindexResult] to hand back when nothing needs writing, or
  /// null when any part of the vault disagrees and the full pass must run.
  ///
  /// Deliberately all-or-nothing. A partial fast path would have to resolve
  /// links against a mix of freshly-parsed notes and rows read back from the
  /// database, and a link resolved against a half-built index looks
  /// authoritative while being wrong. If anything at all changed, the
  /// behaviour is exactly what it was before this existed.
  Future<ReindexResult?> _alreadyMatchesDisk({
    required Map<String, _ScannedFile> notes,
    required Map<String, _ScannedFile> attachments,
    required List<String> skipped,
    required Set<String>? knownPaths,
  }) async {
    // A vault whose index is empty, or a caller that brought remote paths
    // that the disk scan has not accounted for, always takes the full path.
    if (notes.isEmpty && attachments.isEmpty) return null;
    if (knownPaths != null && knownPaths.isNotEmpty) return null;
    if (skipped.any((s) => s.contains('not a note extension'))) return null;

    final rows = await _db.query(
      'notes',
      columns: <String>['id', 'path', 'content_hash', 'is_deleted'],
      where: 'is_deleted = 0',
    );
    if (rows.length != notes.length) return null;

    final indexed = <String, String>{};
    for (final r in rows) {
      indexed[r['path']! as String] = r['content_hash']! as String;
    }

    for (final entry in notes.entries) {
      final expected = indexed[entry.key];
      // A note on disk that the index has never seen, or one whose bytes moved
      // under us — either way the full pass is what makes the index true.
      if (expected == null) return null;
      if (expected != ContentHash.ofBytes(entry.value.bytes)) return null;
    }
    if (indexed.length != notes.length) return null;

    // Attachments are part of the derived index too. Their rows carry a
    // content hash as well, so the same argument applies.
    final attachmentRows =
        await _db.query('attachments', columns: <String>['path', 'content_hash']);
    if (attachmentRows.length != attachments.length) return null;
    final indexedAttachments = <String, String>{
      for (final r in attachmentRows)
        r['path']! as String: r['content_hash']! as String,
    };
    for (final entry in attachments.entries) {
      final expected = indexedAttachments[entry.key];
      if (expected == null) return null;
      if (expected != ContentHash.ofBytes(entry.value.bytes)) return null;
    }

    return ReindexResult(
      filesSeen: notes.length,
      notesIndexed: 0,
      attachmentsIndexed: 0,
      notesUnchanged: notes.length,
      linksIndexed: 0,
    );
  }

  /// Loads every active note's path and uid into one snapshot.
  ///
  /// Used by the sync engine for the same reason the scanner builds one: a
  /// link graph resolved against a stale index is worse than one resolved
  /// against nothing, because it looks authoritative.
  Future<LinkIndex> loadLinkIndex() async {
    final rows = await _db.query(
      'notes',
      columns: <String>['id', 'path'],
      where: 'is_deleted = 0',
    );
    final uidToPath = <String, String>{};
    final pathToUid = <String, String>{};
    final byStem = <String, List<String>>{};

    for (final row in rows) {
      final uid = row['id']! as String;
      final path = row['path']! as String;
      uidToPath[uid] = path;
      pathToUid[path] = uid;
      byStem.putIfAbsent(LinkIndex.stemOf(path), () => <String>[]).add(path);
    }
    for (final list in byStem.values) {
      list.sort();
    }
    return LinkIndex(
      uidToPath: uidToPath,
      pathToUid: pathToUid,
      byStem: byStem,
      aliases: await _loadAliases(),
    );
  }

  LinkIndex _buildLinkIndex(
    Map<String, _ParsedNote> parsed, {
    required Map<String, String> aliasRows,
  }) {
    final uidToPath = <String, String>{};
    final pathToUid = <String, String>{};
    final byStem = <String, List<String>>{};

    for (final entry in parsed.entries) {
      final uid = entry.value.parsed.uid;
      if (uid == null) continue;
      uidToPath[uid] = entry.key;
      pathToUid[entry.key] = uid;
      byStem
          .putIfAbsent(LinkIndex.stemOf(entry.key), () => <String>[])
          .add(entry.key);
    }
    for (final list in byStem.values) {
      list.sort();
    }
    return LinkIndex(
      uidToPath: uidToPath,
      pathToUid: pathToUid,
      byStem: byStem,
      aliases: aliasRows,
    );
  }

  /// Reads every stored disambiguation in one query.
  ///
  /// An alias whose target has been deleted is dropped rather than followed:
  /// the user's decision referred to a note that no longer exists, and
  /// re-pointing it at whatever now shares the name would be a silent
  /// mis-resolution — exactly the failure the disambiguation panel exists to
  /// prevent.
  Future<Map<String, String>> _loadAliases() async {
    final rows = await _db.rawQuery(
      'SELECT src.path AS source_path, la.alias AS alias, tgt.path AS target '
      'FROM link_aliases la '
      'JOIN notes src ON src.id = la.source_note_id '
      'JOIN notes tgt ON tgt.id = la.target_note_id '
      'WHERE src.is_deleted = 0 AND tgt.is_deleted = 0',
    );
    return <String, String>{
      for (final row in rows)
        LinkIndex.aliasKey(
          row['source_path']! as String,
          row['alias']! as String,
        ): row['target']! as String,
    };
  }

  String _stemOf(String notePath) => p.posix.basenameWithoutExtension(
        VaultPaths.stripNotesPrefix(notePath) ?? notePath,
      );

  Future<_LinkCounts> _rebuildLinks(
    DatabaseExecutor txn,
    String sourcePath,
    String sourceUid,
    _ParsedNote entry,
    LinkIndex index,
  ) async {
    // Delete-then-insert, never upsert: a link the user removed from the text
    // must disappear from the graph, and an upsert keyed on the raw target
    // cannot express "it is gone".
    await txn.delete('links',
        where: 'source_note_id = ?', whereArgs: <Object?>[sourceUid]);

    var total = 0;
    var ambiguous = 0;
    var dangling = 0;
    var external = 0;

    for (final found in _allLinks(entry)) {
      final resolution = LinkResolver.resolve(index, sourcePath, found.link);
      switch (resolution.method) {
        case LinkMethod.ambiguous:
          ambiguous++;
        case LinkMethod.dangling:
          dangling++;
        case LinkMethod.external:
          external++;
        case _:
          break;
      }

      await txn.insert(
        'links',
        <String, Object?>{
          'source_note_id': sourceUid,
          'target_note_id': resolution.targetNoteId,
          'target_path': resolution.targetPath ?? found.link.target,
          'raw_target': found.link.target,
          'link_type': found.link.isEmbed ? 'embed' : found.type,
          'is_external': resolution.method == LinkMethod.external ? 1 : 0,
        },
        // The same target can legitimately appear twice in one note
        // (`[[a]] ... [[a]]`). Collapsing them would lose the fact that the
        // user referenced it twice; the index is for navigation, not counting.
        // The unique index on (source, raw_target, type) still keeps a
        // re-index from accumulating rows.
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      total++;
    }
    return _LinkCounts(total, ambiguous, dangling, external);
  }

  /// Wiki links and markdown links, each tagged with its `link_type`.
  ///
  /// Order is wiki-then-markdown and both keep source order, so the link rows
  /// come out the same on every machine — which is what makes a diff of two
  /// devices' indexes meaningful.
  List<({WikiLink link, String type})> _allLinks(_ParsedNote entry) {
    final body = entry.parsed.body;
    return <({WikiLink link, String type})>[
      for (final l in entry.parsed.links) (link: l, type: 'wiki'),
      for (final l in _parser.extractMarkdownLinks(body)) (link: l, type: 'markdown'),
    ];
  }

  Future<void> _rebuildTags(
      DatabaseExecutor txn, String sourceUid, ParsedNote note) async {
    await txn.delete('note_tags',
        where: 'note_id = ?', whereArgs: <Object?>[sourceUid]);
    for (final raw in note.tags) {
      final name = raw.trim();
      if (name.isEmpty) continue;
      await txn.insert('tags', <String, Object?>{'name': name},
          conflictAlgorithm: ConflictAlgorithm.ignore);
      await txn.insert('note_tags', <String, Object?>{'note_id': sourceUid, 'tag': name},
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  Future<void> _rebuildAttachments(
    DatabaseExecutor txn,
    String notePath,
    String noteUid,
    _ParsedNote entry,
    Map<String, _ScannedFile> attachments,
  ) async {
    final dir = VaultPaths.attachmentsDirForNote(notePath);
    final referenced = <String>{};
    for (final found in _allLinks(entry)) {
      if (!found.link.isAttachmentLike) continue;
      final resolved = VaultPaths.resolveWithinVault(
        vaultRoot: _files.vaultRoot,
        notePath: notePath,
        linkTarget: found.link.target,
      );
      if (resolved != null) {
        final noteKey = _files.notePathFor(resolved);
        if (noteKey != null) referenced.add(noteKey);
      }
    }

    for (final entry in attachments.entries) {
      if (!entry.key.startsWith('$dir/')) continue;
      if (!referenced.contains(entry.key)) continue;
      await txn.insert(
        'attachments',
        <String, Object?>{
          'id': _uuid.v4(),
          'note_id': noteUid,
          'path': entry.key,
          'filename': p.posix.basename(entry.key),
          'mime': mimeTypeFor(entry.key),
          'size': entry.value.size,
          'content_hash': ContentHash.ofBytes(entry.value.bytes),
          'created_at': _now().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }

  /// Reports attachment rows whose file is gone, and deletes nothing.
  ///
  /// §4.4: "文件缺失时记录警告，不删除元数据". The metadata row is the only
  /// remaining evidence that the note ever referenced that file; deleting it
  /// would turn "this attachment is missing" into "this note never had one",
  /// which is a claim the scanner is not in a position to make.
  Future<List<String>> _reportMissingAttachments(
      DatabaseExecutor txn, Map<String, _ScannedFile> attachments) async {
    final rows = await txn.query('attachments', columns: <String>['id', 'path']);
    final present = attachments.keys.toSet();
    final missing = <String>[];
    for (final row in rows) {
      final path = row['path']! as String;
      if (!present.contains(path)) missing.add(path);
    }
    missing.sort();
    return missing;
  }
}

/// Scanned file facts, kept together so pass 1 and pass 2 read the same bytes.
class _ScannedFile {
  const _ScannedFile({
    required this.path,
    required this.bytes,
    required this.size,
    required this.mtimeMs,
  });

  final String path;
  final List<int> bytes;
  final int size;
  final int mtimeMs;
}

class _ParsedNote {
  const _ParsedNote({
    required this.file,
    required this.parsed,
    required this.bytes,
  });

  final _ScannedFile file;
  final ParsedNote parsed;

  /// The bytes as they stand *now* — after a uid write-back, if any.
  final List<int> bytes;
}

class _LinkCounts {
  const _LinkCounts(this.total, this.ambiguous, this.dangling, this.external);

  final int total;
  final int ambiguous;
  final int dangling;
  final int external;
}

/// Documents why reindex never deletes a note.
abstract final class Reindex {
  /// Reindex is the *only* place that can see both sides at once, and it is
  /// exactly the place where a mistake is most expensive: it runs right after
  /// a sync round that may have failed part-way, it runs while the vault may
  /// be on a disconnected drive, and it runs before the user has seen the
  /// files. Turning "I did not see this file" into "this note is deleted" in
  /// that position converts a transient IO problem into a deletion propagated
  /// to every device.
  ///
  /// The decision belongs to whoever knows what should be there: the sync
  /// engine, comparing against the remote listing it just built.
  static const String rationale =
      'Reindex reports missing paths; only the sync engine deletes them.';
}