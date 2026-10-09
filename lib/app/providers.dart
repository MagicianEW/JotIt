import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/db/note_dao.dart';
import '../data/search/note_search.dart';
import 'vault_locator.dart';
import 'vault_session.dart';

/// Resolved on startup so the first-run check has something to inspect.
///
/// [VaultLocator] needs the private app directory to keep the chosen path,
/// and this is the one place that asks the platform for it.
final vaultLocatorProvider = FutureProvider<VaultLocator>((ref) async {
  final support = await getApplicationSupportDirectory();
  return VaultLocator(Directory(p.join(support.path, 'JotIt')));
});

/// The open vault. Resolved once at startup; nothing below this point knows
/// where the vault lives, and tests override this with a temp directory.
///
/// Depends on [vaultLocatorProvider] rather than resolving a location of its
/// own, so changing the location invalidates exactly one thing and the old
/// database is closed before the new one is opened.
final vaultProvider = FutureProvider<VaultSession>((ref) async {
  final locator = await ref.watch(vaultLocatorProvider.future);
  final root = (await locator.resolve()).path;
  final session = await VaultSession.open(root);
  ref.onDispose(session.close);
  return session;
});

/// Bumped by every mutation, so the list and the search results re-read the
/// index instead of drifting away from the files.
class NotesVersion extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state = state + 1;
}

final notesVersionProvider = NotifierProvider<NotesVersion, int>(
  NotesVersion.new,
);

class SearchQuery extends Notifier<String> {
  @override
  String build() => '';

  void set(String value) => state = value;
}

final searchQueryProvider =
    NotifierProvider<SearchQuery, String>(SearchQuery.new);

class OpenNote extends Notifier<String?> {
  @override
  String? build() => null;

  // No invalidation lives here on purpose: from this Notifier's ref,
  // invalidating editableNoteProvider reads as a circular dependency (that
  // provider watches this one). Staleness is broken where it is caused —
  // every mutation bumps notesVersionProvider, which editableNoteProvider
  // watches — not where the file happens to be opened.
  void open(String? path) => state = path;
}

final openNoteProvider =
    NotifierProvider<OpenNote, String?>(OpenNote.new);

/// The note list, re-read whenever [notesVersionProvider] changes.
class NoteListState {
  const NoteListState({required this.notes, required this.total});

  final List<NoteRecord> notes;
  final int total;
}

final noteListProvider = FutureProvider<NoteListState>((ref) async {
  final session = await ref.watch(vaultProvider.future);
  ref.watch(notesVersionProvider);
  final dao = session.notes;
  return NoteListState(
    notes: await dao.allActive(limit: 500),
    total: await dao.countActive(),
  );
});

/// Search results for [query]. An empty query yields an empty list rather than
/// the whole vault, so the UI can tell "not searching" from "found nothing".
final searchResultsProvider =
    FutureProvider.family<List<SearchHit>, String>((ref, query) async {
  final session = await ref.watch(vaultProvider.future);
  ref.watch(notesVersionProvider);
  final trimmed = query.trim();
  if (trimmed.isEmpty) return const <SearchHit>[];
  return session.search.search(trimmed, limit: 200);
});

final editableNoteProvider = FutureProvider<EditableNote?>((ref) async {
  final session = await ref.watch(vaultProvider.future);
  // Every mutation bumps this version — the user's own saves and anything
  // the sync engine writes back. Watching it is what makes "open → edit →
  // save → close → open again" read the file as it is now: without this the
  // provider re-runs only when the open path changes, and reopening the
  // same path re-served the pre-save text.
  ref.watch(notesVersionProvider);
  final path = ref.watch(openNoteProvider);
  if (path == null) return null;
  return session.readForEdit(path);
});

/// Every mutation funnels through here so no two views can disagree about what
/// is on disk.
void invalidateNotes(WidgetRef ref) =>
    ref.read(notesVersionProvider.notifier).bump();

/// The same, for callers that hold a [Ref] rather than a [WidgetRef] — the
/// sync controller runs outside the widget tree.
void invalidateNotesFromRef(Ref ref) =>
    ref.read(notesVersionProvider.notifier).bump();