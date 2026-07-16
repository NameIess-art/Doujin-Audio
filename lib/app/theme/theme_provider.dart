import 'dart:io';
import 'package:flutter/material.dart';

import '../../features/settings/application/app_preferences.dart';
import '../../core/widgets/app_transitions.dart';
import 'app_design_tokens.dart';

class ThemeProvider with ChangeNotifier {
  static const _themeModeKey = 'themeMode';

  ThemeMode _themeMode = ThemeMode.system;
  bool _differentiateAsmrTheme = true;
  late ThemeData _lightTheme = _buildTheme(_lightScheme);
  late ThemeData _darkTheme = _buildTheme(_darkScheme);

  ThemeMode get themeMode => _themeMode;
  bool get differentiateAsmrTheme => _differentiateAsmrTheme;
  ThemeData get lightTheme => _lightTheme;
  ThemeData get darkTheme => _darkTheme;

  ThemeProvider() {
    _loadThemeSync();
  }

  void _loadThemeSync() {
    final storedMode = AppPreferences.getStringSync(_themeModeKey);
    _themeMode = ThemeMode.values.firstWhere(
      (mode) => mode.name == storedMode,
      orElse: () => ThemeMode.system,
    );
    _differentiateAsmrTheme =
        AppPreferences.getBoolSync('differentiateAsmrTheme') ?? true;
  }

  Future<void> setThemeMode(ThemeMode value) async {
    if (_themeMode == value) return;
    _themeMode = value;
    notifyListeners();
    await AppPreferences.setString(_themeModeKey, value.name);
  }

  Future<void> setDifferentiateAsmrTheme(bool value) async {
    if (_differentiateAsmrTheme == value) return;
    _differentiateAsmrTheme = value;
    _lightTheme = _buildTheme(_lightScheme);
    _darkTheme = _buildTheme(_darkScheme);
    notifyListeners();
    await AppPreferences.setBool('differentiateAsmrTheme', value);
  }

  static final ColorScheme _lightScheme =
      ColorScheme.fromSeed(seedColor: const Color(0xFFC94D63)).copyWith(
        primary: const Color(0xFFC94D63),
        onPrimary: Colors.white,
        secondary: const Color(0xFF526074),
        onSecondary: Colors.white,
        tertiary: const Color(0xFF7A6C93),
        onTertiary: Colors.white,
        surface: const Color(0xFFFBFAF8),
        onSurface: const Color(0xFF1A1A1E),
        surfaceContainerHighest: const Color(0xFFE8E5E9),
        surfaceContainerHigh: const Color(0xFFF0ECEF),
        surfaceContainer: const Color(0xFFF4F1F3),
        surfaceContainerLow: const Color(0xFFF8F6F7),
        primaryContainer: const Color(0xFFF2D7DC),
        onPrimaryContainer: const Color(0xFF4E1D28),
        secondaryContainer: const Color(0xFFDEE5EF),
        onSecondaryContainer: const Color(0xFF202835),
        tertiaryContainer: const Color(0xFFE6DDF4),
        onTertiaryContainer: const Color(0xFF2B213A),
        outline: const Color(0xFF8B8891),
        outlineVariant: const Color(0xFFD4D4D8),
        shadow: const Color(0xFF18181B),
      );

  static final ColorScheme _darkScheme =
      ColorScheme.fromSeed(
        seedColor: const Color(0xFFE9788E),
        brightness: Brightness.dark,
      ).copyWith(
        primary: const Color(0xFFF08599),
        onPrimary: const Color(0xFF301017),
        secondary: const Color(0xFFD4D9E2),
        onSecondary: const Color(0xFF171D27),
        tertiary: const Color(0xFFCFC6E6),
        onTertiary: const Color(0xFF20182C),
        surface: const Color(0xFF111114),
        onSurface: const Color(0xFFFAFAFA),
        surfaceDim: const Color(0xFF0B0B0D),
        surfaceBright: const Color(0xFF25252B),
        surfaceContainerLowest: const Color(0xFF09090A),
        surfaceContainerLow: const Color(0xFF17171A),
        surfaceContainer: const Color(0xFF1E1E22),
        surfaceContainerHigh: const Color(0xFF25252A),
        surfaceContainerHighest: const Color(0xFF2D2D33),
        onSurfaceVariant: const Color(0xFFB8B3BC),
        primaryContainer: const Color(0xFF3A2028),
        onPrimaryContainer: const Color(0xFFFFD9E0),
        secondaryContainer: const Color(0xFF29313D),
        onSecondaryContainer: const Color(0xFFE6EBF5),
        tertiaryContainer: const Color(0xFF332A43),
        onTertiaryContainer: const Color(0xFFF2E8FF),
        outline: const Color(0xFF71717A),
        outlineVariant: const Color(0xFF3F3F46),
        shadow: Colors.black,
      );

  ThemeData _buildTheme(ColorScheme scheme) {
    final bool isDesktop =
        !const bool.fromEnvironment('dart.library.html') &&
        (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

    final bodyText = const TextTheme().copyWith(
      bodyMedium: TextStyle(
        fontFamily: 'Raleway',
        fontSize: isDesktop ? 13 : 14,
        height: 1.5,
      ),
      bodyLarge: TextStyle(
        fontFamily: 'Raleway',
        fontSize: isDesktop ? 14 : 15,
        height: 1.5,
      ),
      labelLarge: TextStyle(
        fontFamily: 'Raleway',
        fontSize: isDesktop ? 11 : 12,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.1,
      ),
      labelMedium: const TextStyle(
        fontFamily: 'Raleway',
        fontSize: 11,
        fontWeight: FontWeight.w600,
      ),
      labelSmall: const TextStyle(
        fontFamily: 'Raleway',
        fontSize: 10,
        fontWeight: FontWeight.w600,
      ),
      bodySmall: const TextStyle(
        fontFamily: 'Raleway',
        fontSize: 12,
        fontWeight: FontWeight.w500,
      ),
      titleMedium: TextStyle(
        fontFamily: 'Raleway',
        fontWeight: FontWeight.w700,
        fontSize: isDesktop ? 13 : 14,
        height: 1.25,
      ),
      titleLarge: TextStyle(
        fontFamily: 'Outfit',
        fontWeight: FontWeight.w700,
        fontSize: isDesktop ? 16 : 18,
      ),
      headlineMedium: TextStyle(
        fontFamily: 'Outfit',
        fontWeight: FontWeight.w800,
        fontSize: isDesktop ? 26 : 31,
        height: 1.05,
      ),
      headlineSmall: TextStyle(
        fontFamily: 'Outfit',
        fontWeight: FontWeight.w800,
        fontSize: isDesktop ? 18 : 20,
      ),
    );

    AppDesignTokens tokens = scheme.brightness == Brightness.dark
        ? AppDesignTokens.dark
        : AppDesignTokens.light;

    if (!_differentiateAsmrTheme) {
      tokens = tokens.copyWith(
        asmrAccent: scheme.primary,
        asmrContainer: scheme.primaryContainer,
        onAsmrContainer: scheme.onPrimaryContainer,
        onAsmrAccent: scheme.onPrimary,
        asmrSurface: scheme.surfaceContainerLow,
      );
    }

    final largeShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(
        isDesktop ? tokens.radiusSmall : tokens.radiusSection,
      ),
    );

    return ThemeData(
      useMaterial3: true,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      extensions: <ThemeExtension<dynamic>>[tokens],
      visualDensity: isDesktop ? VisualDensity.compact : VisualDensity.standard,
      colorScheme: scheme,
      textTheme: bodyText.apply(
        bodyColor: scheme.onSurface,
        displayColor: scheme.onSurface,
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: CenterScalePageTransitionsBuilder(),
          TargetPlatform.iOS: CenterScalePageTransitionsBuilder(),
          TargetPlatform.linux: CenterScalePageTransitionsBuilder(),
          TargetPlatform.macOS: CenterScalePageTransitionsBuilder(),
          TargetPlatform.windows: CenterScalePageTransitionsBuilder(),
        },
      ),
      hoverColor: scheme.primary.withValues(alpha: 0.08),
      focusColor: scheme.primary.withValues(alpha: 0.12),
      highlightColor: scheme.primary.withValues(alpha: 0.12),
      scaffoldBackgroundColor: isDesktop ? Colors.transparent : scheme.surface,
      canvasColor: isDesktop ? Colors.transparent : scheme.surface,
      dividerColor: scheme.outlineVariant,
      splashFactory: InkRipple.splashFactory,
      cardTheme: CardThemeData(
        color: scheme.surfaceContainerLow,
        elevation: 0,
        margin: EdgeInsets.zero,
        shadowColor: scheme.shadow.withValues(alpha: 0.08),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(
            isDesktop ? tokens.radiusControl : tokens.radiusCard,
          ),
          side: BorderSide(
            color: scheme.outlineVariant.withValues(
              alpha: isDesktop ? 0.38 : tokens.standardBorderAlpha,
            ),
          ),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        useIndicator: true,
        minWidth: 88,
        minExtendedWidth: 250,
        selectedIconTheme: IconThemeData(color: scheme.primary, size: 22),
        unselectedIconTheme: IconThemeData(
          color: scheme.onSurfaceVariant,
          size: 21,
        ),
        selectedLabelTextStyle: TextStyle(
          fontWeight: FontWeight.w700,
          color: scheme.primary,
        ),
        unselectedLabelTextStyle: TextStyle(
          fontWeight: FontWeight.w600,
          color: scheme.onSurfaceVariant,
        ),
        indicatorColor: scheme.primaryContainer,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          shape: largeShape,
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          shape: largeShape,
          side: BorderSide(color: scheme.outlineVariant),
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: Size(tokens.minimumTapTarget, tokens.minimumTapTarget),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(tokens.radiusControl),
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: Size(tokens.minimumTapTarget, tokens.minimumTapTarget),
          visualDensity: VisualDensity.standard,
        ),
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
        dense: isDesktop,
        minLeadingWidth: 24,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(tokens.radiusCard),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primaryContainer,
        foregroundColor: scheme.onPrimaryContainer,
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
          return TextStyle(
            fontSize: 11,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
          );
        }),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        constraints: BoxConstraints(minHeight: tokens.minimumTapTarget),
        fillColor: scheme.surfaceContainer,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(tokens.radiusControl),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(tokens.radiusControl),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(tokens.radiusControl),
          borderSide: BorderSide(color: scheme.primary, width: 1.4),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        contentTextStyle: TextStyle(
          color: scheme.onSurface,
          fontWeight: FontWeight.w500,
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        elevation: 0,
        shadowColor: scheme.shadow.withValues(alpha: 0.12),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(tokens.radiusOverlay),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        modalBackgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        modalElevation: 0,
        dragHandleColor: scheme.onSurfaceVariant.withValues(alpha: 0.42),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(tokens.radiusOverlay),
          ),
          side: BorderSide(
            color: scheme.outlineVariant.withValues(
              alpha: tokens.subtleBorderAlpha,
            ),
          ),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(tokens.radiusCard),
          side: BorderSide(
            color: scheme.outlineVariant.withValues(
              alpha: tokens.standardBorderAlpha,
            ),
          ),
        ),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.hovered)) return isDesktop ? 6 : 8;
          return isDesktop ? 3 : 4;
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
        radius: const Radius.circular(8),
      ),
    );
  }
}

final class ThemeState {
  const ThemeState({
    required this.themeMode,
    required this.differentiateAsmrTheme,
    required this.lightTheme,
    required this.darkTheme,
  });

  factory ThemeState.from(ThemeProvider provider) {
    return ThemeState(
      themeMode: provider.themeMode,
      differentiateAsmrTheme: provider.differentiateAsmrTheme,
      lightTheme: provider.lightTheme,
      darkTheme: provider.darkTheme,
    );
  }

  final ThemeMode themeMode;
  final bool differentiateAsmrTheme;
  final ThemeData lightTheme;
  final ThemeData darkTheme;

  @override
  bool operator ==(Object other) {
    return other is ThemeState &&
        other.themeMode == themeMode &&
        other.differentiateAsmrTheme == differentiateAsmrTheme &&
        identical(other.lightTheme, lightTheme) &&
        identical(other.darkTheme, darkTheme);
  }

  @override
  int get hashCode => Object.hash(
    themeMode,
    differentiateAsmrTheme,
    identityHashCode(lightTheme),
    identityHashCode(darkTheme),
  );
}
