import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/asmr_models.dart';
import 'app_preferences.dart';
import 'app_log_service.dart';
import 'asmr_api_service.dart';

abstract class AsmrTokenStore {
  Future<String?> readToken();
  Future<void> writeToken(String token);
  Future<void> clearToken();

  Future<Map<String, String>?> readCredentials();
  Future<void> writeCredentials(String name, String password);
  Future<void> clearCredentials();
}

class SecureAsmrTokenStore implements AsmrTokenStore {
  SecureAsmrTokenStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(encryptedSharedPreferences: true),
          );

  static const String _tokenKey = 'asmr_one_jwt_token_v1';
  static const String _nameKey = 'asmr_one_name_v1';
  static const String _passKey = 'asmr_one_pass_v1';
  static const String _migratedKey = 'asmr_auth_secure_storage_migrated_v2';

  final FlutterSecureStorage _storage;

  Future<void> _ensureMigrated() async {
    final migrated = await AppPreferences.getBool(_migratedKey);
    if (migrated == true) return;

    final secureToken = await _storage.read(key: _tokenKey);
    final secureName = await _storage.read(key: _nameKey);
    final securePass = await _storage.read(key: _passKey);
    final legacyToken = await AppPreferences.getString(_tokenKey);
    final legacyName = await AppPreferences.getString(_nameKey);
    final legacyEncodedPass = await AppPreferences.getString(_passKey);

    if (secureToken == null && legacyToken?.isNotEmpty == true) {
      await _storage.write(key: _tokenKey, value: legacyToken);
    }
    final legacyPass = _decodeLegacyPassword(legacyEncodedPass);
    if (secureName == null && legacyName?.isNotEmpty == true) {
      await _storage.write(key: _nameKey, value: legacyName);
    }
    if (securePass == null && legacyPass != null) {
      await _storage.write(key: _passKey, value: legacyPass);
    }

    await _removeLegacyValue(_tokenKey);
    await _removeLegacyValue(_nameKey);
    await _removeLegacyValue(_passKey);
    if (!await AppPreferences.setBool(_migratedKey, true)) {
      throw StateError('Failed to mark ASMR credential migration complete');
    }
  }

  String? _decodeLegacyPassword(String? encodedPassword) {
    if (encodedPassword == null || encodedPassword.isEmpty) return null;
    try {
      return utf8.decode(base64.decode(encodedPassword));
    } on FormatException {
      return null;
    }
  }

  Future<void> _removeLegacyValue(String key) async {
    if (!await AppPreferences.remove(key)) {
      throw StateError('Failed to remove legacy ASMR credential: $key');
    }
  }

  @override
  Future<String?> readToken() async {
    await _ensureMigrated();
    return _storage.read(key: _tokenKey);
  }

  @override
  Future<void> writeToken(String token) async {
    await _ensureMigrated();
    await _storage.write(key: _tokenKey, value: token);
  }

  @override
  Future<void> clearToken() async {
    await _storage.delete(key: _tokenKey);
    await _removeLegacyValue(_tokenKey);
  }

  @override
  Future<Map<String, String>?> readCredentials() async {
    await _ensureMigrated();
    final name = await _storage.read(key: _nameKey);
    final pass = await _storage.read(key: _passKey);
    if (name != null && pass != null && name.isNotEmpty) {
      return {'name': name, 'password': pass};
    }
    return null;
  }

  @override
  Future<void> writeCredentials(String name, String password) async {
    await _ensureMigrated();
    await _storage.write(key: _nameKey, value: name);
    await _storage.write(key: _passKey, value: password);
  }

  @override
  Future<void> clearCredentials() async {
    await _storage.delete(key: _nameKey);
    await _storage.delete(key: _passKey);
    await _removeLegacyValue(_nameKey);
    await _removeLegacyValue(_passKey);
  }
}

class AsmrAuthService {
  AsmrAuthService({AsmrApiService? apiService, AsmrTokenStore? tokenStore})
    : _apiService = apiService ?? AsmrApiService(),
      _tokenStore = tokenStore ?? SecureAsmrTokenStore();

  final AsmrApiService _apiService;
  final AsmrTokenStore _tokenStore;

  Future<AsmrAuthSession?> restoreSession() async {
    final token = await _tokenStore.readToken();
    if (token == null || token.trim().isEmpty) {
      return null;
    }
    try {
      final session = await _apiService.checkSession(token);
      if (session == null || !session.isValid) {
        await _tokenStore.clearToken();
        return null;
      }
      if (session.token != token) {
        await _tokenStore.writeToken(session.token);
      }
      return session;
    } catch (error, stackTrace) {
      if (error is AsmrApiException &&
          error.statusCode == HttpStatus.unauthorized) {
        // Token expired. Try auto-login using saved credentials.
        final creds = await _tokenStore.readCredentials();
        if (creds != null) {
          try {
            final newSession = await _apiService.login(
              name: creds['name']!,
              password: creds['password']!,
            );
            await _tokenStore.writeToken(newSession.token);
            return newSession;
          } catch (loginError, loginStackTrace) {
            AppLogService.error(
              'asmr_auto_login_failed',
              error: loginError,
              stackTrace: loginStackTrace,
            );
            // Auto-login failed. Clear everything.
            await _tokenStore.clearToken();
            await _tokenStore.clearCredentials();
            return null;
          }
        } else {
          await _tokenStore.clearToken();
          return null;
        }
      }
      AppLogService.warning(
        'asmr_session_restore_failed_using_cached_token',
        error: error,
        stackTrace: stackTrace,
      );
      return AsmrAuthSession(token: token, userName: '');
    }
  }

  Future<AsmrAuthSession> login(String name, String password) async {
    final session = await _apiService.login(name: name, password: password);
    await _tokenStore.writeToken(session.token);
    await _tokenStore.writeCredentials(name, password);
    return session;
  }

  Future<void> logout() async {
    await _tokenStore.clearToken();
    await _tokenStore.clearCredentials();
  }
}
