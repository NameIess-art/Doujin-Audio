import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/logging/app_log_service.dart';
import '../../asmr/application/asmr_auth_service.dart';

typedef JsonValueReader<T> = T Function(Object? value);

class AppPreferences {
  static const onboardingCompletedKey = 'onboarding_completed_v1';
  static const asmrAccountBackupKey = '_backup_asmr_account_v1';
  static const asmrDownloadTasksKey = 'asmr_download_tasks_v1';
  static SharedPreferences? _instance;
  const AppPreferences._();

  static Future<void> init() async {
    _instance = await SharedPreferences.getInstance();
  }

  static Future<SharedPreferences> get _prefs async {
    final preferences = await SharedPreferences.getInstance();
    _instance = preferences;
    return preferences;
  }

  static String? getStringSync(String key) => _instance?.getString(key);
  static bool? getBoolSync(String key) => _instance?.getBool(key);

  static bool shouldShowOnboardingSync() {
    final prefs = _instance;
    if (prefs == null) return false;
    if (prefs.getBool(onboardingCompletedKey) == true) return false;
    final existingKeys = prefs.getKeys()..remove(onboardingCompletedKey);
    return existingKeys.isEmpty;
  }

  static Future<bool> completeOnboarding() {
    return setBool(onboardingCompletedKey, true);
  }

  static Future<String?> getString(String key) async {
    try {
      return (await _prefs).getString(key);
    } catch (error, stackTrace) {
      _logFailure('read_string', key, error, stackTrace);
      return null;
    }
  }

  static Future<List<String>?> getStringList(String key) async {
    try {
      return (await _prefs).getStringList(key);
    } catch (error, stackTrace) {
      _logFailure('read_string_list', key, error, stackTrace);
      return null;
    }
  }

  static Future<bool?> getBool(String key) async {
    try {
      return (await _prefs).getBool(key);
    } catch (error, stackTrace) {
      _logFailure('read_bool', key, error, stackTrace);
      return null;
    }
  }

  static Future<bool> setString(String key, String value) async {
    try {
      return await (await _prefs).setString(key, value);
    } catch (error, stackTrace) {
      _logFailure('write_string', key, error, stackTrace);
      return false;
    }
  }

  static Future<bool> setStringList(String key, List<String> value) async {
    try {
      return await (await _prefs).setStringList(key, value);
    } catch (error, stackTrace) {
      _logFailure('write_string_list', key, error, stackTrace);
      return false;
    }
  }

  static Future<bool> setBool(String key, bool value) async {
    try {
      return await (await _prefs).setBool(key, value);
    } catch (error, stackTrace) {
      _logFailure('write_bool', key, error, stackTrace);
      return false;
    }
  }

  static Future<bool> remove(String key) async {
    try {
      return await (await _prefs).remove(key);
    } catch (error, stackTrace) {
      _logFailure('remove', key, error, stackTrace);
      return false;
    }
  }

  static Future<Map<String, Object>> exportSafeValues({
    AsmrTokenStore? tokenStore,
  }) async {
    final prefs = await _prefs;
    final values = <String, Object>{};
    for (final key in prefs.getKeys()) {
      if (_isSensitiveKey(key) || _isBackupExcludedKey(key)) continue;
      final value = prefs.get(key);
      if (value is String ||
          value is bool ||
          value is int ||
          value is double ||
          value is List<String>) {
        values[key] = value as Object;
      }
    }

    final resolvedTokenStore = tokenStore ?? SecureAsmrTokenStore();
    final token = await resolvedTokenStore.readToken();
    final credentials = await resolvedTokenStore.readCredentials();
    if ((token != null && token.trim().isNotEmpty) || credentials != null) {
      values[asmrAccountBackupKey] = <String, Object>{
        if (token != null && token.trim().isNotEmpty) 'token': token,
        if (credentials?['name'] case final String name) 'name': name,
        if (credentials?['password'] case final String password)
          'password': password,
      };
    }

    return values;
  }

  static Future<void> restoreSafeValues(
    Map<String, Object?> values, {
    AsmrTokenStore? tokenStore,
  }) async {
    final prefs = await _prefs;
    final previousValues = <String, Object>{
      for (final key in prefs.getKeys())
        if (prefs.get(key) case final Object value) key: value,
    };
    final resolvedTokenStore = tokenStore ?? SecureAsmrTokenStore();
    final previousToken = await resolvedTokenStore.readToken();
    final previousCredentials = await resolvedTokenStore.readCredentials();
    final account = _decodeAsmrAccount(values[asmrAccountBackupKey]);

    try {
      for (final key in prefs.getKeys()) {
        if (!_isSensitiveKey(key) || _isLegacyAsmrCredentialKey(key)) {
          if (!await prefs.remove(key)) {
            throw StateError('Failed to remove preference: $key');
          }
        }
      }
      for (final entry in values.entries) {
        if (entry.key == asmrAccountBackupKey) continue;
        if (_isSensitiveKey(entry.key) || _isBackupExcludedKey(entry.key)) {
          continue;
        }
        final written = await _writeValue(prefs, entry.key, entry.value);
        if (written == false) {
          throw StateError('Failed to restore preference: ${entry.key}');
        }
      }
      await resolvedTokenStore.clearToken();
      await resolvedTokenStore.clearCredentials();
      final restoredToken = account?['token'];
      if (restoredToken != null && restoredToken.trim().isNotEmpty) {
        await resolvedTokenStore.writeToken(restoredToken);
      }
      final restoredName = account?['name'];
      final restoredPassword = account?['password'];
      if (restoredName != null &&
          restoredName.trim().isNotEmpty &&
          restoredPassword != null) {
        await resolvedTokenStore.writeCredentials(
          restoredName,
          restoredPassword,
        );
      }
    } catch (error, stackTrace) {
      await _rollbackRestore(
        prefs,
        previousValues,
        resolvedTokenStore,
        previousToken,
        previousCredentials,
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  static Map<String, String>? _decodeAsmrAccount(Object? value) {
    if (value is! Map) return null;
    final account = <String, String>{};
    for (final key in const <String>['token', 'name', 'password']) {
      final field = value[key];
      if (field is String) account[key] = field;
    }
    return account.isEmpty ? null : account;
  }

  static Future<bool?> _writeValue(
    SharedPreferences prefs,
    String key,
    Object? value,
  ) {
    if (value is String) return prefs.setString(key, value);
    if (value is bool) return prefs.setBool(key, value);
    if (value is int) return prefs.setInt(key, value);
    if (value is double) return prefs.setDouble(key, value);
    if (value is List<dynamic>) {
      return prefs.setStringList(
        key,
        value.whereType<String>().toList(growable: false),
      );
    }
    return Future<bool?>.value();
  }

  static Future<void> _rollbackRestore(
    SharedPreferences prefs,
    Map<String, Object> previousValues,
    AsmrTokenStore tokenStore,
    String? previousToken,
    Map<String, String>? previousCredentials,
  ) async {
    try {
      if (!await prefs.clear()) {
        throw StateError('Failed to clear preferences during rollback.');
      }
      for (final entry in previousValues.entries) {
        if (await _writeValue(prefs, entry.key, entry.value) != true) {
          throw StateError(
            'Failed to restore preference during rollback: ${entry.key}',
          );
        }
      }
    } catch (error, stackTrace) {
      AppLogService.error(
        'preferences_restore_values_rollback_failed',
        error: error,
        stackTrace: stackTrace,
      );
    }

    try {
      if (previousToken == null) {
        await tokenStore.clearToken();
      } else {
        await tokenStore.writeToken(previousToken);
      }
      if (previousCredentials == null) {
        await tokenStore.clearCredentials();
      } else {
        await tokenStore.writeCredentials(
          previousCredentials['name'] ?? '',
          previousCredentials['password'] ?? '',
        );
      }
    } catch (error, stackTrace) {
      AppLogService.error(
        'preferences_restore_credentials_rollback_failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  static bool _isSensitiveKey(String key) {
    final normalized = key.toLowerCase();

    return _isLegacyAsmrCredentialKey(key) ||
        normalized.contains('token') ||
        normalized.contains('password') ||
        normalized.contains('passwd') ||
        normalized.contains('credential') ||
        normalized.contains('authorization') ||
        normalized == 'asmr_auth_secure_storage_migrated_v2';
  }

  static bool _isLegacyAsmrCredentialKey(String key) {
    final normalized = key.toLowerCase();
    return normalized == 'asmr_one_name_v1' ||
        normalized == 'asmr_one_pass_v1' ||
        normalized == 'asmr_one_jwt_token_v1' ||
        normalized == 'asmr_one_token_v1';
  }

  static bool _isBackupExcludedKey(String key) =>
      key == 'session_order_v1' || key == asmrDownloadTasksKey;

  static Future<T?> readJson<T>(String key, JsonValueReader<T> reader) async {
    final raw = await getString(key);
    if (raw == null || raw.isEmpty) {
      return null;
    }

    try {
      return reader(json.decode(raw));
    } catch (error, stackTrace) {
      _logFailure('decode_json', key, error, stackTrace);
      return null;
    }
  }

  static Future<bool> writeJson(String key, Object? value) async {
    return setString(key, json.encode(value));
  }

  static void _logFailure(
    String operation,
    String key,
    Object error,
    StackTrace stackTrace,
  ) {
    AppLogService.error(
      'preferences_${operation}_failed key=$key',
      error: error,
      stackTrace: stackTrace,
    );
  }
}
