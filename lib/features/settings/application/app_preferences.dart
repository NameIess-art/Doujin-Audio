import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/logging/app_log_service.dart';

typedef JsonValueReader<T> = T Function(Object? value);

class AppPreferences {
  static const onboardingCompletedKey = 'onboarding_completed_v1';
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

  static Future<Map<String, Object>> snapshot({
    Set<String> excludedKeys = const <String>{},
  }) async {
    final preferences = await _prefs;
    final result = <String, Object>{};
    for (final key in preferences.getKeys()) {
      if (excludedKeys.contains(key)) continue;
      final value = preferences.get(key);
      if (value is String || value is bool || value is int || value is double) {
        result[key] = value!;
      } else if (value is List<String>) {
        result[key] = List<String>.of(value);
      }
    }
    return result;
  }

  static Future<void> replaceSnapshot(Map<String, Object?> snapshot) async {
    final preferences = await _prefs;
    final normalized = <String, Object>{};
    for (final entry in snapshot.entries) {
      final value = entry.value;
      if (value is String || value is bool || value is int || value is double) {
        normalized[entry.key] = value!;
      } else if (value is List && value.every((item) => item is String)) {
        normalized[entry.key] = value.cast<String>();
      } else {
        throw const FormatException('unsupported_preferences_value');
      }
    }

    if (!await preferences.clear()) {
      throw StateError('preferences_clear_failed');
    }
    for (final entry in normalized.entries) {
      final value = entry.value;
      final saved = switch (value) {
        String value => preferences.setString(entry.key, value),
        bool value => preferences.setBool(entry.key, value),
        int value => preferences.setInt(entry.key, value),
        double value => preferences.setDouble(entry.key, value),
        List<String> value => preferences.setStringList(entry.key, value),
        _ => Future<bool>.value(false),
      };
      if (!await saved) throw StateError('preferences_write_failed');
    }
    _instance = preferences;
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
