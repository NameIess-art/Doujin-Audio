import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/services/app_preferences.dart';
import 'package:nameless_audio/services/asmr_auth_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'safe preference restore replaces safe values and clears old token',
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
      }, tokenStore: _FakeTokenStore(token: 'secure-secret'));

      final preferences = await SharedPreferences.getInstance();
      expect(preferences.containsKey('obsoleteSetting'), isFalse);
      expect(preferences.getString('language'), 'ja');
      expect(preferences.getString('themeMode'), 'system');
      expect(preferences.containsKey('asmr_one_token_v1'), isFalse);
      expect(preferences.containsKey('asmr_one_jwt_token_v1'), isFalse);
      expect(
        preferences.getBool('asmr_auth_secure_storage_migrated_v2'),
        isTrue,
      );
      expect(preferences.containsKey('password'), isFalse);
    },
  );

  test(
    'safe restore clears secure ASMR credentials absent from backup',
    () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      await AppPreferences.init();
      final store = _FakeTokenStore(
        token: 'old-token',
        name: 'old-name',
        password: 'old-password',
      );

      await AppPreferences.restoreSafeValues(const <String, Object?>{
        'language': 'zh',
      }, tokenStore: store);

      expect(await store.readToken(), isNull);
      expect(await store.readCredentials(), isNull);
    },
  );

  test('safe restore replaces secure ASMR credentials', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    await AppPreferences.init();
    final store = _FakeTokenStore(
      token: 'old-token',
      name: 'old-name',
      password: 'old-password',
    );

    await AppPreferences.restoreSafeValues(const <String, Object?>{
      'asmr_one_name_v1': 'new-name',
      'asmr_one_pass_v1': 'new-password',
      'asmr_one_jwt_token_v1': 'new-token',
    }, tokenStore: store);

    expect(await store.readToken(), 'new-token');
    expect(await store.readCredentials(), <String, String>{
      'name': 'new-name',
      'password': 'new-password',
    });
  });
}

class _FakeTokenStore implements AsmrTokenStore {
  _FakeTokenStore({this.token, this.name, this.password});

  String? token;
  String? name;
  String? password;

  @override
  Future<void> clearCredentials() async {
    name = null;
    password = null;
  }

  @override
  Future<void> clearToken() async => token = null;

  @override
  Future<Map<String, String>?> readCredentials() async {
    if (name == null || password == null) return null;
    return <String, String>{'name': name!, 'password': password!};
  }

  @override
  Future<String?> readToken() async => token;

  @override
  Future<void> writeCredentials(String name, String password) async {
    this.name = name;
    this.password = password;
  }

  @override
  Future<void> writeToken(String token) async => this.token = token;
}
