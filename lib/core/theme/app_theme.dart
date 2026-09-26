import 'package:flutter/material.dart';

/// Tourism Aurora V2 — an intentionally visible visual redesign: lavender
/// canvas, elevated pearl surfaces, indigo/cyan identity, larger radii and
/// tactile controls. Expensive live blur is avoided so the stronger look does
/// not cost map/list performance on mid-range Android phones.
class AppTheme {
  AppTheme._();

  // Indigo accent (shadcn-style primary).
  static const Color brandStart = Color(0xFF5B4BDB);
  static const Color brandEnd = Color(0xFF06B6D4);

  // Kept for backwards-compat with existing call sites.
  static const Color seed = brandStart;
  static const Color seedBright = brandEnd;

  static const Color danger = Color(0xFFDC2626);
  static const Color warning = Color(0xFFD97706);
  static const Color success = Color(0xFF16A34A);

  static const double cardRadius = 20;

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
      surface: dark ? const Color(0xFF151824) : const Color(0xFFFEFDFF),
      surfaceContainerLowest:
          dark ? const Color(0xFF10131D) : const Color(0xFFFFFFFF),
      surfaceContainerLow:
          dark ? const Color(0xFF191C29) : const Color(0xFFF9F7FF),
      surfaceContainer:
          dark ? const Color(0xFF1F2230) : const Color(0xFFF0EEFF),
      secondary: dark ? const Color(0xFF22D3EE) : const Color(0xFF0891B2),
      tertiary: dark ? const Color(0xFFF9A8D4) : const Color(0xFFDB2777),
      outline: dark ? const Color(0xFF41465B) : const Color(0xFFD9D5F0),
      outlineVariant:
          dark ? const Color(0xFF2C3040) : const Color(0xFFE7E3F7),
    );

    final Color scaffold =
        dark ? const Color(0xFF090B12) : const Color(0xFFF3F1FC);
    final TextTheme baseTypography = ThemeData(
      brightness: brightness,
      useMaterial3: true,
    ).textTheme;
    final TextTheme typography = baseTypography.copyWith(
      displaySmall: baseTypography.displaySmall
          ?.copyWith(fontWeight: FontWeight.w900, letterSpacing: -1.1),
      headlineLarge: baseTypography.headlineLarge
          ?.copyWith(fontWeight: FontWeight.w900, letterSpacing: -0.8),
      headlineMedium: baseTypography.headlineMedium
          ?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.65),
      headlineSmall: baseTypography.headlineSmall
          ?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.5),
      titleLarge: baseTypography.titleLarge
          ?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.4),
      titleMedium: baseTypography.titleMedium
          ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.2),
      labelLarge:
          baseTypography.labelLarge?.copyWith(fontWeight: FontWeight.w800),
      bodyLarge: baseTypography.bodyLarge?.copyWith(height: 1.35),
      bodyMedium: baseTypography.bodyMedium?.copyWith(height: 1.38),
      bodySmall: baseTypography.bodySmall?.copyWith(height: 1.35),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      textTheme: typography,
      scaffoldBackgroundColor: scaffold,
      visualDensity: VisualDensity.standard,
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: _AuroraPageTransitionsBuilder(),
          TargetPlatform.iOS: _AuroraPageTransitionsBuilder(),
          TargetPlatform.macOS: _AuroraPageTransitionsBuilder(),
          TargetPlatform.linux: _AuroraPageTransitionsBuilder(),
          TargetPlatform.windows: _AuroraPageTransitionsBuilder(),
          TargetPlatform.fuchsia: _AuroraPageTransitionsBuilder(),
        },
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: scaffold,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        toolbarHeight: 64,
        titleSpacing: 18,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 20,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.45,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor:
            dark ? const Color(0xFF151824) : const Color(0xFFFEFDFF),
        indicatorColor: brandStart.withValues(alpha: dark ? 0.28 : 0.14),
        elevation: 8,
        height: 72,
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith<TextStyle>(
          (Set<WidgetState> states) => TextStyle(
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w800
                : FontWeight.w600,
            color: states.contains(WidgetState.selected)
                ? scheme.primary
                : scheme.onSurfaceVariant,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith<IconThemeData>(
          (Set<WidgetState> states) => IconThemeData(
            size: states.contains(WidgetState.selected) ? 25 : 23,
            color: states.contains(WidgetState.selected)
                ? scheme.primary
                : scheme.onSurfaceVariant,
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
          minimumSize: const Size(48, 52),
          elevation: 3,
          shadowColor: scheme.primary.withValues(alpha: 0.28),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(17),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.primary,
          backgroundColor: scheme.surface.withValues(alpha: 0.78),
          minimumSize: const Size(48, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(17),
          ),
          side: BorderSide(
              color: scheme.primary.withValues(alpha: 0.24), width: 1.2),
          textStyle: const TextStyle(fontWeight: FontWeight.w800),
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
        fillColor:
            dark ? const Color(0xFF1D2130) : const Color(0xFFFEFDFF),
        isDense: false,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        labelStyle: TextStyle(
            color: scheme.onSurfaceVariant, fontWeight: FontWeight.w600),
        floatingLabelStyle:
            TextStyle(color: scheme.primary, fontWeight: FontWeight.w700),
        hintStyle: TextStyle(
            color: scheme.onSurfaceVariant.withValues(alpha: 0.72)),
        prefixIconColor: scheme.primary,
        suffixIconColor: scheme.onSurfaceVariant,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: scheme.primary, width: 1.8),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: scheme.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: scheme.error, width: 1.8),
        ),
      ),
      cardTheme: CardThemeData(
        color: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 2,
        shadowColor: scheme.primary.withValues(alpha: dark ? 0.18 : 0.10),
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(cardRadius),
          side: BorderSide(
              color: scheme.primary.withValues(alpha: dark ? 0.22 : 0.12)),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surface,
        selectedColor: scheme.primary.withValues(alpha: 0.16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        side: BorderSide(color: scheme.primary.withValues(alpha: 0.18)),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith<Color?>((states) =>
            states.contains(WidgetState.selected) ? Colors.white : null),
        trackColor: WidgetStateProperty.resolveWith<Color?>((states) =>
            states.contains(WidgetState.selected) ? scheme.primary : null),
      ),
      checkboxTheme: CheckboxThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        fillColor: WidgetStateProperty.resolveWith<Color?>((states) =>
            states.contains(WidgetState.selected) ? scheme.primary : null),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith<Color?>((states) =>
            states.contains(WidgetState.selected) ? scheme.primary : null),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: scheme.primary,
        inactiveTrackColor: scheme.primary.withValues(alpha: 0.12),
        thumbColor: scheme.primary,
        overlayColor: scheme.primary.withValues(alpha: 0.10),
        trackHeight: 4,
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll<Size>(Size(48, 50)),
          padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
              EdgeInsets.symmetric(horizontal: 12, vertical: 11)),
          textStyle: WidgetStateProperty.resolveWith<TextStyle>(
            (Set<WidgetState> states) => TextStyle(
              fontWeight: states.contains(WidgetState.selected)
                  ? FontWeight.w800
                  : FontWeight.w600,
            ),
          ),
          backgroundColor: WidgetStateProperty.resolveWith<Color?>((states) =>
              states.contains(WidgetState.selected)
                  ? scheme.primary.withValues(alpha: dark ? 0.24 : 0.12)
                  : scheme.surface.withValues(alpha: 0.72)),
          side: WidgetStatePropertyAll<BorderSide>(
              BorderSide(color: scheme.outlineVariant)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 12,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        titleTextStyle: typography.titleLarge?.copyWith(color: scheme.onSurface),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: dark ? const Color(0xFFE8E7F4) : const Color(0xFF171827),
          borderRadius: BorderRadius.circular(9),
        ),
        textStyle: TextStyle(
          color: dark ? const Color(0xFF171827) : Colors.white,
          fontWeight: FontWeight.w600,
        ),
      ),
      scrollbarTheme: ScrollbarThemeData(
        radius: const Radius.circular(8),
        thickness: const WidgetStatePropertyAll<double>(4),
        thumbColor: WidgetStatePropertyAll<Color>(
            scheme.primary.withValues(alpha: 0.30)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor:
            dark ? const Color(0xFFE9E7F5) : const Color(0xFF171827),
        contentTextStyle: TextStyle(
            color: dark ? const Color(0xFF171827) : Colors.white,
            fontWeight: FontWeight.w600),
        actionTextColor: dark ? brandStart : const Color(0xFF67E8F9),
        elevation: 10,
        insetPadding: const EdgeInsets.fromLTRB(16, 8, 16, 18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        showDragHandle: true,
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: scheme.surface,
        modalBarrierColor: Colors.black.withValues(alpha: 0.44),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.primary.withValues(alpha: 0.10),
        circularTrackColor: scheme.primary.withValues(alpha: 0.10),
      ),
      dividerTheme: DividerThemeData(
          color: scheme.outlineVariant, thickness: 1, space: 1),
      listTileTheme: ListTileThemeData(
        iconColor: scheme.primary,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
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

/// A restrained fade/slide transition used consistently on Android and
/// desktop. It is intentionally short so navigation feels responsive and
/// does not add expensive blur or scale work over map screens.
class _AuroraPageTransitionsBuilder extends PageTransitionsBuilder {
  const _AuroraPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (route.settings.name == Navigator.defaultRouteName) return child;
    final Animation<double> curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0.035, 0.015),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}

/// Small helper for consistent colored "risk" / status surfaces.
extension AppThemeColors on Color {
  Color withAlphaDouble(double alpha) =>
      withValues(alpha: alpha.clamp(0.0, 1.0));
}
