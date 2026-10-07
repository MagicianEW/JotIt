import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:jotit/app/providers.dart';
import 'package:jotit/app/vault_locator.dart';
import 'package:jotit/app/vault_session.dart';
import 'package:jotit/main.dart';
import 'package:path/path.dart' as p;

/// Boots the real shell — location gate, lock gate, home page — over a vault
/// in a temp directory.
///
/// Both providers have to be replaced, not just [vaultProvider]. The location
/// gate is in front of everything, and it asks `path_provider` for the app
/// support directory; under `flutter_test` no platform answers that channel,
/// so a test that overrides only the vault never gets past the gate. That is
/// worth having: it is the same failure a user would get from a broken
/// support directory, and the gate is supposed to fail open rather than wedge
/// them out of their own notes.
///
/// The default location is aimed at a directory that does not exist, so the
/// gate has nothing to ask and these tests exercise the shell rather than the
/// first-run dialog. `vault_location_gate_test.dart` is where that dialog is
/// tested.
Widget bootApp({required VaultSession vault, required Directory root}) =>
    ProviderScope(
      overrides: [
        vaultProvider.overrideWith((ref) async => vault),
        vaultLocatorProvider.overrideWith(
          (ref) async => VaultLocator(
            Directory(p.join(root.path, '.app-support')),
            documentsDir: root.parent,
          ),
        ),
      ],
      child: const JotItApp(),
    );
