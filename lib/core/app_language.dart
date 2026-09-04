enum AppLanguage { zh, ja, en }

abstract interface class AppTextTranslator {
  String tr(String key, [Map<String, Object?> params = const {}]);
}

enum ContentLanguagePreference {
  followPage,
  zh,
  ja,
  en;

  AppLanguage resolve(AppLanguage pageLanguage) => switch (this) {
    ContentLanguagePreference.followPage => pageLanguage,
    ContentLanguagePreference.zh => AppLanguage.zh,
    ContentLanguagePreference.ja => AppLanguage.ja,
    ContentLanguagePreference.en => AppLanguage.en,
  };

  AppLanguage? get explicitLanguage => switch (this) {
    ContentLanguagePreference.followPage => null,
    ContentLanguagePreference.zh => AppLanguage.zh,
    ContentLanguagePreference.ja => AppLanguage.ja,
    ContentLanguagePreference.en => AppLanguage.en,
  };

  static ContentLanguagePreference fromName(Object? value) {
    if (value is String) {
      for (final preference in ContentLanguagePreference.values) {
        if (preference.name == value) return preference;
      }
    }
    return ContentLanguagePreference.followPage;
  }

  static ContentLanguagePreference fromAppLanguage(AppLanguage language) =>
      switch (language) {
        AppLanguage.zh => ContentLanguagePreference.zh,
        AppLanguage.ja => ContentLanguagePreference.ja,
        AppLanguage.en => ContentLanguagePreference.en,
      };
}
