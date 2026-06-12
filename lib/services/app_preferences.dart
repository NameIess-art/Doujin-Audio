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
