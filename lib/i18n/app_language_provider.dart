import 'package:flutter/material.dart';

import '../services/app_preferences.dart';

import 'app_language_en.dart';
import 'app_language_ja.dart';
import 'app_language_zh.dart';

enum AppLanguage { zh, ja, en }

class AppLanguageProvider with ChangeNotifier {
  static const _prefsKey = 'app_language';

  static const supportedLocales = [Locale('zh'), Locale('ja'), Locale('en')];

  AppLanguage _language = AppLanguage.zh;

  AppLanguageProvider() {
    _loadLanguage();
  }

  AppLanguage get language => _language;

  Locale get locale {
    switch (_language) {
      case AppLanguage.zh:
        return const Locale('zh');
      case AppLanguage.ja:
        return const Locale('ja');
      case AppLanguage.en:
        return const Locale('en');
    }
  }

  String languageName(AppLanguage language) {
    switch (language) {
      case AppLanguage.zh:
        return '中文';
      case AppLanguage.ja:
        return '日本語';
      case AppLanguage.en:
        return 'English';
    }
  }

  Future<void> setLanguage(AppLanguage language) async {
    if (_language == language) return;
    _language = language;
    notifyListeners();
    await AppPreferences.setString(_prefsKey, language.name);
  }

  Future<void> _loadLanguage() async {
    final raw = await AppPreferences.getString(_prefsKey);
    final match = AppLanguage.values.where((e) => e.name == raw);
    if (match.isNotEmpty) {
      _language = match.first;
      notifyListeners();
    }
  }

  String tr(String key, [Map<String, Object?> params = const {}]) {
    final table =
        _localizedValues[_language] ?? _localizedValues[AppLanguage.zh]!;
    var value = table[key] ?? _localizedValues[AppLanguage.zh]![key] ?? key;
    params.forEach((k, v) {
      value = value.replaceAll('{$k}', '${v ?? ''}');
    });
    return value;
  }
}

const Map<AppLanguage, Map<String, String>> _localizedValues = {
  AppLanguage.zh: appLanguageZh,
  AppLanguage.ja: appLanguageJa,
  AppLanguage.en: appLanguageEn,
};
