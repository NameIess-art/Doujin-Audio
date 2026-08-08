import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/features/asmr/application/asmr_auth_service.dart';

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

  test('account backup snapshot round-trips credentials and token', () async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      _tokenKey: 'backup-token',
      _nameKey: 'backup-user',
      _passKey: 'backup-password',
    });
    final store = SecureAsmrTokenStore();

    final snapshot = await store.exportBackupSnapshot();
    await store.clearToken();
    await store.clearCredentials();
    await store.replaceFromBackup(snapshot);

    expect(await store.readToken(), 'backup-token');
    expect(await store.readCredentials(), <String, String>{
      'name': 'backup-user',
      'password': 'backup-password',
    });
    expect(snapshot.toJson()['password'], 'backup-password');
  });

  test('account backup snapshot string does not expose credentials', () {
    final snapshot = AsmrAccountBackupSnapshot(
      token: 'secret-token',
      name: 'secret-name',
      password: 'secret-password',
      createdAt: DateTime.utc(2026),
    );

    final description = snapshot.toString();
    expect(description, isNot(contains('secret-token')));
    expect(description, isNot(contains('secret-name')));
    expect(description, isNot(contains('secret-password')));
  });

  test('account backup snapshot rejects missing credential fields', () {
    expect(
      () => AsmrAccountBackupSnapshot.fromJson(<String, Object?>{
        'name': null,
        'password': null,
        'createdAt': DateTime.utc(2026, 8, 8).toIso8601String(),
      }),
      throwsFormatException,
    );
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
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (failReads) throw StateError('secure read failed');
    return null;
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (failWrites) throw StateError('secure write failed');
  }
}
