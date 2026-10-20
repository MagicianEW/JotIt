import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/db/note_dao.dart';
import '../data/search/note_search.dart';
import '../ui/camera_capture_page.dart';
import 'clip_player.dart';
import 'vault_locator.dart';
import 'vault_session.dart';
import 'photo_service.dart';
import 'voice_recorder.dart';

/// The microphone recorder.
///
/// One for the whole app, not one per editor: the recorder holds a device
/// resource, and a second one while the first is still open is a second
/// microphone session the platform will refuse.
///
/// A plain `Provider` and not an `autoDispose` one. A recorder that is
/// disposed the moment the editor stops watching it would take the platform
/// session down with it — and the recording is not finished at that point:
/// the stop button lives on the same page.
final voiceRecorderProvider = Provider<VoiceRecorder>((ref) {
  final recorder = PluginVoiceRecorder();
  ref.onDispose(() {
    unawaited(recorder.dispose());
  });
  return recorder;
});

/// Builds the player for one recorded clip.
///
/// A provider rather than a direct call, for the same reason the recorder is
/// one: the player is a platform channel, and a preview that cannot be built
/// without one cannot be tested. The factory is a *factory* because a clip
/// owns its player — one preview showing three clips needs three of them.
///
/// Inside `flutter test` the default is a silent player. The real one keeps a
/// periodic timer alive for as long as it exists, and a widget test refuses
/// to finish while a timer is pending — so a test that renders a clip would
/// hang for its whole timeout instead of failing. A test that wants to drive
/// a clip overrides this with a fake, which is also the only way to say what
/// the clip did.
final clipPlayerFactoryProvider = Provider<ClipPlayer Function()>((ref) {
  final inTest = !kIsWeb && Platform.environment.containsKey('FLUTTER_TEST');
  if (inTest) return () => SilentClipPlayer();
  return () => PluginClipPlayer();
});

/// 取照片的服务。
///
/// 拍照和选图都是平台通道，在 `flutter test` 里没有实现，所以这一层必须
/// 可替换——和录音、播放是同一个理由。这里注入桌面端的取景页，是因为
/// 桌面系统没有系统相机界面，那部分界面住在界面层，而这一层不该反过来
/// 认得界面。
final photoServiceProvider = Provider<PhotoService>((ref) {
  return PluginPhotoService(
    desktopCapture: (context) => CameraCapturePage.capture(context),
  );
});

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
  // The profile directory comes from the locator rather than being resolved
  // again inside the session: in the app they are the same directory, but a
  // test that points the locator at a temp directory would otherwise have
  // the credential cipher write its master key into the *real* profile
  // directory of the machine running the test.
  final session = await VaultSession.open(root, appDataDir: locator.appSupportDir);
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
    // The shelf renders one line per note, so the list only needs the first
    // line of each body. The full text of 500 notes is megabytes crossing a
    // platform channel to fill 500 one-line excerpts.
    notes: await dao.allActiveExcerpts(limit: 500),
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