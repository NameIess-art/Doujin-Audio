import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/platform/app_icon_platform_service.dart';
import 'package:nameless_audio/features/settings/application/app_preferences.dart';
import 'package:nameless_audio/app/theme/app_design_tokens.dart';
import 'package:nameless_audio/app/theme/theme_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('defaults to system theme', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    await AppPreferences.init();

    final provider = ThemeProvider();
    expect(provider.themeMode, ThemeMode.system);
    expect(provider.appThemeColor, ThemeAccentPreset.rose);
    expect(provider.asmrThemeColor, ThemeAccentPreset.blue);
    expect(ThemeAccentPreset.values, hasLength(16));
  });

  test('theme presets convert only the light primary palette', () {
    expect(
      ThemeAccentPreset.values.map((preset) => preset.primaryColor),
      const <Color>[
        Color(0xFFFFB4A9),
        Color(0xFFFFB2BD),
        Color(0xFFEBB5ED),
        Color(0xFFD3BCFD),
        Color(0xFFBAC3FF),
        Color(0xFFA1C9FD),
        Color(0xFF8BD0F0),
        Color(0xFF83D2E4),
        Color(0xFF82D5C7),
        Color(0xFFA2D399),
        Color(0xFFB0D18B),
        Color(0xFFC3CD7B),
        Color(0xFFF0BE6D),
        Color(0xFFFFB77B),
        Color(0xFFE7BDB0),
        Color(0xFFC7C6C6),
      ],
    );
    for (final preset in ThemeAccentPreset.values) {
      final lightScheme = preset.colorScheme(Brightness.light);
      final generatedLightScheme = ColorScheme.fromSeed(
        seedColor: preset.primaryColor,
      );
      expect(lightScheme.primary, generatedLightScheme.primary);
      expect(lightScheme.primary, isNot(preset.primaryColor));

      final darkScheme = preset.colorScheme(Brightness.dark);
      expect(darkScheme.primary, preset.primaryColor);
      expect(
        _contrastRatio(darkScheme.onPrimary, darkScheme.primary),
        greaterThan(4.5),
      );
    }
  });

  test('loads and saves the current theme mode preference', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{
      'themeMode': 'dark',
    });
    await AppPreferences.init();
    final provider = ThemeProvider();

    expect(provider.themeMode, ThemeMode.dark);

    await provider.setThemeMode(ThemeMode.light);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('themeMode'), 'light');
  });

  test('theme changes synchronize the launcher icon mode', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    await AppPreferences.init();
    final appIconService = _RecordingAppIconPlatformService();
    final provider = ThemeProvider(appIconPlatformService: appIconService);
    appIconService.modes.clear();

    await provider.setThemeMode(ThemeMode.dark);

    expect(appIconService.modes, <ThemeMode>[ThemeMode.dark]);
  });

  test('light and dark themes expose the shared design tokens', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    await AppPreferences.init();
    final provider = ThemeProvider();

    final lightTokens = provider.lightTheme.extension<AppDesignTokens>();
    final darkTokens = provider.darkTheme.extension<AppDesignTokens>();

    expect(lightTokens, isNotNull);
    expect(darkTokens, isNotNull);
    expect(
      lightTokens!.asmrAccent,
      ThemeAccentPreset.blue.colorScheme(Brightness.light).primary,
    );
    expect(
      darkTokens!.asmrAccent,
      ThemeAccentPreset.blue.colorScheme(Brightness.dark).primary,
    );
    expect(
      lightTokens.onAsmrAccent,
      ThemeAccentPreset.blue.colorScheme(Brightness.light).onPrimary,
    );
    expect(lightTokens.radiusCard, darkTokens.radiusCard);
    expect(lightTokens.radiusOverlay, 24);
    expect(lightTokens.spaceXxs, 4);
    expect(lightTokens.spaceXxl, 32);
    expect(lightTokens.minimumTapTarget, 48);
    expect(lightTokens.success, isNot(darkTokens.success));
    expect(lightTokens.warning, isNot(darkTokens.warning));
  });

  test('disabled ASMR colors follow the normal app color scheme', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    await AppPreferences.init();
    final provider = ThemeProvider();

    await provider.setDifferentiateAsmrTheme(false);

    for (final theme in <ThemeData>[provider.lightTheme, provider.darkTheme]) {
      final scheme = theme.colorScheme;
      final tokens = theme.extension<AppDesignTokens>()!;
      expect(tokens.asmrAccent, scheme.primary);
      expect(tokens.onAsmrAccent, scheme.onPrimary);
      expect(tokens.asmrContainer, scheme.primaryContainer);
      expect(tokens.onAsmrContainer, scheme.onPrimaryContainer);
    }
  });

  test('loads and saves app and ASMR theme colors', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{
      'appThemeColor': 'mint',
      'asmrThemeColor': 'orange',
    });
    await AppPreferences.init();
    final provider = ThemeProvider();

    expect(provider.appThemeColor, ThemeAccentPreset.mint);
    expect(provider.asmrThemeColor, ThemeAccentPreset.orange);

    await provider.setAppThemeColor(ThemeAccentPreset.lavender);
    await provider.setAsmrThemeColor(ThemeAccentPreset.green);

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('appThemeColor'), 'lavender');
    expect(preferences.getString('asmrThemeColor'), 'green');
  });

  test('selected app color updates both brightness theme schemes', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    await AppPreferences.init();
    final provider = ThemeProvider();
    final previousLightPrimary = provider.lightTheme.colorScheme.primary;
    final previousDarkPrimary = provider.darkTheme.colorScheme.primary;

    await provider.setAppThemeColor(ThemeAccentPreset.mint);

    final expectedLight = ThemeAccentPreset.mint.colorScheme(Brightness.light);
    final expectedDark = ThemeAccentPreset.mint.colorScheme(Brightness.dark);
    expect(provider.lightTheme.colorScheme.primary, expectedLight.primary);
    expect(provider.darkTheme.colorScheme.primary, expectedDark.primary);
    expect(provider.lightTheme.colorScheme.secondary, expectedLight.secondary);
    expect(provider.lightTheme.colorScheme.tertiary, expectedLight.tertiary);
    expect(
      provider.lightTheme.colorScheme.surfaceContainer,
      expectedLight.surfaceContainer,
    );
    expect(
      provider.lightTheme.colorScheme.primary,
      isNot(previousLightPrimary),
    );
    expect(provider.darkTheme.colorScheme.primary, isNot(previousDarkPrimary));
  });

  test('selected ASMR color updates independent design tokens', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    await AppPreferences.init();
    final provider = ThemeProvider();

    await provider.setAsmrThemeColor(ThemeAccentPreset.amber);

    final expectedLight = ThemeAccentPreset.amber.colorScheme(Brightness.light);
    final expectedDark = ThemeAccentPreset.amber.colorScheme(Brightness.dark);
    expect(
      provider.lightTheme.extension<AppDesignTokens>()!.asmrAccent,
      expectedLight.primary,
    );
    expect(
      provider.darkTheme.extension<AppDesignTokens>()!.asmrAccent,
      expectedDark.primary,
    );
    expect(
      provider.lightTheme.extension<AppDesignTokens>()!.asmrSurface,
      expectedLight.surfaceContainerLow,
    );
  });

  test('overlay surfaces share the design token radius', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    await AppPreferences.init();
    final theme = ThemeProvider().darkTheme;
    final tokens = theme.extension<AppDesignTokens>()!;

    final dialogShape = theme.dialogTheme.shape! as RoundedRectangleBorder;
    final sheetShape = theme.bottomSheetTheme.shape! as RoundedRectangleBorder;
    final menuShape = theme.popupMenuTheme.shape! as RoundedRectangleBorder;

    expect(
      dialogShape.borderRadius,
      BorderRadius.circular(tokens.radiusOverlay),
    );
    expect(
      sheetShape.borderRadius,
      BorderRadius.vertical(top: Radius.circular(tokens.radiusOverlay)),
    );
    expect(menuShape.borderRadius, BorderRadius.circular(tokens.radiusCard));
  });

  test('interactive component themes keep the minimum tap target', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    await AppPreferences.init();
    final theme = ThemeProvider().lightTheme;
    final tokens = theme.extension<AppDesignTokens>()!;

    expect(
      theme.iconButtonTheme.style?.minimumSize?.resolve(<WidgetState>{}),
      Size.square(tokens.minimumTapTarget),
    );
    expect(
      theme.textButtonTheme.style?.minimumSize?.resolve(<WidgetState>{}),
      Size.square(tokens.minimumTapTarget),
    );
    expect(
      theme.inputDecorationTheme.constraints?.minHeight,
      tokens.minimumTapTarget,
    );
  });

  test('light and dark text colors keep readable visual hierarchy', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    await AppPreferences.init();
    final provider = ThemeProvider();

    for (final theme in <ThemeData>[provider.lightTheme, provider.darkTheme]) {
      final scheme = theme.colorScheme;
      final textTheme = theme.textTheme;
      final titleColor = textTheme.titleMedium!.color!;
      final bodyColor = textTheme.bodyMedium!.color!;
      final supportingColor = textTheme.bodySmall!.color!;

      expect(titleColor, scheme.onSurface);
      expect(bodyColor, isNot(titleColor));
      expect(supportingColor, scheme.onSurfaceVariant);
      expect(supportingColor, isNot(bodyColor));
      expect(titleColor, isNot(Colors.black));
      expect(titleColor, isNot(Colors.white));
      expect(
        _contrastRatio(scheme.onPrimary, scheme.primary),
        greaterThan(4.5),
      );
      expect(_contrastRatio(titleColor, scheme.surface), greaterThan(4.5));
      expect(_contrastRatio(bodyColor, scheme.surface), greaterThan(4.5));
      expect(_contrastRatio(supportingColor, scheme.surface), greaterThan(4.5));
    }
  });
}

final class _RecordingAppIconPlatformService extends AppIconPlatformService {
  _RecordingAppIconPlatformService() : super(isAndroidOverride: false);

  final List<ThemeMode> modes = <ThemeMode>[];

  @override
  Future<void> syncThemeMode(ThemeMode mode) async {
    modes.add(mode);
  }
}

double _contrastRatio(Color foreground, Color background) {
  final foregroundLuminance = foreground.computeLuminance();
  final backgroundLuminance = background.computeLuminance();
  final lighter = foregroundLuminance > backgroundLuminance
      ? foregroundLuminance
      : backgroundLuminance;
  final darker = foregroundLuminance > backgroundLuminance
      ? backgroundLuminance
      : foregroundLuminance;
  return (lighter + 0.05) / (darker + 0.05);
}
