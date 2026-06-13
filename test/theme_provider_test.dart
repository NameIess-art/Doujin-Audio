import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/services/app_preferences.dart';
import 'package:nameless_audio/theme/theme_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('defaults to system theme', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    await AppPreferences.init();

    expect(ThemeProvider().themeMode, ThemeMode.system);
  });

  test('migrates the legacy dark mode preference', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{
      'isDarkMode': true,
    });
    await AppPreferences.init();
    final provider = ThemeProvider();

    expect(provider.themeMode, ThemeMode.dark);

    await provider.setThemeMode(ThemeMode.light);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('themeMode'), 'light');
    expect(preferences.containsKey('isDarkMode'), isFalse);
  });
}
