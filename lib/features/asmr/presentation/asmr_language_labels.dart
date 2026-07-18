import '../../../core/app_language.dart';

String asmrLanguageLabelKey(ContentLanguagePreference preference) {
  return switch (preference) {
    ContentLanguagePreference.followPage => 'follow_interface_language',
    ContentLanguagePreference.zh => 'asmr_language_zh',
    ContentLanguagePreference.ja => 'asmr_language_ja',
    ContentLanguagePreference.en => 'asmr_language_en',
  };
}
