import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/services/app_preferences.dart';
import 'package:nameless_audio/services/asmr_auth_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _tokenKey = 'asmr_one_jwt_token_v1';
const _nameKey = 'asmr_one_name_v1';
const _passKey = 'asmr_one_pass_v1';
const _migratedKey = 'asmr_auth_secure_storage_migrated_v2';

void main() {
  Future<void> resetPreferences([Map<String, Object> values = const {}]) async {
    SharedPreferences.setMockInitialValues(values);
    await AppPreferences.init();
  }

  test('migrates legacy ASMR credentials into secure storage', () async {
    final secureValues = <String, String>{};
    FlutterSecureStorage.setMockInitialValues(secureValues);
    await resetPreferences(<String, Object>{
      _tokenKey: 'legacy-token',
      _nameKey: 'legacy-user',
      _passKey: base64.encode(utf8.encode('legacy-password')),
    });
    final store = SecureAsmrTokenStore();

    expect(await store.readToken(), 'legacy-token');
    expect(await store.readCredentials(), <String, String>{
      'name': 'legacy-user',
      'password': 'legacy-password',
    });
    expect(secureValues, <String, String>{
      _tokenKey: 'legacy-token',
      _nameKey: 'legacy-user',
      _passKey: 'legacy-password',
    });
    expect(await AppPreferences.getString(_tokenKey), isNull);
    expect(await AppPreferences.getString(_nameKey), isNull);
    expect(await AppPreferences.getString(_passKey), isNull);
    expect(await AppPreferences.getBool(_migratedKey), isTrue);
  });

  test(
    'existing secure ASMR values are never overwritten by migration',
    () async {
      final secureValues = <String, String>{
        _tokenKey: 'secure-token',
        _nameKey: 'secure-user',
        _passKey: 'secure-password',
      };
      FlutterSecureStorage.setMockInitialValues(secureValues);
      await resetPreferences(<String, Object>{
        _tokenKey: 'legacy-token',
        _nameKey: 'legacy-user',
        _passKey: base64.encode(utf8.encode('legacy-password')),
      });

      final store = SecureAsmrTokenStore();

      expect(await store.readToken(), 'secure-token');
      expect(await store.readCredentials(), <String, String>{
        'name': 'secure-user',
        'password': 'secure-password',
      });
      expect(secureValues[_tokenKey], 'secure-token');
      expect(secureValues[_nameKey], 'secure-user');
      expect(secureValues[_passKey], 'secure-password');
    },
  );

  test('writes and restores ASMR values only from secure storage', () async {
    final secureValues = <String, String>{};
    FlutterSecureStorage.setMockInitialValues(secureValues);
    await resetPreferences();
    final store = SecureAsmrTokenStore();

    await store.writeToken('new-token');
    await store.writeCredentials('new-user', 'new-password');

    expect(await store.readToken(), 'new-token');
    expect(await store.readCredentials(), <String, String>{
      'name': 'new-user',
      'password': 'new-password',
    });
    expect(await AppPreferences.getString(_tokenKey), isNull);
    expect(await AppPreferences.getString(_nameKey), isNull);
    expect(await AppPreferences.getString(_passKey), isNull);
  });

  test('logout cleanup removes secure and legacy ASMR values', () async {
    final secureValues = <String, String>{
      _tokenKey: 'secure-token',
      _nameKey: 'secure-user',
      _passKey: 'secure-password',
    };
    FlutterSecureStorage.setMockInitialValues(secureValues);
    await resetPreferences(<String, Object>{
      _tokenKey: 'legacy-token',
      _nameKey: 'legacy-user',
      _passKey: base64.encode(utf8.encode('legacy-password')),
    });
    final store = SecureAsmrTokenStore();

    await store.clearToken();
    await store.clearCredentials();

    expect(secureValues, isEmpty);
    expect(await AppPreferences.getString(_tokenKey), isNull);
    expect(await AppPreferences.getString(_nameKey), isNull);
    expect(await AppPreferences.getString(_passKey), isNull);
  });

  test('secure storage migration failure keeps legacy ASMR values', () async {
    await resetPreferences(<String, Object>{
      _tokenKey: 'legacy-token',
      _nameKey: 'legacy-user',
      _passKey: base64.encode(utf8.encode('legacy-password')),
    });
    final store = SecureAsmrTokenStore(
      storage: _ThrowingSecureStorage(failWrites: true),
    );

    await expectLater(store.readToken(), throwsA(isA<StateError>()));

    expect(await AppPreferences.getString(_tokenKey), 'legacy-token');
    expect(await AppPreferences.getString(_nameKey), 'legacy-user');
    expect(await AppPreferences.getString(_passKey), isNotNull);
    expect(await AppPreferences.getBool(_migratedKey), isNull);
  });

  test(
    'secure storage read failure does not mark migration complete',
    () async {
      await resetPreferences(<String, Object>{_tokenKey: 'legacy-token'});
      final store = SecureAsmrTokenStore(
        storage: _ThrowingSecureStorage(failReads: true),
      );

      await expectLater(store.readToken(), throwsA(isA<StateError>()));

      expect(await AppPreferences.getString(_tokenKey), 'legacy-token');
      expect(await AppPreferences.getBool(_migratedKey), isNull);
    },
  );
}

class _ThrowingSecureStorage extends FlutterSecureStorage {
  _ThrowingSecureStorage({this.failReads = false, this.failWrites = false});

  final bool failReads;
  final bool failWrites;

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (failReads) throw StateError('secure read failed');
    return null;
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (failWrites) throw StateError('secure write failed');
  }
}
