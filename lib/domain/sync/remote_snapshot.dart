import '../../data/db/sync_meta_store.dart';

/// What a single remote resource looks like right now.
///
/// Only the fields change detection actually needs. In particular the ETag is
/// carried verbatim and never inspected: §6.2 records it as an opaque token,
/// because Synology's `size-hex-mtimeHex`, nginx's and Nextcloud's have nothing
/// in common, and any code that starts parsing it breaks on a server upgrade.
class RemoteEntry {
  const RemoteEntry({
    required this.path,
    required this.etag,
    this.contentLength,
    this.lastModified,
    this.isCollection = false,
  });

  /// Vault-relative POSIX path, matching `sync_meta.path`.
  final String path;

  /// Opaque token, including whatever quoting the server used.
  final String? etag;

  final int? contentLength;
  final DateTime? lastModified;
  final bool isCollection;
}

/// One round's view of the remote side.
class RemoteSnapshot {
  RemoteSnapshot({
    Map<String, RemoteEntry>? entries,
    this.collectionCtag,
    this.probedCtag = false,
  }) : entries = entries ?? <String, RemoteEntry>{};

  /// Every resource under the synced subtree, keyed by vault path.
  final Map<String, RemoteEntry> entries;

  /// Collection-level change token, when the server has one. Its absence is
  /// itself information: §6.2 says CTag comes from RFC 3253 and that only
  /// Nextcloud / ownCloud / SabreDAV implement it.
  final String? collectionCtag;

  /// Distinguishes "the server said there is no CTag" from "we did not ask".
  /// Only the former justifies falling back to a full depth=1 walk.
  final bool probedCtag;

  Iterable<RemoteEntry> get files =>
      entries.values.where((e) => !e.isCollection);

  Iterable<RemoteEntry> get collections =>
      entries.values.where((e) => e.isCollection);

  /// Immediate child collections of [parentPath].
  List<RemoteEntry> childCollectionsOf(String parentPath) {
    final prefix = parentPath.isEmpty ? '' : '$parentPath/';
    final out = <RemoteEntry>[];
    for (final e in collections) {
      if (!e.path.startsWith(prefix)) continue;
      final rest = e.path.substring(prefix.length);
      // Depth 1: only entries with no further separator are direct children.
      if (!rest.contains('/') && rest.isNotEmpty) out.add(e);
    }
    out.sort((a, b) => a.path.compareTo(b.path));
    return out;
  }
}

/// Whether a remote entry differs from the recorded base.
enum RemoteChange {
  unchanged,

  changed,

  /// Not enough information to tell — the server sent no ETag and no usable
  /// size or timestamp. Callers must re-fetch: assuming "unchanged" here is
  /// the one answer that can silently lose a remote edit.
  unknown,
}

/// The paths this round's snapshot disagrees with the base on.
class RemoteChanges {
  const RemoteChanges({
    this.added = const <String>[],
    this.changed = const <String>[],
    this.deleted = const <String>[],
    this.unknown = const <String>[],
  });

  /// Present remotely, no base row: a file this device has never seen.
  final List<String> added;

  /// Present on both sides with a different ETag.
  final List<String> changed;

  /// In the base, absent from the snapshot. Not yet a deletion decision — the
  /// matrix weighs this against the local state (§5.3 rows 4 and 5).
  final List<String> deleted;

  /// Present on both sides but not comparable.
  final List<String> unknown;

  bool get isEmpty =>
      added.isEmpty &&
      changed.isEmpty &&
      deleted.isEmpty &&
      unknown.isEmpty;

  int get total => added.length + changed.length + deleted.length + unknown.length;

  @override
  String toString() => 'RemoteChanges(+${added.length} ~${changed.length} '
      '-${deleted.length} ?${unknown.length})';
}

/// Compares a [RemoteSnapshot] against the recorded merge base.
///
/// Pure, and the only place a "the remote changed" verdict is produced. The
/// §5.3 matrix consumes the result; it never compares ETags itself.
abstract final class RemoteDiff {
  static RemoteChanges between(
    RemoteSnapshot snapshot,
    List<SyncMetaRecord> base,
  ) {
    final byPath = {for (final r in base) r.path: r};
    final added = <String>[];
    final changed = <String>[];
    final unknown = <String>[];

    for (final entry in snapshot.files) {
      final record = byPath[entry.path];
      if (record == null) {
        added.add(entry.path);
        continue;
      }
      switch (classify(entry, record)) {
        case RemoteChange.unchanged:
          break;
        case RemoteChange.changed:
          changed.add(entry.path);
        case RemoteChange.unknown:
          unknown.add(entry.path);
      }
    }

    final deleted = base
        .map((r) => r.path)
        .where((path) => !snapshot.entries.containsKey(path))
        .toList();

    added.sort();
    changed.sort();
    deleted.sort();
    unknown.sort();
    return RemoteChanges(
      added: added,
      changed: changed,
      deleted: deleted,
      unknown: unknown,
    );
  }

  /// The verdict for one path. The ETag comparison is a bare `!=`: a token is
  /// only ever equal or not.
  ///
  /// With an ETag missing on either side the answer is [RemoteChange.unknown]
  /// rather than a guess from size or mtime. Neither is stored in `sync_meta`,
  /// and inventing a weaker comparison here would mean a server that quietly
  /// stopped sending ETags looks unchanged forever — precisely the failure
  /// §6.2's capability negotiation exists to prevent. Unknown costs a re-fetch;
  /// a wrong "unchanged" costs somebody's edit.
  static RemoteChange classify(RemoteEntry entry, SyncMetaRecord base) {
    final remoteEtag = entry.etag;
    final baseEtag = base.baseEtag;
    if (remoteEtag == null || baseEtag == null) return RemoteChange.unknown;
    return remoteEtag == baseEtag ? RemoteChange.unchanged : RemoteChange.changed;
  }

  /// True when the snapshot proves nothing changed and the walk can be
  /// skipped entirely.
  ///
  /// Only ever true when the server actually reported a CTag. A server with no
  /// CTag must be walked every round — treating "I have no idea" as "nothing
  /// changed" is how v2.0 reported every device as in sync forever.
  static bool canSkipWalk(RemoteSnapshot snapshot, String? baseCtag) {
    if (!snapshot.probedCtag) return false;
    final current = snapshot.collectionCtag;
    if (current == null) return false;
    return baseCtag != null && current == baseCtag;
  }
}