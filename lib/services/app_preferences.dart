import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'app_log_service.dart';

typedef JsonValueReader<T> = T Function(Object? value);

class AppPreferences {
  static SharedPreferences? _instance;
  const AppPreferences._();

  static Future<void> init() async {
    _instance = await SharedPreferences.getInstance();
  }

  static Future<SharedPreferences> get _prefs async {
    return _instance ??= await SharedPreferences.getInstance();
  }

  static String? getStringSync(String key) => _instance?.getString(key);
  static bool? getBoolSync(String key) => _instance?.getBool(key);

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

  static Future<Map<String, Object>> exportSafeValues() async {
    final prefs = await _prefs;
    final values = <String, Object>{};
    for (final key in prefs.getKeys()) {
      if (_isSensitiveKey(key)) continue;
      final value = prefs.get(key);
      if (value is String ||
          value is bool ||
          value is int ||
          value is double ||
          value is List<String>) {
        values[key] = value as Object;
      }
    }
    return values;
  }

  static Future<void> restoreSafeValues(Map<String, Object?> values) async {
    final prefs = await _prefs;
    for (final key in prefs.getKeys()) {
      if (!_isSensitiveKey(key)) {
        await prefs.remove(key);
      }
    }
    for (final entry in values.entries) {
      if (_isSensitiveKey(entry.key)) continue;
      final value = entry.value;
      if (value is String) {
        await prefs.setString(entry.key, value);
      } else if (value is bool) {
        await prefs.setBool(entry.key, value);
      } else if (value is int) {
        await prefs.setInt(entry.key, value);
      } else if (value is double) {
        await prefs.setDouble(entry.key, value);
      } else if (value is List<dynamic>) {
        await prefs.setStringList(
          entry.key,
          value.whereType<String>().toList(growable: false),
        );
      }
    }
  }

  static bool _isSensitiveKey(String key) {
    final normalized = key.toLowerCase();
    return normalized.contains('token') ||
        normalized.contains('password') ||
        normalized.contains('passwd') ||
        normalized.contains('credential') ||
        normalized.contains('authorization') ||
        normalized == 'asmr_one_name_v1' ||
        normalized == 'asmr_one_pass_v1' ||
        normalized == 'asmr_auth_secure_storage_migrated_v2';
  }

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
