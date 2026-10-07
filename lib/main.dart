import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ui/home_page.dart';
import 'ui/lock_gate.dart';
import 'ui/vault_location_gate.dart';

/// The JotIt shell.
///
/// The theme is plain on purpose. This app's whole pitch is that the notes are
/// ordinary Markdown in an ordinary folder, and a UI that dresses them up
/// would be arguing with the thing it is selling.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: JotItApp()));
}

class JotItApp extends StatelessWidget {
  const JotItApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'JotIt',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3F6C51),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3F6C51),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      // Order matters: where the vault is, then whether it is locked, then the
      // vault itself. Asking about a lock in a vault that has not been chosen
      // yet would open the wrong database to find out.
      home: const VaultLocationGate(
        child: LockGate(child: HomePage()),
      ),
    );
  }
}