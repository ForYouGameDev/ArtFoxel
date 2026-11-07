import 'package:flutter/material.dart';

import 'design_tokens.dart';

enum ThemePreference { system, light, dark }

class AppTheme {
  AppTheme._();

  static ThemeData light() => _create(Brightness.light);
  static ThemeData dark() => _create(Brightness.dark);

  static ThemeData _create(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: ArtFoxelColors.violet,
      brightness: brightness,
      surface: isDark ? const Color(0xFF101321) : const Color(0xFFF7F6FC),
    ).copyWith(
      primary: isDark ? const Color(0xFFA38CFF) : const Color(0xFF6549D8),
      onPrimary: Colors.white,
      secondary: isDark ? ArtFoxelColors.cyan : const Color(0xFF087F97),
      tertiary: isDark ? ArtFoxelColors.magenta : const Color(0xFFAC3C9C),
      surface: isDark ? const Color(0xFF101321) : const Color(0xFFF7F6FC),
      surfaceContainerLow:
          isDark ? const Color(0xFF151A2B) : const Color(0xFFFFFFFF),
      surfaceContainer: isDark ? const Color(0xFF1A2033) : const Color(0xFFF0EEF7),
      onSurface: isDark ? const Color(0xFFF3F1FC) : const Color(0xFF202033),
      onSurfaceVariant:
          isDark ? const Color(0xFFB4B5C9) : const Color(0xFF66677B),
      outlineVariant:
          isDark ? const Color(0xFF32374B) : const Color(0xFFE1DFEA),
    );
    final baseTextTheme =
        isDark ? Typography.material2021().white : Typography.material2021().black;
    final textTheme = baseTextTheme.apply(
          bodyColor: scheme.onSurface,
          displayColor: scheme.onSurface,
        );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      textTheme: textTheme,
      visualDensity: VisualDensity.standard,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: textTheme.titleLarge?.copyWith(
          color: scheme.onSurface,
          fontWeight: FontWeight.w800,
        ),
      ),
      cardTheme: CardThemeData(
        color: scheme.surfaceContainerLow,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ArtFoxelRadius.md),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: .72)),
        ),
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(ArtFoxelRadius.sm),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(ArtFoxelRadius.sm),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        filled: true,
        fillColor: scheme.surfaceContainerLow,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(ArtFoxelRadius.sm),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(ArtFoxelRadius.sm),
          ),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ArtFoxelRadius.lg),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        showDragHandle: true,
        backgroundColor: scheme.surfaceContainerLow,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(ArtFoxelRadius.lg),
          ),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        indicatorColor: scheme.primary.withValues(alpha: .15),
        elevation: 0,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          return textTheme.labelSmall?.copyWith(
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w800
                : FontWeight.w500,
          );
        }),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: scheme.primary.withValues(alpha: .15),
        selectedIconTheme: IconThemeData(color: scheme.primary),
        selectedLabelTextStyle:
            textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w800),
      ),
    );
  }
}
