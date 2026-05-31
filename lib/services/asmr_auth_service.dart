import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/asmr_models.dart';
import 'app_preferences.dart';
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
    : _storage = storage ?? const FlutterSecureStorage(
        aOptions: AndroidOptions(encryptedSharedPreferences: true),
      );

  static const String _tokenKey = 'asmr_one_jwt_token_v1';
  static const String _nameKey = 'asmr_one_name_v1';
  static const String _passKey = 'asmr_one_pass_v1';
  static const String _migratedKey = 'asmr_auth_migrated_v1';

  final FlutterSecureStorage _storage;

  Future<void> _ensureMigrated() async {
    final migrated = await AppPreferences.getBool(_migratedKey);
    if (migrated == true) return;

    try {
      final token = await _storage.read(key: _tokenKey);
      final name = await _storage.read(key: _nameKey);
      final pass = await _storage.read(key: _passKey);

      if (token != null && token.isNotEmpty) {
        await AppPreferences.setString(_tokenKey, token);
      }
      if (name != null && pass != null && name.isNotEmpty) {
        await AppPreferences.setString(_nameKey, name);
        // Basic obfuscation so it's not plain text in the XML
        final encodedPass = base64.encode(utf8.encode(pass));
        await AppPreferences.setString(_passKey, encodedPass);
      }
    } catch (_) {}

    await AppPreferences.setBool(_migratedKey, true);
  }

  @override
  Future<String?> readToken() async {
    await _ensureMigrated();
    return AppPreferences.getString(_tokenKey);
  }

  @override
  Future<void> writeToken(String token) async {
    await _ensureMigrated();
    await AppPreferences.setString(_tokenKey, token);
  }

  @override
  Future<void> clearToken() async {
    await _ensureMigrated();
    await AppPreferences.remove(_tokenKey);
  }

  @override
  Future<Map<String, String>?> readCredentials() async {
    await _ensureMigrated();
    final name = await AppPreferences.getString(_nameKey);
    final encodedPass = await AppPreferences.getString(_passKey);
    if (name != null && encodedPass != null && name.isNotEmpty) {
      try {
        final pass = utf8.decode(base64.decode(encodedPass));
        return {'name': name, 'password': pass};
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  @override
  Future<void> writeCredentials(String name, String password) async {
    await _ensureMigrated();
    await AppPreferences.setString(_nameKey, name);
    final encodedPass = base64.encode(utf8.encode(password));
    await AppPreferences.setString(_passKey, encodedPass);
  }

  @override
  Future<void> clearCredentials() async {
    await _ensureMigrated();
    await AppPreferences.remove(_nameKey);
    await AppPreferences.remove(_passKey);
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
    } catch (error) {
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
          } catch (loginError) {
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
