import 'package:flutter/material.dart';

/// Tourism "clean" theme — shadcn-inspired: neutral surfaces, hairline
/// borders, restrained shadows and a single indigo accent. No gradients, no
/// neon glow — professional, neat and consistent.
class AppTheme {
  AppTheme._();

  // Indigo accent (shadcn-style primary).
  static const Color brandStart = Color(0xFF4F46E5);
  static const Color brandEnd = Color(0xFF6366F1);

  // Kept for backwards-compat with existing call sites.
  static const Color seed = brandStart;
  static const Color seedBright = brandEnd;

  static const Color danger = Color(0xFFDC2626);
  static const Color warning = Color(0xFFD97706);
  static const Color success = Color(0xFF16A34A);

  static const double cardRadius = 14;

  /// Subtle, shadcn-style shadow (1px hairline + faint elevation).
  static List<BoxShadow> softShadow(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    return <BoxShadow>[
      BoxShadow(
        color: Colors.black.withValues(alpha: dark ? 0.35 : 0.05),
        blurRadius: 8,
        offset: const Offset(0, 1),
      ),
    ];
  }

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final bool dark = brightness == Brightness.dark;
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: brandStart,
      brightness: brightness,
    ).copyWith(
      primary: dark ? brandEnd : brandStart,
      onPrimary: Colors.white,
      surface: dark ? const Color(0xFF18181B) : Colors.white,
      outline: dark ? const Color(0xFF3F3F46) : const Color(0xFFE4E4E7),
    );

    final Color scaffold = dark ? const Color(0xFF09090B) : const Color(0xFFFAFAFA);

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scaffold,
      visualDensity: VisualDensity.adaptivePlatformDensity,
      appBarTheme: AppBarTheme(
        backgroundColor: scaffold,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 18,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: dark ? const Color(0xFF18181B) : Colors.white,
        indicatorColor: brandStart.withValues(alpha: dark ? 0.22 : 0.10),
        elevation: 1,
        labelTextStyle: WidgetStatePropertyAll<TextStyle>(
          TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: danger,
        foregroundColor: Colors.white,
        elevation: 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.onSurface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          side: BorderSide(color: scheme.outline),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: scheme.primary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? const Color(0xFF27272A) : const Color(0xFFF4F4F5),
        isDense: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.primary, width: 1.4),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.error, width: 1.4),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        side: BorderSide(color: scheme.outline),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        showDragHandle: true,
        backgroundColor: Colors.transparent,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: brandStart),
      dividerTheme: DividerThemeData(color: scheme.outline),
      listTileTheme: ListTileThemeData(iconColor: scheme.primary),
    );
  }

  /// shadcn-style card: clean surface, hairline border, faint shadow.
  static BoxDecoration cardBox(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    return BoxDecoration(
      color: dark ? const Color(0xFF18181B) : Colors.white,
      borderRadius: BorderRadius.circular(cardRadius),
      border: Border.all(
        color: dark ? const Color(0xFF3F3F46) : const Color(0xFFE4E4E7),
      ),
      boxShadow: <BoxShadow>[
        BoxShadow(
          color: Colors.black.withValues(alpha: dark ? 0.35 : 0.05),
          blurRadius: 8,
          offset: const Offset(0, 1),
        ),
      ],
    );
  }
}

/// Small helper for consistent colored "risk" / status surfaces.
extension AppThemeColors on Color {
  Color withAlphaDouble(double alpha) =>
      withValues(alpha: alpha.clamp(0.0, 1.0));
}
