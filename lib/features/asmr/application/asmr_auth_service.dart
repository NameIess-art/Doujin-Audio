import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../domain/asmr_models.dart';
import '../../../core/logging/app_log_service.dart';
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

  final FlutterSecureStorage _storage;

  @override
  Future<String?> readToken() async {
    return _storage.read(key: _tokenKey);
  }

  @override
  Future<void> writeToken(String token) async {
    await _storage.write(key: _tokenKey, value: token);
  }

  @override
  Future<void> clearToken() async {
    await _storage.delete(key: _tokenKey);
  }

  @override
  Future<Map<String, String>?> readCredentials() async {
    final name = await _storage.read(key: _nameKey);
    final pass = await _storage.read(key: _passKey);
    if (name != null && pass != null && name.isNotEmpty) {
      return {'name': name, 'password': pass};
    }
    return null;
  }

  @override
  Future<void> writeCredentials(String name, String password) async {
    await _storage.write(key: _nameKey, value: name);
    await _storage.write(key: _passKey, value: password);
  }

  @override
  Future<void> clearCredentials() async {
    await _storage.delete(key: _nameKey);
    await _storage.delete(key: _passKey);
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
      return _restoreWithStoredCredentials();
    }
    try {
      final session = await _apiService.checkSession(token);
      if (session == null || !session.isValid) {
        await _tokenStore.clearToken();
        return _restoreWithStoredCredentials();
      }
      if (session.token != token) {
        await _tokenStore.writeToken(session.token);
      }
      return _withStoredAccountName(session);
    } catch (error, stackTrace) {
      if (AsmrApiException.isAuthenticationError(error)) {
        await _tokenStore.clearToken();
        return _restoreWithStoredCredentials(
          clearCredentialsOnAuthFailure: true,
        );
      }
      AppLogService.warning(
        'asmr_session_restore_failed_using_cached_token',
        error: error,
        stackTrace: stackTrace,
      );
      final fallbackName = await _storedAccountName();
      if (fallbackName == null) {
        return null;
      }
      return AsmrAuthSession(token: token, userName: fallbackName);
    }
  }

  Future<AsmrAuthSession?> _restoreWithStoredCredentials({
    bool clearCredentialsOnAuthFailure = false,
  }) async {
    final creds = await _tokenStore.readCredentials();
    if (creds == null) {
      return null;
    }
    try {
      final session = await _apiService.login(
        name: creds['name']!,
        password: creds['password']!,
      );
      await _tokenStore.writeToken(session.token);
      return _withStoredAccountName(session, credentials: creds);
    } catch (error, stackTrace) {
      AppLogService.error(
        'asmr_auto_login_failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (clearCredentialsOnAuthFailure &&
          AsmrApiException.isAuthenticationError(error)) {
        await _tokenStore.clearCredentials();
      }
      return null;
    }
  }

  Future<AsmrAuthSession> _withStoredAccountName(
    AsmrAuthSession session, {
    Map<String, String>? credentials,
  }) async {
    final sessionName = session.userName.trim();
    if (sessionName.isNotEmpty) {
      return AsmrAuthSession(token: session.token, userName: sessionName);
    }
    final credentialName = credentials?['name']?.trim();
    final resolvedName = credentialName != null && credentialName.isNotEmpty
        ? credentialName
        : await _storedAccountName();
    return AsmrAuthSession(token: session.token, userName: resolvedName ?? '');
  }

  Future<String?> _storedAccountName() async {
    final creds = await _tokenStore.readCredentials();
    final name = creds?['name']?.trim();
    return name == null || name.isEmpty ? null : name;
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
