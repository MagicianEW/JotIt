import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/vault_paths.dart';

/// What moving a note did to the folder of attachments that travels with it.
class MoveOutcome {
  const MoveOutcome({
    this.moved = 0,
    this.identical = 0,
    this.collisions = const <String>[],
    this.relocations = const <String, String>{},
  });

  /// Files carried to the new location.
  final int moved;

  /// Files that were already at the destination with the same bytes.
  ///
  /// Counted separately from [moved] because the *cause* is different: a
  /// moved file is this device catching up, an identical one is the other
  /// device having already done the move and this one arriving second.
  final int identical;

  /// Destination files that already existed with **different** bytes.
  ///
  /// Left where they are, at both ends. Overwriting is what C3 forbids, and
  /// these are immutable paths (§9.3 / ADR-11), so two different files at two
  /// destinations is a fact for a person to resolve rather than a diff to
  /// resolve automatically.
  final List<String> collisions;

  /// Old vault path → new vault path, for every file the move carried.
  ///
  /// The caller needs this to finish the move on the server. §5.5 treats a
  /// path as an identity, so the copy still sitting at the old path is not
  /// "stale metadata" — it is a second copy of an immutable file that will
  /// otherwise sit on the server forever, and which another device would
  /// happily download back as a phantom duplicate.
  final Map<String, String> relocations;

  bool get isEmpty => moved == 0 && identical == 0 && collisions.isEmpty;

  @override
  String toString() => 'MoveOutcome(moved $moved, identical $identical, '
      'collisions ${collisions.length}, relocated ${relocations.length})';
}

/// Carries a note's `attachments/` folder when the note moves (v3.0 §9.3
/// rule 4).
///
/// **Why the links need no rewriting.** The rule that would normally force it
/// is §9.3 rule 2: a pasted file always lands in an `attachments/` folder
/// *beside the note*. If the folder travels with the note, the attachment is
/// still at `dirname(note)/attachments/x.png` and the link is still
/// `attachments/x.png`, whatever depth the note now sits at. A mover that
/// rewrote links would be solving a problem it had itself created.
///
/// The bug this exists for: the sync engine renames the note file and nothing
/// else. On the device that adopts a rename, the picture is then still in the
/// old folder while the note's link — which came down with the note text —
/// points at the new one. The note arrives intact and the image inside it is
/// broken, and since the note is a plain `.md` file it renders fine in every
/// other tool. Nothing anywhere says anything is wrong.
class NoteMover {
  NoteMover({required this.vaultRoot, this.bytesEqual = _defaultEqual});

  final String vaultRoot;

  /// Injectable so a test can drive a collision without a 100 MB fixture.
  final Future<bool> Function(List<int> a, List<int> b) bytesEqual;

  static Future<bool> _defaultEqual(List<int> a, List<int> b) async {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Directory? _dirOf(String vaultPath) {
    if (!VaultPaths.isInsideNotes(vaultPath)) return null;
    return Directory(p.joinAll([vaultRoot, ...p.split(vaultPath)]));
  }

  /// Moves the attachments of [fromNotePath] to wherever [toNotePath] keeps
  /// them.
  ///
  /// No-ops when the two notes share a directory, which is the common case:
  /// `daily/2024-01-01.md` becoming `daily/2024-01-02.md` has nothing to do
  /// with attachments.
  Future<MoveOutcome> moveAttachments({
    required String fromNotePath,
    required String toNotePath,
  }) async {
    final from = VaultPaths.attachmentsDirForNote(fromNotePath);
    final to = VaultPaths.attachmentsDirForNote(toNotePath);
    if (from == to) return const MoveOutcome();

    final source = _dirOf(from);
    if (source == null || !await source.exists()) return const MoveOutcome();

    final destination = _dirOf(to);
    if (destination == null) return const MoveOutcome();

    final entries = source.listSync().whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    var moved = 0;
    var identical = 0;
    final collisions = <String>[];
    final relocations = <String, String>{};

    for (final file in entries) {
      final name = p.basename(file.path);
      final target = File(p.joinAll([destination.path, name]));
      final oldPath = VaultPaths.normalizeRelative('$from/$name');
      final newPath = VaultPaths.normalizeRelative('$to/$name');

      if (!await target.exists()) {
        await destination.create(recursive: true);
        // ADR-11: the path is immutable, so there is nothing at the
        // destination to overwrite and nothing to merge.
        await file.rename(target.path);
        if (oldPath != null && newPath != null) relocations[oldPath] = newPath;
        moved++;
        continue;
      }

      final same = await bytesEqual(await file.readAsBytes(), await target.readAsBytes());
      if (same) {
        // The same immutable file, already carried by whoever moved the note
        // first. Keeping both would be a duplicate that syncs forever.
        await file.delete();
        // Still a relocation for the server's purposes: the copy at the old
        // path has to go there too, or it comes back on the next round.
        if (oldPath != null && newPath != null) relocations[oldPath] = newPath;
        identical++;
        continue;
      }

      collisions.add(VaultPaths.normalizeRelative('$to/$name') ?? '$to/$name');
    }

    // The empty folder left behind is not worth keeping: an empty
    // `attachments/` in a directory that has no notes is just clutter, and a
    // later paste would reuse it harmlessly either way.
    if (source.listSync().isEmpty) {
      try {
        await source.delete();
      } on FileSystemException {
        // Another process may hold it open on Windows. Leaving an empty
        // folder is untidy, not wrong.
      }
    }

    return MoveOutcome(
      moved: moved,
      identical: identical,
      collisions: collisions,
      relocations: relocations,
    );
  }
}
