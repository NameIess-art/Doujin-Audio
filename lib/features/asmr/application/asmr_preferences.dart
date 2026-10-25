import 'dart:convert';

import '../domain/asmr_tag_interest.dart';
import '../domain/asmr_search_suggestions.dart';
import '../../../core/app_language.dart';
import '../domain/asmr_models.dart';
import '../domain/asmr_persistence_repository.dart';

class AsmrPreferencesStore {
  AsmrPreferencesStore({required AsmrPersistenceRepository repository})
    : _repository = repository;

  static const String _tagPreferencesKey = 'asmr_tag_preferences_v1';
  static const String _voiceActorPreferencesKey =
      'asmr_voice_actor_preferences_v1';
  static const String _circlePreferencesKey = 'asmr_circle_preferences_v1';
  static const String _lastSyncAtKey = 'asmr_last_sync_at_v1';
  static const String _syncOutboxSeededKey = 'asmr_sync_outbox_seeded_v2';
  static const String _contentLanguageKey = 'asmr_content_language_v1';
  static const _searchSuggestionsKey = 'asmr_search_suggestions_v1';

  final AsmrPersistenceRepository _repository;

  Future<void> clearForTest() async {
    await _repository.clearForTest();
    for (final key in [
      _contentLanguageKey,
      _tagPreferencesKey,
      _voiceActorPreferencesKey,
      _circlePreferencesKey,
      _lastSyncAtKey,
      _searchSuggestionsKey,
      _syncOutboxSeededKey,
      for (final language in AsmrContentLanguage.values)
        'asmr_daily_discovery_v1_${language.name}',
    ]) {
      await _repository.saveSetting(key, null);
    }
  }

  Future<({AsmrSearchSuggestions suggestions, DateTime updatedAt})?>
  loadSearchSuggestions() async {
    final raw = await _repository.loadSetting(_searchSuggestionsKey);
    if (raw == null) return null;
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return (
      suggestions: AsmrSearchSuggestions.fromJson(json),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
    );
  }

  Future<void> saveSearchSuggestions(
    AsmrSearchSuggestions suggestions,
    DateTime updatedAt,
  ) => _repository.saveSetting(
    _searchSuggestionsKey,
    jsonEncode({
      ...suggestions.toJson(),
      'updatedAt': updatedAt.toIso8601String(),
    }),
  );

  Future<AsmrTagPreferences> loadTagPreferences() async {
    final raw = await _repository.loadSetting(_tagPreferencesKey);
    return raw == null
        ? AsmrTagPreferences()
        : AsmrTagPreferences.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> saveTagPreferences(AsmrTagPreferences value) =>
      _repository.saveSetting(_tagPreferencesKey, jsonEncode(value.toJson()));

  Future<AsmrTagPreferences> loadVoiceActorPreferences() async {
    final raw = await _repository.loadSetting(_voiceActorPreferencesKey);
    return raw == null
        ? AsmrTagPreferences()
        : AsmrTagPreferences.fromJson({
            ...jsonDecode(raw) as Map<String, dynamic>,
            'limit': 20,
          });
  }

  Future<void> saveVoiceActorPreferences(AsmrTagPreferences value) =>
      _repository.saveSetting(
        _voiceActorPreferencesKey,
        jsonEncode(value.toJson()),
      );

  Future<AsmrTagPreferences> loadCirclePreferences() async {
    final raw = await _repository.loadSetting(_circlePreferencesKey);
    return raw == null
        ? AsmrTagPreferences()
        : AsmrTagPreferences.fromJson({
            ...jsonDecode(raw) as Map<String, dynamic>,
            'limit': 20,
          });
  }

  Future<void> saveCirclePreferences(AsmrTagPreferences value) => _repository
      .saveSetting(_circlePreferencesKey, jsonEncode(value.toJson()));

  static const dailyRecommendationsVersion = 3;

  Future<({String date, List<AsmrWork> works, int version, String interests})?>
  loadDailyRecommendations(AsmrContentLanguage language) async {
    final raw = await _repository.loadSetting(
      'asmr_daily_discovery_v1_${language.name}',
    );
    if (raw == null) return null;
    final value = jsonDecode(raw) as Map<String, dynamic>;
    return (
      date: value['date'] as String,
      version: (value['version'] as num?)?.toInt() ?? 1,
      interests: value['interests'] as String? ?? '',
      works: (value['works'] as List)
          .map(
            (work) => AsmrWork.fromJson(
              Map<String, dynamic>.from(work as Map),
              language: language,
            ),
          )
          .toList(growable: false),
    );
  }

  Future<void> saveDailyRecommendations({
    required AsmrContentLanguage language,
    required String date,
    required List<AsmrWork> works,
    String interests = '',
  }) => _repository.saveSetting(
    'asmr_daily_discovery_v1_${language.name}',
    jsonEncode({
      'date': date,
      'version': dailyRecommendationsVersion,
      'interests': interests,
      'works': works.map((work) => work.toJson()).toList(),
    }),
  );

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

  Future<void> saveHistoryState({
    required AsmrWork work,
    required List<String> historyWorkKeys,
    AsmrSyncOperation? operation,
  }) => _repository.saveHistoryState(
    work: work,
    historyWorkKeys: historyWorkKeys,
    operation: operation,
  );

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

  Future<void> saveFavoriteState({
    required List<AsmrWork> works,
    required bool favorite,
    required List<AsmrSyncOperation> operations,
  }) => _repository.saveFavoriteState(
    works: works,
    favorite: favorite,
    operations: operations,
  );

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
