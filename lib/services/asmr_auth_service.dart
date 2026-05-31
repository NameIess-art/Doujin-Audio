import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/asmr_models.dart';
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

  final FlutterSecureStorage _storage;

  @override
  Future<String?> readToken() async {
    try {
      return await _storage.read(key: _tokenKey);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> writeToken(String token) async {
    try {
      await _storage.write(key: _tokenKey, value: token);
    } catch (_) {
      // Secure storage can be unavailable in tests or unsupported shells.
    }
  }

  @override
  Future<void> clearToken() async {
    try {
      await _storage.delete(key: _tokenKey);
    } catch (_) {
      // See writeToken.
    }
  }

  @override
  Future<Map<String, String>?> readCredentials() async {
    try {
      final name = await _storage.read(key: _nameKey);
      final pass = await _storage.read(key: _passKey);
      if (name != null && pass != null && name.isNotEmpty) {
        return {'name': name, 'password': pass};
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> writeCredentials(String name, String password) async {
    try {
      await _storage.write(key: _nameKey, value: name);
      await _storage.write(key: _passKey, value: password);
    } catch (_) {}
  }

  @override
  Future<void> clearCredentials() async {
    try {
      await _storage.delete(key: _nameKey);
      await _storage.delete(key: _passKey);
    } catch (_) {}
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
