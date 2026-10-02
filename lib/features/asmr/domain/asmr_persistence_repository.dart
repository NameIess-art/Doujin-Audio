import '../../../core/media/music_track.dart';
import 'asmr_models.dart';

abstract interface class AsmrPersistenceRepository {
  Future<List<String>> loadVisibleCategoryNames();
  Future<void> saveVisibleCategoryNames(List<String> categories);
  Future<String?> loadSetting(String key);
  Future<void> saveSetting(String key, String? value);
  Future<List<AsmrWork>> loadWorkList(String listType);
  Future<void> saveWorkList(String listType, List<AsmrWork> works);
  Future<List<AsmrSyncOperation>> loadSyncOperations();
  Future<void> saveSyncOperations(List<AsmrSyncOperation> operations);
  Future<void> saveAccountSyncState({
    required List<AsmrWork> favoriteWorks,
    required List<AsmrWork> historyWorks,
    required List<AsmrSyncOperation> operations,
  });
  Future<List<MusicTrack>> loadTracksForRecommendations();
  Future<void> clearForTest();
}
