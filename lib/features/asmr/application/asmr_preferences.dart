import '../../../core/app_language.dart';
import '../domain/asmr_models.dart';
import '../domain/asmr_persistence_repository.dart';

class AsmrPreferencesStore {
  AsmrPreferencesStore({required AsmrPersistenceRepository repository})
    : _repository = repository;

  static const String _lastSyncAtKey = 'asmr_last_sync_at_v1';
  static const String _syncOutboxSeededKey = 'asmr_sync_outbox_seeded_v2';
  static const String _contentLanguageKey = 'asmr_content_language_v1';

  final AsmrPersistenceRepository _repository;

  Future<void> clearForTest() async {
    await _repository.clearForTest();
    for (final key in [
      _contentLanguageKey,
      _lastSyncAtKey,
      _syncOutboxSeededKey,
    ]) {
      await _repository.saveSetting(key, null);
    }
  }

  Future<List<AsmrCategoryType>> loadVisibleCategories() async {
    final stored = await _repository.loadVisibleCategoryNames();
    return _sanitizeCategories(stored);
  }

  Future<void> saveVisibleCategories(List<AsmrCategoryType> categories) async {
    await _repository.saveVisibleCategoryNames(
      _sanitizeCategories(
        categories.map((category) => category.name).toList(),
      ).map((category) => category.name).toList(growable: false),
    );
  }

  Future<ContentLanguagePreference> loadContentLanguagePreference() async {
    final raw = await _repository.loadSetting(_contentLanguageKey);
    return ContentLanguagePreference.fromName(raw);
  }

  Future<void> saveContentLanguagePreference(
    ContentLanguagePreference preference,
  ) async {
    await _repository.saveSetting(_contentLanguageKey, preference.name);
  }

  Future<List<AsmrWork>> loadFavoriteWorks() async {
    return _repository.loadWorkList('favorites');
  }

  Future<void> saveFavoriteWorks(List<AsmrWork> works) async {
    await _repository.saveWorkList('favorites', works);
  }

  Future<List<AsmrWork>> loadHistoryWorks() async {
    return _repository.loadWorkList('history');
  }

  Future<void> saveHistoryWorks(List<AsmrWork> works) async {
    await _repository.saveWorkList('history', works);
  }

  Future<List<AsmrSyncOperation>> loadSyncOperations() async {
    return _repository.loadSyncOperations();
  }

  Future<void> saveSyncOperations(List<AsmrSyncOperation> operations) async {
    await _repository.saveSyncOperations(operations);
  }

  Future<void> saveAccountSyncState({
    required List<AsmrWork> favoriteWorks,
    required List<AsmrWork> historyWorks,
    required List<AsmrSyncOperation> operations,
  }) {
    return _repository.saveAccountSyncState(
      favoriteWorks: favoriteWorks,
      historyWorks: historyWorks,
      operations: operations,
    );
  }

  Future<DateTime?> loadLastSyncAt() async {
    return DateTime.tryParse(
      await _repository.loadSetting(_lastSyncAtKey) ?? '',
    );
  }

  Future<void> saveLastSyncAt(DateTime value) async {
    await _repository.saveSetting(_lastSyncAtKey, value.toIso8601String());
  }

  Future<bool> isSyncOutboxSeeded() async =>
      await _repository.loadSetting(_syncOutboxSeededKey) == 'true';

  Future<void> markSyncOutboxSeeded() async {
    await _repository.saveSetting(_syncOutboxSeededKey, 'true');
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
      if (result.length == 5) {
        break;
      }
    }
    return result.isEmpty
        ? kDefaultVisibleAsmrCategories
        : result.toList(growable: false);
  }
}
