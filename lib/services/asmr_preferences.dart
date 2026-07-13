import 'dart:io';
import '../models/asmr_models.dart';
import 'app_database.dart';

class AsmrPreferencesStore {
  AsmrPreferencesStore({AppDatabase? database}) : _providedDatabase = database;

  static const String _lastSyncAtKey = 'asmr_last_sync_at_v1';
  static const String _syncOutboxSeededKey = 'asmr_sync_outbox_seeded_v2';
  static const String _contentLanguageKey = 'asmr_content_language_v1';

  final AppDatabase? _providedDatabase;

  AppDatabase get _database {
    if (_providedDatabase case final database?) {
      return database;
    }
    AppDatabase.initializeForPlatform();
    return AppDatabase.instance;
  }

  Future<void> clearForTest() async {
    final db = await _database.databaseForTest;
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

  Future<List<AsmrCategoryType>> loadVisibleCategories() async {
    final db = _database;
    final stored = await db.loadAsmrVisibleCategoryNames();
    return _sanitizeCategories(stored);
  }

  Future<void> saveVisibleCategories(List<AsmrCategoryType> categories) async {
    await _database.saveAsmrVisibleCategoryNames(
      _sanitizeCategories(
        categories.map((category) => category.name).toList(),
      ).map((category) => category.name).toList(growable: false),
    );
  }

  Future<AsmrContentLanguage> loadContentLanguage(
    AsmrContentLanguage defaultLanguage,
  ) async {
    final raw = await _database.loadAppSetting(_contentLanguageKey);
    if (raw == null || raw.isEmpty) {
      return defaultLanguage;
    }
    return AsmrContentLanguage.fromName(raw);
  }

  Future<void> saveContentLanguage(AsmrContentLanguage language) async {
    await _database.saveAppSetting(_contentLanguageKey, language.name);
  }

  Future<List<AsmrWork>> loadFavoriteWorks() async {
    return _database.loadAsmrWorkList('favorites');
  }

  Future<void> saveFavoriteWorks(List<AsmrWork> works) async {
    await _database.saveAsmrWorkList('favorites', works);
  }

  Future<List<AsmrWork>> loadHistoryWorks() async {
    return _database.loadAsmrWorkList('history');
  }

  Future<void> saveHistoryWorks(List<AsmrWork> works) async {
    await _database.saveAsmrWorkList('history', works);
  }

  Future<List<AsmrSyncOperation>> loadSyncOperations() async {
    return _database.loadAsmrSyncOperations();
  }

  Future<void> saveSyncOperations(List<AsmrSyncOperation> operations) async {
    await _database.saveAsmrSyncOperations(operations);
  }

  Future<void> saveWorkListAndSyncOperations(
    String listType,
    List<AsmrWork> works,
    List<AsmrSyncOperation> operations,
  ) {
    return _database.saveAsmrWorkListAndSyncOperations(
      listType,
      works,
      operations,
    );
  }

  Future<DateTime?> loadLastSyncAt() async {
    return DateTime.tryParse(
      await _database.loadAppSetting(_lastSyncAtKey) ?? '',
    );
  }

  Future<void> saveLastSyncAt(DateTime value) async {
    await _database.saveAppSetting(_lastSyncAtKey, value.toIso8601String());
  }

  Future<bool> isSyncOutboxSeeded() async {
    return await _database.loadAppSetting(_syncOutboxSeededKey) == 'true';
  }

  Future<void> markSyncOutboxSeeded() async {
    await _database.saveAppSetting(_syncOutboxSeededKey, 'true');
  }

  List<AsmrCategoryType> _sanitizeCategories(List<String>? raw) {
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
