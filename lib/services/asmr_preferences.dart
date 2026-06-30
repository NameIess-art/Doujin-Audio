import 'dart:io';
import '../models/asmr_models.dart';
import 'app_database.dart';
import 'app_preferences.dart';

abstract final class AsmrPreferences {
  static const String _favoriteWorksKey = 'asmr_favorite_works_v1';
  static const String _historyWorksKey = 'asmr_history_works_v1';
  static const String _syncOpsKey = 'asmr_sync_ops_v1';
  static const String _lastSyncAtKey = 'asmr_last_sync_at_v1';
  static const String _visibleCategoriesKey = 'asmr_visible_categories_v1';
  static const String _contentLanguageKey = 'asmr_content_language_v1';

  static AppDatabase get _database {
    AppDatabase.initializeForPlatform();
    return AppDatabase.instance;
  }

  static Future<void> clearForTest() async {
    final db = await _database.database;
    final batch = db.batch();
    batch.delete('asmr_sync_operations');
    batch.delete('asmr_visible_categories');
    batch.delete('asmr_work_lists');
    batch.delete('asmr_work_tags');
    batch.delete('asmr_work_voice_actors');
    batch.delete('asmr_works');
    for (final key in [_contentLanguageKey, _lastSyncAtKey]) {
      batch.delete('app_kv_settings', where: 'key = ?', whereArgs: [key]);
    }
    await batch.commit(noResult: true);
  }

  static Future<List<AsmrCategoryType>> loadVisibleCategories() async {
    final db = _database;
    final stored = await db.loadAsmrVisibleCategoryNames();
    if (stored.isNotEmpty) return _sanitizeCategories(stored);
    final legacy = await AppPreferences.getStringList(_visibleCategoriesKey);
    final migrated = _sanitizeCategories(legacy);
    if (legacy != null && legacy.isNotEmpty) {
      await saveVisibleCategories(migrated);
      await AppPreferences.remove(_visibleCategoriesKey);
    }
    return migrated;
  }

  static Future<void> saveVisibleCategories(
    List<AsmrCategoryType> categories,
  ) async {
    await _database.saveAsmrVisibleCategoryNames(
      _sanitizeCategories(
        categories.map((category) => category.name).toList(),
      ).map((category) => category.name).toList(growable: false),
    );
    await AppPreferences.remove(_visibleCategoriesKey);
  }

  static Future<AsmrContentLanguage> loadContentLanguage(
    AsmrContentLanguage defaultLanguage,
  ) async {
    final raw =
        await _database.loadAppSetting(_contentLanguageKey) ??
        await AppPreferences.getString(_contentLanguageKey);
    if (raw == null || raw.isEmpty) {
      return defaultLanguage;
    }
    await _database.saveAppSetting(_contentLanguageKey, raw);
    await AppPreferences.remove(_contentLanguageKey);
    return AsmrContentLanguage.fromName(raw);
  }

  static Future<void> saveContentLanguage(AsmrContentLanguage language) async {
    await _database.saveAppSetting(_contentLanguageKey, language.name);
    await AppPreferences.remove(_contentLanguageKey);
  }

  static Future<List<AsmrWork>> loadFavoriteWorks() async {
    final stored = await _database.loadAsmrWorkList('favorites');
    if (stored.isNotEmpty) return stored;
    final raw = await AppPreferences.readJson<List<AsmrWork>>(
      _favoriteWorksKey,
      (value) {
        final list = value as List<dynamic>? ?? const <dynamic>[];
        return list
            .whereType<Map<String, dynamic>>()
            .map((item) => AsmrWork.fromJson(item))
            .toList(growable: false);
      },
    );
    final works = raw ?? const <AsmrWork>[];
    if (works.isNotEmpty) {
      await saveFavoriteWorks(works);
      await AppPreferences.remove(_favoriteWorksKey);
    }
    return works;
  }

  static Future<void> saveFavoriteWorks(List<AsmrWork> works) async {
    await _database.saveAsmrWorkList('favorites', works);
    await AppPreferences.remove(_favoriteWorksKey);
  }

  static Future<List<AsmrWork>> loadHistoryWorks() async {
    final stored = await _database.loadAsmrWorkList('history');
    if (stored.isNotEmpty) return stored;
    final raw = await AppPreferences.readJson<List<AsmrWork>>(
      _historyWorksKey,
      (value) {
        final list = value as List<dynamic>? ?? const <dynamic>[];
        return list
            .whereType<Map<String, dynamic>>()
            .map((item) => AsmrWork.fromJson(item))
            .toList(growable: false);
      },
    );
    final works = raw ?? const <AsmrWork>[];
    if (works.isNotEmpty) {
      await saveHistoryWorks(works);
      await AppPreferences.remove(_historyWorksKey);
    }
    return works;
  }

  static Future<void> saveHistoryWorks(List<AsmrWork> works) async {
    await _database.saveAsmrWorkList('history', works);
    await AppPreferences.remove(_historyWorksKey);
  }

  static Future<List<AsmrSyncOperation>> loadSyncOperations() async {
    final stored = await _database.loadAsmrSyncOperations();
    if (stored.isNotEmpty) return stored;
    final raw = await AppPreferences.readJson<List<AsmrSyncOperation>>(
      _syncOpsKey,
      (value) {
        final list = value as List<dynamic>? ?? const <dynamic>[];
        return list
            .whereType<Map<String, dynamic>>()
            .map(AsmrSyncOperation.fromJson)
            .where((operation) => operation.workId > 0)
            .toList(growable: false);
      },
    );
    final operations = raw ?? const <AsmrSyncOperation>[];
    if (operations.isNotEmpty) {
      await saveSyncOperations(operations);
      await AppPreferences.remove(_syncOpsKey);
    }
    return operations;
  }

  static Future<void> saveSyncOperations(
    List<AsmrSyncOperation> operations,
  ) async {
    await _database.saveAsmrSyncOperations(operations);
    await AppPreferences.remove(_syncOpsKey);
  }

  static Future<DateTime?> loadLastSyncAt() async {
    return DateTime.tryParse(
      await _database.loadAppSetting(_lastSyncAtKey) ??
          await AppPreferences.getString(_lastSyncAtKey) ??
          '',
    );
  }

  static Future<void> saveLastSyncAt(DateTime value) async {
    await _database.saveAppSetting(_lastSyncAtKey, value.toIso8601String());
    await AppPreferences.remove(_lastSyncAtKey);
  }

  static List<AsmrCategoryType> _sanitizeCategories(List<String>? raw) {
    final result = <AsmrCategoryType>[];
    for (final name in raw ?? const <String>[]) {
      final category = AsmrCategoryType.values.where(
        (category) => category.name == name,
      );
      if (category.isEmpty) {
        continue;
      }
      final value = category.first;
      if (!kAsmrSelectableCategories.contains(value) ||
          result.contains(value)) {
        continue;
      }
      result.add(value);
      if (!Platform.isWindows && result.length == 5) {
        break;
      }
    }
    return result.isEmpty
        ? kDefaultVisibleAsmrCategories
        : result.toList(growable: false);
  }
}
