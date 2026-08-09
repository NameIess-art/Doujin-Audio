import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/app/localization/app_language_en.dart';
import 'package:doujin_audio/app/localization/app_language_ja.dart';
import 'package:doujin_audio/app/localization/app_language_zh.dart';

void main() {
  test('localized language tables expose the same keys as Chinese', () {
    final zhKeys = appLanguageZh.keys.toSet();

    expect(appLanguageJa.keys.toSet(), zhKeys);
    expect(appLanguageEn.keys.toSet(), zhKeys);
  });

  test('localized values preserve the placeholders used in Chinese', () {
    final placeholderPattern = RegExp(r'\{[^{}]+\}');

    List<String> placeholders(String value) {
      final matches = placeholderPattern
          .allMatches(value)
          .map((match) => match.group(0)!)
          .toList();
      return matches..sort();
    }

    for (final entry in appLanguageZh.entries) {
      final expected = placeholders(entry.value);

      expect(
        placeholders(appLanguageJa[entry.key]!),
        expected,
        reason: 'ja:${entry.key}',
      );
      expect(
        placeholders(appLanguageEn[entry.key]!),
        expected,
        reason: 'en:${entry.key}',
      );
    }
  });

  test('localized values are non-empty and have no edge whitespace', () {
    final languageTables = <String, Map<String, String>>{
      'zh': appLanguageZh,
      'ja': appLanguageJa,
      'en': appLanguageEn,
    };

    for (final language in languageTables.entries) {
      for (final entry in language.value.entries) {
        expect(entry.value, isNotEmpty, reason: '${language.key}:${entry.key}');
        expect(
          entry.value.trim(),
          entry.value,
          reason: '${language.key}:${entry.key}',
        );
      }
    }
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

  test('download conflict overwrite labels stay concise across languages', () {
    expect(appLanguageZh['asmr_download_conflict_overwrite'], '覆盖');
    expect(appLanguageJa['asmr_download_conflict_overwrite'], '上書き');
    expect(appLanguageEn['asmr_download_conflict_overwrite'], 'Overwrite');
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
