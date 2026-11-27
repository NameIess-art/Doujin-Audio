part of 'app_database.dart';

const String _crossPlatformSyncDeviceIdKey = 'cross_platform_sync_device_id_v1';

class PersistedSyncTrackRow {
  const PersistedSyncTrackRow({
    required this.syncKey,
    required this.workKey,
    required this.relativePath,
    required this.stemKey,
    required this.positionMs,
    this.lastPlayedAtMs,
    required this.isFavorite,
    required this.favoriteUpdatedAtMs,
    required this.updatedAtMs,
  });

  final String syncKey;
  final String workKey;
  final String relativePath;
  final String stemKey;
  final int positionMs;
  final int? lastPlayedAtMs;
  final bool isFavorite;
  final int favoriteUpdatedAtMs;
  final int updatedAtMs;
}

class PersistedSyncTimeSegmentRow {
  const PersistedSyncTimeSegmentRow({
    required this.id,
    required this.workKey,
    required this.relativePath,
    required this.name,
    required this.startMs,
    required this.endMs,
    required this.colorValue,
    required this.createdAtMs,
    required this.updatedAtMs,
  });

  final String id;
  final String workKey;
  final String relativePath;
  final String name;
  final int startMs;
  final int endMs;
  final int colorValue;
  final int createdAtMs;
  final int updatedAtMs;
}

class PersistedSyncHistoryRow {
  const PersistedSyncHistoryRow({
    required this.workKey,
    required this.title,
    required this.subtitle,
    this.remoteCoverUrl,
    required this.lastPlayedAtMs,
    this.updatedAtMs,
  });

  final String workKey;
  final String title;
  final String subtitle;
  final String? remoteCoverUrl;
  final int lastPlayedAtMs;
  final int? updatedAtMs;
}

class PersistedSyncWorkRow {
  const PersistedSyncWorkRow({
    required this.workKey,
    required this.rjCode,
    this.workTitle = '',
    this.circleName = '',
    this.voiceActors = const <String>[],
    this.tags = const <String>[],
    this.releaseDateMs,
    this.salesCount,
    this.rating,
    this.detailUpdatedAtMs = 0,
    this.listenStatus,
    this.userRating,
    this.reviewText = '',
    this.reviewUpdatedAtMs = 0,
  });

  final String workKey;
  final String rjCode;
  final String workTitle;
  final String circleName;
  final List<String> voiceActors;
  final List<String> tags;
  final int? releaseDateMs;
  final int? salesCount;
  final double? rating;
  final int detailUpdatedAtMs;
  final String? listenStatus;
  final int? userRating;
  final String reviewText;
  final int reviewUpdatedAtMs;
}

class PersistedCrossPlatformSyncSnapshot {
  const PersistedCrossPlatformSyncSnapshot({
    required this.deviceId,
    required this.tracks,
    required this.deviceDayLedger,
    required this.deviceWorkDayLedger,
    required this.history,
    required this.deletedHistory,
    required this.timeSegments,
    required this.deletedTimeSegments,
    required this.interestSettings,
    this.workStates = const <PersistedSyncWorkRow>[],
  });

  final String deviceId;
  final List<PersistedSyncTrackRow> tracks;
  final Map<String, Map<String, int>> deviceDayLedger;
  final Map<String, Map<String, Map<String, int>>> deviceWorkDayLedger;
  final List<PersistedSyncHistoryRow> history;
  final Map<String, int> deletedHistory;
  final List<PersistedSyncTimeSegmentRow> timeSegments;
  final Map<String, int> deletedTimeSegments;
  final Map<String, String?> interestSettings;
  final List<PersistedSyncWorkRow> workStates;
}

class PersistedCrossPlatformSyncApplyResult {
  const PersistedCrossPlatformSyncApplyResult({
    required this.updatedTrackPaths,
    required this.trackStatesMerged,
    required this.listeningDaysUpdated,
    required this.timeSegmentsMerged,
    this.updatedDetailTargets = const <(String, String)>{},
    this.workStatesMerged = 0,
    this.historyChanged = false,
  });

  final Set<String> updatedTrackPaths;
  final int trackStatesMerged;
  final int listeningDaysUpdated;
  final int timeSegmentsMerged;
  final Set<(String, String)> updatedDetailTargets;
  final int workStatesMerged;
  final bool historyChanged;
}

extension AppDatabaseSync on AppDatabase {
  Future<String> ensureCrossPlatformSyncDeviceId(
    String Function() generateDeviceId,
  ) => _runDatabaseRead((db) async {
    return db.transaction((txn) => _ensureSyncDeviceIdInTxn(txn, generateDeviceId));
  });

  Future<PersistedSyncTrackRow?> findSyncedTrackState({
    required String workKey,
    required String relativePath,
  }) async => (await findSyncedTrackStates(
    workKey: workKey,
    relativePaths: [relativePath],
  ))[relativePath];

  Future<Map<String, PersistedSyncTrackRow>> findSyncedTrackStates({
    required String workKey,
    required Iterable<String> relativePaths,
  }) {
    final keys = {
      for (final relativePath in relativePaths)
        relativePath: ?CrossPlatformMediaIdentity.fromWorkAndRelativePath(
          workKey: workKey,
          relativePath: relativePath,
        ),
    };
    if (keys.isEmpty) return Future.value(const {});
    return _runDatabaseRead((db) async {
      final rows = await db.query(
        'sync_track_states',
        where: 'work_key = ?',
        whereArgs: [workKey.trim()],
      );
      final exact = <String, PersistedSyncTrackRow>{};
      final byStem = <String, PersistedSyncTrackRow?>{};
      for (final row in rows) {
        final value = _syncTrackRowFromDb(row);
        exact[value.syncKey] = value;
        byStem[value.stemKey] = byStem.containsKey(value.stemKey)
            ? null
            : value;
      }
      return {
        for (final MapEntry(key: path, value: identity) in keys.entries)
          path: ?(exact[identity.syncKey] ?? byStem[identity.stemSyncKey]),
      };
    });
  }

  Future<void> saveRemoteTrackProgress({
    required String workKey,
    required String relativePath,
    required int positionMs,
    required int playedAtMs,
  }) async {
    final identity = CrossPlatformMediaIdentity.fromWorkAndRelativePath(
      workKey: workKey,
      relativePath: relativePath,
    );
    if (identity == null) return;
    await _runDatabaseWrite(
      (db) => db.transaction((txn) async {
        final rows = await txn.query(
          'sync_track_states',
          where: 'work_key = ? AND stem_key = ?',
          whereArgs: [identity.workKey, identity.stemSyncKey],
        );
        final row =
            rows
                .where((row) => row['sync_key'] == identity.syncKey)
                .firstOrNull ??
            rows.singleOrNull;
        final existing = row == null ? null : _syncTrackRowFromDb(row);
        if (playedAtMs < (existing?.lastPlayedAtMs ?? 0)) return;
        await txn.insert(
          'sync_track_states',
          _syncTrackRowToDb(
            PersistedSyncTrackRow(
              syncKey: identity.syncKey,
              workKey: identity.workKey,
              relativePath: identity.relativePath,
              stemKey: identity.stemSyncKey,
              positionMs: positionMs,
              lastPlayedAtMs: playedAtMs,
              isFavorite: existing?.isFavorite ?? false,
              favoriteUpdatedAtMs: existing?.favoriteUpdatedAtMs ?? 0,
              updatedAtMs: max(playedAtMs, existing?.updatedAtMs ?? 0),
            ),
          ),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }),
    );
  }

  Future<PersistedSyncWorkRow?> findSyncedWorkState(String workKey) async =>
      (await findSyncedWorkStates([workKey]))[workKey.trim()];

  Future<Map<String, PersistedSyncWorkRow>> findSyncedWorkStates(
    Iterable<String> workKeys,
  ) {
    final keys = workKeys
        .map((key) => key.trim())
        .where((key) => key.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (keys.isEmpty) return Future.value(const {});
    return _runDatabaseRead((db) async {
      final results = <String, PersistedSyncWorkRow>{};
      for (final chunk in _stringChunks(keys)) {
        final placeholders = List.filled(chunk.length, '?').join(', ');
        final rows = await db.query(
          'sync_work_states',
          where: 'work_key IN ($placeholders)',
          whereArgs: chunk,
        );
        for (final row in rows) {
          final work = _syncWorkRowFromDb(row);
          results[work.workKey] = work;
        }
      }
      return results;
    });
  }

  Future<Map<String, String?>> loadSyncInterestSettings(
    Iterable<String> keys,
  ) => _runDatabaseRead((db) => _loadSyncInterestSettings(db, keys));

  Future<Set<(String, String)>> upsertSyncedWorkState(
    PersistedSyncWorkRow incoming,
  ) => _runDatabaseRead((db) async {
    return db.transaction((txn) async {
      final batch = txn.batch();
      final res = await _mergeIncomingWorkStatesInTxn(
        txn,
        batch,
        <PersistedSyncWorkRow>[incoming],
      );
      await batch.commit(noResult: true);
      return res.updatedDetailTargets;
    });
  });

  Future<PersistedCrossPlatformSyncSnapshot> exportCrossPlatformSyncSnapshot({
    required String Function() generateDeviceId,
    required Iterable<String> interestSettingKeys,
  }) => _runDatabaseRead((db) async {
    return db.transaction(
      (txn) => _exportSyncSnapshotInTxn(
        txn,
        generateDeviceId: generateDeviceId,
        interestSettingKeys: interestSettingKeys,
      ),
    );
  });

  Future<PersistedCrossPlatformSyncApplyResult> applyCrossPlatformSyncData({
    required String Function() generateDeviceId,
    required List<PersistedSyncTrackRow> incomingTracks,
    required Map<String, Map<String, int>> incomingDeviceDayLedger,
    required Map<String, Map<String, Map<String, int>>> incomingDeviceWorkDayLedger,
    required List<PersistedSyncHistoryRow> incomingHistory,
    Map<String, int> incomingDeletedHistory = const {},
    required List<PersistedSyncTimeSegmentRow> incomingTimeSegments,
    required Map<String, int> incomingDeletedTimeSegments,
    required Map<String, String?> mergedInterestSettings,
    List<PersistedSyncWorkRow> incomingWorkStates = const <PersistedSyncWorkRow>[],
  }) => _runDatabaseRead((db) async {
    return db.transaction((txn) async {
      final localDeviceId = await _ensureSyncDeviceIdInTxn(
        txn,
        generateDeviceId,
      );
      await _snapshotDayLedgerInTxn(txn, localDeviceId);
      await _snapshotWorkDayLedgerInTxn(txn, localDeviceId);

      final rjByTargetKey = await _loadTargetRjMap(txn);
      final localIndex = await _loadLocalTrackIdentityIndex(txn, rjByTargetKey);

      final existingSyncRows = await txn.query('sync_track_states');
      final existingSyncByKey = <String, PersistedSyncTrackRow>{
        for (final row in existingSyncRows)
          (row['sync_key'] as String): _syncTrackRowFromDb(row),
      };

      final updatedTrackPaths = <String>{};
      var trackStatesMerged = 0;
      final batch = txn.batch();

      for (final incoming in incomingTracks) {
        final identity = CrossPlatformMediaIdentity.fromWorkAndRelativePath(
          workKey: incoming.workKey,
          relativePath: incoming.relativePath,
        );
        if (identity == null) continue;
        final currentSync = existingSyncByKey[identity.syncKey];
        final incomingPlayedAt = incoming.lastPlayedAtMs ?? 0;
        final currentSyncPlayedAt = currentSync?.lastPlayedAtMs ?? 0;
        final newerProgress =
            currentSync == null || incomingPlayedAt > currentSyncPlayedAt;
        final newerFav =
            currentSync == null ||
            _isNewerFavorite(
              incoming.favoriteUpdatedAtMs,
              incoming.isFavorite,
              currentSync.favoriteUpdatedAtMs,
              currentSync.isFavorite,
            );

        if (newerProgress || newerFav) {
          final mergedRow = PersistedSyncTrackRow(
            syncKey: identity.syncKey,
            workKey: identity.workKey,
            relativePath: identity.relativePath,
            stemKey: identity.stemSyncKey,
            positionMs: newerProgress
                ? incoming.positionMs
                : currentSync.positionMs,
            lastPlayedAtMs: newerProgress
                ? incoming.lastPlayedAtMs
                : currentSync.lastPlayedAtMs,
            isFavorite: newerFav ? incoming.isFavorite : currentSync.isFavorite,
            favoriteUpdatedAtMs: newerFav
                ? incoming.favoriteUpdatedAtMs
                : currentSync.favoriteUpdatedAtMs,
            updatedAtMs: incoming.updatedAtMs > (currentSync?.updatedAtMs ?? 0)
                ? incoming.updatedAtMs
                : (currentSync?.updatedAtMs ?? 0),
          );
          existingSyncByKey[identity.syncKey] = mergedRow;
          batch.insert(
            'sync_track_states',
            _syncTrackRowToDb(mergedRow),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
          trackStatesMerged++;
        }

        final merged = existingSyncByKey[identity.syncKey]!;
        final matchedLocalTracks = localIndex.findMatches(identity);
        for (final local in matchedLocalTracks) {
          final localPlayedAt = local.lastPlayedAtMs ?? 0;
          final applyProgress = (merged.lastPlayedAtMs ?? 0) > localPlayedAt;
          final applyFavorite = _isNewerFavorite(
            merged.favoriteUpdatedAtMs,
            merged.isFavorite,
            local.favoriteUpdatedAtMs,
            local.isFavorite,
          );
          if (!applyProgress && !applyFavorite) continue;

          if (applyProgress) {
            local.positionMs = merged.positionMs;
            local.lastPlayedAtMs = merged.lastPlayedAtMs;
          }
          if (applyFavorite) {
            local.isFavorite = merged.isFavorite;
            local.favoriteUpdatedAtMs = merged.favoriteUpdatedAtMs;
          }
          batch.insert('track_playback_state', <String, Object?>{
            'path': local.path,
            'last_played_position_ms': local.positionMs,
            'last_played_at_ms': local.lastPlayedAtMs,
            'is_favorite': local.isFavorite ? 1 : 0,
            'favorite_updated_at_ms': local.favoriteUpdatedAtMs,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
          updatedTrackPaths.add(local.path);
        }
      }

      // Merge per-device G-Counter listening ledgers without double-counting.
      final existingDayLedgerRows = await txn.query(
        'sync_listening_day_ledger',
      );
      final localDayLedger = <String, Map<String, int>>{};
      for (final row in existingDayLedgerRows) {
        final dev = row['device_id'] as String;
        final date = row['date'] as String;
        final ms = (row['milliseconds'] as num).toInt();
        localDayLedger.putIfAbsent(dev, () => <String, int>{})[date] = ms;
      }

      final dayDeltas = <String, int>{};
      for (final entry in incomingDeviceDayLedger.entries) {
        final peerId = entry.key;
        final peerMap = localDayLedger.putIfAbsent(
          peerId,
          () => <String, int>{},
        );
        for (final dayEntry in entry.value.entries) {
          final date = dayEntry.key;
          final incomingMs = dayEntry.value;
          if (incomingMs <= 0) continue;
          final prevMs = peerMap[date] ?? 0;
          if (incomingMs > prevMs) {
            dayDeltas[date] = (dayDeltas[date] ?? 0) + (incomingMs - prevMs);
            peerMap[date] = incomingMs;
            batch.insert(
              'sync_listening_day_ledger',
              <String, Object?>{
                'device_id': peerId,
                'date': date,
                'milliseconds': incomingMs,
              },
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          }
        }
      }

      final existingDays = dayDeltas.isEmpty
          ? const <String>{}
          : await _loadExistingListeningDays(txn, dayDeltas.keys.toList());
      for (final entry in dayDeltas.entries) {
        if (existingDays.contains(entry.key)) {
          batch.rawUpdate(
            'UPDATE listening_days SET milliseconds = milliseconds + ? WHERE date = ?',
            [entry.value, entry.key],
          );
        } else {
          batch.insert('listening_days', <String, Object?>{
            'date': entry.key,
            'milliseconds': entry.value,
          });
        }
      }

      final existingWorkLedgerRows = await txn.query(
        'sync_listening_work_ledger',
      );
      final localWorkLedger = <String, Map<String, Map<String, int>>>{};
      for (final row in existingWorkLedgerRows) {
        final dev = row['device_id'] as String;
        final date = row['date'] as String;
        final wk = row['work_key'] as String;
        final ms = (row['milliseconds'] as num).toInt();
        localWorkLedger
            .putIfAbsent(dev, () => <String, Map<String, int>>{})
            .putIfAbsent(date, () => <String, int>{})[wk] = ms;
      }

      final workDeltasByDate = <String, Map<String, int>>{};
      for (final devEntry in incomingDeviceWorkDayLedger.entries) {
        final peerId = devEntry.key;
        final peerDates = localWorkLedger.putIfAbsent(
          peerId,
          () => <String, Map<String, int>>{},
        );
        for (final dateEntry in devEntry.value.entries) {
          final date = dateEntry.key;
          final peerWorks = peerDates.putIfAbsent(date, () => <String, int>{});
          for (final workEntry in dateEntry.value.entries) {
            final wk = workEntry.key;
            final incomingMs = workEntry.value;
            if (incomingMs <= 0) continue;
            final prevMs = peerWorks[wk] ?? 0;
            if (incomingMs > prevMs) {
              final delta = incomingMs - prevMs;
              peerWorks[wk] = incomingMs;
              workDeltasByDate.putIfAbsent(date, () => <String, int>{})[wk] =
                  (workDeltasByDate[date]?[wk] ?? 0) + delta;
              batch.insert(
                'sync_listening_work_ledger',
                <String, Object?>{
                  'device_id': peerId,
                  'date': date,
                  'work_key': wk,
                  'milliseconds': incomingMs,
                },
                conflictAlgorithm: ConflictAlgorithm.replace,
              );
            }
          }
        }
      }

      if (workDeltasByDate.isNotEmpty) {
        final existingWorkDays = await _loadExistingListeningWorkDays(
          txn,
          workDeltasByDate,
        );
        for (final dateEntry in workDeltasByDate.entries) {
          final date = dateEntry.key;
          final existingForDate = existingWorkDays[date];
          for (final workEntry in dateEntry.value.entries) {
            if (existingForDate != null &&
                existingForDate.contains(workEntry.key)) {
              batch.rawUpdate(
                'UPDATE listening_work_days SET milliseconds = milliseconds + ? '
                'WHERE date = ? AND work_key = ?',
                [workEntry.value, date, workEntry.key],
              );
            } else {
              batch.insert('listening_work_days', <String, Object?>{
                'date': date,
                'work_key': workEntry.key,
                'milliseconds': workEntry.value,
              });
            }
          }
        }
      }

      final historyChanged = await _mergeListeningHistory(
        txn,
        batch,
        localIndex,
        incomingHistory,
        incomingDeletedHistory,
      );

      // Merge time segment tombstones & labels.
      final existingDeletedRows = await txn.query('sync_deleted_time_segments');
      final deletedById = <String, int>{
        for (final row in existingDeletedRows)
          row['id'] as String: (row['deleted_at_ms'] as num).toInt(),
      };
      final existingLabelRows = await txn.query(
        'time_segment_labels',
        columns: const ['id', 'updated_at_ms'],
      );
      final labelUpdatedById = <String, int>{
        for (final row in existingLabelRows)
          row['id'] as String: (row['updated_at_ms'] as num).toInt(),
      };

      var timeSegmentsMerged = 0;
      for (final entry in incomingDeletedTimeSegments.entries) {
        final id = entry.key;
        final deletedAt = entry.value;
        final prevDeleted = deletedById[id] ?? -1;
        if (deletedAt > prevDeleted) {
          deletedById[id] = deletedAt;
          batch.insert(
            'sync_deleted_time_segments',
            <String, Object?>{'id': id, 'deleted_at_ms': deletedAt},
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        final existingLabelTs = labelUpdatedById[id];
        if (existingLabelTs != null && deletedAt >= existingLabelTs) {
          batch.delete(
            'time_segment_labels',
            where: 'id = ?',
            whereArgs: [id],
          );
          labelUpdatedById.remove(id);
          timeSegmentsMerged++;
        }
      }

      for (final seg in incomingTimeSegments) {
        final tombstoneTs = deletedById[seg.id];
        if (tombstoneTs != null && tombstoneTs >= seg.updatedAtMs) continue;
        final existingTs = labelUpdatedById[seg.id];
        if (existingTs != null && existingTs >= seg.updatedAtMs) continue;

        final identity = CrossPlatformMediaIdentity.fromWorkAndRelativePath(
          workKey: seg.workKey,
          relativePath: seg.relativePath,
        );
        if (identity == null) continue;
        final matchedLocal = localIndex.findMatches(identity);
        final resolvedTrackKey = matchedLocal.isNotEmpty
            ? PathMatcher.normalize(matchedLocal.first.path)
            : (identity.workKey.startsWith('asmr:')
                  ? identity.timeSegmentTrackKey
                  : identity.timeSegmentTrackKey);
        final record = TimeSegmentLabelRecord(
          id: seg.id,
          trackKey: resolvedTrackKey,
          name: seg.name,
          startMs: seg.startMs,
          endMs: seg.endMs,
          colorValue: seg.colorValue,
          createdAtMs: seg.createdAtMs,
          updatedAtMs: seg.updatedAtMs,
        );
        batch.insert(
          'time_segment_labels',
          _timeSegmentLabelRow(record, identity),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        if (tombstoneTs != null) {
          batch.delete(
            'sync_deleted_time_segments',
            where: 'id = ?',
            whereArgs: [seg.id],
          );
          deletedById.remove(seg.id);
        }
        labelUpdatedById[seg.id] = seg.updatedAtMs;
        timeSegmentsMerged++;
      }

      for (final entry in mergedInterestSettings.entries) {
        if (entry.value == null) {
          batch.delete(
            'app_kv_settings',
            where: 'key = ?',
            whereArgs: [entry.key],
          );
        } else {
          batch.insert(
            'app_kv_settings',
            <String, Object?>{'key': entry.key, 'value': entry.value},
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      }

      final workMerge = incomingWorkStates.isEmpty
          ? (updatedDetailTargets: const <(String, String)>{}, mergedCount: 0)
          : await _mergeIncomingWorkStatesInTxn(txn, batch, incomingWorkStates);

      await batch.commit(noResult: true);
      return PersistedCrossPlatformSyncApplyResult(
        updatedTrackPaths: updatedTrackPaths,
        trackStatesMerged: trackStatesMerged,
        listeningDaysUpdated: dayDeltas.length,
        timeSegmentsMerged: timeSegmentsMerged,
        updatedDetailTargets: workMerge.updatedDetailTargets,
        workStatesMerged: workMerge.mergedCount,
        historyChanged: historyChanged,
      );
    });
  });
}

bool _isPortableListeningWork(String key) =>
    key.startsWith('rj:') || key.startsWith('asmr:');

Future<bool> _mergeListeningHistory(
  Transaction txn,
  Batch batch,
  _LocalTrackIdentityIndex localIndex,
  List<PersistedSyncHistoryRow> incoming,
  Map<String, int> deleted,
) async {
  final incomingByKey = {
    for (final row in incoming)
      if (row.lastPlayedAtMs > 0 && _isPortableListeningWork(row.workKey))
        row.workKey: row,
  };
  final keys = {
    ...incomingByKey.keys,
    ...deleted.keys.where(_isPortableListeningWork),
  };
  if (keys.isEmpty) return false;
  final edits = await _loadListeningHistoryEdits(txn, keys);
  final currentPlayed = <String, int>{};
  for (final chunk in _stringChunks(keys.toList(growable: false))) {
    final placeholders = List.filled(chunk.length, '?').join(', ');
    final rows = await txn.query(
      'listening_history',
      columns: ['work_key', 'last_played_at_ms'],
      where: 'work_key IN ($placeholders)',
      whereArgs: chunk,
    );
    for (final row in rows) {
      currentPlayed[row['work_key']! as String] =
          row['last_played_at_ms']! as int;
    }
  }
  var changed = false;
  var newestEdit = 0;
  for (final workKey in keys) {
    final item = incomingByKey[workKey];
    final playedAt = currentPlayed[workKey];
    final edit = edits[workKey];
    final localMs = max(playedAt ?? 0, edit?.updatedAtMs ?? 0);
    final deletedAt = deleted[workKey] ?? 0;
    final incomingMs = item?.updatedAtMs ?? item?.lastPlayedAtMs ?? 0;
    if (deletedAt > 0 && deletedAt >= incomingMs && deletedAt >= localMs) {
      if (deletedAt == localMs && edit?.deleted == true && playedAt == null) {
        continue;
      }
      batch.insert(
        'sync_listening_history_edits',
        {'work_key': workKey, 'updated_at_ms': deletedAt, 'deleted': 1},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      newestEdit = max(newestEdit, deletedAt);
      if (playedAt != null) {
        batch.delete(
          'listening_history',
          where: 'work_key = ?',
          whereArgs: [workKey],
        );
        changed = true;
      }
    } else if (item != null && incomingMs > localMs) {
      if (playedAt == null) {
        final local = localIndex.firstForWorkKey(workKey);
        final track = MusicTrack(
          path: local?.path ?? workKey,
          displayName: local?.displayName ?? item.title,
          groupKey: local?.groupKey ?? workKey,
          groupTitle: item.title,
          groupSubtitle: item.subtitle,
          isSingle: false,
          remoteCoverUrl: item.remoteCoverUrl,
        );
        batch.insert('listening_history', {
          'work_key': workKey,
          'track_json': jsonEncode(track.toJson()),
          'last_played_at_ms': item.lastPlayedAtMs,
          'legacy_order': 0,
        });
        changed = true;
      } else if (item.lastPlayedAtMs > playedAt) {
        batch.update(
          'listening_history',
          {'last_played_at_ms': item.lastPlayedAtMs},
          where: 'work_key = ?',
          whereArgs: [workKey],
        );
        changed = true;
      }
      if (incomingMs > item.lastPlayedAtMs) {
        newestEdit = max(newestEdit, incomingMs);
        batch.insert(
          'sync_listening_history_edits',
          {'work_key': workKey, 'updated_at_ms': incomingMs, 'deleted': 0},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    }
  }
  if (newestEdit > 0) {
    batch.rawInsert(
      'INSERT OR REPLACE INTO app_kv_settings (key, value) '
      'VALUES (?, MAX(?, COALESCE((SELECT CAST(value AS INTEGER) '
      'FROM app_kv_settings WHERE key = ?), 0)))',
      [_listeningHistoryEditedAtKey, newestEdit, _listeningHistoryEditedAtKey],
    );
  }
  return changed;
}

Future<PersistedCrossPlatformSyncSnapshot> _exportSyncSnapshotInTxn(
  Transaction txn, {
  required String Function() generateDeviceId,
  required Iterable<String> interestSettingKeys,
}) async {
  final deviceId = await _ensureSyncDeviceIdInTxn(txn, generateDeviceId);
  final rjByTargetKey = await _loadTargetRjMap(txn);
  final localTrackIndex = await _loadLocalTrackIdentityIndex(txn, rjByTargetKey);

  final trackStatesBySyncKey = <String, PersistedSyncTrackRow>{};
  final storedSyncRows = await txn.query('sync_track_states');
  for (final row in storedSyncRows) {
    final parsed = _syncTrackRowFromDb(row);
    trackStatesBySyncKey[parsed.syncKey] = parsed;
  }

  for (final item in localTrackIndex.tracks) {
    if (item.positionMs <= 0 &&
        (item.lastPlayedAtMs == null || item.lastPlayedAtMs! <= 0) &&
        item.favoriteUpdatedAtMs <= 0 &&
        !item.isFavorite) {
      continue;
    }
    final existing = trackStatesBySyncKey[item.identity.syncKey];
    final itemPlayedAt = item.lastPlayedAtMs ?? 0;
    final existingPlayedAt = existing?.lastPlayedAtMs ?? 0;
    final preferLocalProgress =
        existing == null || itemPlayedAt >= existingPlayedAt;
    final preferLocalFavorite =
        existing == null ||
        _isNewerFavorite(
          item.favoriteUpdatedAtMs,
          item.isFavorite,
          existing.favoriteUpdatedAtMs,
          existing.isFavorite,
        );
    final favTs = max(
      item.favoriteUpdatedAtMs,
      existing?.favoriteUpdatedAtMs ?? 0,
    );
    final updatedAt = max(max(itemPlayedAt, favTs), existing?.updatedAtMs ?? 0);

    trackStatesBySyncKey[item.identity.syncKey] = PersistedSyncTrackRow(
      syncKey: item.identity.syncKey,
      workKey: item.identity.workKey,
      relativePath: item.identity.relativePath,
      stemKey: item.identity.stemSyncKey,
      positionMs: preferLocalProgress ? item.positionMs : existing.positionMs,
      lastPlayedAtMs: preferLocalProgress
          ? item.lastPlayedAtMs
          : existing.lastPlayedAtMs,
      isFavorite: preferLocalFavorite ? item.isFavorite : existing.isFavorite,
      favoriteUpdatedAtMs: favTs,
      updatedAtMs: updatedAt,
    );
  }

  final dayLedgers = await _snapshotDayLedgerInTxn(txn, deviceId);
  final workDayLedgers = await _snapshotWorkDayLedgerInTxn(txn, deviceId);

  final rawHistory = await txn.rawQuery('''
    SELECT h.*, e.updated_at_ms AS edit_updated_at_ms
    FROM listening_history h
    LEFT JOIN sync_listening_history_edits e ON e.work_key = h.work_key
    WHERE h.work_key LIKE 'rj:%' OR h.work_key LIKE 'asmr:%'
    ORDER BY h.last_played_at_ms DESC LIMIT 500
  ''');
  final history = <PersistedSyncHistoryRow>[];
  for (final row in rawHistory) {
    final workKey = row['work_key'] as String? ?? '';
    final lastPlayedAtMs = (row['last_played_at_ms'] as num?)?.toInt() ?? 0;
    if (lastPlayedAtMs <= 0) continue;
    Map<String, Object?>? decodedTrack;
    try {
      final rawJson = row['track_json'] as String?;
      if (rawJson != null && rawJson.isNotEmpty) {
        final parsed = jsonDecode(rawJson);
        if (parsed is Map) {
          decodedTrack = parsed.cast<String, Object?>();
        }
      }
    } on Object {
      decodedTrack = null;
    }
    final title =
        decodedTrack?['groupTitle']?.toString().trim().isNotEmpty == true
        ? decodedTrack!['groupTitle']!.toString().trim()
        : (decodedTrack?['displayName']?.toString().trim() ?? workKey);
    final subtitle = decodedTrack?['groupSubtitle']?.toString().trim() ?? '';
    final remoteCoverUrl = decodedTrack?['remoteCoverUrl']?.toString();
    history.add(
      PersistedSyncHistoryRow(
        workKey: workKey,
        title: title,
        subtitle: subtitle,
        remoteCoverUrl: remoteCoverUrl?.isEmpty == true ? null : remoteCoverUrl,
        lastPlayedAtMs: lastPlayedAtMs,
        updatedAtMs: switch (row['edit_updated_at_ms']) {
          final int editedAt when editedAt > lastPlayedAtMs => editedAt,
          _ => null,
        },
      ),
    );
  }
  final deletedHistory = <String, int>{
    for (final row in await txn.rawQuery('''
      SELECT e.work_key, e.updated_at_ms
      FROM sync_listening_history_edits e
      LEFT JOIN listening_history h ON h.work_key = e.work_key
      WHERE e.deleted = 1 AND h.work_key IS NULL
    '''))
      if (_isPortableListeningWork(row['work_key']! as String))
        row['work_key']! as String: row['updated_at_ms']! as int,
  };

  final rawLabels = await txn.query('time_segment_labels');
  final segments = <PersistedSyncTimeSegmentRow>[];
  for (final row in rawLabels) {
    final trackKey = row['track_key'] as String? ?? '';
    final resolvedIdentity = _resolveIdentityForLabelTrackKey(
      trackKey,
      localTrackIndex,
    );
    if (resolvedIdentity == null) continue;
    segments.add(
      PersistedSyncTimeSegmentRow(
        id: row['id'] as String,
        workKey: resolvedIdentity.workKey,
        relativePath: resolvedIdentity.relativePath,
        name: row['name'] as String,
        startMs: (row['start_ms'] as num).toInt(),
        endMs: (row['end_ms'] as num).toInt(),
        colorValue: (row['color_value'] as num).toInt(),
        createdAtMs: (row['created_at_ms'] as num).toInt(),
        updatedAtMs: (row['updated_at_ms'] as num).toInt(),
      ),
    );
  }

  final deletedRows = await txn.query('sync_deleted_time_segments');
  final deletedSegments = <String, int>{
    for (final row in deletedRows)
      row['id'] as String: (row['deleted_at_ms'] as num).toInt(),
  };

  final interestSettings = await _loadSyncInterestSettings(
    txn,
    interestSettingKeys,
  );
  final workStatesByKey = await _collectSyncWorkStatesInTxn(txn);

  return PersistedCrossPlatformSyncSnapshot(
    deviceId: deviceId,
    tracks: trackStatesBySyncKey.values.toList(growable: false),
    deviceDayLedger: dayLedgers,
    deviceWorkDayLedger: workDayLedgers,
    history: history,
    deletedHistory: deletedHistory,
    timeSegments: segments,
    deletedTimeSegments: deletedSegments,
    interestSettings: interestSettings,
    workStates: workStatesByKey.values.toList(growable: false),
  );
}

Future<Map<String, String?>> _loadSyncInterestSettings(
  DatabaseExecutor db,
  Iterable<String> keys,
) async {
  final settings = <String, String?>{for (final key in keys) key: null};
  for (final chunk in _stringChunks(settings.keys.toList(growable: false))) {
    final placeholders = List.filled(chunk.length, '?').join(', ');
    final rows = await db.query(
      'app_kv_settings',
      where: 'key IN ($placeholders)',
      whereArgs: chunk,
    );
    for (final row in rows) {
      settings[row['key'] as String] = row['value'] as String?;
    }
  }
  return settings;
}

Future<String> _ensureSyncDeviceIdInTxn(
  Transaction txn,
  String Function() generateDeviceId,
) async {
  final rows = await txn.query(
    'app_kv_settings',
    columns: const ['value'],
    where: 'key = ?',
    whereArgs: [_crossPlatformSyncDeviceIdKey],
    limit: 1,
  );
  final existing = rows.firstOrNull?['value'] as String?;
  if (existing != null && existing.trim().isNotEmpty) return existing.trim();
  final created = generateDeviceId();
  await txn.insert(
    'app_kv_settings',
    <String, Object?>{'key': _crossPlatformSyncDeviceIdKey, 'value': created},
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
  return created;
}

Future<Map<String, String>> _loadTargetRjMap(
  DatabaseExecutor db, {
  Iterable<String>? targets,
}) async {
  const fields = ['target_path', 'rj_code'];
  final rows = <Map<String, Object?>>[];
  if (targets == null) {
    rows.addAll(
      await db.query('audio_details', columns: fields, where: "rj_code != ''"),
    );
  } else {
    for (final chunk in _stringChunks(targets.toList(growable: false))) {
      final placeholders = List.filled(chunk.length, '?').join(', ');
      rows.addAll(
        await db.query(
          'audio_details',
          columns: fields,
          where:
              "target_type IN ('libraryRootFolder', 'singleAudioFile') "
              "AND target_path IN ($placeholders) AND rj_code != ''",
          whereArgs: chunk,
        ),
      );
    }
  }
  final map = <String, String>{};
  for (final row in rows) {
    final targetPath = row['target_path'] as String? ?? '';
    final rj = CrossPlatformMediaIdentity.normalizeRjCode(
      row['rj_code'] as String?,
    );
    if (targetPath.isNotEmpty && rj != null) {
      map[PathMatcher.equivalenceKey(targetPath)] = rj;
    }
  }
  return map;
}

bool _isNewerFavorite(
  int incomingMs,
  bool incomingValue,
  int currentMs,
  bool currentValue,
) =>
    incomingMs > currentMs ||
    (incomingMs == currentMs &&
        incomingValue != currentValue &&
        (incomingMs > 0 ? !incomingValue : incomingValue));

class _LocalTrackSyncCandidate {
  _LocalTrackSyncCandidate({
    required this.path,
    required this.displayName,
    required this.groupKey,
    required this.identity,
    required this.positionMs,
    required this.lastPlayedAtMs,
    required this.isFavorite,
    required this.favoriteUpdatedAtMs,
  });

  final String path;
  final String displayName;
  final String groupKey;
  final CrossPlatformTrackIdentity identity;
  int positionMs;
  int? lastPlayedAtMs;
  bool isFavorite;
  int favoriteUpdatedAtMs;
}

class _LocalTrackIdentityIndex {
  _LocalTrackIdentityIndex(this.tracks) {
    for (final track in tracks) {
      bySyncKey
          .putIfAbsent(track.identity.syncKey, () => <_LocalTrackSyncCandidate>[])
          .add(track);
      byStemKey
          .putIfAbsent(
            track.identity.stemSyncKey,
            () => <_LocalTrackSyncCandidate>[],
          )
          .add(track);
      byNormalizedPath[PathMatcher.equivalenceKey(track.path)] = track.identity;
      byWorkKey.putIfAbsent(track.identity.workKey, () => track);
    }
  }

  final List<_LocalTrackSyncCandidate> tracks;
  final Map<String, List<_LocalTrackSyncCandidate>> bySyncKey = {};
  final Map<String, List<_LocalTrackSyncCandidate>> byStemKey = {};
  final Map<String, CrossPlatformTrackIdentity> byNormalizedPath = {};
  final Map<String, _LocalTrackSyncCandidate> byWorkKey = {};

  List<_LocalTrackSyncCandidate> findMatches(
    CrossPlatformTrackIdentity identity,
  ) {
    final exact = bySyncKey[identity.syncKey];
    if (exact != null && exact.isNotEmpty) return exact;
    final stemMatches = byStemKey[identity.stemSyncKey];
    if (stemMatches != null && stemMatches.length == 1) return stemMatches;
    return const <_LocalTrackSyncCandidate>[];
  }

  _LocalTrackSyncCandidate? firstForWorkKey(String workKey) =>
      byWorkKey[workKey];
}

Future<_LocalTrackIdentityIndex> _loadLocalTrackIdentityIndex(
  DatabaseExecutor db,
  Map<String, String>? rjByTargetKey, {
  List<String>? paths,
}) async {
  final where = paths == null
      ? ''
      : 'WHERE t.path IN (${List.filled(paths.length, '?').join(', ')})';
  final rows = await db.rawQuery('''
    SELECT
      t.path,
      t.display_name,
      t.group_key,
      t.group_title,
      t.group_subtitle,
      t.is_single,
      p.last_played_position_ms,
      p.last_played_at_ms,
      p.is_favorite,
      p.favorite_updated_at_ms,
      r.remote_metadata_kind,
      r.remote_metadata_json
    FROM tracks t
    LEFT JOIN track_playback_state p ON p.path = t.path
    LEFT JOIN track_remote_metadata r ON r.path = t.path
    $where
  ''', paths);
  final targetRj =
      rjByTargetKey ??
      await _loadTargetRjMap(
        db,
        targets: {
          for (final row in rows) ...[
            row['path'] as String,
            row['group_key'] as String,
          ],
        },
      );

  final candidates = <_LocalTrackSyncCandidate>[];
  for (final row in rows) {
    final path = row['path'] as String;
    final groupKey = row['group_key'] as String? ?? '';
    final isSingle = ((row['is_single'] as num?)?.toInt() ?? 0) != 0;
    final rjOverride =
        targetRj[PathMatcher.equivalenceKey(isSingle ? path : groupKey)] ??
        targetRj[PathMatcher.equivalenceKey(path)];
    Map<String, Object?>? remoteMetadata;
    final rawMeta = row['remote_metadata_json'] as String?;
    if (rawMeta != null && rawMeta.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawMeta);
        if (decoded is Map) remoteMetadata = decoded.cast<String, Object?>();
      } on Object {
        remoteMetadata = null;
      }
    }
    final workKey = CrossPlatformMediaIdentity.resolveWorkKey(
      rjCode: rjOverride,
      remoteMetadataKind: row['remote_metadata_kind'] as String?,
      remoteMetadata: remoteMetadata,
      groupSubtitle: row['group_subtitle'] as String?,
      groupTitle: row['group_title'] as String?,
      groupKey: groupKey,
      trackPath: path,
    );
    if (workKey.isEmpty) continue;
    final rel = CrossPlatformMediaIdentity.resolveRelativeTrackPath(
      trackPath: path,
      groupKey: groupKey,
      isSingle: isSingle,
      remoteMetadata: remoteMetadata,
    );
    if (rel.isEmpty) continue;
    final identity = CrossPlatformTrackIdentity(
      workKey: workKey,
      relativePath: rel,
      stemPath: CrossPlatformMediaIdentity.stripExtensionPosix(rel),
    );
    candidates.add(
      _LocalTrackSyncCandidate(
        path: path,
        displayName: row['display_name'] as String? ?? '',
        groupKey: groupKey,
        identity: identity,
        positionMs: (row['last_played_position_ms'] as num?)?.toInt() ?? 0,
        lastPlayedAtMs: (row['last_played_at_ms'] as num?)?.toInt(),
        isFavorite: ((row['is_favorite'] as num?)?.toInt() ?? 0) != 0,
        favoriteUpdatedAtMs:
            (row['favorite_updated_at_ms'] as num?)?.toInt() ?? 0,
      ),
    );
  }
  return _LocalTrackIdentityIndex(candidates);
}

CrossPlatformTrackIdentity? _resolveIdentityForLabelTrackKey(
  String trackKey, [
  _LocalTrackIdentityIndex? localIndex,
]) {
  final direct =
      localIndex?.byNormalizedPath[PathMatcher.equivalenceKey(trackKey)];
  if (direct != null) return direct;
  if (trackKey.startsWith('asmr.one:')) {
    final rest = trackKey.substring('asmr.one:'.length);
    final sep = rest.indexOf(':');
    if (sep > 0 && sep + 1 < rest.length) {
      final sourceId = rest.substring(0, sep);
      final rel = rest.substring(sep + 1);
      final rj = CrossPlatformMediaIdentity.normalizeRjCode(sourceId);
      return CrossPlatformMediaIdentity.fromWorkAndRelativePath(
        workKey: rj != null ? 'rj:$rj' : 'asmr-key:$sourceId',
        relativePath: rel,
      );
    }
  }
  final doubleColon = trackKey.indexOf('::');
  if (doubleColon > 0 &&
      (trackKey.startsWith('rj:') ||
          trackKey.startsWith('asmr:') ||
          trackKey.startsWith('asmr-key:') ||
          trackKey.startsWith('work:'))) {
    return CrossPlatformMediaIdentity.fromWorkAndRelativePath(
      workKey: trackKey.substring(0, doubleColon),
      relativePath: trackKey.substring(doubleColon + 2),
    );
  }
  final rjInKey = CrossPlatformMediaIdentity.normalizeRjCode(trackKey);
  if (rjInKey != null) {
    final normalized = trackKey.replaceAll('\\', '/');
    final rjMatch = RegExp(r'RJ\d{6,}', caseSensitive: false).firstMatch(
      normalized,
    );
    if (rjMatch != null) {
      final slashAfterWork = normalized.indexOf('/', rjMatch.end);
      if (slashAfterWork >= 0 && slashAfterWork + 1 < normalized.length) {
        return CrossPlatformMediaIdentity.fromWorkAndRelativePath(
          workKey: 'rj:$rjInKey',
          relativePath: normalized.substring(slashAfterWork + 1),
        );
      }
    }
  }
  return null;
}

Future<Map<String, Map<String, int>>> _snapshotDayLedgerInTxn(
  Transaction txn,
  String localDeviceId,
) async {
  final totalRows = await txn.query('listening_days');
  final ledgerRows = await txn.query('sync_listening_day_ledger');
  final byDevice = <String, Map<String, int>>{};
  final peerSumByDate = <String, int>{};

  for (final row in ledgerRows) {
    final dev = row['device_id'] as String;
    final date = row['date'] as String;
    final ms = (row['milliseconds'] as num).toInt();
    byDevice.putIfAbsent(dev, () => <String, int>{})[date] = ms;
    if (dev != localDeviceId) {
      peerSumByDate[date] = (peerSumByDate[date] ?? 0) + ms;
    }
  }

  final ownMap = byDevice.putIfAbsent(localDeviceId, () => <String, int>{});
  final batch = txn.batch();
  var changed = false;
  for (final row in totalRows) {
    final date = row['date'] as String;
    final totalMs = (row['milliseconds'] as num).toInt();
    final ownMs = totalMs - (peerSumByDate[date] ?? 0);
    final prevOwn = ownMap[date] ?? 0;
    if (ownMs > prevOwn) {
      ownMap[date] = ownMs;
      batch.insert(
        'sync_listening_day_ledger',
        <String, Object?>{
          'device_id': localDeviceId,
          'date': date,
          'milliseconds': ownMs,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      changed = true;
    }
  }
  if (changed) await batch.commit(noResult: true);
  return byDevice;
}

Future<Map<String, Map<String, Map<String, int>>>> _snapshotWorkDayLedgerInTxn(
  Transaction txn,
  String localDeviceId,
) async {
  final totalRows = await txn.query('listening_work_days');
  final ledgerRows = await txn.query('sync_listening_work_ledger');
  final byDevice = <String, Map<String, Map<String, int>>>{};
  final peerSumByDateWork = <String, Map<String, int>>{};

  for (final row in ledgerRows) {
    final dev = row['device_id'] as String;
    final date = row['date'] as String;
    final wk = row['work_key'] as String;
    final ms = (row['milliseconds'] as num).toInt();
    byDevice
        .putIfAbsent(dev, () => <String, Map<String, int>>{})
        .putIfAbsent(date, () => <String, int>{})[wk] = ms;
    if (dev != localDeviceId) {
      final dateMap = peerSumByDateWork.putIfAbsent(
        date,
        () => <String, int>{},
      );
      dateMap[wk] = (dateMap[wk] ?? 0) + ms;
    }
  }

  final ownDates = byDevice.putIfAbsent(
    localDeviceId,
    () => <String, Map<String, int>>{},
  );
  final batch = txn.batch();
  var changed = false;
  for (final row in totalRows) {
    final date = row['date'] as String;
    final wk = row['work_key'] as String;
    // Only sync portable work keys (rj:* or asmr:*); skip platform-local paths.
    if (!wk.startsWith('rj:') && !wk.startsWith('asmr:')) continue;
    final totalMs = (row['milliseconds'] as num).toInt();
    final peerMs = peerSumByDateWork[date]?[wk] ?? 0;
    final ownMs = totalMs - peerMs;
    final ownWorks = ownDates.putIfAbsent(date, () => <String, int>{});
    final prevOwn = ownWorks[wk] ?? 0;
    if (ownMs > prevOwn) {
      ownWorks[wk] = ownMs;
      batch.insert(
        'sync_listening_work_ledger',
        <String, Object?>{
          'device_id': localDeviceId,
          'date': date,
          'work_key': wk,
          'milliseconds': ownMs,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      changed = true;
    }
  }
  if (changed) await batch.commit(noResult: true);
  return byDevice;
}

PersistedSyncTrackRow _syncTrackRowFromDb(Map<String, Object?> row) =>
    PersistedSyncTrackRow(
      syncKey: row['sync_key'] as String,
      workKey: row['work_key'] as String,
      relativePath: row['relative_path'] as String,
      stemKey: row['stem_key'] as String,
      positionMs: (row['position_ms'] as num?)?.toInt() ?? 0,
      lastPlayedAtMs: (row['last_played_at_ms'] as num?)?.toInt(),
      isFavorite: ((row['is_favorite'] as num?)?.toInt() ?? 0) != 0,
      favoriteUpdatedAtMs:
          (row['favorite_updated_at_ms'] as num?)?.toInt() ?? 0,
      updatedAtMs: (row['updated_at_ms'] as num?)?.toInt() ?? 0,
    );

Map<String, Object?> _syncTrackRowToDb(PersistedSyncTrackRow row) =>
    <String, Object?>{
      'sync_key': row.syncKey,
      'work_key': row.workKey,
      'relative_path': row.relativePath,
      'stem_key': row.stemKey,
      'position_ms': row.positionMs,
      'last_played_at_ms': row.lastPlayedAtMs,
      'is_favorite': row.isFavorite ? 1 : 0,
      'favorite_updated_at_ms': row.favoriteUpdatedAtMs,
      'updated_at_ms': row.updatedAtMs,
    };

PersistedSyncWorkRow _syncWorkRowFromDb(Map<String, Object?> row) {
  List<String> decodeList(Object? raw) {
    if (raw is! String || raw.isEmpty) return const <String>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList(growable: false);
      }
    } on Object {
      // Ignore malformed legacy list JSON.
    }
    return const <String>[];
  }

  return PersistedSyncWorkRow(
    workKey: row['work_key'] as String,
    rjCode: row['rj_code'] as String? ?? '',
    workTitle: row['work_title'] as String? ?? '',
    circleName: row['circle_name'] as String? ?? '',
    voiceActors: decodeList(row['voice_actors_json']),
    tags: decodeList(row['tags_json']),
    releaseDateMs: (row['release_date_ms'] as num?)?.toInt(),
    salesCount: (row['sales_count'] as num?)?.toInt(),
    rating: (row['rating'] as num?)?.toDouble(),
    detailUpdatedAtMs: (row['detail_updated_at_ms'] as num?)?.toInt() ?? 0,
    listenStatus: row['listen_status'] as String?,
    userRating: (row['user_rating'] as num?)?.toInt(),
    reviewText: row['review_text'] as String? ?? '',
    reviewUpdatedAtMs: (row['review_updated_at_ms'] as num?)?.toInt() ?? 0,
  );
}

Map<String, Object?> _syncWorkRowToDb(PersistedSyncWorkRow row) =>
    <String, Object?>{
      'work_key': row.workKey,
      'rj_code': row.rjCode,
      'work_title': row.workTitle,
      'circle_name': row.circleName,
      'voice_actors_json': jsonEncode(row.voiceActors),
      'tags_json': jsonEncode(row.tags),
      'release_date_ms': row.releaseDateMs,
      'sales_count': row.salesCount,
      'rating': row.rating,
      'detail_updated_at_ms': row.detailUpdatedAtMs,
      'listen_status': row.listenStatus,
      'user_rating': row.userRating,
      'review_text': row.reviewText,
      'review_updated_at_ms': row.reviewUpdatedAtMs,
    };

PersistedSyncWorkRow _mergeSyncWorkRows(
  PersistedSyncWorkRow current,
  PersistedSyncWorkRow incoming,
) {
  final takeDetail = incoming.detailUpdatedAtMs > current.detailUpdatedAtMs;
  final takeReview = incoming.reviewUpdatedAtMs > current.reviewUpdatedAtMs;
  return PersistedSyncWorkRow(
    workKey: current.workKey,
    rjCode: incoming.rjCode.isNotEmpty ? incoming.rjCode : current.rjCode,
    workTitle: takeDetail ? incoming.workTitle : current.workTitle,
    circleName: takeDetail ? incoming.circleName : current.circleName,
    voiceActors: takeDetail ? incoming.voiceActors : current.voiceActors,
    tags: takeDetail ? incoming.tags : current.tags,
    releaseDateMs: takeDetail ? incoming.releaseDateMs : current.releaseDateMs,
    salesCount: takeDetail ? incoming.salesCount : current.salesCount,
    rating: takeDetail ? incoming.rating : current.rating,
    detailUpdatedAtMs: takeDetail
        ? incoming.detailUpdatedAtMs
        : current.detailUpdatedAtMs,
    listenStatus: takeReview ? incoming.listenStatus : current.listenStatus,
    userRating: takeReview ? incoming.userRating : current.userRating,
    reviewText: takeReview ? incoming.reviewText : current.reviewText,
    reviewUpdatedAtMs: takeReview
        ? incoming.reviewUpdatedAtMs
        : current.reviewUpdatedAtMs,
  );
}

Future<Map<String, PersistedSyncWorkRow>> _collectSyncWorkStatesInTxn(
  DatabaseExecutor txn,
) async {
  final map = <String, PersistedSyncWorkRow>{};
  final storedRows = await txn.query('sync_work_states');
  for (final row in storedRows) {
    final parsed = _syncWorkRowFromDb(row);
    map[parsed.workKey] = parsed;
  }

  final detailTargetRows = await txn.query(
    'audio_details',
    columns: const ['target_type', 'target_path', 'rj_code'],
    where: "rj_code != ''",
  );
  if (detailTargetRows.isEmpty) return map;

  final targets = <(String, String)>[
    for (final r in detailTargetRows)
      (r['target_type'] as String, r['target_path'] as String),
  ];
  final records = await _loadAudioDetailRecords(txn, targets);
  for (final rec in records) {
    final rj = CrossPlatformMediaIdentity.normalizeRjCode(rec.rjCode);
    if (rj == null) continue;
    final workKey = 'rj:$rj';
    final hasMetadata =
        rec.workTitle.trim().isNotEmpty ||
        rec.circleName.trim().isNotEmpty ||
        rec.voiceActors.isNotEmpty ||
        rec.tags.isNotEmpty ||
        rec.releaseDate != null ||
        rec.salesCount != null ||
        rec.rating != null;
    final detailTs = hasMetadata
        ? (rec.updatedAt?.millisecondsSinceEpoch ??
              rec.createdAt?.millisecondsSinceEpoch ??
              1)
        : 0;
    final reviewTs = rec.reviewUpdatedAt?.millisecondsSinceEpoch ?? 0;
    if (detailTs <= 0 && reviewTs <= 0) continue;

    final candidate = PersistedSyncWorkRow(
      workKey: workKey,
      rjCode: rj,
      workTitle: rec.workTitle,
      circleName: rec.circleName,
      voiceActors: rec.voiceActors,
      tags: rec.tags,
      releaseDateMs: rec.releaseDate?.millisecondsSinceEpoch,
      salesCount: rec.salesCount,
      rating: rec.rating,
      detailUpdatedAtMs: detailTs,
      listenStatus: rec.listenStatus,
      userRating: rec.userRating,
      reviewText: rec.reviewText,
      reviewUpdatedAtMs: reviewTs,
    );
    final existing = map[workKey];
    map[workKey] = existing == null
        ? candidate
        : _mergeSyncWorkRows(existing, candidate);
  }
  return map;
}

Future<({Set<(String, String)> updatedDetailTargets, int mergedCount})>
_mergeIncomingWorkStatesInTxn(
  DatabaseExecutor txn,
  Batch batch,
  List<PersistedSyncWorkRow> incomingList,
) async {
  final existingRows = await txn.query('sync_work_states');
  final existingByKey = <String, PersistedSyncWorkRow>{
    for (final r in existingRows)
      (r['work_key'] as String): _syncWorkRowFromDb(r),
  };

  final detailTargetRows = await txn.query(
    'audio_details',
    columns: const ['target_type', 'target_path', 'rj_code'],
    where: "rj_code != ''",
  );
  final targetsByRj = <String, List<(String, String)>>{};
  for (final r in detailTargetRows) {
    final rj = CrossPlatformMediaIdentity.normalizeRjCode(
      r['rj_code'] as String?,
    );
    if (rj == null) continue;
    targetsByRj
        .putIfAbsent(rj, () => <(String, String)>[])
        .add((r['target_type'] as String, r['target_path'] as String));
  }

  final matchedTargets = <(String, String)>{};
  for (final item in incomingList) {
    final rj =
        CrossPlatformMediaIdentity.normalizeRjCode(item.rjCode) ??
        CrossPlatformMediaIdentity.normalizeRjCode(item.workKey);
    if (rj != null && targetsByRj[rj] != null) {
      matchedTargets.addAll(targetsByRj[rj]!);
    }
  }
  final localRecords = matchedTargets.isEmpty
      ? const <AudioDetailRecord>[]
      : await _loadAudioDetailRecords(txn, matchedTargets);
  final localByTarget = <(String, String), AudioDetailRecord>{
    for (final rec in localRecords) (rec.targetType, rec.targetPath): rec,
  };

  final updatedDetailTargets = <(String, String)>{};
  var mergedCount = 0;

  for (final incoming in incomingList) {
    final rj =
        CrossPlatformMediaIdentity.normalizeRjCode(incoming.rjCode) ??
        CrossPlatformMediaIdentity.normalizeRjCode(incoming.workKey);
    final workKey = rj != null ? 'rj:$rj' : incoming.workKey.trim();
    if (workKey.isEmpty) continue;

    final normalizedIncoming = PersistedSyncWorkRow(
      workKey: workKey,
      rjCode: rj ?? incoming.rjCode,
      workTitle: incoming.workTitle,
      circleName: incoming.circleName,
      voiceActors: incoming.voiceActors,
      tags: incoming.tags,
      releaseDateMs: incoming.releaseDateMs,
      salesCount: incoming.salesCount,
      rating: incoming.rating,
      detailUpdatedAtMs: incoming.detailUpdatedAtMs,
      listenStatus: incoming.listenStatus,
      userRating: incoming.userRating,
      reviewText: incoming.reviewText,
      reviewUpdatedAtMs: incoming.reviewUpdatedAtMs,
    );

    final prev = existingByKey[workKey];
    final newerInTable =
        prev == null ||
        normalizedIncoming.detailUpdatedAtMs > prev.detailUpdatedAtMs ||
        normalizedIncoming.reviewUpdatedAtMs > prev.reviewUpdatedAtMs;
    if (newerInTable) {
      final merged = prev == null
          ? normalizedIncoming
          : _mergeSyncWorkRows(prev, normalizedIncoming);
      existingByKey[workKey] = merged;
      batch.insert(
        'sync_work_states',
        _syncWorkRowToDb(merged),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      mergedCount++;
    }

    if (rj == null) continue;
    final targets = targetsByRj[rj];
    if (targets == null) continue;
    for (final target in targets) {
      final local = localByTarget[target];
      if (local == null) continue;
      final localDetailTs =
          local.updatedAt?.millisecondsSinceEpoch ??
          local.createdAt?.millisecondsSinceEpoch ??
          0;
      final localReviewTs = local.reviewUpdatedAt?.millisecondsSinceEpoch ?? 0;
      final applyDetail = normalizedIncoming.detailUpdatedAtMs > localDetailTs;
      final applyReview = normalizedIncoming.reviewUpdatedAtMs > localReviewTs;
      if (!applyDetail && !applyReview) continue;

      final nextRecord = AudioDetailRecord(
        targetType: local.targetType,
        targetPath: local.targetPath,
        rjCode: local.rjCode,
        workTitle: applyDetail && normalizedIncoming.workTitle.isNotEmpty
            ? normalizedIncoming.workTitle
            : local.workTitle,
        circleName: applyDetail && normalizedIncoming.circleName.isNotEmpty
            ? normalizedIncoming.circleName
            : local.circleName,
        voiceActors: applyDetail && normalizedIncoming.voiceActors.isNotEmpty
            ? normalizedIncoming.voiceActors
            : local.voiceActors,
        tags: applyDetail && normalizedIncoming.tags.isNotEmpty
            ? normalizedIncoming.tags
            : local.tags,
        cardCoverPath: local.cardCoverPath,
        cardCoverSelected: local.cardCoverSelected,
        releaseDate: applyDetail && normalizedIncoming.releaseDateMs != null
            ? DateTime.fromMillisecondsSinceEpoch(
                normalizedIncoming.releaseDateMs!,
              )
            : local.releaseDate,
        duration: local.duration,
        salesCount: applyDetail
            ? (normalizedIncoming.salesCount ?? local.salesCount)
            : local.salesCount,
        rating: applyDetail
            ? (normalizedIncoming.rating ?? local.rating)
            : local.rating,
        listenStatus: applyReview
            ? normalizedIncoming.listenStatus
            : local.listenStatus,
        userRating: applyReview
            ? normalizedIncoming.userRating
            : local.userRating,
        reviewText: applyReview
            ? normalizedIncoming.reviewText
            : local.reviewText,
        reviewUpdatedAt: applyReview
            ? DateTime.fromMillisecondsSinceEpoch(
                normalizedIncoming.reviewUpdatedAtMs,
              )
            : local.reviewUpdatedAt,
        createdAt: local.createdAt,
        updatedAt: applyDetail
            ? DateTime.fromMillisecondsSinceEpoch(
                normalizedIncoming.detailUpdatedAtMs,
              )
            : local.updatedAt,
      );
      localByTarget[target] = nextRecord;
      _writeAudioDetailRecordToBatch(batch, nextRecord);
      updatedDetailTargets.add(target);
    }
  }

  return (
    updatedDetailTargets: updatedDetailTargets,
    mergedCount: mergedCount,
  );
}
