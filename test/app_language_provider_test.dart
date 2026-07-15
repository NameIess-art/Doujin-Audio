import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/app/localization/app_language_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(const <String, Object>{});

  test(
    'background transparency and boosted volume copy are localized',
    () async {
      final provider = AppLanguageProvider();

      await provider.setLanguage(AppLanguage.zh);
      expect(provider.tr('background_transparency'), '背景透明度');
      expect(provider.tr('volume_range_hint'), '0-200');

      await provider.setLanguage(AppLanguage.ja);
      expect(provider.tr('background_transparency'), '背景透明度');
      expect(
        provider.tr('volume_warning_message'),
        '音量ブーストはクリッピングや歪みの原因になることがあります',
      );

      await provider.setLanguage(AppLanguage.en);
      expect(provider.tr('background_transparency'), 'Background Transparency');
      expect(provider.tr('exact_alarm_permission_title'), 'Allow exact alarms');
    },
  );

  test('content language preference follows or overrides page language', () {
    expect(
      ContentLanguagePreference.followPage.resolve(AppLanguage.ja),
      AppLanguage.ja,
    );
    expect(
      ContentLanguagePreference.en.resolve(AppLanguage.ja),
      AppLanguage.en,
    );
    expect(
      ContentLanguagePreference.fromName('ja'),
      ContentLanguagePreference.ja,
    );
    expect(
      ContentLanguagePreference.fromName(null),
      ContentLanguagePreference.followPage,
    );
  });
}
