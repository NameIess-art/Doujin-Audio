import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/i18n/app_language_en.dart';
import 'package:nameless_audio/i18n/app_language_ja.dart';
import 'package:nameless_audio/i18n/app_language_zh.dart';

void main() {
  test('localized language tables expose the same keys as Chinese', () {
    final zhKeys = appLanguageZh.keys.toSet();

    expect(appLanguageJa.keys.toSet(), zhKeys);
    expect(appLanguageEn.keys.toSet(), zhKeys);
  });
}
