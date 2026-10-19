import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ui/home_page.dart';
import 'ui/lock_gate.dart';
import 'ui/theme.dart';
import 'ui/vault_location_gate.dart';

/// The JotIt shell.
///
/// The interface is paper, not an application: notes are ordinary Markdown in
/// an ordinary folder, so the chrome stays quiet and the text carries the
/// page. The tokens that make this true live in `ui/theme.dart` — one green
/// accent, warm neutral surfaces, hairline rules instead of shadows. Dressing
/// the notes up in gradients and cards would argue with the thing the app is
/// selling; making the paper warm and the type comfortable does not.
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
      theme: JotItTheme.light,
      darkTheme: JotItTheme.dark,
      // Order matters: where the vault is, then whether it is locked, then the
      // vault itself. Asking about a lock in a vault that has not been chosen
      // yet would open the wrong database to find out.
      home: const VaultLocationGate(
        child: LockGate(child: HomePage()),
      ),
    );
  }
}