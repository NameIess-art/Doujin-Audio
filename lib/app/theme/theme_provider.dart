import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/widgets/app_buttons.dart';
import '../../core/widgets/app_edit_panel.dart' show appEditPanelActionStyle;
import '../../core/widgets/app_tap_highlight.dart';

import '../../core/persistence/persisted_state_reloader.dart';
import '../../core/persistence/app_preferences.dart';
import '../../core/widgets/app_transitions.dart';
import 'app_design_tokens.dart';
import 'app_styles.dart';

double appColorContrastRatio(Color first, Color second) {
  final a = first.computeLuminance();
  final b = second.computeLuminance();
  return (math.max(a, b) + 0.05) / (math.min(a, b) + 0.05);
}

/// Picks a refined dark ink or pure white foreground that satisfies [minContrast]
/// against [background], falling back to whichever achieves higher contrast.
Color appReadableOnColor(Color background, {double minContrast = 4.5}) {
  const darkInk = Color(0xFF18191D);
  final darkRatio = appColorContrastRatio(darkInk, background);
  final whiteRatio = appColorContrastRatio(Colors.white, background);
  if (darkRatio >= minContrast || whiteRatio >= minContrast) {
    return darkRatio >= whiteRatio ? darkInk : Colors.white;
  }
  final blackRatio = appColorContrastRatio(Colors.black, background);
  return blackRatio >= whiteRatio ? Colors.black : Colors.white;
}

/// Adjusts [accent] lightness when needed so icons, active labels, and progress
/// rings remain clearly legible against [surface] in both light and dark modes.
Color appReadableAccentColor(
  Color accent,
  Color surface, {
  double minContrast = 3.0,
  double? targetContrast,
}) {
  if (appColorContrastRatio(accent, surface) >= minContrast) return accent;
  final goal = targetContrast ?? minContrast;
  final isDarkSurface =
      ThemeData.estimateBrightnessForColor(surface) == Brightness.dark;
  final hsl = HSLColor.fromColor(accent);
  for (var step = 1; step <= 18; step++) {
    final targetLightness = isDarkSurface
        ? (hsl.lightness + step * 0.045).clamp(0.0, 0.88)
        : (hsl.lightness - step * 0.045).clamp(0.16, 1.0);
    final candidate = hsl.withLightness(targetLightness).toColor();
    if (appColorContrastRatio(candidate, surface) >= goal) {
      return candidate;
    }
  }
  return isDarkSurface ? const Color(0xFFD2D6DE) : const Color(0xFF363A45);
}

Color _tintDarkSurface(Color base, Color accent, double amount) =>
    Color.alphaBlend(accent.withValues(alpha: amount), base);

/// Applies the app's 3-level readable text hierarchy (title / body / supporting)
/// while keeping tabular figures and platform typography metrics intact.
TextTheme applyAppTextThemeColors(TextTheme base, ColorScheme scheme) {
  final bodyColor = Color.alphaBlend(
    scheme.onSurface.withValues(alpha: 0.88),
    scheme.surface,
  );
  return base.copyWith(
    displayLarge: base.displayLarge?.copyWith(color: scheme.onSurface),
    displayMedium: base.displayMedium?.copyWith(color: scheme.onSurface),
    displaySmall: base.displaySmall?.copyWith(color: scheme.onSurface),
    headlineLarge: base.headlineLarge?.copyWith(color: scheme.onSurface),
    headlineMedium: base.headlineMedium?.copyWith(color: scheme.onSurface),
    headlineSmall: base.headlineSmall?.copyWith(color: scheme.onSurface),
    titleLarge: base.titleLarge?.copyWith(color: scheme.onSurface),
    titleMedium: base.titleMedium?.copyWith(color: scheme.onSurface),
    titleSmall: base.titleSmall?.copyWith(color: scheme.onSurface),
    bodyLarge: base.bodyLarge?.copyWith(color: bodyColor),
    bodyMedium: base.bodyMedium?.copyWith(color: bodyColor),
    bodySmall: base.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
    labelLarge: base.labelLarge?.copyWith(color: bodyColor),
    labelMedium: base.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
    labelSmall: base.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
  );
}

/// Applies the app's OLED pure-black canvas with distinct tinted dark container
/// elevation steps so cards, overlays, and shimmers remain clearly separated.
ColorScheme applyPureBlackSurface(ColorScheme scheme) {
  if (scheme.brightness != Brightness.dark) return scheme;
  const black = Color(0xFF000000);
  final accent = scheme.primary;
  final containerLow = _tintDarkSurface(const Color(0xFF0B0C0F), accent, 0.020);
  final container = _tintDarkSurface(const Color(0xFF131419), accent, 0.028);
  final containerHigh = _tintDarkSurface(
    const Color(0xFF1B1D23),
    accent,
    0.036,
  );
  final containerHighest = _tintDarkSurface(
    const Color(0xFF252830),
    accent,
    0.044,
  );
  return scheme.copyWith(
    surface: black,
    surfaceDim: black,
    surfaceBright: containerHigh,
    surfaceContainerLowest: black,
    surfaceContainerLow: containerLow,
    surfaceContainer: container,
    surfaceContainerHigh: containerHigh,
    surfaceContainerHighest: containerHighest,
  );
}

/// Applies the app's calibrated light, dark, or pure-black surface elevation
/// ramp to any generated [ColorScheme], keeping cover-derived detail palettes
/// visually cohesive with the rest of the application.
ColorScheme applyAppSurfaceRamp(
  ColorScheme scheme, {
  required Color seedColor,
  bool pureBlack = false,
  bool highContrast = false,
  Color? surfaceOverride,
}) {
  if (scheme.brightness == Brightness.light) {
    final lightSurface =
        surfaceOverride ??
        Color.alphaBlend(
          seedColor.withValues(alpha: highContrast ? 0.015 : 0.024),
          const Color(0xFFFAF9FB),
        );
    final neutralScale = highContrast ? 1.35 : 1.0;
    final tintScale = highContrast ? 0.55 : 1.0;
    Color stepLight(double neutralAlpha, double tintAlpha) => Color.alphaBlend(
      scheme.primary.withValues(alpha: tintAlpha * tintScale),
      Color.alphaBlend(
        Colors.black.withValues(alpha: neutralAlpha * neutralScale),
        lightSurface,
      ),
    );
    return scheme.copyWith(
      surface: lightSurface,
      surfaceBright: lightSurface,
      surfaceDim: Color.alphaBlend(
        Colors.black.withValues(alpha: 0.055 * neutralScale),
        lightSurface,
      ),
      surfaceContainerLowest: const Color(0xFFFFFFFF),
      surfaceContainerLow: stepLight(0.014, 0.012),
      surfaceContainer: stepLight(0.028, 0.018),
      surfaceContainerHigh: stepLight(0.044, 0.024),
      surfaceContainerHighest: stepLight(0.066, 0.030),
    );
  }

  if (pureBlack) {
    return applyPureBlackSurface(scheme);
  }

  final darkSurface =
      surfaceOverride ??
      Color.alphaBlend(
        seedColor.withValues(alpha: highContrast ? 0.025 : 0.040),
        const Color(0xFF111215),
      );
  final primary = scheme.primary;
  final liftScale = highContrast ? 1.20 : 1.0;
  final tintScale = highContrast ? 0.65 : 1.0;
  final containerLowest = Color.alphaBlend(
    Colors.black.withValues(alpha: 0.34),
    darkSurface,
  );
  final containerLow = _tintDarkSurface(
    Color.alphaBlend(
      Colors.white.withValues(alpha: 0.030 * liftScale),
      darkSurface,
    ),
    primary,
    0.016 * tintScale,
  );
  final container = _tintDarkSurface(
    Color.alphaBlend(
      Colors.white.withValues(alpha: 0.056 * liftScale),
      darkSurface,
    ),
    primary,
    0.024 * tintScale,
  );
  final containerHigh = _tintDarkSurface(
    Color.alphaBlend(
      Colors.white.withValues(alpha: 0.088 * liftScale),
      darkSurface,
    ),
    primary,
    0.032 * tintScale,
  );
  final containerHighest = _tintDarkSurface(
    Color.alphaBlend(
      Colors.white.withValues(alpha: 0.122 * liftScale),
      darkSurface,
    ),
    primary,
    0.040 * tintScale,
  );
  return scheme.copyWith(
    surface: darkSurface,
    surfaceDim: darkSurface,
    surfaceBright: containerHigh,
    surfaceContainerLowest: containerLowest,
    surfaceContainerLow: containerLow,
    surfaceContainer: container,
    surfaceContainerHigh: containerHigh,
    surfaceContainerHighest: containerHighest,
  );
}

/// Maps an arbitrary seed color to the closest Android splash/window surface
/// preset family so cold startup transitions stay visually cohesive.
ThemeAccentPreset nearestStartupPresetForColor(Color color) {
  final hsl = HSLColor.fromColor(color);
  if (hsl.saturation < 0.12 || hsl.lightness < 0.08 || hsl.lightness > 0.94) {
    return ThemeAccentPreset.gray;
  }
  final hue = hsl.hue;
  if (hue < 22 || hue >= 315) return ThemeAccentPreset.rose;
  if (hue < 72) return ThemeAccentPreset.yellow;
  if (hue < 172) return ThemeAccentPreset.teal;
  if (hue < 245) return ThemeAccentPreset.blue;
  return ThemeAccentPreset.purple;
}

ColorScheme buildAppColorScheme({
  required Color seedColor,
  required Brightness brightness,
  bool pureBlack = false,
  bool highContrast = false,
  Color? darkPrimaryOverride,
  Color? surfaceOverride,
}) {
  final effectivePureBlack = pureBlack && brightness == Brightness.dark;
  final contrastLevel = highContrast ? 1.0 : 0.0;
  final generated = ColorScheme.fromSeed(
    seedColor: seedColor,
    brightness: brightness,
    dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
    contrastLevel: contrastLevel,
  );

  if (brightness == Brightness.light) {
    return applyAppSurfaceRamp(
      generated,
      seedColor: seedColor,
      highContrast: highContrast,
      surfaceOverride: surfaceOverride,
    );
  }

  final usePrimaryOverride = !highContrast && darkPrimaryOverride != null;
  final primary = usePrimaryOverride ? darkPrimaryOverride : generated.primary;
  Color onPrimary = generated.onPrimary;
  if (usePrimaryOverride && appColorContrastRatio(onPrimary, primary) < 4.5) {
    onPrimary = appReadableOnColor(primary);
  }
  final darkScheme = generated.copyWith(
    primary: primary,
    onPrimary: onPrimary,
    surfaceTint: primary,
  );
  return applyAppSurfaceRamp(
    darkScheme,
    seedColor: seedColor,
    pureBlack: effectivePureBlack,
    highContrast: highContrast,
    surfaceOverride: surfaceOverride,
  );
}

const _tabularDigits = TextStyle(
  fontFamily: 'Outfit',
  fontFeatures: [FontFeature.tabularFigures()],
);
const _tabularTextTheme = TextTheme(
  displayLarge: _tabularDigits,
  displayMedium: _tabularDigits,
  displaySmall: _tabularDigits,
  headlineLarge: _tabularDigits,
  headlineMedium: _tabularDigits,
  headlineSmall: _tabularDigits,
  titleLarge: _tabularDigits,
  titleMedium: _tabularDigits,
  titleSmall: _tabularDigits,
  bodyLarge: _tabularDigits,
  bodyMedium: _tabularDigits,
  bodySmall: _tabularDigits,
  labelLarge: _tabularDigits,
  labelMedium: _tabularDigits,
  labelSmall: _tabularDigits,
);

const _windowsTextTheme = TextTheme(
  headlineMedium: TextStyle(
    fontSize: 30,
    fontWeight: FontWeight.w600,
    height: 1.2,
  ),
  headlineSmall: TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.w600,
    height: 1.25,
  ),
  titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, height: 1.3),
  titleMedium: TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    height: 1.4,
  ),
  titleSmall: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, height: 1.4),
  bodyLarge: TextStyle(fontSize: 16, fontWeight: FontWeight.w400, height: 1.5),
  bodyMedium: TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w400,
    height: 1.45,
  ),
  bodySmall: TextStyle(fontSize: 12, fontWeight: FontWeight.w400, height: 1.4),
  labelLarge: TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    height: 1.35,
  ),
  labelMedium: TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w400,
    height: 1.35,
  ),
  labelSmall: TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    height: 1.35,
  ),
);

enum ThemeAccentPreset {
  red,
  rose,
  pink,
  purple,
  indigo,
  blue,
  sky,
  cyan,
  teal,
  green,
  olive,
  yellow,
  orange,
  brown,
  gray,
  monochrome,
}

extension ThemeAccentPresetValue on ThemeAccentPreset {
  /// Signature accent used directly in dark mode (and as the dark seed).
  Color get primaryColor => switch (this) {
    ThemeAccentPreset.red => const Color(0xFFFF8A80),
    ThemeAccentPreset.rose => const Color(0xFFFF9EB5),
    ThemeAccentPreset.pink => const Color(0xFFF2A6E8),
    ThemeAccentPreset.purple => const Color(0xFFC8A8FF),
    ThemeAccentPreset.indigo => const Color(0xFFA5B4FC),
    ThemeAccentPreset.blue => const Color(0xFF82B9FF),
    ThemeAccentPreset.sky => const Color(0xFF7AD0F5),
    ThemeAccentPreset.cyan => const Color(0xFF6BD6E0),
    ThemeAccentPreset.teal => const Color(0xFF6FD6C2),
    ThemeAccentPreset.green => const Color(0xFF86D993),
    ThemeAccentPreset.olive => const Color(0xFFB9D47A),
    ThemeAccentPreset.yellow => const Color(0xFFF5D76E),
    ThemeAccentPreset.orange => const Color(0xFFFFB074),
    ThemeAccentPreset.brown => const Color(0xFFD9B39B),
    ThemeAccentPreset.gray => const Color(0xFFB8BDC4),
    ThemeAccentPreset.monochrome => const Color(0xFFF5F5F7),
  };

  /// Distinct, saturated seed calibrated for crisp light-mode primaries.
  Color get lightSeedColor => switch (this) {
    ThemeAccentPreset.red => const Color(0xFFD93025),
    ThemeAccentPreset.rose => const Color(0xFFD81B60),
    ThemeAccentPreset.pink => const Color(0xFFC239B3),
    ThemeAccentPreset.purple => const Color(0xFF7C3AED),
    ThemeAccentPreset.indigo => const Color(0xFF4F46E5),
    ThemeAccentPreset.blue => const Color(0xFF1A73E8),
    ThemeAccentPreset.sky => const Color(0xFF0284C7),
    ThemeAccentPreset.cyan => const Color(0xFF0891B2),
    ThemeAccentPreset.teal => const Color(0xFF0D9488),
    ThemeAccentPreset.green => const Color(0xFF1E8E3E),
    ThemeAccentPreset.olive => const Color(0xFF658A1E),
    ThemeAccentPreset.yellow => const Color(0xFFB8860B),
    ThemeAccentPreset.orange => const Color(0xFFE06510),
    ThemeAccentPreset.brown => const Color(0xFF8D5534),
    ThemeAccentPreset.gray => const Color(0xFF5A6068),
    ThemeAccentPreset.monochrome => const Color(0xFF141417),
  };

  String get labelKey => 'theme_color_$name';

  Color bootstrapSurfaceColor(Brightness brightness, {bool pureBlack = false}) {
    if (pureBlack && brightness == Brightness.dark) {
      return const Color(0xFF000000);
    }
    final dark = brightness == Brightness.dark;
    return switch (this) {
      ThemeAccentPreset.red ||
      ThemeAccentPreset.rose ||
      ThemeAccentPreset.pink =>
        dark ? const Color(0xFF141112) : const Color(0xFFFFF8F8),
      ThemeAccentPreset.purple || ThemeAccentPreset.indigo =>
        dark ? const Color(0xFF131117) : const Color(0xFFFAF8FF),
      ThemeAccentPreset.blue ||
      ThemeAccentPreset.sky ||
      ThemeAccentPreset.cyan =>
        dark ? const Color(0xFF101218) : const Color(0xFFF7F9FF),
      ThemeAccentPreset.teal ||
      ThemeAccentPreset.green ||
      ThemeAccentPreset.olive =>
        dark ? const Color(0xFF101513) : const Color(0xFFF5FFF9),
      ThemeAccentPreset.yellow ||
      ThemeAccentPreset.orange ||
      ThemeAccentPreset.brown =>
        dark ? const Color(0xFF151310) : const Color(0xFFFFF9F2),
      ThemeAccentPreset.gray || ThemeAccentPreset.monochrome =>
        dark ? const Color(0xFF121315) : const Color(0xFFF7F8FA),
    };
  }

  static final Map<(ThemeAccentPreset, Brightness, bool, bool), ColorScheme>
  _colorSchemeCache =
      <(ThemeAccentPreset, Brightness, bool, bool), ColorScheme>{};

  ColorScheme colorScheme(
    Brightness brightness, {
    bool pureBlack = false,
    bool highContrast = false,
  }) {
    final effectivePureBlack = pureBlack && brightness == Brightness.dark;
    return _colorSchemeCache.putIfAbsent(
      (this, brightness, effectivePureBlack, highContrast),
      () => _computeColorScheme(
        brightness,
        pureBlack: effectivePureBlack,
        highContrast: highContrast,
      ),
    );
  }

  ColorScheme _computeColorScheme(
    Brightness brightness, {
    bool pureBlack = false,
    bool highContrast = false,
  }) {
    if (this == ThemeAccentPreset.gray) {
      return _grayColorScheme(
        brightness,
        pureBlack: pureBlack,
        highContrast: highContrast,
      );
    }
    if (this == ThemeAccentPreset.monochrome) {
      return _monochromeColorScheme(
        brightness,
        pureBlack: pureBlack,
        highContrast: highContrast,
      );
    }
    return buildAppColorScheme(
      seedColor: brightness == Brightness.light ? lightSeedColor : primaryColor,
      brightness: brightness,
      pureBlack: pureBlack,
      highContrast: highContrast,
      darkPrimaryOverride: primaryColor,
      surfaceOverride: bootstrapSurfaceColor(brightness, pureBlack: pureBlack),
    );
  }

  static ColorScheme _monochromeColorScheme(
    Brightness brightness, {
    bool pureBlack = false,
    bool highContrast = false,
  }) {
    if (brightness == Brightness.dark) {
      final primary = highContrast
          ? const Color(0xFFFFFFFF)
          : const Color(0xFFF5F5F7);
      const onPrimary = Color(0xFF111114);
      final primaryContainer = highContrast
          ? const Color(0xFF42434A)
          : const Color(0xFF2E3036);
      const onPrimaryContainer = Color(0xFFFFFFFF);
      final secondary = highContrast
          ? const Color(0xFFEAECEF)
          : const Color(0xFFD0D2D8);
      const onSecondary = Color(0xFF17181B);
      const secondaryContainer = Color(0xFF292B30);
      const onSecondaryContainer = Color(0xFFE8E9ED);
      const tertiary = Color(0xFFA6A9B0);
      const onTertiary = Color(0xFF17181B);
      const tertiaryContainer = Color(0xFF23252A);
      const onTertiaryContainer = Color(0xFFD8DAE0);
      const error = Color(0xFFFFB4AB);
      const onError = Color(0xFF690005);
      const errorContainer = Color(0xFF93000A);
      const onErrorContainer = Color(0xFFFFDAD6);
      const surface = Color(0xFF121315);
      final onSurface = highContrast
          ? const Color(0xFFFFFFFF)
          : const Color(0xFFF0F1F4);
      final onSurfaceVariant = highContrast
          ? const Color(0xFFE2E4E9)
          : const Color(0xFFBDC0C7);
      final outline = highContrast
          ? const Color(0xFFC2C5CC)
          : const Color(0xFF8A8E96);
      final outlineVariant = highContrast
          ? const Color(0xFF72767E)
          : const Color(0xFF3E4148);
      const shadow = Color(0xFF000000);
      const scrim = Color(0xFF000000);
      const inverseSurface = Color(0xFFF0F1F4);
      const onInverseSurface = Color(0xFF121315);
      const inversePrimary = Color(0xFF141417);
      const surfaceDim = Color(0xFF121315);
      const surfaceBright = Color(0xFF27292E);
      const surfaceContainerLowest = Color(0xFF0B0C0E);
      const surfaceContainerLow = Color(0xFF18191D);
      const surfaceContainer = Color(0xFF1F2126);
      const surfaceContainerHigh = Color(0xFF27292E);
      const surfaceContainerHighest = Color(0xFF32343B);

      final scheme = ColorScheme(
        brightness: Brightness.dark,
        primary: primary,
        onPrimary: onPrimary,
        primaryContainer: primaryContainer,
        onPrimaryContainer: onPrimaryContainer,
        secondary: secondary,
        onSecondary: onSecondary,
        secondaryContainer: secondaryContainer,
        onSecondaryContainer: onSecondaryContainer,
        tertiary: tertiary,
        onTertiary: onTertiary,
        tertiaryContainer: tertiaryContainer,
        onTertiaryContainer: onTertiaryContainer,
        error: error,
        onError: onError,
        errorContainer: errorContainer,
        onErrorContainer: onErrorContainer,
        surface: surface,
        onSurface: onSurface,
        onSurfaceVariant: onSurfaceVariant,
        outline: outline,
        outlineVariant: outlineVariant,
        shadow: shadow,
        scrim: scrim,
        inverseSurface: inverseSurface,
        onInverseSurface: onInverseSurface,
        inversePrimary: inversePrimary,
        surfaceDim: surfaceDim,
        surfaceBright: surfaceBright,
        surfaceContainerLowest: surfaceContainerLowest,
        surfaceContainerLow: surfaceContainerLow,
        surfaceContainer: surfaceContainer,
        surfaceContainerHigh: surfaceContainerHigh,
        surfaceContainerHighest: surfaceContainerHighest,
        surfaceTint: primary,
      );
      return pureBlack ? applyPureBlackSurface(scheme) : scheme;
    }

    final primary = highContrast
        ? const Color(0xFF000000)
        : const Color(0xFF141417);
    const onPrimary = Color(0xFFFFFFFF);
    const primaryContainer = Color(0xFFE4E5E9);
    const onPrimaryContainer = Color(0xFF111215);
    final secondary = highContrast
        ? const Color(0xFF1C1D21)
        : const Color(0xFF3A3C42);
    const onSecondary = Color(0xFFFFFFFF);
    const secondaryContainer = Color(0xFFE8E9ED);
    const onSecondaryContainer = Color(0xFF17181B);
    const tertiary = Color(0xFF555860);
    const onTertiary = Color(0xFFFFFFFF);
    const tertiaryContainer = Color(0xFFECEEF2);
    const onTertiaryContainer = Color(0xFF1E2024);
    const error = Color(0xFFBA1A1A);
    const onError = Color(0xFFFFFFFF);
    const errorContainer = Color(0xFFFFDAD6);
    const onErrorContainer = Color(0xFF410002);
    const surface = Color(0xFFF7F8FA);
    final onSurface = highContrast
        ? const Color(0xFF000000)
        : const Color(0xFF141518);
    final onSurfaceVariant = highContrast
        ? const Color(0xFF202226)
        : const Color(0xFF474A52);
    final outline = highContrast
        ? const Color(0xFF3E4148)
        : const Color(0xFF72767E);
    final outlineVariant = highContrast
        ? const Color(0xFF848890)
        : const Color(0xFFC5C8CE);
    const shadow = Color(0xFF000000);
    const scrim = Color(0xFF000000);
    const inverseSurface = Color(0xFF1D1E22);
    const onInverseSurface = Color(0xFFF4F5F7);
    const inversePrimary = Color(0xFFF5F5F7);
    const surfaceDim = Color(0xFFDCDFE4);
    const surfaceBright = Color(0xFFF7F8FA);
    const surfaceContainerLowest = Color(0xFFFFFFFF);
    const surfaceContainerLow = Color(0xFFF0F2F5);
    const surfaceContainer = Color(0xFFE9ECF0);
    const surfaceContainerHigh = Color(0xFFE2E5EA);
    const surfaceContainerHighest = Color(0xFFDADEE4);

    return ColorScheme(
      brightness: Brightness.light,
      primary: primary,
      onPrimary: onPrimary,
      primaryContainer: primaryContainer,
      onPrimaryContainer: onPrimaryContainer,
      secondary: secondary,
      onSecondary: onSecondary,
      secondaryContainer: secondaryContainer,
      onSecondaryContainer: onSecondaryContainer,
      tertiary: tertiary,
      onTertiary: onTertiary,
      tertiaryContainer: tertiaryContainer,
      onTertiaryContainer: onTertiaryContainer,
      error: error,
      onError: onError,
      errorContainer: errorContainer,
      onErrorContainer: onErrorContainer,
      surface: surface,
      onSurface: onSurface,
      onSurfaceVariant: onSurfaceVariant,
      outline: outline,
      outlineVariant: outlineVariant,
      shadow: shadow,
      scrim: scrim,
      inverseSurface: inverseSurface,
      onInverseSurface: onInverseSurface,
      inversePrimary: inversePrimary,
      surfaceDim: surfaceDim,
      surfaceBright: surfaceBright,
      surfaceContainerLowest: surfaceContainerLowest,
      surfaceContainerLow: surfaceContainerLow,
      surfaceContainer: surfaceContainer,
      surfaceContainerHigh: surfaceContainerHigh,
      surfaceContainerHighest: surfaceContainerHighest,
      surfaceTint: primary,
    );
  }

  static ColorScheme _grayColorScheme(
    Brightness brightness, {
    bool pureBlack = false,
    bool highContrast = false,
  }) {
    if (brightness == Brightness.dark) {
      final primary = highContrast
          ? const Color(0xFFDFE2E6)
          : const Color(0xFFB8BDC4);
      final onPrimary = highContrast
          ? const Color(0xFF000000)
          : const Color(0xFF1B1B1F);
      final primaryContainer = highContrast
          ? const Color(0xFF5A5E63)
          : const Color(0xFF44474B);
      final onPrimaryContainer = highContrast
          ? const Color(0xFFFFFFFF)
          : const Color(0xFFE2E3E6);
      final secondary = highContrast
          ? const Color(0xFFE5E6E9)
          : const Color(0xFFC6C7CA);
      const onSecondary = Color(0xFF222426);
      const secondaryContainer = Color(0xFF45484C);
      const onSecondaryContainer = Color(0xFFE2E3E6);
      final tertiary = highContrast
          ? const Color(0xFFD5D7DA)
          : const Color(0xFFA8A9AC);
      const onTertiary = Color(0xFF222426);
      const tertiaryContainer = Color(0xFF383A3D);
      const onTertiaryContainer = Color(0xFFD6D7DA);
      const error = Color(0xFFFFB4AB);
      const onError = Color(0xFF690005);
      const errorContainer = Color(0xFF93000A);
      const onErrorContainer = Color(0xFFFFDAD6);
      const surface = Color(0xFF121315);
      final onSurface = highContrast
          ? const Color(0xFFFFFFFF)
          : const Color(0xFFE2E3E6);
      final onSurfaceVariant = highContrast
          ? const Color(0xFFE0E2E6)
          : const Color(0xFFC4C7CB);
      final outline = highContrast
          ? const Color(0xFFB8BBC0)
          : const Color(0xFF8E9195);
      final outlineVariant = highContrast
          ? const Color(0xFF6E7278)
          : const Color(0xFF44474B);
      const shadow = Color(0xFF000000);
      const scrim = Color(0xFF000000);
      const inverseSurface = Color(0xFFE2E3E6);
      const onInverseSurface = Color(0xFF121315);
      const inversePrimary = Color(0xFF5C5F62);
      const surfaceDim = Color(0xFF121315);
      const surfaceBright = Color(0xFF27282A);
      const surfaceContainerLowest = Color(0xFF0C0C0E);
      const surfaceContainerLow = Color(0xFF1A1B1D);
      const surfaceContainer = Color(0xFF202123);
      const surfaceContainerHigh = Color(0xFF27282A);
      const surfaceContainerHighest = Color(0xFF313233);

      final scheme = ColorScheme(
        brightness: Brightness.dark,
        primary: primary,
        onPrimary: onPrimary,
        primaryContainer: primaryContainer,
        onPrimaryContainer: onPrimaryContainer,
        secondary: secondary,
        onSecondary: onSecondary,
        secondaryContainer: secondaryContainer,
        onSecondaryContainer: onSecondaryContainer,
        tertiary: tertiary,
        onTertiary: onTertiary,
        tertiaryContainer: tertiaryContainer,
        onTertiaryContainer: onTertiaryContainer,
        error: error,
        onError: onError,
        errorContainer: errorContainer,
        onErrorContainer: onErrorContainer,
        surface: surface,
        onSurface: onSurface,
        onSurfaceVariant: onSurfaceVariant,
        outline: outline,
        outlineVariant: outlineVariant,
        shadow: shadow,
        scrim: scrim,
        inverseSurface: inverseSurface,
        onInverseSurface: onInverseSurface,
        inversePrimary: inversePrimary,
        surfaceDim: surfaceDim,
        surfaceBright: surfaceBright,
        surfaceContainerLowest: surfaceContainerLowest,
        surfaceContainerLow: surfaceContainerLow,
        surfaceContainer: surfaceContainer,
        surfaceContainerHigh: surfaceContainerHigh,
        surfaceContainerHighest: surfaceContainerHighest,
        surfaceTint: primary,
      );
      return pureBlack ? applyPureBlackSurface(scheme) : scheme;
    }

    final primary = highContrast
        ? const Color(0xFF2B2D30)
        : const Color(0xFF5A6068);
    const onPrimary = Color(0xFFFFFFFF);
    const primaryContainer = Color(0xFFE2E3E5);
    const onPrimaryContainer = Color(0xFF191C1E);
    final secondary = highContrast
        ? const Color(0xFF34373A)
        : const Color(0xFF5D6063);
    const onSecondary = Color(0xFFFFFFFF);
    const secondaryContainer = Color(0xFFE2E3E5);
    const onSecondaryContainer = Color(0xFF1A1C1E);
    final tertiary = highContrast
        ? const Color(0xFF424549)
        : const Color(0xFF707376);
    const onTertiary = Color(0xFFFFFFFF);
    const tertiaryContainer = Color(0xFFEAEBEE);
    const onTertiaryContainer = Color(0xFF202224);
    const error = Color(0xFFBA1A1A);
    const onError = Color(0xFFFFFFFF);
    const errorContainer = Color(0xFFFFDAD6);
    const onErrorContainer = Color(0xFF410002);
    const surface = Color(0xFFF7F8FA);
    final onSurface = highContrast
        ? const Color(0xFF0B0C0D)
        : const Color(0xFF1A1C1E);
    final onSurfaceVariant = highContrast
        ? const Color(0xFF26282B)
        : const Color(0xFF44474A);
    final outline = highContrast
        ? const Color(0xFF494C50)
        : const Color(0xFF74777B);
    final outlineVariant = highContrast
        ? const Color(0xFF8C9095)
        : const Color(0xFFC4C7CB);
    const shadow = Color(0xFF000000);
    const scrim = Color(0xFF000000);
    const inverseSurface = Color(0xFF2F3133);
    const onInverseSurface = Color(0xFFF1F0F4);
    const inversePrimary = Color(0xFFC7C6C6);
    const surfaceDim = Color(0xFFDCDFE2);
    const surfaceBright = Color(0xFFF7F8FA);
    const surfaceContainerLowest = Color(0xFFFFFFFF);
    const surfaceContainerLow = Color(0xFFF1F3F5);
    const surfaceContainer = Color(0xFFEBEDEF);
    const surfaceContainerHigh = Color(0xFFE5E7EA);
    const surfaceContainerHighest = Color(0xFFDFE2E4);

    return ColorScheme(
      brightness: Brightness.light,
      primary: primary,
      onPrimary: onPrimary,
      primaryContainer: primaryContainer,
      onPrimaryContainer: onPrimaryContainer,
      secondary: secondary,
      onSecondary: onSecondary,
      secondaryContainer: secondaryContainer,
      onSecondaryContainer: onSecondaryContainer,
      tertiary: tertiary,
      onTertiary: onTertiary,
      tertiaryContainer: tertiaryContainer,
      onTertiaryContainer: onTertiaryContainer,
      error: error,
      onError: onError,
      errorContainer: errorContainer,
      onErrorContainer: onErrorContainer,
      surface: surface,
      onSurface: onSurface,
      onSurfaceVariant: onSurfaceVariant,
      outline: outline,
      outlineVariant: outlineVariant,
      shadow: shadow,
      scrim: scrim,
      inverseSurface: inverseSurface,
      onInverseSurface: onInverseSurface,
      inversePrimary: inversePrimary,
      surfaceDim: surfaceDim,
      surfaceBright: surfaceBright,
      surfaceContainerLowest: surfaceContainerLowest,
      surfaceContainerLow: surfaceContainerLow,
      surfaceContainer: surfaceContainer,
      surfaceContainerHigh: surfaceContainerHigh,
      surfaceContainerHighest: surfaceContainerHighest,
      surfaceTint: primary,
    );
  }
}

typedef ThemePreferenceWriter = Future<bool> Function(String key, Object value);

class ThemeProvider with ChangeNotifier implements PersistedStateReloader {
  static const _themeModeKey = 'themeMode';
  static const _pureBlackThemeKey = 'pureBlackTheme';
  static const _barGlassEnabledKey = 'barGlassEnabled';
  static const _appThemeColorKey = 'appThemeColor';
  static const _customThemeColorKey = 'customThemeColor';
  static const _useSystemAccentColorKey = 'useSystemAccentColor';

  ThemeMode _themeMode = ThemeMode.system;
  bool _pureBlackTheme = false;
  bool _barGlassEnabled = false;
  ThemeAccentPreset _appThemeColor = ThemeAccentPreset.rose;
  int? _customThemeColorValue;
  bool _useSystemAccentColor = false;
  Color? _systemAccentColor;
  final ValueNotifier<Color?> _systemAccentColorNotifier =
      ValueNotifier<Color?>(null);
  late ThemeMode _persistedThemeMode;
  late bool _persistedPureBlackTheme;
  late bool _persistedBarGlassEnabled;
  late ThemeAccentPreset _persistedAppThemeColor;
  int? _persistedCustomThemeColorValue;
  bool _persistedUseSystemAccentColor = false;
  int _themeModeMutation = 0;
  int _pureBlackThemeMutation = 0;
  int _barGlassEnabledMutation = 0;
  int _appThemeColorMutation = 0;
  int _customThemeColorMutation = 0;
  int _useSystemAccentColorMutation = 0;
  int _reloadGeneration = 0;
  bool _disposed = false;
  ThemeData? _lightTheme;
  ThemeData? _darkTheme;
  ThemeData? _highContrastLightTheme;
  ThemeData? _highContrastDarkTheme;
  int? _lightWindowBorderColor;
  int? _darkWindowBorderColor;

  ThemeMode get themeMode => _themeMode;
  bool get pureBlackTheme => _pureBlackTheme;
  bool get barGlassEnabled => _barGlassEnabled;
  ThemeAccentPreset get appThemeColor => _appThemeColor;
  int? get customThemeColorValue => _customThemeColorValue;
  Color? get customThemeColor => _customThemeColorValue == null
      ? null
      : Color(_customThemeColorValue!);
  bool get useSystemAccentColor => _useSystemAccentColor;
  Color? get systemAccentColor => _systemAccentColor;
  ValueListenable<Color?> get systemAccentColorListenable =>
      _systemAccentColorNotifier;

  /// Active non-preset seed color when following system accent or custom color.
  Color? get activeCustomSeedColor {
    if (_useSystemAccentColor && _systemAccentColor != null) {
      return _systemAccentColor;
    }
    final custom = _customThemeColorValue;
    return custom == null ? null : Color(custom);
  }

  /// Closest preset family used by native cold-start splash / window surfaces.
  ThemeAccentPreset get effectiveStartupPreset {
    final seed = activeCustomSeedColor;
    return seed == null ? _appThemeColor : nearestStartupPresetForColor(seed);
  }

  ThemeData get lightTheme =>
      _lightTheme ??= _buildTheme(_colorSchemeFor(Brightness.light));
  ThemeData get darkTheme =>
      _darkTheme ??= _buildTheme(_colorSchemeFor(Brightness.dark));
  ThemeData get highContrastLightTheme =>
      _highContrastLightTheme ??= _buildTheme(
        _colorSchemeFor(Brightness.light, highContrast: true),
        highContrast: true,
      );
  ThemeData get highContrastDarkTheme =>
      _highContrastDarkTheme ??= _buildTheme(
        _colorSchemeFor(Brightness.dark, highContrast: true),
        highContrast: true,
      );

  ThemeData themeFor(Brightness platformBrightness, {required bool highContrast}) {
    final brightness = switch (_themeMode) {
      ThemeMode.light => Brightness.light,
      ThemeMode.dark => Brightness.dark,
      ThemeMode.system => platformBrightness,
    };
    return switch ((brightness, highContrast)) {
      (Brightness.light, false) => lightTheme,
      (Brightness.dark, false) => darkTheme,
      (Brightness.light, true) => highContrastLightTheme,
      (Brightness.dark, true) => highContrastDarkTheme,
    };
  }

  /// Computes the Windows window border RGB value for [brightness] without
  /// building the full [ThemeData] for an inactive brightness.
  int windowBorderColorFor(Brightness brightness) {
    final cached = brightness == Brightness.dark
        ? _darkWindowBorderColor
        : _lightWindowBorderColor;
    if (cached != null) return cached;
    final colors = brightness == Brightness.dark
        ? (_darkTheme?.colorScheme ?? _colorSchemeFor(Brightness.dark))
        : (_lightTheme?.colorScheme ?? _colorSchemeFor(Brightness.light));
    final border = Color.alphaBlend(
      colors.outlineVariant.withValues(
        alpha: colors.brightness == Brightness.dark ? 0.45 : 0.65,
      ),
      colors.surface,
    );
    final value = border.toARGB32() & 0xffffff;
    if (brightness == Brightness.dark) {
      _darkWindowBorderColor = value;
    } else {
      _lightWindowBorderColor = value;
    }
    return value;
  }

  ThemeProvider({
    ThemePreferenceWriter? preferenceWriter,
    bool loadPersistedState = true,
  }) : _preferenceWriter = preferenceWriter ?? _writePreference {
    _loadThemeSync(readPreferences: loadPersistedState);
  }

  final ThemePreferenceWriter _preferenceWriter;
  Future<void> _preferenceWriteTail = Future<void>.value();
  final _pendingPreferenceWrites = <Future<bool>>{};

  /// Captures current writes so later changes cannot extend a backup barrier.
  Future<void> flushPendingWrites() async {
    final results = await Future.wait(_pendingPreferenceWrites.toList());
    if (results.contains(false)) {
      throw StateError('theme_preferences_write_failed');
    }
  }

  static Future<bool> _writePreference(String key, Object value) {
    return switch (value) {
      String stringValue => AppPreferences.setString(key, stringValue),
      bool boolValue => AppPreferences.setBool(key, boolValue),
      int intValue => AppPreferences.setInt(key, intValue),
      _ => Future<bool>.value(false),
    };
  }

  Future<bool> _writePreferenceInOrder(String key, Object value) {
    final write = _preferenceWriteTail.then(
      (_) => _preferenceWriter(key, value),
    );
    _pendingPreferenceWrites.add(write);
    _preferenceWriteTail = write.then<void>(
      (_) => _pendingPreferenceWrites.remove(write),
      onError: (Object _, StackTrace _) =>
          _pendingPreferenceWrites.remove(write),
    );
    return write;
  }

  static ThemeMode readThemeModeSync() {
    final storedMode = AppPreferences.getStringSync(_themeModeKey);
    return ThemeMode.values.firstWhere(
      (mode) => mode.name == storedMode,
      orElse: () => ThemeMode.system,
    );
  }

  static ThemeAccentPreset readAppThemeColorSync() {
    final storedColor = AppPreferences.getStringSync(_appThemeColorKey);
    final migrated = switch (storedColor) {
      'coral' => 'red',
      'lavender' => 'purple',
      'periwinkle' => 'indigo',
      'mint' => 'teal',
      'lightGreen' => 'green',
      'lime' => 'olive',
      'amber' => 'yellow',
      'peach' => 'brown',
      _ => storedColor,
    };
    return ThemeAccentPreset.values.firstWhere(
      (preset) => preset.name == migrated,
      orElse: () => ThemeAccentPreset.rose,
    );
  }

  static int? readCustomThemeColorSync() {
    final stored = AppPreferences.getIntSync(_customThemeColorKey);
    if (stored == null || stored == 0) return null;
    return stored | 0xFF000000;
  }

  void _loadThemeSync({bool readPreferences = true}) {
    if (readPreferences) {
      _themeMode = readThemeModeSync();
      _pureBlackTheme = AppPreferences.getBoolSync(_pureBlackThemeKey) ?? false;
      _barGlassEnabled =
          AppPreferences.getBoolSync(_barGlassEnabledKey) ?? false;
      _appThemeColor = readAppThemeColorSync();
      _customThemeColorValue = readCustomThemeColorSync();
      _useSystemAccentColor =
          AppPreferences.getBoolSync(_useSystemAccentColorKey) ?? false;
    }
    _persistedThemeMode = _themeMode;
    _persistedPureBlackTheme = _pureBlackTheme;
    _persistedBarGlassEnabled = _barGlassEnabled;
    _persistedAppThemeColor = _appThemeColor;
    _persistedCustomThemeColorValue = _customThemeColorValue;
    _persistedUseSystemAccentColor = _useSystemAccentColor;
  }

  void _notifyIfActive() {
    if (!_disposed) notifyListeners();
  }

  void _bumpAllMutations() {
    _themeModeMutation++;
    _pureBlackThemeMutation++;
    _barGlassEnabledMutation++;
    _appThemeColorMutation++;
    _customThemeColorMutation++;
    _useSystemAccentColorMutation++;
  }

  void setSystemAccentColor(Color? color) {
    if (_disposed) return;
    final normalized = color == null
        ? null
        : Color(color.toARGB32() | 0xFF000000);
    if (_systemAccentColor == normalized) return;
    _systemAccentColor = normalized;
    _systemAccentColorNotifier.value = normalized;
    if (!_useSystemAccentColor) return;
    _rebuildThemes();
    _notifyIfActive();
  }

  @override
  void dispose() {
    _disposed = true;
    _systemAccentColorNotifier.dispose();
    super.dispose();
  }

  Future<bool> setThemeMode(ThemeMode value) async {
    if (_disposed) return false;
    if (_themeMode == value) return true;
    final mutation = ++_themeModeMutation;
    final reloadGeneration = _reloadGeneration;
    _themeMode = value;
    _notifyIfActive();
    final persisted = await _writePreferenceInOrder(_themeModeKey, value.name);
    if (reloadGeneration != _reloadGeneration) return persisted;
    if (persisted) {
      _persistedThemeMode = value;
      return true;
    }
    if (mutation != _themeModeMutation) return false;
    _themeMode = _persistedThemeMode;
    _notifyIfActive();
    return false;
  }

  Future<bool> setPureBlackTheme(bool value) async {
    if (_disposed) return false;
    if (_pureBlackTheme == value) return true;
    final mutation = ++_pureBlackThemeMutation;
    final reloadGeneration = _reloadGeneration;
    _pureBlackTheme = value;
    _darkTheme = null;
    _highContrastDarkTheme = null;
    _darkWindowBorderColor = null;
    _notifyIfActive();
    final persisted = await _writePreferenceInOrder(_pureBlackThemeKey, value);
    if (reloadGeneration != _reloadGeneration) return persisted;
    if (persisted) {
      _persistedPureBlackTheme = value;
      return true;
    }
    if (mutation != _pureBlackThemeMutation) return false;
    _pureBlackTheme = _persistedPureBlackTheme;
    _darkTheme = null;
    _highContrastDarkTheme = null;
    _darkWindowBorderColor = null;
    _notifyIfActive();
    return false;
  }

  Future<bool> setBarGlassEnabled(bool value) async {
    if (_disposed) return false;
    if (_barGlassEnabled == value) return true;
    final mutation = ++_barGlassEnabledMutation;
    final reloadGeneration = _reloadGeneration;
    _barGlassEnabled = value;
    _rebuildThemes();
    _notifyIfActive();
    final persisted = await _writePreferenceInOrder(_barGlassEnabledKey, value);
    if (reloadGeneration != _reloadGeneration) return persisted;
    if (persisted) {
      _persistedBarGlassEnabled = value;
      return true;
    }
    if (mutation != _barGlassEnabledMutation) return false;
    _barGlassEnabled = _persistedBarGlassEnabled;
    _rebuildThemes();
    _notifyIfActive();
    return false;
  }

  Future<bool> setAppThemeColor(ThemeAccentPreset value) async {
    if (_disposed) return false;
    final clearingCustom = _customThemeColorValue != null;
    final clearingSystem = _useSystemAccentColor;
    if (_appThemeColor == value && !clearingCustom && !clearingSystem) {
      return true;
    }
    final presetMutation = ++_appThemeColorMutation;
    final customMutation = clearingCustom
        ? ++_customThemeColorMutation
        : _customThemeColorMutation;
    final systemMutation = clearingSystem
        ? ++_useSystemAccentColorMutation
        : _useSystemAccentColorMutation;
    final reloadGeneration = _reloadGeneration;
    _appThemeColor = value;
    _customThemeColorValue = null;
    _useSystemAccentColor = false;
    _rebuildThemes();
    _notifyIfActive();

    final presetWrite = _writePreferenceInOrder(_appThemeColorKey, value.name);
    final customWrite = clearingCustom
        ? _writePreferenceInOrder(_customThemeColorKey, 0)
        : null;
    final systemWrite = clearingSystem
        ? _writePreferenceInOrder(_useSystemAccentColorKey, false)
        : null;
    final presetPersisted = await presetWrite;
    final customPersisted = customWrite == null ? true : await customWrite;
    final systemPersisted = systemWrite == null ? true : await systemWrite;
    final allPersisted = presetPersisted && customPersisted && systemPersisted;
    if (reloadGeneration != _reloadGeneration) return allPersisted;

    var rolledBack = false;
    if (presetPersisted) {
      _persistedAppThemeColor = value;
    } else if (presetMutation == _appThemeColorMutation) {
      _appThemeColor = _persistedAppThemeColor;
      rolledBack = true;
    }
    if (clearingCustom) {
      if (customPersisted) {
        _persistedCustomThemeColorValue = null;
      } else if (customMutation == _customThemeColorMutation) {
        _customThemeColorValue = _persistedCustomThemeColorValue;
        rolledBack = true;
      }
    }
    if (clearingSystem) {
      if (systemPersisted) {
        _persistedUseSystemAccentColor = false;
      } else if (systemMutation == _useSystemAccentColorMutation) {
        _useSystemAccentColor = _persistedUseSystemAccentColor;
        rolledBack = true;
      }
    }
    if (allPersisted) return true;
    if (rolledBack) {
      _rebuildThemes();
      _notifyIfActive();
    }
    return false;
  }

  Future<bool> setCustomThemeColor(Color? value) async {
    if (_disposed) return false;
    final normalized = value == null ? null : (value.toARGB32() | 0xFF000000);
    final clearingSystem = normalized != null && _useSystemAccentColor;
    if (_customThemeColorValue == normalized && !clearingSystem) return true;
    final customMutation = ++_customThemeColorMutation;
    final systemMutation = clearingSystem
        ? ++_useSystemAccentColorMutation
        : _useSystemAccentColorMutation;
    final reloadGeneration = _reloadGeneration;
    _customThemeColorValue = normalized;
    if (clearingSystem) _useSystemAccentColor = false;
    _rebuildThemes();
    _notifyIfActive();

    final customWrite = _writePreferenceInOrder(
      _customThemeColorKey,
      normalized ?? 0,
    );
    final systemWrite = clearingSystem
        ? _writePreferenceInOrder(_useSystemAccentColorKey, false)
        : null;
    final customPersisted = await customWrite;
    final systemPersisted = systemWrite == null ? true : await systemWrite;
    final allPersisted = customPersisted && systemPersisted;
    if (reloadGeneration != _reloadGeneration) return allPersisted;

    var rolledBack = false;
    if (customPersisted) {
      _persistedCustomThemeColorValue = normalized;
    } else if (customMutation == _customThemeColorMutation) {
      _customThemeColorValue = _persistedCustomThemeColorValue;
      rolledBack = true;
    }
    if (clearingSystem) {
      if (systemPersisted) {
        _persistedUseSystemAccentColor = false;
      } else if (systemMutation == _useSystemAccentColorMutation) {
        _useSystemAccentColor = _persistedUseSystemAccentColor;
        rolledBack = true;
      }
    }
    if (allPersisted) return true;
    if (rolledBack) {
      _rebuildThemes();
      _notifyIfActive();
    }
    return false;
  }

  Future<bool> setUseSystemAccentColor(bool value) async {
    if (_disposed) return false;
    if (_useSystemAccentColor == value) return true;
    final mutation = ++_useSystemAccentColorMutation;
    final reloadGeneration = _reloadGeneration;
    _useSystemAccentColor = value;
    _rebuildThemes();
    _notifyIfActive();
    final persisted = await _writePreferenceInOrder(
      _useSystemAccentColorKey,
      value,
    );
    if (reloadGeneration != _reloadGeneration) return persisted;
    if (persisted) {
      _persistedUseSystemAccentColor = value;
      return true;
    }
    if (mutation != _useSystemAccentColorMutation) return false;
    _useSystemAccentColor = _persistedUseSystemAccentColor;
    _rebuildThemes();
    _notifyIfActive();
    return false;
  }

  @override
  Future<void> reloadPersistedState() async {
    if (_disposed) return;
    final generation = ++_reloadGeneration;
    _bumpAllMutations();
    if (_pendingPreferenceWrites.isNotEmpty) {
      await _preferenceWriteTail;
      if (_disposed || generation != _reloadGeneration) return;
    }
    final previousMode = _themeMode;
    final previousPureBlack = _pureBlackTheme;
    final previousBarGlass = _barGlassEnabled;
    final previousColor = _appThemeColor;
    final previousCustom = _customThemeColorValue;
    final previousSystem = _useSystemAccentColor;
    _loadThemeSync();
    if (_themeMode == previousMode &&
        _pureBlackTheme == previousPureBlack &&
        _barGlassEnabled == previousBarGlass &&
        _appThemeColor == previousColor &&
        _customThemeColorValue == previousCustom &&
        _useSystemAccentColor == previousSystem) {
      return;
    }
    _rebuildThemes();
    _notifyIfActive();
  }

  void _rebuildThemes() {
    _lightTheme = null;
    _darkTheme = null;
    _highContrastLightTheme = null;
    _highContrastDarkTheme = null;
    _lightWindowBorderColor = null;
    _darkWindowBorderColor = null;
  }

  ColorScheme _colorSchemeFor(
    Brightness brightness, {
    bool highContrast = false,
  }) {
    final pureBlack = _pureBlackTheme && brightness == Brightness.dark;
    final customSeed = activeCustomSeedColor;
    if (customSeed != null) {
      return buildAppColorScheme(
        seedColor: customSeed,
        brightness: brightness,
        pureBlack: pureBlack,
        highContrast: highContrast,
      );
    }
    return _appThemeColor.colorScheme(
      brightness,
      pureBlack: pureBlack,
      highContrast: highContrast,
    );
  }

  ThemeData _buildTheme(ColorScheme scheme, {bool highContrast = false}) {
    final isWindows = defaultTargetPlatform == TargetPlatform.windows;
    const mobileText = TextTheme(
      bodyMedium: TextStyle(fontSize: 14, height: 1.5),
      bodyLarge: TextStyle(fontSize: 15, height: 1.5),
      labelLarge: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.1,
      ),
      labelMedium: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
      labelSmall: TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
      bodySmall: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
      titleMedium: TextStyle(
        fontWeight: FontWeight.w700,
        fontSize: 14,
        height: 1.25,
      ),
      titleSmall: TextStyle(
        fontWeight: FontWeight.w600,
        fontSize: 13,
        height: 1.3,
      ),
      titleLarge: TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
      headlineMedium: TextStyle(
        fontWeight: FontWeight.w800,
        fontSize: 31,
        height: 1.05,
      ),
      headlineSmall: TextStyle(fontWeight: FontWeight.w800, fontSize: 20),
    );
    final bodyText = isWindows ? _windowsTextTheme : mobileText;

    final effectivePureBlack =
        _pureBlackTheme && scheme.brightness == Brightness.dark;
    final baseTokens = switch ((scheme.brightness, highContrast)) {
      (Brightness.dark, true) => AppDesignTokens.highContrastDark,
      (Brightness.dark, false) => AppDesignTokens.dark,
      (Brightness.light, true) => AppDesignTokens.highContrastLight,
      (Brightness.light, false) => AppDesignTokens.light,
    };
    final tokens = baseTokens.copyWith(
      barGlassEnabled: _barGlassEnabled,
      pureBlack: effectivePureBlack,
    );
    final floatingSurface = appFloatingSurfaceColor(scheme);

    const buttonShape = StadiumBorder();
    final textTheme = applyAppTextThemeColors(
      bodyText,
      scheme,
    ).merge(_tabularTextTheme);
    final inputBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(tokens.radiusControl),
      borderSide: BorderSide(color: scheme.outlineVariant),
    );
    final focusedInputBorder = inputBorder.copyWith(
      borderSide: BorderSide(color: scheme.primary, width: 1.4),
    );
    final pickerShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(tokens.radiusOverlay),
    );
    final pickerActionStyle = appEditPanelActionStyle();
    final pickerTitleStyle = textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w800,
    );

    return ThemeData(
      useMaterial3: true,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      extensions: <ThemeExtension<dynamic>>[tokens],
      visualDensity: VisualDensity.standard,
      colorScheme: scheme,
      textTheme: textTheme,
      primaryTextTheme: _tabularTextTheme,
      tooltipTheme: const TooltipThemeData(
        triggerMode: TooltipTriggerMode.manual,
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: AppPageTransitionsBuilder(),
          TargetPlatform.fuchsia: AppPageTransitionsBuilder(),
          TargetPlatform.iOS: AppPageTransitionsBuilder(),
          TargetPlatform.linux: AppPageTransitionsBuilder(),
          TargetPlatform.macOS: AppPageTransitionsBuilder(),
          TargetPlatform.windows: AppPageTransitionsBuilder(),
        },
      ),
      hoverColor: appHoverTint(scheme),
      // Switches belong to interactive option rows, which paint their own
      // hover shape. Avoid a second circular highlight around the thumb.
      checkboxTheme: const CheckboxThemeData(
        mouseCursor: WidgetStateMouseCursor.clickable,
      ),
      radioTheme: const RadioThemeData(
        mouseCursor: WidgetStateMouseCursor.clickable,
      ),
      switchTheme: SwitchThemeData(
        mouseCursor: WidgetStateMouseCursor.clickable,
        overlayColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.hovered) || states.contains(WidgetState.pressed)
                ? Colors.transparent
                : null,
        ),
      ),
      focusColor: scheme.primary.withValues(alpha: 0.12),
      highlightColor: Colors.transparent,
      splashColor: appPressedTint(scheme),
      scaffoldBackgroundColor: scheme.surface,
      canvasColor: scheme.surface,
      dividerColor: scheme.outlineVariant,
      splashFactory: AppTapHighlightFactory.forPlatform(defaultTargetPlatform),
      cardTheme: CardThemeData(
        color: scheme.surfaceContainerLow,
        elevation: 0,
        margin: EdgeInsets.zero,
        shadowColor: scheme.shadow.withValues(alpha: 0.08),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(tokens.radiusCard),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        useIndicator: true,
        indicatorShape: const CircleBorder(),
        minWidth: 88,
        minExtendedWidth: 250,
        selectedIconTheme: IconThemeData(color: scheme.primary, size: 22),
        unselectedIconTheme: IconThemeData(
          color: scheme.onSurfaceVariant,
          size: 21,
        ),
        selectedLabelTextStyle: _tabularDigits.copyWith(
          fontWeight: isWindows ? FontWeight.w600 : FontWeight.w700,
          color: scheme.primary,
        ),
        unselectedLabelTextStyle: _tabularDigits.copyWith(
          fontWeight: isWindows ? FontWeight.w400 : FontWeight.w600,
          color: scheme.onSurfaceVariant,
        ),
        indicatorColor: scheme.primaryContainer,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: appSurfaceButtonStyle(
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
            shape: buttonShape,
            textStyle: _tabularDigits.copyWith(
              fontWeight: isWindows ? FontWeight.w600 : FontWeight.w700,
            ),
          ),
          colorScheme: scheme,
          platform: isWindows ? TargetPlatform.windows : defaultTargetPlatform,
          defaultBackgroundColor: scheme.primary,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: appSurfaceButtonStyle(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
            shape: buttonShape,
            side: BorderSide(color: scheme.outlineVariant),
            textStyle: _tabularDigits.copyWith(
              fontWeight: isWindows ? FontWeight.w600 : FontWeight.w700,
            ),
          ),
          colorScheme: scheme,
          platform: isWindows ? TargetPlatform.windows : defaultTargetPlatform,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: appTextButtonStyle(
          style: TextButton.styleFrom(
            minimumSize: Size(tokens.minimumTapTarget, tokens.minimumTapTarget),
            shape: buttonShape,
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: appIconButtonStyle(
          IconButton.styleFrom(
            minimumSize: Size(tokens.minimumTapTarget, tokens.minimumTapTarget),
            visualDensity: VisualDensity.standard,
            shape: const CircleBorder(),
          ),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: appSegmentedButtonStyle(
          colorScheme: scheme,
          platform: isWindows ? TargetPlatform.windows : defaultTargetPlatform,
        ),
      ),
      chipTheme: appChipTheme(
        colorScheme: scheme,
        platform: isWindows ? TargetPlatform.windows : defaultTargetPlatform,
        baseLabelStyle: textTheme.labelLarge,
      ),
      sliderTheme: SliderThemeData(
        trackHeight: 4,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
        activeTrackColor: scheme.primary,
        inactiveTrackColor: scheme.outlineVariant.withValues(alpha: 0.55),
        thumbColor: scheme.primary,
        overlayColor: scheme.primary.withValues(alpha: 0.12),
      ),
      listTileTheme: ListTileThemeData(
        // A passive ListTile can be the visual child of a clickable entry.
        mouseCursor: const WidgetStateProperty.fromMap({
          WidgetState.disabled: MouseCursor.defer,
          WidgetState.any: SystemMouseCursors.click,
        }),
        dense: false,
        minLeadingWidth: 24,
        textColor: scheme.onSurface,
        titleTextStyle: textTheme.titleMedium,
        subtitleTextStyle: textTheme.bodySmall,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(tokens.radiusCard),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        mouseCursor: WidgetStateMouseCursor.clickable,
        backgroundColor: scheme.primaryContainer,
        foregroundColor: scheme.onPrimaryContainer,
        hoverColor: Colors.transparent,
        splashColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(tokens.radiusCard),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 68,
        backgroundColor: scheme.surfaceContainerLow,
        indicatorColor: scheme.primaryContainer,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return _tabularDigits.copyWith(
            fontSize: 11,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
          );
        }),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        labelStyle: textTheme.bodyMedium,
        hintStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        helperStyle: textTheme.bodySmall,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 12,
        ),
        constraints: BoxConstraints(minHeight: tokens.minimumTapTarget - 4),
        fillColor: scheme.surfaceContainer,
        border: inputBorder,
        enabledBorder: inputBorder,
        focusedBorder: focusedInputBorder,
      ),
      datePickerTheme: DatePickerThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        shape: pickerShape,
        headerHelpStyle: pickerTitleStyle,
        cancelButtonStyle: pickerActionStyle,
        confirmButtonStyle: pickerActionStyle,
      ),
      timePickerTheme: TimePickerThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        shape: pickerShape,
        helpTextStyle: pickerTitleStyle,
        cancelButtonStyle: pickerActionStyle,
        confirmButtonStyle: pickerActionStyle,
        inputDecorationTheme: InputDecorationThemeData(
          contentPadding: EdgeInsets.zero,
          filled: true,
          fillColor: scheme.surfaceContainer,
          border: inputBorder,
          enabledBorder: inputBorder,
          focusedBorder: focusedInputBorder,
          hintStyle: _tabularDigits.copyWith(color: scheme.onSurfaceVariant),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        toolbarHeight: AppPageHeaderMetrics.toolbarHeight,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: floatingSurface,
        contentTextStyle: _tabularDigits.copyWith(
          color: scheme.onSurface,
          fontWeight: FontWeight.w500,
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        elevation: 0,
        shadowColor: scheme.shadow.withValues(alpha: 0.14),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(tokens.radiusOverlay),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: floatingSurface,
        modalBackgroundColor: floatingSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        modalElevation: 0,
        dragHandleColor: scheme.onSurfaceVariant.withValues(alpha: 0.42),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(tokens.radiusOverlay),
          ),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        mouseCursor: WidgetStateMouseCursor.clickable,
        color: floatingSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(tokens.radiusCard),
        ),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.dragged) ||
              states.contains(WidgetState.hovered)) {
            return 8;
          }
          return 4;
        }),
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.dragged)) {
            return scheme.primary;
          }
          if (states.contains(WidgetState.hovered)) {
            return scheme.primary.withValues(alpha: 0.7);
          }
          return scheme.outlineVariant.withValues(alpha: 0.5);
        }),
        trackColor: WidgetStateProperty.all(Colors.transparent),
        crossAxisMargin: 4,
        mainAxisMargin: 4,
        radius: const Radius.circular(AppRadius.small),
      ),
    );
  }
}
