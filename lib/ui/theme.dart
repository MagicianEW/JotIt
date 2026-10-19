import 'package:flutter/material.dart';

/// Design tokens for JotIt's "quiet study" look.
///
/// The app's pitch is that notes are ordinary Markdown in an ordinary folder,
/// so the interface must stay out of the way: warm paper, one green accent,
/// hairline rules, no gradients and no decorative shadows. Every colour and
/// size the screens use lives here — a screen that hard-codes a hex value is
/// a screen that will drift away from the rest.
///
/// Source of truth: UI美化设计文档 §3 (design tokens).
class JotItTokens {
  const JotItTokens._();

  // Radii. Small values for inline bits, medium for cards and inputs, large
  // for the floating action button and the lock card.
  static const double rXs = 6;
  static const double rSm = 8;
  static const double rMd = 12;
  static const double rLg = 16;

  // Spacing, on a 4 px base. Bear's spacing system is the reference: a
  // rhythm beats a pile of one-off values.
  static const double s1 = 4;
  static const double s2 = 8;
  static const double s3 = 12;
  static const double s4 = 16;
  static const double s5 = 24;
  static const double s6 = 32;

  /// Prose column on wide screens. 45–75 characters per line is the range
  /// reading research keeps pointing at; at 16 px that is about 680 px.
  static const double readingWidth = 680;

  /// Padding around the note body: phones get 16, desktop gets 24.
  static double gutter(double width) => width >= 600 ? s5 : s4;

  /// Monospace stack, shared by the source view, code blocks and the status
  /// bar facts.
  ///
  /// The old code named `Consolas` alone, which exists only on Windows: on
  /// macOS and Android the text silently fell back to a proportional face,
  /// and CJK text inside code lost its monospace alignment entirely.
  static const List<String> monoFallback = <String>[
    'Menlo', // macOS
    'Roboto Mono', // Android
    'DejaVu Sans Mono', // Linux
    'Noto Sans Mono CJK SC', // CJK coverage
  ];

  static const TextStyle monoBase = TextStyle(
    fontFamily: 'Consolas',
    fontFamilyFallback: monoFallback,
    fontSize: 13.5,
    height: 1.6,
  );

  static TextStyle mono(Color color) => monoBase.copyWith(color: color);
}

class JotItTheme {
  const JotItTheme._();

  /// The app keeps one coloured voice: a deep pine green for ink, actions and
  /// selection. Everything else is a warm neutral — the palettes here are the
  /// hand-tuned paper/warm-dark sets from the design document, not M3's
  /// colder generated defaults.
  static ColorScheme _lightScheme() {
    final base = ColorScheme.fromSeed(
      seedColor: const Color(0xFF3F6C51),
      brightness: Brightness.light,
    );
    return base.copyWith(
      primary: const Color(0xFF2E5B43),
      onPrimary: const Color(0xFFFFFFFF),
      primaryContainer: const Color(0xFFCFE6D6),
      onPrimaryContainer: const Color(0xFF0F3325),
      secondary: const Color(0xFF53624F),
      onSecondary: const Color(0xFFFFFFFF),
      secondaryContainer: const Color(0xFFE2E8DC),
      onSecondaryContainer: const Color(0xFF37422F),
      tertiary: const Color(0xFF6E5A2E),
      onTertiary: const Color(0xFFFFFFFF),
      tertiaryContainer: const Color(0xFFF3E5C8),
      onTertiaryContainer: const Color(0xFF46380F),
      error: const Color(0xFFB3261E),
      onError: const Color(0xFFFFFFFF),
      errorContainer: const Color(0xFFF9DEDC),
      onErrorContainer: const Color(0xFF410E0B),
      surface: const Color(0xFFFAF8F3),
      surfaceContainerLowest: const Color(0xFFFFFFFF),
      surfaceContainerLow: const Color(0xFFF4F1E9),
      surfaceContainer: const Color(0xFFEFEBE0),
      surfaceContainerHigh: const Color(0xFFE9E5D9),
      surfaceContainerHighest: const Color(0xFFE2DDCF),
      onSurface: const Color(0xFF1D1C17),
      onSurfaceVariant: const Color(0xFF4C4A3F),
      outline: const Color(0xFF7C7A6C),
      outlineVariant: const Color(0xFFD6D2C2),
      inverseSurface: const Color(0xFF32302A),
      onInverseSurface: const Color(0xFFF4F1E9),
      shadow: const Color(0xFF000000),
    );
  }

  static ColorScheme _darkScheme() {
    final base = ColorScheme.fromSeed(
      seedColor: const Color(0xFF3F6C51),
      brightness: Brightness.dark,
    );
    return base.copyWith(
      primary: const Color(0xFFA5D6B4),
      onPrimary: const Color(0xFF123824),
      primaryContainer: const Color(0xFF2C5138),
      onPrimaryContainer: const Color(0xFFC0EACB),
      secondary: const Color(0xFFBAC9AE),
      onSecondary: const Color(0xFF1F2A1C),
      secondaryContainer: const Color(0xFF3A4433),
      onSecondaryContainer: const Color(0xFFD6E4C8),
      tertiary: const Color(0xFFD9C48E),
      onTertiary: const Color(0xFF3B2F0E),
      tertiaryContainer: const Color(0xFF4E4226),
      onTertiaryContainer: const Color(0xFFF3E5C8),
      error: const Color(0xFFF2B8B5),
      onError: const Color(0xFF3B0908),
      errorContainer: const Color(0xFF8C1D18),
      onErrorContainer: const Color(0xFFF9DEDC),
      surface: const Color(0xFF14130F),
      surfaceContainerLowest: const Color(0xFF0E0D0A),
      surfaceContainerLow: const Color(0xFF1E1C17),
      surfaceContainer: const Color(0xFF23211B),
      surfaceContainerHigh: const Color(0xFF2D2B24),
      surfaceContainerHighest: const Color(0xFF38352C),
      onSurface: const Color(0xFFE8E4D8),
      onSurfaceVariant: const Color(0xFFCBC7B8),
      outline: const Color(0xFF97917F),
      outlineVariant: const Color(0xFF4B483C),
      inverseSurface: const Color(0xFFE8E4D8),
      onInverseSurface: const Color(0xFF32302A),
      shadow: const Color(0xFF000000),
    );
  }

  /// Type scale from the design document §3.2. No `fontFamily` anywhere:
  /// system fonts mean zero download, zero flash of invisible text, and the
  /// platform's own idea of "normal text" — the same call Obsidian makes.
  static TextTheme _textTheme(ColorScheme scheme) {
    final ink = scheme.onSurface;
    final soft = scheme.onSurfaceVariant;
    return TextTheme(
      titleLarge: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        height: 1.4,
        color: ink,
        letterSpacing: 0.5,
      ),
      titleMedium: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        height: 1.5,
        color: ink,
      ),
      titleSmall: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        height: 1.4,
        color: ink,
      ),
      bodyLarge: TextStyle(fontSize: 16, height: 1.75, color: ink),
      bodyMedium: TextStyle(fontSize: 14, height: 1.6, color: soft),
      bodySmall: TextStyle(fontSize: 12, height: 1.5, color: soft),
      labelLarge: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        height: 1.2,
        color: ink,
      ),
      labelSmall: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        height: 1.2,
        color: soft,
      ),
    );
  }

  static ThemeData _build(ColorScheme scheme) {
    final text = _textTheme(scheme);
    final hairline = BorderSide(color: scheme.outlineVariant);

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      textTheme: text,
      // A hairline under the app bar instead of a shadow: elevation is reserved
      // for things that genuinely float (FAB, menus, dialogs).
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: text.titleLarge,
        iconTheme: IconThemeData(color: scheme.onSurfaceVariant),
        shape: Border(bottom: hairline),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        space: 1,
        thickness: 1,
      ),
      // Filled inputs with no rest-state outline: a field should read as a
      // slightly darker patch of paper, not as a box drawn on top of it.
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHigh,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        hintStyle: TextStyle(color: scheme.onSurfaceVariant.withValues(alpha: 0.7)),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(JotItTokens.rMd),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(JotItTokens.rMd),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(JotItTokens.rMd),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(JotItTokens.rMd),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: scheme.primary,
          textStyle: text.labelLarge,
        ),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: scheme.primary,
        selectionColor: scheme.primary.withValues(alpha: 0.2),
        selectionHandleColor: scheme.primary,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: TextStyle(color: scheme.onInverseSurface, fontSize: 14),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  static ThemeData get light => _build(_lightScheme());

  static ThemeData get dark => _build(_darkScheme());
}
