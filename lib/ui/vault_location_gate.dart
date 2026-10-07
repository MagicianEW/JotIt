import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../app/providers.dart';
import '../app/vault_locator.dart';

/// Asks where the vault should live, when the default folder is already taken.
///
/// Shown once, before anything is written. The alternative — silently adopting
/// a folder that holds somebody's project — is not destructive, because
/// JotIt only ever reads `notes/`, but it is exactly the kind of quiet
/// surprise this app is supposed to be free of.
///
/// Both answers are remembered, so this never comes back on its own.
class VaultLocationGate extends ConsumerStatefulWidget {
  const VaultLocationGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<VaultLocationGate> createState() =>
      _VaultLocationGateState();
}

class _VaultLocationGateState extends ConsumerState<VaultLocationGate> {
  bool _checking = true;
  Directory? _occupied;
  late final TextEditingController _path;

  @override
  void initState() {
    super.initState();
    _path = TextEditingController();
    unawaited(_check());
  }

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final occupied = await _occupiedDir();
    if (!mounted) return;
    if (occupied != null) {
      _path.text =
          p.join(occupied.parent.path, '${p.basename(occupied.path)} 笔记');
    }
    setState(() {
      _occupied = occupied;
      _checking = false;
    });
  }

  /// The folder worth asking about, or null when there is nothing to ask.
  ///
  /// Fails open on purpose. This gate sits in front of the user's own notes,
  /// so any error reaching it — an unreadable settings file, a platform
  /// channel that is not answering, a permission error on somebody's
  /// Documents folder — must open the door rather than leave a spinner
  /// spinning. Worst case the user gets the default location, which is exactly
  /// where they would have started anyway, and the settings screen always
  /// shows where the vault actually is.
  Future<Directory?> _occupiedDir() async {
    try {
      final locator = await ref.read(vaultLocatorProvider.future);
      final chosen = await locator.resolve();

      // Only the *unstated default* is ever questioned. A location the user
      // picked — including "no, the default is fine after all" — is their
      // business, whatever is in it, and asking again every launch would make
      // this dialog a tax rather than a question.
      if (chosen.fromPreference) return null;

      final dir = Directory(chosen.path);
      final isDefault = p.equals(dir.path, (await locator.defaultDir()).path);
      if (!isDefault) return null;
      return VaultLocator.inspect(dir) == VaultVerdict.occupied ? dir : null;
    } on Object catch (error, stack) {
      // Surfaced, not swallowed: a vault that opens somewhere unexpected is
      // worth a line in the log, even when the right response is to carry on.
      FlutterError.reportError(FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'jotit',
        context: ErrorDescription(
          'deciding whether to ask about the vault location',
        ),
      ));
      return null;
    }
  }

  /// Records [path] as the chosen location, and reports whether it was.
  ///
  /// False means the field was blank, and nothing was written: an empty path
  /// is not "the current directory", it is `Directory('')`, and storing that
  /// would point the vault at whatever folder the process was launched from.
  Future<bool> _use(String path) async {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return false;
    final locator = await ref.read(vaultLocatorProvider.future);
    await locator.store(Directory(trimmed));
    return true;
  }

  Future<void> _accept(String path) async {
    if (!await _use(path)) return;
    if (!mounted) return;
    setState(() => _occupied = null);
    // The location changed under the provider that resolved it, so the vault
    // has to be opened again from scratch.
    ref.invalidate(vaultProvider);
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final occupied = _occupied;
    if (occupied == null) return widget.child;

    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.folder_shared_outlined, size: 40),
                  const SizedBox(height: 12),
                  Text('这个文件夹已经有别的东西',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  SelectableText(
                    '${occupied.path}\n\n'
                    '它不是空的，也不是一个 JotIt 库。JotIt 只读写里面的 '
                    'notes/，不会动你原有的文件，但把库放在这里并不是个好主意。',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _path,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: '换个位置',
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () => _accept(_path.text),
                    child: const Text('用这个位置'),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => _accept(occupied.path),
                    style: TextButton.styleFrom(foregroundColor: scheme.error),
                    child: Text('仍然使用 ${p.basename(occupied.path)}'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
