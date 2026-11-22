import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../domain/asmr_tag_interest.dart';
import '../domain/asmr_search_suggestions.dart';
import '../../../core/app_language.dart';
import '../domain/asmr_models.dart';
import '../domain/asmr_persistence_repository.dart';

AsmrTagPreferences _decodePreferences(
  ({String preferences, String? catalog, String catalogKey, int? limit}) input,
) => AsmrTagPreferences.fromJson(
  jsonDecode(input.preferences) as Map<String, dynamic>,
  catalog: input.catalog == null
      ? null
      : jsonDecode(input.catalog!) as Map<String, dynamic>,
  limit: input.limit,
  storedCatalogKey: input.catalogKey,
);

String _encodeInterestCatalog(AsmrTagPreferences value) =>
    jsonEncode(value.toCatalogJson());

class AsmrPreferencesStore {
  AsmrPreferencesStore({required AsmrPersistenceRepository repository})
    : _repository = repository;

  static const String _tagPreferencesKey = 'asmr_tag_preferences_v1';
  static const String _voiceActorPreferencesKey =
      'asmr_voice_actor_preferences_v1';
  static const String _circlePreferencesKey = 'asmr_circle_preferences_v1';
  static final interestCatalogKeys = Map<String, String>.unmodifiable({
    for (final key in [
      _tagPreferencesKey,
      _voiceActorPreferencesKey,
      _circlePreferencesKey,
    ])
      key: '${key}_catalog',
  });
  static const String _lastSyncAtKey = 'asmr_last_sync_at_v1';
  static const String _syncOutboxSeededKey = 'asmr_sync_outbox_seeded_v2';
  static const String _contentLanguageKey = 'asmr_content_language_v1';
  static const _searchSuggestionsKey = 'asmr_search_suggestions_v1';

  final AsmrPersistenceRepository _repository;

  static bool keepLocalInterestOnRestore(String local, String? backup) {
    final localData = _decodeInterestSetting(local);
    const timeKey = AsmrTagPreferences.updatedAtMsKey;
    final localTime = localData?[timeKey];
    final backupTime = _decodeInterestSetting(backup)?[timeKey];
    if (localTime is int && backupTime is int) return localTime >= backupTime;

    // Older settings lack timestamps. Keep local selections and learned
    // interests when their order is unknown, but allow catalog-only settings
    // to be replaced by a backup that contains personal data.
    return localTime is int ||
        switch (localData) {
          {'manualInterests': List(isNotEmpty: true)} ||
          {'excluded': List(isNotEmpty: true)} ||
          {'learned': Map(isNotEmpty: true)} ||
          {'weights': Map(isNotEmpty: true)} => true,
          _ => false,
        };
  }

  static Map<String, dynamic>? _decodeInterestSetting(String? value) {
    if (value == null) return null;
    try {
      final decoded = jsonDecode(value);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  @visibleForTesting
  Future<void> clearForTest() async {
    // ignore: invalid_use_of_visible_for_testing_member
    await _repository.clearForTest();
    for (final key in [
      _contentLanguageKey,
      ...interestCatalogKeys.keys,
      ...interestCatalogKeys.values,
      _lastSyncAtKey,
      _searchSuggestionsKey,
      _syncOutboxSeededKey,
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

  Future<AsmrTagPreferences> loadTagPreferences() =>
      _loadInterests(_tagPreferencesKey);

  Future<void> saveTagPreferences(AsmrTagPreferences value) =>
      _saveInterests(_tagPreferencesKey, value);

  Future<AsmrTagPreferences> loadVoiceActorPreferences() =>
      _loadInterests(_voiceActorPreferencesKey, limit: 20);

  Future<void> saveVoiceActorPreferences(AsmrTagPreferences value) =>
      _saveInterests(_voiceActorPreferencesKey, value);

  Future<AsmrTagPreferences> loadCirclePreferences() =>
      _loadInterests(_circlePreferencesKey, limit: 20);

  Future<void> saveCirclePreferences(AsmrTagPreferences value) =>
      _saveInterests(_circlePreferencesKey, value);

  Future<
    ({
      AsmrTagPreferences tags,
      AsmrTagPreferences voiceActors,
      AsmrTagPreferences circles,
    })
  >
  loadAllInterestPreferences() async {
    final keys = <String>[
      for (final entry in interestCatalogKeys.entries) ...[
        entry.key,
        entry.value,
      ],
    ];
    final settings = await _repository.loadSettings(keys);
    final results = await Future.wait<AsmrTagPreferences>([
      _decodeInterestsFromSettings(_tagPreferencesKey, settings),
      _decodeInterestsFromSettings(
        _voiceActorPreferencesKey,
        settings,
        limit: 20,
      ),
      _decodeInterestsFromSettings(_circlePreferencesKey, settings, limit: 20),
    ]);
    return (tags: results[0], voiceActors: results[1], circles: results[2]);
  }

  Future<AsmrTagPreferences> _loadInterests(String key, {int? limit}) async {
    final catalogKey = interestCatalogKeys[key]!;
    final settings = await _repository.loadSettings([key, catalogKey]);
    return _decodeInterestsFromSettings(key, settings, limit: limit);
  }

  Future<AsmrTagPreferences> _decodeInterestsFromSettings(
    String key,
    Map<String, String?> settings, {
    int? limit,
  }) async {
    final catalogKey = interestCatalogKeys[key]!;
    final preferences = settings[key];
    if (preferences == null) return AsmrTagPreferences(limit: limit ?? 20);
    final catalog = settings[catalogKey];
    final input = (
      preferences: preferences,
      catalog: catalog,
      catalogKey: catalogKey,
      limit: limit,
    );
    const backgroundDecodeThreshold = 32 * 1024;
    if (preferences.length + (catalog?.length ?? 0) >
        backgroundDecodeThreshold) {
      return compute(_decodePreferences, input);
    }
    return _decodePreferences(input);
  }

  Future<void> _saveInterests(String key, AsmrTagPreferences value) async {
    final preferences = jsonEncode(value.toPreferenceJson());
    final catalogKey = interestCatalogKeys[key]!;
    if (!value.needsCatalogSave(catalogKey)) {
      await _repository.saveSetting(key, preferences);
      return;
    }
    final catalog = await compute(_encodeInterestCatalog, value);
    await _repository.saveSettings({key: preferences, catalogKey: catalog});
    value.markCatalogSaved(catalogKey);
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
