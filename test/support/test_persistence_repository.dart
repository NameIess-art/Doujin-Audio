import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/persistence/app_database.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_persistence_repository.dart';
import 'package:doujin_audio/features/player/domain/playback_persistence_repository.dart';
import 'package:doujin_audio/features/player/domain/time_segment_label.dart';
import 'package:doujin_audio/infrastructure/sqlite/sqlite_asmr_repository.dart';
import 'package:doujin_audio/infrastructure/sqlite/sqlite_library_repository.dart';
import 'package:doujin_audio/infrastructure/sqlite/sqlite_playback_repository.dart';

/// Shared SQLite fixture for tests that exercise more than one feature port.
class TestPersistenceRepository extends SqliteLibraryRepository
    implements PlaybackPersistenceRepository, AsmrPersistenceRepository {
  TestPersistenceRepository({AppDatabase? database})
    : this._(database ?? AppDatabase.instance);

  TestPersistenceRepository._(AppDatabase database)
    : _playback = SqlitePlaybackRepository(database: database),
      _asmr = SqliteAsmrRepository(database: database),
      super(database: database);

  final SqlitePlaybackRepository _playback;
  final SqliteAsmrRepository _asmr;

  @override
  Future<List<PersistedPlaybackSession>> loadAllSessions() =>
      _playback.loadAllSessions();
  @override
  Future<void> saveAllSessions(List<PersistedPlaybackSession> sessions) =>
      _playback.saveAllSessions(sessions);
  @override
  Future<void> updateSessionOrder(List<String> sessionIds) =>
      _playback.updateSessionOrder(sessionIds);
  @override
  Future<void> updatePlaybackQueueEntryOrder(
    String sessionId,
    List<String> entryIds,
  ) => _playback.updatePlaybackQueueEntryOrder(sessionId, entryIds);
  @override
  Future<void> upsertSessionPlaybackState(PersistedPlaybackSession session) =>
      _playback.upsertSessionPlaybackState(session);
  @override
  Future<List<TimeSegmentLabel>> loadTimeSegmentLabels(String trackKey) =>
      _playback.loadTimeSegmentLabels(trackKey);
  @override
  Future<void> upsertTimeSegmentLabel(TimeSegmentLabel label) =>
      _playback.upsertTimeSegmentLabel(label);
  @override
  Future<void> deleteTimeSegmentLabel(String id) =>
      _playback.deleteTimeSegmentLabel(id);

  @override
  Future<List<String>> loadVisibleCategoryNames() =>
      _asmr.loadVisibleCategoryNames();
  @override
  Future<void> saveVisibleCategoryNames(List<String> categories) =>
      _asmr.saveVisibleCategoryNames(categories);
  @override
  Future<String?> loadSetting(String key) => _asmr.loadSetting(key);
  @override
  Future<void> saveSetting(String key, String? value) =>
      _asmr.saveSetting(key, value);
  @override
  Future<List<AsmrWork>> loadWorkList(String listType) =>
      _asmr.loadWorkList(listType);
  @override
  Future<void> saveWorkList(String listType, List<AsmrWork> works) =>
      _asmr.saveWorkList(listType, works);
  @override
  Future<List<AsmrSyncOperation>> loadSyncOperations() =>
      _asmr.loadSyncOperations();
  @override
  Future<void> saveSyncOperations(List<AsmrSyncOperation> operations) =>
      _asmr.saveSyncOperations(operations);
  @override
  Future<void> saveWorkListAndSyncOperations(
    String listType,
    List<AsmrWork> works,
    List<AsmrSyncOperation> operations,
  ) => _asmr.saveWorkListAndSyncOperations(listType, works, operations);
  @override
  Future<List<MusicTrack>> loadTracksForRecommendations() => loadAllTracks();
  @override
  Future<void> clearForTest() => _asmr.clearForTest();
}
