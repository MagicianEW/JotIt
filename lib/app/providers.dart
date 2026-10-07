import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/db/note_dao.dart';
import '../data/search/note_search.dart';
import 'vault_session.dart';

/// The open vault. Resolved once at startup; nothing below this point knows
/// where the vault lives, and tests override this with a temp directory.
final vaultProvider = FutureProvider<VaultSession>((ref) async {
  final root = await VaultSession.defaultVaultRoot();
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