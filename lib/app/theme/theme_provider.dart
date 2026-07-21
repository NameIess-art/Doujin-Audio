import 'dart:async';

import 'package:flutter/material.dart';

import '../../features/settings/application/app_preferences.dart';
import '../../core/platform/app_icon_platform_service.dart';
import '../../core/ui/app_icon_color_group.dart';
import '../../core/widgets/app_transitions.dart';
import 'app_design_tokens.dart';

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

  AppIconColorGroup get iconColorGroup => switch (this) {
    ThemeAccentPreset.coral ||
    ThemeAccentPreset.rose ||
    ThemeAccentPreset.pink => AppIconColorGroup.warm,
    ThemeAccentPreset.lavender ||
    ThemeAccentPreset.periwinkle => AppIconColorGroup.purple,
    ThemeAccentPreset.blue ||
    ThemeAccentPreset.sky ||
    ThemeAccentPreset.cyan => AppIconColorGroup.blue,
    ThemeAccentPreset.mint ||
    ThemeAccentPreset.green ||
    ThemeAccentPreset.lightGreen => AppIconColorGroup.green,
    ThemeAccentPreset.lime ||
    ThemeAccentPreset.amber ||
    ThemeAccentPreset.orange ||
    ThemeAccentPreset.peach => AppIconColorGroup.sunset,
    ThemeAccentPreset.gray => AppIconColorGroup.neutral,
  };

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

class ThemeProvider with ChangeNotifier {
  static const _themeModeKey = 'themeMode';
  static const _differentiateAsmrThemeKey = 'differentiateAsmrTheme';
  static const _appThemeColorKey = 'appThemeColor';
  static const _asmrThemeColorKey = 'asmrThemeColor';

  ThemeMode _themeMode = ThemeMode.system;
  bool _differentiateAsmrTheme = true;
  ThemeAccentPreset _appThemeColor = ThemeAccentPreset.rose;
  ThemeAccentPreset _asmrThemeColor = ThemeAccentPreset.blue;
  late ThemeData _lightTheme;
  late ThemeData _darkTheme;

  ThemeMode get themeMode => _themeMode;
  bool get differentiateAsmrTheme => _differentiateAsmrTheme;
  ThemeAccentPreset get appThemeColor => _appThemeColor;
  ThemeAccentPreset get asmrThemeColor => _asmrThemeColor;
  ThemeData get lightTheme => _lightTheme;
  ThemeData get darkTheme => _darkTheme;

  ThemeProvider({AppIconPlatformService? appIconPlatformService})
    : _appIconPlatformService =
          appIconPlatformService ?? AppIconPlatformService() {
    _loadThemeSync();
    _rebuildThemes();
    unawaited(_syncAppIconTheme());
  }

  final AppIconPlatformService _appIconPlatformService;

  void _loadThemeSync() {
    final storedMode = AppPreferences.getStringSync(_themeModeKey);
    _themeMode = ThemeMode.values.firstWhere(
      (mode) => mode.name == storedMode,
      orElse: () => ThemeMode.system,
    );
    _differentiateAsmrTheme =
        AppPreferences.getBoolSync(_differentiateAsmrThemeKey) ?? true;
    _appThemeColor = _readThemeColor(
      AppPreferences.getStringSync(_appThemeColorKey),
      ThemeAccentPreset.rose,
    );
    _asmrThemeColor = _readThemeColor(
      AppPreferences.getStringSync(_asmrThemeColorKey),
      ThemeAccentPreset.blue,
    );
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

  Future<void> setThemeMode(ThemeMode value) async {
    if (_themeMode == value) return;
    _themeMode = value;
    notifyListeners();
    await AppPreferences.setString(_themeModeKey, value.name);
    await _syncAppIconTheme();
  }

  Future<void> _syncAppIconTheme() {
    return _appIconPlatformService.syncThemeMode(
      _themeMode,
      _appThemeColor.iconColorGroup,
    );
  }

  Future<void> setDifferentiateAsmrTheme(bool value) async {
    if (_differentiateAsmrTheme == value) return;
    _differentiateAsmrTheme = value;
    _rebuildThemes();
    notifyListeners();
    await AppPreferences.setBool(_differentiateAsmrThemeKey, value);
  }

  Future<void> setAppThemeColor(ThemeAccentPreset value) async {
    if (_appThemeColor == value) return;
    _appThemeColor = value;
    _rebuildThemes();
    notifyListeners();
    await AppPreferences.setString(_appThemeColorKey, value.name);
    await _syncAppIconTheme();
  }

  Future<void> setAsmrThemeColor(ThemeAccentPreset value) async {
    if (_asmrThemeColor == value) return;
    _asmrThemeColor = value;
    _rebuildThemes();
    notifyListeners();
    await AppPreferences.setString(_asmrThemeColorKey, value.name);
  }

  void _rebuildThemes() {
    _lightTheme = _buildTheme(_appThemeColor.colorScheme(Brightness.light));
    _darkTheme = _buildTheme(_appThemeColor.colorScheme(Brightness.dark));
  }

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

    final largeShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(tokens.radiusSection),
    );
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
      extensions: <ThemeExtension<dynamic>>[
        tokens,
        AppBrandIconTheme.forGroup(
          _appThemeColor.iconColorGroup,
          scheme.brightness,
        ),
      ],
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
        radius: const Radius.circular(8),
      ),
    );
  }
}

final class ThemeState {
  const ThemeState({
    required this.themeMode,
    required this.differentiateAsmrTheme,
    required this.appThemeColor,
    required this.asmrThemeColor,
    required this.lightTheme,
    required this.darkTheme,
  });

  factory ThemeState.from(ThemeProvider provider) {
    return ThemeState(
      themeMode: provider.themeMode,
      differentiateAsmrTheme: provider.differentiateAsmrTheme,
      appThemeColor: provider.appThemeColor,
      asmrThemeColor: provider.asmrThemeColor,
      lightTheme: provider.lightTheme,
      darkTheme: provider.darkTheme,
    );
  }

  final ThemeMode themeMode;
  final bool differentiateAsmrTheme;
  final ThemeAccentPreset appThemeColor;
  final ThemeAccentPreset asmrThemeColor;
  final ThemeData lightTheme;
  final ThemeData darkTheme;

  @override
  bool operator ==(Object other) {
    return other is ThemeState &&
        other.themeMode == themeMode &&
        other.differentiateAsmrTheme == differentiateAsmrTheme &&
        other.appThemeColor == appThemeColor &&
        other.asmrThemeColor == asmrThemeColor &&
        identical(other.lightTheme, lightTheme) &&
        identical(other.darkTheme, darkTheme);
  }

  @override
  int get hashCode => Object.hash(
    themeMode,
    differentiateAsmrTheme,
    appThemeColor,
    asmrThemeColor,
    identityHashCode(lightTheme),
    identityHashCode(darkTheme),
  );
}
