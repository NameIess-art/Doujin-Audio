import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/features/settings/application/app_preferences.dart';
import 'package:nameless_audio/features/asmr/application/asmr_auth_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'safe preference restore replaces safe values and clears old token',
    () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{
        'obsoleteSetting': true,
        'language': 'en',
        'session_order_v1': '["current-session"]',
        'asmr_one_token_v1': 'secret',
        'asmr_auth_secure_storage_migrated_v2': true,
      });
      await AppPreferences.init();

      await AppPreferences.restoreSafeValues(const <String, Object?>{
        'language': 'ja',
        'themeMode': 'system',
        'session_order_v1': '["backup-session"]',
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
      expect(preferences.containsKey('session_order_v1'), isFalse);
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

  test('backup excludes ASMR token and stored credentials', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{
      'language': 'zh',
      'session_order_v1': '["session-1"]',
      AppPreferences.asmrDownloadTasksKey: '{"tasks":[]}',
    });
    await AppPreferences.init();
    final values = await AppPreferences.exportSafeValues();
    final restored = _FakeTokenStore(
      token: 'current-token',
      name: 'current-name',
      password: 'current-password',
    );

    await AppPreferences.restoreSafeValues(values, tokenStore: restored);

    expect(values, isNot(contains(AppPreferences.asmrAccountBackupKey)));
    expect(values, isNot(contains('session_order_v1')));
    expect(values, isNot(contains(AppPreferences.asmrDownloadTasksKey)));
    expect(await restored.readToken(), isNull);
    expect(await restored.readCredentials(), isNull);
  });

  test('safe restore ignores account credentials from older backups', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    await AppPreferences.init();
    final store = _FakeTokenStore(
      token: 'current-token',
      name: 'current-name',
      password: 'current-password',
    );

    await AppPreferences.restoreSafeValues(const <String, Object?>{
      'language': 'ja',
      AppPreferences.asmrAccountBackupKey: <String, Object>{
        'token': 'backup-token',
        'name': 'backup-name',
        'password': 'backup-password',
      },
    }, tokenStore: store);

    expect(await store.readToken(), isNull);
    expect(await store.readCredentials(), isNull);
    expect((await SharedPreferences.getInstance()).getString('language'), 'ja');
  });

  test(
    'safe restore removes plaintext ASMR credentials from old backups',
    () async {
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

      final preferences = await SharedPreferences.getInstance();
      expect(preferences.containsKey('asmr_one_name_v1'), isFalse);
      expect(preferences.containsKey('asmr_one_pass_v1'), isFalse);
      expect(preferences.containsKey('asmr_one_jwt_token_v1'), isFalse);
      expect(await store.readToken(), isNull);
      expect(await store.readCredentials(), isNull);
    },
  );

  test('failed safe restore rolls preferences and credentials back', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{
      'language': 'en',
      'themeMode': 'dark',
      'asmr_one_pass_v1': 'plain-password',
    });
    await AppPreferences.init();
    final store = _FakeTokenStore(
      token: 'old-token',
      name: 'old-name',
      password: 'old-password',
      failNextCredentialClear: true,
    );

    await expectLater(
      AppPreferences.restoreSafeValues(const <String, Object?>{
        'language': 'zh',
        'themeMode': 'light',
      }, tokenStore: store),
      throwsStateError,
    );

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('language'), 'en');
    expect(preferences.getString('themeMode'), 'dark');
    expect(preferences.getString('asmr_one_pass_v1'), 'plain-password');
    expect(await store.readToken(), 'old-token');
    expect(await store.readCredentials(), const <String, String>{
      'name': 'old-name',
      'password': 'old-password',
    });
  });
}

class _FakeTokenStore implements AsmrTokenStore {
  _FakeTokenStore({
    this.token,
    this.name,
    this.password,
    this.failNextCredentialClear = false,
  });

  String? token;
  String? name;
  String? password;
  bool failNextCredentialClear;

  @override
  Future<void> clearCredentials() async {
    name = null;
    password = null;
    if (failNextCredentialClear) {
      failNextCredentialClear = false;
      throw StateError('credential clear failed');
    }
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
