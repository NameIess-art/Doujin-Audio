import '../../core/persistence/app_database.dart';
import '../../features/data_support/domain/cross_platform_sync_models.dart';

class SqliteCrossPlatformSyncRepository implements CrossPlatformSyncRepository {
  SqliteCrossPlatformSyncRepository({AppDatabase? database})
    : _database = database ?? AppDatabase.instance;

  final AppDatabase _database;

  @override
  Future<String> ensureDeviceId(String Function() generateDeviceId) =>
      _database.ensureCrossPlatformSyncDeviceId(generateDeviceId);

  @override
  Future<SyncTrackStateEntry?> findSyncedTrackState({
    required String workKey,
    required String relativePath,
  }) async {
    final row = await _database.findSyncedTrackState(
      workKey: workKey,
      relativePath: relativePath,
    );
    if (row == null) return null;
    return _trackEntryFromRow(row);
  }

  @override
  Future<Map<String, SyncTrackStateEntry>> findSyncedTrackStates({
    required String workKey,
    required Iterable<String> relativePaths,
  }) async => (await _database.findSyncedTrackStates(
    workKey: workKey,
    relativePaths: relativePaths,
  )).map((key, row) => MapEntry(key, _trackEntryFromRow(row)));

  @override
  Future<Map<String, SyncWorkStateEntry>> findSyncedWorkStates(
    Iterable<String> workKeys,
  ) async => (await _database.findSyncedWorkStates(
    workKeys,
  )).map((key, row) => MapEntry(key, _workEntryFromRow(row)));

  @override
  Future<void> saveRemoteTrackProgress({
    required String workKey,
    required String relativePath,
    required int positionMs,
    required int playedAtMs,
  }) => _database.saveRemoteTrackProgress(
    workKey: workKey,
    relativePath: relativePath,
    positionMs: positionMs,
    playedAtMs: playedAtMs,
  );

  @override
  Future<Map<String, String?>> loadInterestSettings(Iterable<String> keys) =>
      _database.loadSyncInterestSettings(keys);

  @override
  Future<SyncWorkStateEntry?> findSyncedWorkState(String workKey) async {
    final row = await _database.findSyncedWorkState(workKey);
    return row == null ? null : _workEntryFromRow(row);
  }

  @override
  Future<Set<(String, String)>> upsertSyncedWorkState(
    SyncWorkStateEntry entry,
  ) => _database.upsertSyncedWorkState(_workRowFromEntry(entry));

  @override
  Future<
    ({
      String deviceId,
      List<SyncTrackStateEntry> tracks,
      Map<String, Map<String, int>> deviceDayLedger,
      Map<String, Map<String, Map<String, int>>> deviceWorkDayLedger,
      List<SyncHistoryWorkEntry> history,
      Map<String, int> deletedHistory,
      List<SyncTimeSegmentEntry> timeSegments,
      Map<String, int> deletedTimeSegments,
      Map<String, String?> interestSettings,
      List<SyncWorkStateEntry> workStates,
    })
  >
  exportSnapshot({
    required String Function() generateDeviceId,
    required Iterable<String> interestSettingKeys,
  }) async {
    final raw = await _database.exportCrossPlatformSyncSnapshot(
      generateDeviceId: generateDeviceId,
      interestSettingKeys: interestSettingKeys,
    );
    return (
      deviceId: raw.deviceId,
      tracks: [for (final row in raw.tracks) _trackEntryFromRow(row)],
      deviceDayLedger: raw.deviceDayLedger,
      deviceWorkDayLedger: raw.deviceWorkDayLedger,
      history: [
        for (final row in raw.history)
          SyncHistoryWorkEntry(
            workKey: row.workKey,
            title: row.title,
            subtitle: row.subtitle,
            remoteCoverUrl: row.remoteCoverUrl,
            lastPlayedAtMs: row.lastPlayedAtMs,
            updatedAtMs: row.updatedAtMs,
          ),
      ],
      deletedHistory: raw.deletedHistory,
      timeSegments: [
        for (final row in raw.timeSegments)
          SyncTimeSegmentEntry(
            id: row.id,
            workKey: row.workKey,
            relativePath: row.relativePath,
            name: row.name,
            startMs: row.startMs,
            endMs: row.endMs,
            colorValue: row.colorValue,
            createdAtMs: row.createdAtMs,
            updatedAtMs: row.updatedAtMs,
          ),
      ],
      deletedTimeSegments: raw.deletedTimeSegments,
      interestSettings: raw.interestSettings,
      workStates: [for (final row in raw.workStates) _workEntryFromRow(row)],
    );
  }

  @override
  Future<CrossPlatformSyncApplyOutcome> applyMergedSnapshot({
    required String Function() generateDeviceId,
    required List<SyncTrackStateEntry> incomingTracks,
    required Map<String, Map<String, int>> incomingDeviceDayLedger,
    required Map<String, Map<String, Map<String, int>>>
    incomingDeviceWorkDayLedger,
    required List<SyncHistoryWorkEntry> incomingHistory,
    Map<String, int> incomingDeletedHistory = const {},
    required List<SyncTimeSegmentEntry> incomingTimeSegments,
    required Map<String, int> incomingDeletedTimeSegments,
    required Map<String, String?> mergedInterestSettings,
    List<SyncWorkStateEntry> incomingWorkStates = const <SyncWorkStateEntry>[],
  }) async {
    final res = await _database.applyCrossPlatformSyncData(
      generateDeviceId: generateDeviceId,
      incomingTracks: [
        for (final t in incomingTracks)
          PersistedSyncTrackRow(
            syncKey: '${t.workKey}::${t.relativePath.toLowerCase()}',
            workKey: t.workKey,
            relativePath: t.relativePath,
            stemKey: '',
            positionMs: t.positionMs,
            lastPlayedAtMs: t.lastPlayedAtMs,
            isFavorite: t.isFavorite,
            favoriteUpdatedAtMs: t.favoriteUpdatedAtMs,
            updatedAtMs: t.updatedAtMs,
          ),
      ],
      incomingDeviceDayLedger: incomingDeviceDayLedger,
      incomingDeviceWorkDayLedger: incomingDeviceWorkDayLedger,
      incomingHistory: [
        for (final h in incomingHistory)
          PersistedSyncHistoryRow(
            workKey: h.workKey,
            title: h.title,
            subtitle: h.subtitle,
            remoteCoverUrl: h.remoteCoverUrl,
            lastPlayedAtMs: h.lastPlayedAtMs,
            updatedAtMs: h.updatedAtMs,
          ),
      ],
      incomingDeletedHistory: incomingDeletedHistory,
      incomingTimeSegments: [
        for (final s in incomingTimeSegments)
          PersistedSyncTimeSegmentRow(
            id: s.id,
            workKey: s.workKey,
            relativePath: s.relativePath,
            name: s.name,
            startMs: s.startMs,
            endMs: s.endMs,
            colorValue: s.colorValue,
            createdAtMs: s.createdAtMs,
            updatedAtMs: s.updatedAtMs,
          ),
      ],
      incomingDeletedTimeSegments: incomingDeletedTimeSegments,
      mergedInterestSettings: mergedInterestSettings,
      incomingWorkStates: [
        for (final w in incomingWorkStates) _workRowFromEntry(w),
      ],
    );
    return CrossPlatformSyncApplyOutcome(
      updatedTrackPaths: res.updatedTrackPaths,
      trackStatesMerged: res.trackStatesMerged,
      listeningDaysUpdated: res.listeningDaysUpdated,
      timeSegmentsMerged: res.timeSegmentsMerged,
      updatedDetailTargets: res.updatedDetailTargets,
      workStatesMerged: res.workStatesMerged,
      historyChanged: res.historyChanged,
    );
  }

  static SyncTrackStateEntry _trackEntryFromRow(PersistedSyncTrackRow row) =>
      SyncTrackStateEntry(
        workKey: row.workKey,
        relativePath: row.relativePath,
        positionMs: row.positionMs,
        lastPlayedAtMs: row.lastPlayedAtMs,
        isFavorite: row.isFavorite,
        favoriteUpdatedAtMs: row.favoriteUpdatedAtMs,
        updatedAtMs: row.updatedAtMs,
      );

  static SyncWorkStateEntry _workEntryFromRow(PersistedSyncWorkRow row) =>
      SyncWorkStateEntry(
        workKey: row.workKey,
        rjCode: row.rjCode,
        workTitle: row.workTitle,
        circleName: row.circleName,
        voiceActors: row.voiceActors,
        tags: row.tags,
        releaseDateMs: row.releaseDateMs,
        salesCount: row.salesCount,
        rating: row.rating,
        detailUpdatedAtMs: row.detailUpdatedAtMs,
        listenStatus: row.listenStatus,
        userRating: row.userRating,
        reviewText: row.reviewText,
        reviewUpdatedAtMs: row.reviewUpdatedAtMs,
      );

  static PersistedSyncWorkRow _workRowFromEntry(SyncWorkStateEntry e) =>
      PersistedSyncWorkRow(
        workKey: e.workKey,
        rjCode: e.rjCode,
        workTitle: e.workTitle,
        circleName: e.circleName,
        voiceActors: e.voiceActors,
        tags: e.tags,
        releaseDateMs: e.releaseDateMs,
        salesCount: e.salesCount,
        rating: e.rating,
        detailUpdatedAtMs: e.detailUpdatedAtMs,
        listenStatus: e.listenStatus,
        userRating: e.userRating,
        reviewText: e.reviewText,
        reviewUpdatedAtMs: e.reviewUpdatedAtMs,
      );
}
