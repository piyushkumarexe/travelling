import 'package:flutter/material.dart';

/// Tourism "premium glass" theme — uiverse-inspired: gradient + glow buttons,
/// translucent glass cards, deep violet/cyan signature and soft radii.
///
/// Palette:
///   brand gradient  violet #7C4DFF → cyan #00E5FF
///   danger           rosy red
///   warning          amber
///   success          emerald
class AppTheme {
  AppTheme._();

  // Signature gradient endpoints (buttons, accents, glows).
  static const Color brandStart = Color(0xFF7C4DFF);
  static const Color brandEnd = Color(0xFF00E5FF);

  // Kept for backwards-compat with existing call sites.
  static const Color seed = brandStart;
  static const Color seedBright = brandEnd;

  static const Color danger = Color(0xFFFF3B5C);
  static const Color warning = Color(0xFFFFB020);
  static const Color success = Color(0xFF2BD576);

  static const double cardRadius = 20;

  /// Signature violet→cyan gradient used for primary buttons and accents.
  static const LinearGradient brandGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: <Color>[brandStart, brandEnd],
  );

  /// Soft "floating card" shadow used across the app.
  static List<BoxShadow> softShadow(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    return <BoxShadow>[
      BoxShadow(
        color: Colors.black.withValues(alpha: dark ? 0.45 : 0.08),
        blurRadius: 24,
        offset: const Offset(0, 10),
      ),
    ];
  }

  /// Colored "neon glow" for primary actions (uiverse-style glow button).
  static List<BoxShadow> glow(Color color, {double alpha = 0.45}) =>
      <BoxShadow>[
        BoxShadow(
          color: color.withValues(alpha: alpha),
          blurRadius: 18,
          offset: const Offset(0, 6),
        ),
        BoxShadow(
          color: color.withValues(alpha: alpha * 0.6),
          blurRadius: 40,
          offset: const Offset(0, 12),
        ),
      ];

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final bool dark = brightness == Brightness.dark;
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: brandStart,
      brightness: brightness,
    ).copyWith(
      primary: dark ? brandEnd : brandStart,
      secondary: dark ? brandStart : brandEnd,
      surface: dark ? const Color(0xFF16102C) : Colors.white,
    );

    final Color scaffold = dark ? const Color(0xFF0D0920) : const Color(0xFFF6F5FB);

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scaffold,
      visualDensity: VisualDensity.adaptivePlatformDensity,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 20,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.3,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor:
            dark ? const Color(0xFF120C28) : const Color(0xFFFFFFFF),
        indicatorColor: brandStart.withValues(alpha: dark ? 0.30 : 0.14),
        elevation: 10,
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
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          side: BorderSide(color: scheme.outlineVariant),
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
        fillColor: dark
            ? Colors.white.withValues(alpha: 0.06)
            : const Color(0xFFF1EFFA),
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.7)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: brandEnd, width: 1.6),
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
        backgroundColor: dark ? const Color(0xFF241A44) : const Color(0xFF2A2138),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        showDragHandle: true,
        backgroundColor: Colors.transparent,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: brandEnd),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant),
      listTileTheme: ListTileThemeData(iconColor: scheme.primary),
    );
  }

  /// Glassmorphism "card" style used across the app: translucent surface,
  /// hairline border and a soft drop shadow.
  static BoxDecoration cardBox(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    return BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: dark
            ? <Color>[
                Colors.white.withValues(alpha: 0.08),
                Colors.white.withValues(alpha: 0.03),
              ]
            : <Color>[Colors.white, const Color(0xFFFBFBFF)],
      ),
      borderRadius: BorderRadius.circular(cardRadius),
      border: Border.all(
        color: dark
            ? Colors.white.withValues(alpha: 0.10)
            : scheme.outlineVariant.withValues(alpha: 0.5),
      ),
      boxShadow: <BoxShadow>[
        BoxShadow(
          color: Colors.black.withValues(alpha: dark ? 0.35 : 0.06),
          blurRadius: 22,
          offset: const Offset(0, 10),
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
