import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/asmr_models.dart';
import 'asmr_api_service.dart';

abstract class AsmrTokenStore {
  Future<String?> readToken();
  Future<void> writeToken(String token);
  Future<void> clearToken();
}

class SecureAsmrTokenStore implements AsmrTokenStore {
  SecureAsmrTokenStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const String _tokenKey = 'asmr_one_jwt_token_v1';

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
      return session;
    } catch (error) {
      if (error is AsmrApiException &&
          error.statusCode == HttpStatus.unauthorized) {
        await _tokenStore.clearToken();
        return null;
      }
      return AsmrAuthSession(token: token, userName: '');
    }
  }

  Future<AsmrAuthSession> login(String name, String password) async {
    final session = await _apiService.login(name: name, password: password);
    await _tokenStore.writeToken(session.token);
    return session;
  }

  Future<void> logout() => _tokenStore.clearToken();
}
