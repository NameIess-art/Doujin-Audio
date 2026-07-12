import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/services/app_preferences.dart';
import 'package:nameless_audio/theme/app_design_tokens.dart';
import 'package:nameless_audio/theme/theme_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('defaults to system theme', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    await AppPreferences.init();

    expect(ThemeProvider().themeMode, ThemeMode.system);
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

  test('light and dark themes expose the shared design tokens', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    await AppPreferences.init();
    final provider = ThemeProvider();

    final lightTokens = provider.lightTheme.extension<AppDesignTokens>();
    final darkTokens = provider.darkTheme.extension<AppDesignTokens>();

    expect(lightTokens, isNotNull);
    expect(darkTokens, isNotNull);
    expect(lightTokens!.asmrAccent, const Color(0xFF1D4ED8));
    expect(darkTokens!.asmrAccent, const Color(0xFF60A5FA));
    expect(lightTokens.radiusCard, darkTokens.radiusCard);
    expect(lightTokens.radiusOverlay, 24);
    expect(lightTokens.spaceXxs, 4);
    expect(lightTokens.spaceXxl, 32);
    expect(lightTokens.minimumTapTarget, 48);
    expect(lightTokens.success, isNot(darkTokens.success));
    expect(lightTokens.warning, isNot(darkTokens.warning));
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
}
