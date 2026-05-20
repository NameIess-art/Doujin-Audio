import '../models/asmr_models.dart';
import 'app_preferences.dart';

abstract final class AsmrPreferences {
  static const String _authSessionKey = 'asmr_auth_session_v1';
  static const String _favoriteWorksKey = 'asmr_favorite_works_v1';
  static const String _historyWorksKey = 'asmr_history_works_v1';
  static const String _visibleCategoriesKey = 'asmr_visible_categories_v1';
  static const String _contentLanguageKey = 'asmr_content_language_v1';
  static const String _recommenderUuidKey = 'asmr_recommender_uuid_v1';

  static Future<AsmrAuthSession> loadAuthSession() async {
    return (await AppPreferences.readJson(
          _authSessionKey,
          AsmrAuthSession.fromJson,
        )) ??
        const AsmrAuthSession();
  }

  static Future<void> saveAuthSession(AsmrAuthSession session) async {
    await AppPreferences.writeJson(_authSessionKey, session.toJson());
  }

  static Future<List<AsmrCategoryType>> loadVisibleCategories() async {
    final raw = await AppPreferences.getStringList(_visibleCategoriesKey);
    return _sanitizeCategories(raw);
  }

  static Future<void> saveVisibleCategories(
    List<AsmrCategoryType> categories,
  ) async {
    await AppPreferences.setStringList(
      _visibleCategoriesKey,
      _sanitizeCategories(
        categories.map((category) => category.name).toList(),
      ).map((category) => category.name).toList(growable: false),
    );
  }

  static Future<AsmrContentLanguage> loadContentLanguage(
    AsmrContentLanguage defaultLanguage,
  ) async {
    final raw = await AppPreferences.getString(_contentLanguageKey);
    if (raw == null || raw.isEmpty) {
      return defaultLanguage;
    }
    return AsmrContentLanguage.fromName(raw);
  }

  static Future<void> saveContentLanguage(AsmrContentLanguage language) async {
    await AppPreferences.setString(_contentLanguageKey, language.name);
  }

  static Future<String?> loadRecommenderUuid() {
    return AppPreferences.getString(_recommenderUuidKey);
  }

  static Future<void> saveRecommenderUuid(String uuid) async {
    await AppPreferences.setString(_recommenderUuidKey, uuid);
  }

  static Future<List<AsmrWork>> loadFavoriteWorks() async {
    final raw = await AppPreferences.readJson<List<AsmrWork>>(
      _favoriteWorksKey,
      (value) {
        final list = value as List<dynamic>? ?? const <dynamic>[];
        return list
            .whereType<Map<Object?, Object?>>()
            .map(
              (item) => AsmrWork.fromJson(
                item.map((key, value) => MapEntry(key.toString(), value)),
              ),
            )
            .toList(growable: false);
      },
    );
    return raw ?? const <AsmrWork>[];
  }

  static Future<void> saveFavoriteWorks(List<AsmrWork> works) async {
    await AppPreferences.writeJson(
      _favoriteWorksKey,
      works.map((work) => work.toJson()).toList(growable: false),
    );
  }

  static Future<List<AsmrWork>> loadHistoryWorks() async {
    final raw = await AppPreferences.readJson<List<AsmrWork>>(
      _historyWorksKey,
      (value) {
        final list = value as List<dynamic>? ?? const <dynamic>[];
        return list
            .whereType<Map<Object?, Object?>>()
            .map(
              (item) => AsmrWork.fromJson(
                item.map((key, value) => MapEntry(key.toString(), value)),
              ),
            )
            .toList(growable: false);
      },
    );
    return raw ?? const <AsmrWork>[];
  }

  static Future<void> saveHistoryWorks(List<AsmrWork> works) async {
    await AppPreferences.writeJson(
      _historyWorksKey,
      works.map((work) => work.toJson()).toList(growable: false),
    );
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
      if (result.length == 5) {
        break;
      }
    }
    return result.isEmpty
        ? kDefaultVisibleAsmrCategories
        : result.toList(growable: false);
  }
}
