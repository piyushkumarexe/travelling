import 'package:flutter/material.dart';

/// YatraWise "Clean Minimal" theme (uiverse-inspired soft UI):
/// fresh teal accent, hairline borders, soft shadows, pill-ish radii.
library;

class AppTheme {
  AppTheme._();

  static const Color seed = Color(0xFF0D9488);
  static const Color seedBright = Color(0xFF14B8A6);
  static const Color danger = Color(0xFFE11D48);
  static const Color warning = Color(0xFFF59E0B);
  static const Color success = Color(0xFF16A34A);

  static const double cardRadius = 18;

  /// Soft "floating card" shadow used across the app.
  static List<BoxShadow> softShadow(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    return <BoxShadow>[
      BoxShadow(
        color: Colors.black.withOpacity(dark ? 0.28 : 0.06),
        blurRadius: 18,
        offset: const Offset(0, 6),
      ),
    ];
  }

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final ColorScheme scheme =
        ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
    final bool dark = brightness == Brightness.dark;

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor:
          dark ? scheme.surface : const Color(0xFFF6F8F7),
      visualDensity: VisualDensity.adaptivePlatformDensity,
      appBarTheme: AppBarTheme(
        backgroundColor: dark ? scheme.surface : const Color(0xFFF6F8F7),
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 20,
          fontWeight: FontWeight.w800,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: dark ? scheme.surfaceContainer : Colors.white,
        indicatorColor: scheme.primary.withOpacity(0.12),
        elevation: 8,
        labelTextStyle: WidgetStatePropertyAll<TextStyle>(
          TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: danger,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 15,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: scheme.primary, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: scheme.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: scheme.error, width: 1.6),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        showDragHandle: true,
        backgroundColor: Colors.transparent,
      ),
      progressIndicatorTheme:
          const ProgressIndicatorThemeData(color: seed),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant),
      listTileTheme: ListTileThemeData(iconColor: scheme.primary),
    );
  }

  /// Filled "card" style used across the app (avoids global CardTheme which
  /// changed type across Flutter versions).
  static BoxDecoration cardBox(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    return BoxDecoration(
      color: dark ? scheme.surfaceContainerLow : Colors.white,
      borderRadius: BorderRadius.circular(cardRadius),
      border: Border.all(color: scheme.outlineVariant.withOpacity(0.5)),
      boxShadow: <BoxShadow>[
        BoxShadow(
          color: Colors.black.withOpacity(dark ? 0.28 : 0.06),
          blurRadius: 18,
          offset: const Offset(0, 6),
        ),
      ],
    );
  }
}

/// Small helper for consistent colored "risk" / status surfaces.
extension AppThemeColors on Color {
  Color withAlphaDouble(double alpha) => withOpacity(alpha.clamp(0.0, 1.0));
}
