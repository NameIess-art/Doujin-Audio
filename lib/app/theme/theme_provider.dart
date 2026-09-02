import 'package:flutter/material.dart';

import '../../core/persistence/persisted_state_reloader.dart';
import '../../features/settings/application/app_preferences.dart';
import '../../core/widgets/app_transitions.dart';
import 'app_design_tokens.dart';
import 'app_styles.dart';

enum ThemeAccentPreset {
  coral,
  rose,
  pink,
  lavender,
  periwinkle,
  blue,
  sky,
  cyan,
  mint,
  green,
  lightGreen,
  lime,
  amber,
  orange,
  peach,
  gray,
}

extension ThemeAccentPresetValue on ThemeAccentPreset {
  Color get primaryColor => switch (this) {
    ThemeAccentPreset.coral => const Color(0xFFFFB4A9),
    ThemeAccentPreset.rose => const Color(0xFFFFB2BD),
    ThemeAccentPreset.pink => const Color(0xFFEBB5ED),
    ThemeAccentPreset.lavender => const Color(0xFFD3BCFD),
    ThemeAccentPreset.periwinkle => const Color(0xFFBAC3FF),
    ThemeAccentPreset.blue => const Color(0xFFA1C9FD),
    ThemeAccentPreset.sky => const Color(0xFF8BD0F0),
    ThemeAccentPreset.cyan => const Color(0xFF83D2E4),
    ThemeAccentPreset.mint => const Color(0xFF82D5C7),
    ThemeAccentPreset.green => const Color(0xFFA2D399),
    ThemeAccentPreset.lightGreen => const Color(0xFFB0D18B),
    ThemeAccentPreset.lime => const Color(0xFFC3CD7B),
    ThemeAccentPreset.amber => const Color(0xFFF0BE6D),
    ThemeAccentPreset.orange => const Color(0xFFFFB77B),
    ThemeAccentPreset.peach => const Color(0xFFE7BDB0),
    ThemeAccentPreset.gray => const Color(0xFFC7C6C6),
  };

  String get labelKey => switch (this) {
    ThemeAccentPreset.lightGreen => 'theme_color_light_green',
    _ => 'theme_color_$name',
  };

  Color bootstrapSurfaceColor(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return switch (this) {
      ThemeAccentPreset.coral ||
      ThemeAccentPreset.rose ||
      ThemeAccentPreset.pink =>
        dark ? const Color(0xFF211A1B) : const Color(0xFFFFF8F8),
      ThemeAccentPreset.lavender || ThemeAccentPreset.periwinkle =>
        dark ? const Color(0xFF1D1927) : const Color(0xFFFAF8FF),
      ThemeAccentPreset.blue ||
      ThemeAccentPreset.sky ||
      ThemeAccentPreset.cyan =>
        dark ? const Color(0xFF111D24) : const Color(0xFFF5FBFF),
      ThemeAccentPreset.mint ||
      ThemeAccentPreset.green ||
      ThemeAccentPreset.lightGreen =>
        dark ? const Color(0xFF12201C) : const Color(0xFFF5FFF9),
      ThemeAccentPreset.lime ||
      ThemeAccentPreset.amber ||
      ThemeAccentPreset.orange ||
      ThemeAccentPreset.peach =>
        dark ? const Color(0xFF241D13) : const Color(0xFFFFF9F2),
      ThemeAccentPreset.gray =>
        dark ? const Color(0xFF1A1D21) : const Color(0xFFF7F8FA),
    };
  }

  ColorScheme colorScheme(Brightness brightness) {
    final generated = ColorScheme.fromSeed(
      seedColor: primaryColor,
      brightness: brightness,
    );
    if (brightness == Brightness.light) return generated;
    final onPrimary =
        ThemeData.estimateBrightnessForColor(primaryColor) == Brightness.dark
        ? Colors.white
        : const Color(0xFF1B1B1F);
    return generated.copyWith(
      primary: primaryColor,
      onPrimary: onPrimary,
      surfaceTint: primaryColor,
    );
  }
}

typedef ThemePreferenceWriter = Future<bool> Function(String key, Object value);

class ThemeProvider with ChangeNotifier implements PersistedStateReloader {
  static const _themeModeKey = 'themeMode';
  static const _differentiateAsmrThemeKey = 'differentiateAsmrTheme';
  static const _appThemeColorKey = 'appThemeColor';
  static const _asmrThemeColorKey = 'asmrThemeColor';

  ThemeMode _themeMode = ThemeMode.system;
  bool _differentiateAsmrTheme = true;
  ThemeAccentPreset _appThemeColor = ThemeAccentPreset.rose;
  ThemeAccentPreset _asmrThemeColor = ThemeAccentPreset.blue;
  late ThemeMode _persistedThemeMode;
  late bool _persistedDifferentiateAsmrTheme;
  late ThemeAccentPreset _persistedAppThemeColor;
  late ThemeAccentPreset _persistedAsmrThemeColor;
  int _themeModeMutation = 0;
  int _differentiateAsmrThemeMutation = 0;
  int _appThemeColorMutation = 0;
  int _asmrThemeColorMutation = 0;
  late ThemeData _lightTheme;
  late ThemeData _darkTheme;

  ThemeMode get themeMode => _themeMode;
  bool get differentiateAsmrTheme => _differentiateAsmrTheme;
  ThemeAccentPreset get appThemeColor => _appThemeColor;
  ThemeAccentPreset get asmrThemeColor => _asmrThemeColor;
  ThemeData get lightTheme => _lightTheme;
  ThemeData get darkTheme => _darkTheme;

  ThemeProvider({ThemePreferenceWriter? preferenceWriter})
    : _preferenceWriter = preferenceWriter ?? _writePreference {
    _loadThemeSync();
    _rebuildThemes();
  }

  final ThemePreferenceWriter _preferenceWriter;
  Future<void> _preferenceWriteTail = Future<void>.value();

  static Future<bool> _writePreference(String key, Object value) {
    return switch (value) {
      String stringValue => AppPreferences.setString(key, stringValue),
      bool boolValue => AppPreferences.setBool(key, boolValue),
      _ => Future<bool>.value(false),
    };
  }

  Future<bool> _writePreferenceInOrder(String key, Object value) {
    final write = _preferenceWriteTail.then(
      (_) => _preferenceWriter(key, value),
    );
    _preferenceWriteTail = write.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
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
    return ThemeAccentPreset.values.firstWhere(
      (preset) => preset.name == storedColor,
      orElse: () => ThemeAccentPreset.rose,
    );
  }

  void _loadThemeSync() {
    _themeMode = readThemeModeSync();
    _differentiateAsmrTheme =
        AppPreferences.getBoolSync(_differentiateAsmrThemeKey) ?? true;
    _appThemeColor = readAppThemeColorSync();
    _asmrThemeColor = _readThemeColor(
      AppPreferences.getStringSync(_asmrThemeColorKey),
      ThemeAccentPreset.blue,
    );
    _persistedThemeMode = _themeMode;
    _persistedDifferentiateAsmrTheme = _differentiateAsmrTheme;
    _persistedAppThemeColor = _appThemeColor;
    _persistedAsmrThemeColor = _asmrThemeColor;
  }

  ThemeAccentPreset _readThemeColor(
    String? storedValue,
    ThemeAccentPreset fallback,
  ) {
    return ThemeAccentPreset.values.firstWhere(
      (preset) => preset.name == storedValue,
      orElse: () => fallback,
    );
  }

  Future<bool> setThemeMode(ThemeMode value) async {
    if (_themeMode == value) return true;
    final mutation = ++_themeModeMutation;
    _themeMode = value;
    notifyListeners();
    final persisted = await _writePreferenceInOrder(_themeModeKey, value.name);
    if (persisted) {
      _persistedThemeMode = value;
      return true;
    }
    if (mutation != _themeModeMutation) return false;
    _themeMode = _persistedThemeMode;
    notifyListeners();
    return false;
  }

  Future<bool> setDifferentiateAsmrTheme(bool value) async {
    if (_differentiateAsmrTheme == value) return true;
    final mutation = ++_differentiateAsmrThemeMutation;
    _differentiateAsmrTheme = value;
    _rebuildThemes();
    notifyListeners();
    final persisted = await _writePreferenceInOrder(
      _differentiateAsmrThemeKey,
      value,
    );
    if (persisted) {
      _persistedDifferentiateAsmrTheme = value;
      return true;
    }
    if (mutation != _differentiateAsmrThemeMutation) return false;
    _differentiateAsmrTheme = _persistedDifferentiateAsmrTheme;
    _rebuildThemes();
    notifyListeners();
    return false;
  }

  Future<bool> setAppThemeColor(ThemeAccentPreset value) async {
    if (_appThemeColor == value) return true;
    final mutation = ++_appThemeColorMutation;
    _appThemeColor = value;
    _rebuildThemes();
    notifyListeners();
    final persisted = await _writePreferenceInOrder(
      _appThemeColorKey,
      value.name,
    );
    if (persisted) {
      _persistedAppThemeColor = value;
      return true;
    }
    if (mutation != _appThemeColorMutation) return false;
    _appThemeColor = _persistedAppThemeColor;
    _rebuildThemes();
    notifyListeners();
    return false;
  }

  Future<bool> setAsmrThemeColor(ThemeAccentPreset value) async {
    if (_asmrThemeColor == value) return true;
    final mutation = ++_asmrThemeColorMutation;
    _asmrThemeColor = value;
    _rebuildThemes();
    notifyListeners();
    final persisted = await _writePreferenceInOrder(
      _asmrThemeColorKey,
      value.name,
    );
    if (persisted) {
      _persistedAsmrThemeColor = value;
      return true;
    }
    if (mutation != _asmrThemeColorMutation) return false;
    _asmrThemeColor = _persistedAsmrThemeColor;
    _rebuildThemes();
    notifyListeners();
    return false;
  }

  @override
  Future<void> reloadPersistedState() async {
    _loadThemeSync();
    _rebuildThemes();
    notifyListeners();
  }

  void _rebuildThemes() {
    _lightTheme = _buildTheme(_colorSchemeFor(Brightness.light));
    _darkTheme = _buildTheme(_colorSchemeFor(Brightness.dark));
  }

  ColorScheme _colorSchemeFor(Brightness brightness) => _appThemeColor
      .colorScheme(brightness)
      .copyWith(surface: _appThemeColor.bootstrapSurfaceColor(brightness));

  ThemeData _buildTheme(ColorScheme scheme) {
    final bodyText = const TextTheme().copyWith(
      bodyMedium: const TextStyle(
        fontFamily: 'Raleway',
        fontSize: 14,
        height: 1.5,
      ),
      bodyLarge: const TextStyle(
        fontFamily: 'Raleway',
        fontSize: 15,
        height: 1.5,
      ),
      labelLarge: const TextStyle(
        fontFamily: 'Raleway',
        fontSize: 12,
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
      titleMedium: const TextStyle(
        fontFamily: 'Raleway',
        fontWeight: FontWeight.w700,
        fontSize: 14,
        height: 1.25,
      ),
      titleLarge: const TextStyle(
        fontFamily: 'Outfit',
        fontWeight: FontWeight.w700,
        fontSize: 18,
      ),
      headlineMedium: const TextStyle(
        fontFamily: 'Outfit',
        fontWeight: FontWeight.w800,
        fontSize: 31,
        height: 1.05,
      ),
      headlineSmall: const TextStyle(
        fontFamily: 'Outfit',
        fontWeight: FontWeight.w800,
        fontSize: 20,
      ),
    );

    AppDesignTokens tokens = scheme.brightness == Brightness.dark
        ? AppDesignTokens.dark
        : AppDesignTokens.light;

    if (_differentiateAsmrTheme) {
      final asmrScheme = _asmrThemeColor.colorScheme(scheme.brightness);
      tokens = tokens.copyWith(
        asmrAccent: asmrScheme.primary,
        asmrContainer: asmrScheme.primaryContainer,
        onAsmrContainer: asmrScheme.onPrimaryContainer,
        onAsmrAccent: asmrScheme.onPrimary,
        asmrSurface: asmrScheme.surfaceContainerLow,
      );
    } else {
      tokens = tokens.copyWith(
        asmrAccent: scheme.primary,
        asmrContainer: scheme.primaryContainer,
        onAsmrContainer: scheme.onPrimaryContainer,
        onAsmrAccent: scheme.onPrimary,
        asmrSurface: scheme.surfaceContainerLow,
      );
    }

    const buttonShape = StadiumBorder();
    final bodyColor = Color.alphaBlend(
      scheme.onSurface.withValues(alpha: 0.88),
      scheme.surface,
    );
    final textTheme = bodyText.copyWith(
      headlineMedium: bodyText.headlineMedium?.copyWith(
        color: scheme.onSurface,
      ),
      headlineSmall: bodyText.headlineSmall?.copyWith(color: scheme.onSurface),
      titleLarge: bodyText.titleLarge?.copyWith(color: scheme.onSurface),
      titleMedium: bodyText.titleMedium?.copyWith(color: scheme.onSurface),
      bodyLarge: bodyText.bodyLarge?.copyWith(color: bodyColor),
      bodyMedium: bodyText.bodyMedium?.copyWith(color: bodyColor),
      bodySmall: bodyText.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
      labelLarge: bodyText.labelLarge?.copyWith(color: bodyColor),
      labelMedium: bodyText.labelMedium?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
      labelSmall: bodyText.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
    );

    return ThemeData(
      useMaterial3: true,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      extensions: <ThemeExtension<dynamic>>[tokens],
      visualDensity: VisualDensity.standard,
      colorScheme: scheme,
      textTheme: textTheme,
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: CenterScalePageTransitionsBuilder(),
          TargetPlatform.iOS: CenterScalePageTransitionsBuilder(),
        },
      ),
      hoverColor: scheme.primary.withValues(alpha: 0.08),
      focusColor: scheme.primary.withValues(alpha: 0.12),
      highlightColor: scheme.primary.withValues(alpha: 0.12),
      scaffoldBackgroundColor: scheme.surface,
      canvasColor: scheme.surface,
      dividerColor: scheme.outlineVariant,
      splashFactory: InkRipple.splashFactory,
      cardTheme: CardThemeData(
        color: scheme.surfaceContainerLow,
        elevation: 0,
        margin: EdgeInsets.zero,
        shadowColor: scheme.shadow.withValues(alpha: 0.08),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(tokens.radiusCard),
          side: BorderSide(
            color: scheme.outlineVariant.withValues(
              alpha: tokens.standardBorderAlpha,
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
          shape: buttonShape,
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          shape: buttonShape,
          side: BorderSide(color: scheme.outlineVariant),
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: Size(tokens.minimumTapTarget, tokens.minimumTapTarget),
          shape: buttonShape,
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
        labelStyle: textTheme.bodyMedium,
        hintStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        helperStyle: textTheme.bodySmall,
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
        toolbarHeight: AppPageHeaderMetrics.toolbarHeight,
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
          if (states.contains(WidgetState.hovered)) return 8;
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
