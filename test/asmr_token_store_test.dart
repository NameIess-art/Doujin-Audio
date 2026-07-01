import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/services/asmr_auth_service.dart';

const _tokenKey = 'asmr_one_jwt_token_v1';
const _nameKey = 'asmr_one_name_v1';
const _passKey = 'asmr_one_pass_v1';

void main() {
  test('reads existing ASMR values from secure storage', () async {
    final secureValues = <String, String>{
      _tokenKey: 'secure-token',
      _nameKey: 'secure-user',
      _passKey: 'secure-password',
    };
    FlutterSecureStorage.setMockInitialValues(secureValues);

    final store = SecureAsmrTokenStore();

    expect(await store.readToken(), 'secure-token');
    expect(await store.readCredentials(), <String, String>{
      'name': 'secure-user',
      'password': 'secure-password',
    });
  });

  test('writes and restores ASMR values only from secure storage', () async {
    final secureValues = <String, String>{};
    FlutterSecureStorage.setMockInitialValues(secureValues);
    final store = SecureAsmrTokenStore();

    await store.writeToken('new-token');
    await store.writeCredentials('new-user', 'new-password');

    expect(await store.readToken(), 'new-token');
    expect(await store.readCredentials(), <String, String>{
      'name': 'new-user',
      'password': 'new-password',
    });
  });

  test('logout cleanup removes secure ASMR values', () async {
    final secureValues = <String, String>{
      _tokenKey: 'secure-token',
      _nameKey: 'secure-user',
      _passKey: 'secure-password',
    };
    FlutterSecureStorage.setMockInitialValues(secureValues);
    final store = SecureAsmrTokenStore();

    await store.clearToken();
    await store.clearCredentials();

    expect(secureValues, isEmpty);
  });

  test('secure storage write failure is surfaced', () async {
    final store = SecureAsmrTokenStore(
      storage: _ThrowingSecureStorage(failWrites: true),
    );

    await expectLater(store.writeToken('token'), throwsA(isA<StateError>()));
  });

  test('secure storage read failure is surfaced', () async {
    final store = SecureAsmrTokenStore(
      storage: _ThrowingSecureStorage(failReads: true),
    );

    await expectLater(store.readToken(), throwsA(isA<StateError>()));
  });
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
