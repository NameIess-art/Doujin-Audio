import 'dart:convert';

import 'package:flutter/foundation.dart' show compute;
import 'package:meta/meta.dart';

import '../../core/media/music_track.dart';
import '../../core/persistence/app_database.dart';
import '../../core/persistence/persistence_records.dart';
import '../../features/asmr/domain/asmr_models.dart';
import '../../features/asmr/domain/asmr_persistence_repository.dart';

const _asmrWorkComputeThreshold = 32;

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
  Future<Map<String, String?>> loadSettings(List<String> keys) =>
      _database.loadAppSettings(keys);
  @override
  Future<void> saveSetting(String key, String? value) =>
      _database.saveAppSetting(key, value);
  @override
  Future<void> saveSettings(Map<String, String> values) =>
      _database.saveAppSettings(values);
  @override
  Future<List<AsmrWork>> loadWorkList(String listType) async {
    final records = await _database.loadAsmrWorkList(listType);
    if (records.length < _asmrWorkComputeThreshold) {
      return _worksFromRecords(records);
    }
    return compute(_worksFromRecords, records);
  }
  @override
  Future<void> saveWorkList(String listType, List<AsmrWork> works) async {
    final records = works.length < _asmrWorkComputeThreshold
        ? _worksToRecords(works)
        : await compute(_worksToRecords, works);
    await _database.saveAsmrWorkList(listType, records);
  }
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
  Future<void> saveHistoryState({
    required AsmrWork work,
    required List<String> historyWorkKeys,
    AsmrSyncOperation? operation,
  }) => _database.saveAsmrHistoryState(
    _workToRecord(work),
    historyWorkKeys,
    operation == null ? null : _operationToRecord(operation),
  );
  @override
  Future<void> saveFavoriteState({
    required List<AsmrWork> works,
    required bool favorite,
    required List<AsmrSyncOperation> operations,
  }) async {
    final records = works.length < _asmrWorkComputeThreshold
        ? _worksToRecords(works)
        : await compute(_worksToRecords, works);
    await _database.saveAsmrFavoriteState(
      records,
      favorite,
      operations.map(_operationToRecord).toList(growable: false),
    );
  }
  @override
  Future<void> saveAccountSyncState({
    required List<AsmrWork> favoriteWorks,
    required List<AsmrWork> historyWorks,
    required List<AsmrSyncOperation> operations,
  }) async {
    final (favoriteRecords, historyRecords) =
        favoriteWorks.length + historyWorks.length < _asmrWorkComputeThreshold
        ? (_worksToRecords(favoriteWorks), _worksToRecords(historyWorks))
        : await compute(_workListsToRecords, (favoriteWorks, historyWorks));
    await _database.saveAsmrAccountSyncState(
      favoriteRecords,
      historyRecords,
      operations.map(_operationToRecord).toList(growable: false),
    );
  }
  @override
  Future<List<MusicTrack>> loadTracksForRecommendations() =>
      _database.loadTracksForRecommendations();
  @override
  @visibleForTesting
  Future<void> clearForTest() {
    // ignore: invalid_use_of_visible_for_testing_member
    return _database.clearAsmrTablesForTest();
  }
}

List<AsmrWork> _worksFromRecords(List<AsmrWorkRecord> records) =>
    records.map(_workFromRecord).toList(growable: false);

List<AsmrWorkRecord> _worksToRecords(List<AsmrWork> works) =>
    works.map(_workToRecord).toList(growable: false);

(List<AsmrWorkRecord>, List<AsmrWorkRecord>) _workListsToRecords(
  (List<AsmrWork>, List<AsmrWork>) lists,
) => (_worksToRecords(lists.$1), _worksToRecords(lists.$2));

AsmrWorkRecord _workToRecord(AsmrWork work) => AsmrWorkRecord(
  id: work.id,
  workKey: work.workKey,
  resourcesJson: jsonEncode(
    work.resources.map((resource) => resource.toJson()).toList(),
  ),
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
  resources: record.resourcesJson == null
      ? null
      : (jsonDecode(record.resourcesJson!) as List)
            .map(
              (value) => AsmrWorkResource.fromJson(
                Map<String, dynamic>.from(value as Map),
              ),
            )
            .toList(),
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
