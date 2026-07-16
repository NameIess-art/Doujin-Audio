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

  test(
    'queue creation and other-detail labels use action-specific copy',
    () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final provider = AppLanguageProvider();
      await Future<void>.delayed(Duration.zero);

      await provider.setLanguage(AppLanguage.zh);
      expect(provider.tr('add_playback_queue'), '创建播放队列');
      expect(provider.tr('asmr_detail_other'), '其他详细');

      await provider.setLanguage(AppLanguage.en);
      expect(provider.tr('add_playback_queue'), 'Create playback queue');
      expect(provider.tr('asmr_detail_other'), 'Other details');

      await provider.setLanguage(AppLanguage.ja);
      expect(provider.tr('add_playback_queue'), '再生キューを作成');
      expect(provider.tr('asmr_detail_other'), 'その他の詳細');
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
