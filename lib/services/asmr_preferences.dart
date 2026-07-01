import 'dart:io';
import '../models/asmr_models.dart';
import 'app_database.dart';

abstract final class AsmrPreferences {
  static const String _lastSyncAtKey = 'asmr_last_sync_at_v1';
  static const String _syncOutboxSeededKey = 'asmr_sync_outbox_seeded_v2';
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
    for (final key in [
      _contentLanguageKey,
      _lastSyncAtKey,
      _syncOutboxSeededKey,
    ]) {
      batch.delete('app_kv_settings', where: 'key = ?', whereArgs: [key]);
    }
    await batch.commit(noResult: true);
  }

  static Future<List<AsmrCategoryType>> loadVisibleCategories() async {
    final db = _database;
    final stored = await db.loadAsmrVisibleCategoryNames();
    return _sanitizeCategories(stored);
  }

  static Future<void> saveVisibleCategories(
    List<AsmrCategoryType> categories,
  ) async {
    await _database.saveAsmrVisibleCategoryNames(
      _sanitizeCategories(
        categories.map((category) => category.name).toList(),
      ).map((category) => category.name).toList(growable: false),
    );
  }

  static Future<AsmrContentLanguage> loadContentLanguage(
    AsmrContentLanguage defaultLanguage,
  ) async {
    final raw = await _database.loadAppSetting(_contentLanguageKey);
    if (raw == null || raw.isEmpty) {
      return defaultLanguage;
    }
    return AsmrContentLanguage.fromName(raw);
  }

  static Future<void> saveContentLanguage(AsmrContentLanguage language) async {
    await _database.saveAppSetting(_contentLanguageKey, language.name);
  }

  static Future<List<AsmrWork>> loadFavoriteWorks() async {
    return _database.loadAsmrWorkList('favorites');
  }

  static Future<void> saveFavoriteWorks(List<AsmrWork> works) async {
    await _database.saveAsmrWorkList('favorites', works);
  }

  static Future<List<AsmrWork>> loadHistoryWorks() async {
    return _database.loadAsmrWorkList('history');
  }

  static Future<void> saveHistoryWorks(List<AsmrWork> works) async {
    await _database.saveAsmrWorkList('history', works);
  }

  static Future<List<AsmrSyncOperation>> loadSyncOperations() async {
    return _database.loadAsmrSyncOperations();
  }

  static Future<void> saveSyncOperations(
    List<AsmrSyncOperation> operations,
  ) async {
    await _database.saveAsmrSyncOperations(operations);
  }

  static Future<DateTime?> loadLastSyncAt() async {
    return DateTime.tryParse(
      await _database.loadAppSetting(_lastSyncAtKey) ?? '',
    );
  }

  static Future<void> saveLastSyncAt(DateTime value) async {
    await _database.saveAppSetting(_lastSyncAtKey, value.toIso8601String());
  }

  static Future<bool> isSyncOutboxSeeded() async {
    return await _database.loadAppSetting(_syncOutboxSeededKey) == 'true';
  }

  static Future<void> markSyncOutboxSeeded() async {
    await _database.saveAppSetting(_syncOutboxSeededKey, 'true');
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
