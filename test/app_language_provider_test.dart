import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(const <String, Object>{});

  test(
    'background transparency and boosted volume copy are localized',
    () async {
      final provider = AppLanguageProvider();
      addTearDown(provider.dispose);

      await provider.setLanguage(AppLanguage.zh);
      expect(provider.tr('background_transparency'), '背景透明度');
      expect(provider.tr('haptic_feedback_enabled'), '操作震动');
      expect(provider.tr('volume_range_hint'), '0-150');

      await provider.setLanguage(AppLanguage.ja);
      expect(provider.tr('background_transparency'), '背景透明度');
      expect(provider.tr('volume_range_hint'), '0-150');
      expect(
        provider.tr('volume_warning_message'),
        '音量ブーストはクリッピングや歪みの原因になることがあります。',
      );

      await provider.setLanguage(AppLanguage.en);
      expect(provider.tr('background_transparency'), 'Background transparency');
      expect(provider.tr('volume_range_hint'), '0-150');
      expect(provider.tr('exact_alarm_permission_title'), 'Allow exact alarms');
    },
  );

  test(
    'queue creation and other-detail labels use action-specific copy',
    () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final provider = AppLanguageProvider();
      addTearDown(provider.dispose);
      await Future<void>.delayed(Duration.zero);

      await provider.setLanguage(AppLanguage.zh);
      expect(provider.tr('add_playback_queue'), '创建播放队列');
      expect(provider.tr('audio_detail_title'), '详细信息');
      expect(provider.tr('asmr_detail_other'), '其他信息');
      expect(provider.tr('asmr_category_rating'), '评分');

      await provider.setLanguage(AppLanguage.en);
      expect(provider.tr('add_playback_queue'), 'Create playback queue');
      expect(provider.tr('audio_detail_title'), 'Details');
      expect(provider.tr('asmr_detail_other'), 'Other information');

      await provider.setLanguage(AppLanguage.ja);
      expect(provider.tr('add_playback_queue'), '再生キューを作成');
      expect(provider.tr('audio_detail_title'), '詳細情報');
      expect(provider.tr('asmr_detail_other'), 'その他の情報');
    },
  );

  test(
    'cover resolution labels use pixel values and localized original',
    () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final provider = AppLanguageProvider();
      addTearDown(provider.dispose);

      await provider.setLanguage(AppLanguage.zh);
      expect(provider.tr('cover_image_resolution_300'), '300px');
      expect(provider.tr('cover_image_resolution_600'), '600px');
      expect(provider.tr('cover_image_resolution_900'), '900px');
      expect(provider.tr('cover_image_resolution_1200'), '1200px');
      expect(provider.tr('cover_image_resolution_original'), '原画');

      await provider.setLanguage(AppLanguage.en);
      expect(provider.tr('cover_image_resolution_1200'), '1200px');
      expect(provider.tr('cover_image_resolution_original'), 'Original');

      await provider.setLanguage(AppLanguage.ja);
      expect(provider.tr('cover_image_resolution_1200'), '1200px');
      expect(provider.tr('cover_image_resolution_original'), 'オリジナル');
    },
  );

  testWidgets('interface language defaults to and persists follow system', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    tester.binding.platformDispatcher.localesTestValue = const <Locale>[
      Locale('ja'),
    ];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);

    final provider = AppLanguageProvider();
    addTearDown(provider.dispose);
    await tester.pump();

    expect(provider.preference, AppLanguagePreference.system);
    expect(provider.language, AppLanguage.ja);

    await provider.setLanguage(AppLanguage.en);
    expect(provider.preference, AppLanguagePreference.en);
    expect(provider.language, AppLanguage.en);

    await provider.setLanguagePreference(AppLanguagePreference.system);
    expect(provider.preference, AppLanguagePreference.system);
    expect(provider.language, AppLanguage.ja);
    expect(
      (await SharedPreferences.getInstance()).getString('app_language'),
      'system',
    );
  });

  testWidgets('follow system reacts to locale changes', (tester) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    tester.binding.platformDispatcher.localesTestValue = const <Locale>[
      Locale('en'),
    ];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);

    final provider = AppLanguageProvider();
    addTearDown(provider.dispose);
    await tester.pump();
    expect(provider.language, AppLanguage.en);

    tester.binding.platformDispatcher.localesTestValue = const <Locale>[
      Locale('zh'),
    ];
    await tester.pump();
    expect(provider.language, AppLanguage.zh);
  });

  testWidgets('stored explicit interface language remains compatible', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{
      'app_language': 'en',
    });
    tester.binding.platformDispatcher.localesTestValue = const <Locale>[
      Locale('ja'),
    ];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);

    final provider = AppLanguageProvider();
    addTearDown(provider.dispose);
    await tester.pump();

    expect(provider.preference, AppLanguagePreference.en);
    expect(provider.language, AppLanguage.en);
  });

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
