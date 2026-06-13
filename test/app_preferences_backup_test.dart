import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/services/app_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'safe preference restore replaces safe values and keeps credentials',
    () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{
        'obsoleteSetting': true,
        'language': 'en',
        'asmr_one_token_v1': 'secret',
        'asmr_auth_secure_storage_migrated_v2': true,
      });
      await AppPreferences.init();

      await AppPreferences.restoreSafeValues(const <String, Object?>{
        'language': 'ja',
        'themeMode': 'system',
        'password': 'must-not-restore',
      });

      final preferences = await SharedPreferences.getInstance();
      expect(preferences.containsKey('obsoleteSetting'), isFalse);
      expect(preferences.getString('language'), 'ja');
      expect(preferences.getString('themeMode'), 'system');
      expect(preferences.getString('asmr_one_token_v1'), 'secret');
      expect(
        preferences.getBool('asmr_auth_secure_storage_migrated_v2'),
        isTrue,
      );
      expect(preferences.containsKey('password'), isFalse);
    },
  );
}
