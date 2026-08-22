import 'package:flutter/material.dart';

import '../application/persisted_state_reloader.dart';
import '../../core/app_language.dart';
import '../../features/settings/application/app_preferences.dart';

import 'app_language_en.dart';
import 'app_language_ja.dart';
import 'app_language_zh.dart';

export '../../core/app_language.dart';

enum AppLanguagePreference {
  system,
  zh,
  ja,
  en;

  AppLanguage? get explicitLanguage => switch (this) {
    AppLanguagePreference.system => null,
    AppLanguagePreference.zh => AppLanguage.zh,
    AppLanguagePreference.ja => AppLanguage.ja,
    AppLanguagePreference.en => AppLanguage.en,
  };

  static AppLanguagePreference fromLanguage(AppLanguage language) =>
      switch (language) {
        AppLanguage.zh => AppLanguagePreference.zh,
        AppLanguage.ja => AppLanguagePreference.ja,
        AppLanguage.en => AppLanguagePreference.en,
      };
}

@immutable
class AppLanguageState {
  const AppLanguageState({required this.preference, required this.language});

  factory AppLanguageState.from(AppLanguageProvider provider) {
    return AppLanguageState(
      preference: provider.preference,
      language: provider.language,
    );
  }

  final AppLanguagePreference preference;
  final AppLanguage language;

  Locale get locale => switch (language) {
    AppLanguage.zh => const Locale('zh'),
    AppLanguage.ja => const Locale('ja'),
    AppLanguage.en => const Locale('en'),
  };

  @override
  bool operator ==(Object other) =>
      other is AppLanguageState &&
      other.preference == preference &&
      other.language == language;

  @override
  int get hashCode => Object.hash(preference, language);
}

class AppLanguageProvider
    with ChangeNotifier, WidgetsBindingObserver
    implements PersistedStateReloader {
  static const _prefsKey = 'app_language';

  static const supportedLocales = [Locale('zh'), Locale('ja'), Locale('en')];

  AppLanguagePreference _preference = AppLanguagePreference.system;
  late AppLanguage _language;
  int _preferenceRevision = 0;
  bool _disposed = false;
  late Future<void> _loadFuture;

  AppLanguageProvider() {
    _language = _resolveSystemLanguage();
    WidgetsBinding.instance.addObserver(this);
    _loadFuture = _loadLanguage();
  }

  AppLanguagePreference get preference => _preference;

  AppLanguage get language => _language;

  Future<void> get initialized => _loadFuture;

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
    await setLanguagePreference(AppLanguagePreference.fromLanguage(language));
  }

  Future<void> setLanguagePreference(AppLanguagePreference preference) async {
    final language = preference.explicitLanguage ?? _resolveSystemLanguage();
    _preferenceRevision++;
    if (_preference != preference || _language != language) {
      _preference = preference;
      _language = language;
      notifyListeners();
    }
    await AppPreferences.setString(_prefsKey, preference.name);
  }

  @override
  Future<void> reloadPersistedState() async {
    _preferenceRevision++;
    _loadFuture = _loadLanguage();
    await _loadFuture;
  }

  Future<void> _loadLanguage() async {
    final revision = _preferenceRevision;
    final raw = await AppPreferences.getString(_prefsKey);
    if (_disposed || revision != _preferenceRevision) return;
    final preference = AppLanguagePreference.values.firstWhere(
      (value) => value.name == raw,
      orElse: () => AppLanguagePreference.system,
    );
    final language = preference.explicitLanguage ?? _resolveSystemLanguage();
    if (_preference == preference && _language == language) return;
    _preference = preference;
    _language = language;
    notifyListeners();
  }

  @override
  void didChangeLocales(List<Locale>? locales) {
    if (_disposed || _preference != AppLanguagePreference.system) return;
    final language = _resolveSystemLanguage(locales);
    if (_language == language) return;
    _language = language;
    notifyListeners();
  }

  AppLanguage _resolveSystemLanguage([List<Locale>? locales]) {
    final systemLocales =
        locales ?? WidgetsBinding.instance.platformDispatcher.locales;
    for (final locale in systemLocales) {
      switch (locale.languageCode.toLowerCase()) {
        case 'zh':
          return AppLanguage.zh;
        case 'ja':
          return AppLanguage.ja;
        case 'en':
          return AppLanguage.en;
      }
    }
    return AppLanguage.zh;
  }

  @override
  void dispose() {
    _disposed = true;
    _preferenceRevision++;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
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
