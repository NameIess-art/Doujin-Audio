import '../../core/media/music_track.dart';
import '../../core/persistence/app_database.dart';
import '../../core/persistence/persistence_records.dart';
import '../../features/asmr/domain/asmr_models.dart';
import '../../features/asmr/domain/asmr_persistence_repository.dart';

class SqliteAsmrRepository implements AsmrPersistenceRepository {
  SqliteAsmrRepository({required AppDatabase database}) : _database = database;

  final AppDatabase _database;

  @override
  Future<List<String>> loadVisibleCategoryNames() =>
      _database.loadAsmrVisibleCategoryNames();
  @override
  Future<void> saveVisibleCategoryNames(List<String> categories) =>
      _database.saveAsmrVisibleCategoryNames(categories);
  @override
  Future<String?> loadSetting(String key) => _database.loadAppSetting(key);
  @override
  Future<void> saveSetting(String key, String? value) =>
      _database.saveAppSetting(key, value);
  @override
  Future<List<AsmrWork>> loadWorkList(String listType) async =>
      (await _database.loadAsmrWorkList(
        listType,
      )).map(_workFromRecord).toList(growable: false);
  @override
  Future<void> saveWorkList(String listType, List<AsmrWork> works) =>
      _database.saveAsmrWorkList(
        listType,
        works.map(_workToRecord).toList(growable: false),
      );
  @override
  Future<List<AsmrSyncOperation>> loadSyncOperations() async =>
      (await _database.loadAsmrSyncOperations())
          .map(_operationFromRecord)
          .toList(growable: false);
  @override
  Future<void> saveSyncOperations(List<AsmrSyncOperation> operations) =>
      _database.saveAsmrSyncOperations(
        operations.map(_operationToRecord).toList(growable: false),
      );
  @override
  Future<void> saveAccountSyncState({
    required List<AsmrWork> favoriteWorks,
    required List<AsmrWork> historyWorks,
    required List<AsmrSyncOperation> operations,
  }) => _database.saveAsmrAccountSyncState(
    favoriteWorks.map(_workToRecord).toList(growable: false),
    historyWorks.map(_workToRecord).toList(growable: false),
    operations.map(_operationToRecord).toList(growable: false),
  );
  @override
  Future<List<MusicTrack>> loadTracksForRecommendations() =>
      _database.loadAllTracks();
  @override
  Future<void> clearForTest() async {
    final db = await _database.databaseForTest;
    final batch = db.batch();
    batch.delete('asmr_sync_operations');
    batch.delete('asmr_visible_categories');
    batch.delete('asmr_work_lists');
    batch.delete('asmr_work_tags');
    batch.delete('asmr_work_voice_actors');
    batch.delete('asmr_works');
    await batch.commit(noResult: true);
  }
}

AsmrWorkRecord _workToRecord(AsmrWork work) => AsmrWorkRecord(
  id: work.id,
  title: work.title,
  circleName: work.circleName,
  sourceId: work.sourceId,
  sourceType: work.sourceType,
  sourceUrl: work.sourceUrl,
  coverUrl: work.coverUrl,
  thumbnailUrl: work.thumbnailUrl,
  mainCoverUrl: work.mainCoverUrl,
  releaseDate: work.releaseDate,
  createDate: work.createDate,
  duration: work.duration,
  dlCount: work.dlCount,
  reviewCount: work.reviewCount,
  rating: work.rating,
  voiceActors: work.voiceActors,
  tags: work.tags,
  hasSubtitle: work.hasSubtitle,
  isFavorite: work.isFavorite,
);

AsmrWork _workFromRecord(AsmrWorkRecord record) => AsmrWork(
  id: record.id,
  title: record.title,
  circleName: record.circleName,
  sourceId: record.sourceId,
  sourceType: record.sourceType,
  sourceUrl: record.sourceUrl,
  coverUrl: record.coverUrl,
  thumbnailUrl: record.thumbnailUrl,
  mainCoverUrl: record.mainCoverUrl,
  releaseDate: record.releaseDate,
  createDate: record.createDate,
  duration: record.duration,
  dlCount: record.dlCount,
  reviewCount: record.reviewCount,
  rating: record.rating,
  voiceActors: record.voiceActors,
  tags: record.tags,
  hasSubtitle: record.hasSubtitle,
  isFavorite: record.isFavorite,
);

AsmrSyncOperationRecord _operationToRecord(AsmrSyncOperation operation) =>
    AsmrSyncOperationRecord(
      type: operation.type.name,
      workId: operation.workId,
      sourceId: operation.sourceId,
      createdAt: operation.createdAt,
      retryCount: operation.retryCount,
    );

AsmrSyncOperation _operationFromRecord(AsmrSyncOperationRecord record) =>
    AsmrSyncOperation(
      type: AsmrSyncOperationType.fromName(record.type),
      workId: record.workId,
      sourceId: record.sourceId,
      createdAt: record.createdAt,
      retryCount: record.retryCount,
    );
