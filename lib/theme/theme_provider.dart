import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/app_preferences.dart';

class ThemeProvider with ChangeNotifier {
  bool _isDarkMode = false;
  late final ThemeData _lightTheme = _buildTheme(_lightScheme);
  late final ThemeData _darkTheme = _buildTheme(_darkScheme);

  bool get isDarkMode => _isDarkMode;

  ThemeProvider() {
    _loadThemeSync();
  }

  void _loadThemeSync() {
    _isDarkMode = AppPreferences.getBoolSync('isDarkMode') ?? false;
  }

  Future<void> _loadTheme() async {
    final savedDarkMode = await AppPreferences.getBool('isDarkMode') ?? false;
    if (_isDarkMode == savedDarkMode) return;
    _isDarkMode = savedDarkMode;
    notifyListeners();
  }

  Future<void> toggleTheme(bool value) async {
    if (_isDarkMode == value) return;
    _isDarkMode = value;
    await AppPreferences.setBool('isDarkMode', value);
    notifyListeners();
  }

  static final ColorScheme _lightScheme =
      ColorScheme.fromSeed(seedColor: const Color(0xFFE05A74)).copyWith(
        primary: const Color(0xFFD94B66),
        onPrimary: Colors.white,
        secondary: const Color(0xFF526074),
        onSecondary: Colors.white,
        tertiary: const Color(0xFF7A6C93),
        onTertiary: Colors.white,
        surface: const Color(0xFFF7F4EE),
        onSurface: const Color(0xFF1A1820),
        surfaceContainerHighest: const Color(0xFFE2DBD1),
        surfaceContainerHigh: const Color(0xFFEEE8DF),
        surfaceContainer: const Color(0xFFF3EEE6),
        surfaceContainerLow: const Color(0xFFFCFAF6),
        primaryContainer: const Color(0xFFF9D7DE),
        onPrimaryContainer: const Color(0xFF521D29),
        secondaryContainer: const Color(0xFFDEE5EF),
        onSecondaryContainer: const Color(0xFF202835),
        tertiaryContainer: const Color(0xFFE6DDF4),
        onTertiaryContainer: const Color(0xFF2B213A),
        outline: const Color(0xFF8B7F78),
        outlineVariant: const Color(0xFFD8CEC3),
        shadow: const Color(0xFF211B1A),
      );

  static final ColorScheme _darkScheme =
      ColorScheme.fromSeed(
        seedColor: const Color(0xFFFF6B88),
        brightness: Brightness.dark,
      ).copyWith(
        primary: const Color(0xFFFF8CA1),
        onPrimary: const Color(0xFF35101A),
        secondary: const Color(0xFFD4D9E2),
        onSecondary: const Color(0xFF171D27),
        tertiary: const Color(0xFFD7C8F1),
        onTertiary: const Color(0xFF20182C),
        surface: const Color(0xFF121017),
        onSurface: const Color(0xFFF6F1EA),
        surfaceContainerHighest: const Color(0xFF322C37),
        surfaceContainerHigh: const Color(0xFF26212B),
        surfaceContainer: const Color(0xFF211C25),
        surfaceContainerLow: const Color(0xFF18141D),
        primaryContainer: const Color(0xFF4D2430),
        onPrimaryContainer: const Color(0xFFFFD9E0),
        secondaryContainer: const Color(0xFF2B3340),
        onSecondaryContainer: const Color(0xFFE6EBF5),
        tertiaryContainer: const Color(0xFF372B4B),
        onTertiaryContainer: const Color(0xFFF2E8FF),
        outline: const Color(0xFF7B7481),
        outlineVariant: const Color(0xFF433C47),
        shadow: Colors.black,
      );

  ThemeData _buildTheme(ColorScheme scheme) {
    final bodyText = GoogleFonts.ralewayTextTheme().copyWith(
      bodyMedium: GoogleFonts.raleway(fontSize: 14, height: 1.5),
      bodyLarge: GoogleFonts.raleway(fontSize: 15, height: 1.5),
      labelLarge: GoogleFonts.raleway(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.1,
      ),
      labelMedium: GoogleFonts.raleway(
        fontSize: 10,
        fontWeight: FontWeight.w600,
      ),
      labelSmall: GoogleFonts.raleway(
        fontSize: 9.5,
        fontWeight: FontWeight.w600,
      ),
      bodySmall: GoogleFonts.raleway(fontSize: 10, fontWeight: FontWeight.w500),
      titleMedium: GoogleFonts.raleway(
        fontWeight: FontWeight.w800,
        fontSize: 14,
        height: 1.25,
      ),
      titleLarge: GoogleFonts.lora(fontWeight: FontWeight.w800, fontSize: 18),
      headlineSmall: GoogleFonts.lora(
        fontWeight: FontWeight.w900,
        fontSize: 20,
      ),
    );

    final largeShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      textTheme: bodyText.apply(
        bodyColor: scheme.onSurface,
        displayColor: scheme.onSurface,
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.linux: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
        },
      ),
      scaffoldBackgroundColor: scheme.surface,
      canvasColor: scheme.surface,
      dividerColor: scheme.outlineVariant,
      splashFactory: InkRipple.splashFactory,
      cardTheme: CardThemeData(
        color: scheme.surfaceContainerLow,
        elevation: 0,
        margin: EdgeInsets.zero,
        shadowColor: scheme.shadow.withValues(alpha: 0.12),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.82),
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
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(44, 44),
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primaryContainer,
        foregroundColor: scheme.onPrimaryContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 72,
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
        fillColor: scheme.surfaceContainer,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
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
          borderRadius: BorderRadius.circular(28),
          side: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.5),
            width: 1,
          ),
        ),
      ),
    );
  }

  ThemeData get currentTheme {
    return _isDarkMode ? _darkTheme : _lightTheme;
  }
}
