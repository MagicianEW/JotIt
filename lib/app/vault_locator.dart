import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Where the vault lives, and whether that choice is still safe.
///
/// `Documents/JotIt` is the right default for almost everyone, and it was
/// chosen because these notes are meant to be ordinary files the user opens,
/// edits and backs up with everything else. It is also, on at least one real
/// machine, the folder someone keeps their JotIt **source** in — and a vault
/// that silently adopts somebody's project directory is not "ordinary files",
/// it is a surprise.
///
/// So the location is stored rather than assumed, and the default is only
/// adopted when the folder is empty or is already a vault.
class VaultLocator {
  VaultLocator(this._appSupportDir, {Directory? documentsDir})
      : _documentsOverride = documentsDir;

  final Directory _appSupportDir;
  final Directory? _documentsOverride;

  static const String _fileName = 'jotit.json';

  File get _file => File(p.join(_appSupportDir.path, _fileName));

  /// The default location, resolved lazily for the same reason the credential
  /// key is: `path_provider` is a platform channel, and putting it on the
  /// startup path makes the whole app untestable without a plugin.
  Future<Directory> defaultDir() async {
    final override = _documentsOverride;
    if (override != null) return Directory(p.join(override.path, 'JotIt'));
    final docs = await getApplicationDocumentsDirectory();
    return Directory(p.join(docs.path, 'JotIt'));
  }

  /// The configured location, or the default when nothing is stored.
  ///
  /// The [fromPreference] flag is what stops the first-run question from
  /// coming back on its own: a user who answered "仍然使用" has answered it,
  /// and asking them again every launch is worse than asking once.
  Future<VaultLocation> resolve() async {
    try {
      final raw = await _file.readAsString();
      final json = jsonDecode(raw);
      if (json is Map) {
        final path = json['vault_path'] as String?;
        if (path != null && path.trim().isNotEmpty) {
          return VaultLocation(path: path, fromPreference: true);
        }
      }
    } on Object {
      // A missing or unreadable settings file means "no preference yet", which
      // is exactly what an absent file means. Refusing to start over it would
      // be a self-inflicted lockout.
    }
    return VaultLocation(path: (await defaultDir()).path, fromPreference: false);
  }

  Future<void> store(Directory dir) async {
    await _appSupportDir.create(recursive: true);
    await _file.writeAsString(
      jsonEncode(<String, Object?>{'vault_path': dir.path}),
      flush: true,
    );
  }

  /// True when [dir] already holds a JotIt vault.
  static bool isVault(Directory dir) =>
      Directory(p.join(dir.path, '.jotit')).existsSync();

  /// The verdict for a candidate location, before anything is written there.
  ///
  /// Three cases, and the middle one is the reason this class exists.
  static VaultVerdict inspect(Directory dir) {
    if (!dir.existsSync()) return VaultVerdict.fresh;
    if (isVault(dir)) return VaultVerdict.existingVault;
    if (dir.listSync().isEmpty) return VaultVerdict.emptyFolder;
    return VaultVerdict.occupied;
  }
}

/// Where the vault will be opened from, and how that came about.
class VaultLocation {
  const VaultLocation({required this.path, required this.fromPreference});

  final String path;

  /// True when this location was stored on purpose, false when it is merely
  /// the default nobody has agreed to yet.
  final bool fromPreference;
}

/// What [VaultLocator.inspect] found.
enum VaultVerdict {
  /// Nothing there. Safe to create.
  fresh,

  /// There, and empty. Safe to create.
  emptyFolder,

  /// There, and already a vault. Just open it.
  existingVault,

  /// There, has somebody else's files in it, and is not a vault.
  ///
  /// Adopting it is not destructive — JotIt only ever reads `notes/` — but it
  /// puts a vault inside a folder of unrelated things, and the user's first
  /// note lands somewhere they did not choose.
  occupied,
}