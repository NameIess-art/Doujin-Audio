import '../models/asmr_models.dart';
import 'app_preferences.dart';

abstract final class AsmrPreferences {
  static const String _authSessionKey = 'asmr_auth_session_v1';
  static const String _favoriteWorksKey = 'asmr_favorite_works_v1';
  static const String _historyWorksKey = 'asmr_history_works_v1';

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
}
