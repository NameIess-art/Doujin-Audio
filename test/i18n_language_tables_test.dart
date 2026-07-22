import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/app/localization/app_language_en.dart';
import 'package:nameless_audio/app/localization/app_language_ja.dart';
import 'package:nameless_audio/app/localization/app_language_zh.dart';

void main() {
  test('localized language tables expose the same keys as Chinese', () {
    final zhKeys = appLanguageZh.keys.toSet();

    expect(appLanguageJa.keys.toSet(), zhKeys);
    expect(appLanguageEn.keys.toSet(), zhKeys);
  });

  test('about page localization keys are present in every language', () {
    const requiredKeys = <String>[
      'about',
      'about_version',
      'about_source_code',
      'about_wiki',
      'about_wiki_open_failed',
      'about_author',
      'about_reward',
      'about_reward_open_failed',
    ];

    for (final key in requiredKeys) {
      expect(appLanguageZh[key], isNotNull, reason: 'zh:$key');
      expect(appLanguageJa[key], isNotNull, reason: 'ja:$key');
      expect(appLanguageEn[key], isNotNull, reason: 'en:$key');
    }
  });

  test(
    'download and safe error localization keys are present in every language',
    () {
      const requiredKeys = <String>[
        'asmr_download_task_not_found',
        'asmr_download_details_title',
        'asmr_download_no_files_selected',
        'refresh',
        'downloads',
        'asmr_network_failed_retry',
        'asmr_authentication_failed_retry',
        'playback_network_failed_retry',
      ];

      for (final key in requiredKeys) {
        expect(appLanguageZh[key], isNotNull, reason: 'zh:$key');
        expect(appLanguageJa[key], isNotNull, reason: 'ja:$key');
        expect(appLanguageEn[key], isNotNull, reason: 'en:$key');
      }
    },
  );
}
