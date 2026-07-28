part of 'app_database.dart';

extension AppDatabaseAudioDetails on AppDatabase {
  Future<AudioDetail?> loadAudioDetail(AudioDetailTarget target) async {
    return _runDatabaseRead((db) async {
      final normalizedTargetPath = PathMatcher.normalize(target.targetPath);
      final rows = await db.query(
        'audio_details',
        where: 'target_type = ? AND target_path = ?',
        whereArgs: [target.targetType.dbValue, normalizedTargetPath],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      return AudioDetail.fromRow(rows.first);
    });
  }

  Future<List<AudioDetail>> loadAudioDetails(
    Iterable<AudioDetailTarget> targets,
  ) async {
    return _runDatabaseRead((db) async {
      final pathsByType = <String, Set<String>>{};
      for (final target in targets) {
        pathsByType
            .putIfAbsent(target.targetType.dbValue, () => <String>{})
            .add(PathMatcher.normalize(target.targetPath));
      }
      if (pathsByType.isEmpty) return const <AudioDetail>[];

      final details = <AudioDetail>[];
      for (final entry in pathsByType.entries) {
        final paths = entry.value.toList(growable: false);
        if (paths.isEmpty) continue;
        const chunkSize = 900;
        for (var start = 0; start < paths.length; start += chunkSize) {
          final end = (start + chunkSize).clamp(0, paths.length);
          final chunk = paths.sublist(start, end);
          final placeholders = List.filled(chunk.length, '?').join(', ');
          final rows = await db.query(
            'audio_details',
            where: 'target_type = ? AND target_path IN ($placeholders)',
            whereArgs: [entry.key, ...chunk],
          );
          details.addAll(rows.map(AudioDetail.fromRow));
        }
      }
      return details;
    });
  }

  Future<void> upsertAudioDetail(AudioDetail detail) async {
    await _runDatabaseWrite((db) async {
      final row = detail.toRow();
      row['target_path'] = PathMatcher.normalize(detail.target.targetPath);
      await db.insert(
        'audio_details',
        row,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  Future<AudioDetailBackupSyncRecord> upsertAudioDetailAndEnqueueBackupSync(
    AudioDetail detail,
  ) async {
    late AudioDetailBackupSyncRecord task;
    await _runDatabaseWrite((db) async {
      await db.transaction((transaction) async {
        final normalizedPath = PathMatcher.normalize(detail.target.targetPath);
        final row = detail.toRow()..['target_path'] = normalizedPath;
        await transaction.insert(
          'audio_details',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        final existing = await transaction.query(
          'audio_detail_backup_sync',
          columns: const <String>['generation'],
          where: 'target_type = ? AND target_path = ?',
          whereArgs: <Object?>[
            detail.target.targetType.dbValue,
            normalizedPath,
          ],
          limit: 1,
        );
        final generation = existing.isEmpty
            ? 1
            : (existing.single['generation']! as int) + 1;
        task = AudioDetailBackupSyncRecord(
          targetType: detail.target.targetType.dbValue,
          targetPath: normalizedPath,
          generation: generation,
          attemptCount: 0,
          nextAttemptAtMs: 0,
        );
        await transaction.insert('audio_detail_backup_sync', <String, Object?>{
          'target_type': task.targetType,
          'target_path': task.targetPath,
          'generation': generation,
          'attempt_count': 0,
          'next_attempt_at_ms': 0,
          'last_error': null,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      });
    });
    return task;
  }

  Future<AudioDetailBackupSyncRecord> enqueueAudioDetailBackupSync(
    AudioDetailTarget target,
  ) async {
    late AudioDetailBackupSyncRecord task;
    await _runDatabaseWrite((db) async {
      final normalizedPath = PathMatcher.normalize(target.targetPath);
      await db.transaction((transaction) async {
        final existing = await transaction.query(
          'audio_detail_backup_sync',
          columns: const <String>['generation'],
          where: 'target_type = ? AND target_path = ?',
          whereArgs: <Object?>[target.targetType.dbValue, normalizedPath],
          limit: 1,
        );
        final generation = existing.isEmpty
            ? 1
            : (existing.single['generation']! as int) + 1;
        task = AudioDetailBackupSyncRecord(
          targetType: target.targetType.dbValue,
          targetPath: normalizedPath,
          generation: generation,
          attemptCount: 0,
          nextAttemptAtMs: 0,
        );
        await transaction.insert('audio_detail_backup_sync', <String, Object?>{
          'target_type': target.targetType.dbValue,
          'target_path': normalizedPath,
          'generation': generation,
          'attempt_count': 0,
          'next_attempt_at_ms': 0,
          'last_error': null,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      });
    });
    return task;
  }

  Future<List<AudioDetailBackupSyncRecord>> loadDueAudioDetailBackupSyncTasks({
    required int nowMs,
    int limit = 100,
  }) {
    return _runDatabaseRead((db) async {
      final rows = await db.query(
        'audio_detail_backup_sync',
        where: 'next_attempt_at_ms <= ?',
        whereArgs: <Object?>[nowMs],
        orderBy: 'next_attempt_at_ms ASC, target_type ASC, target_path ASC',
        limit: limit,
      );
      return rows
          .map(AudioDetailBackupSyncRecord.fromRow)
          .toList(growable: false);
    });
  }

  Future<int?> loadNextAudioDetailBackupSyncAtMs() {
    return _runDatabaseRead((db) async {
      final rows = await db.rawQuery(
        'SELECT MIN(next_attempt_at_ms) AS next_attempt_at_ms '
        'FROM audio_detail_backup_sync',
      );
      return rows.single['next_attempt_at_ms'] as int?;
    });
  }

  Future<bool> deleteAudioDetailBackupSyncTask(
    AudioDetailTarget target, {
    required int generation,
  }) async {
    var deleted = 0;
    await _runDatabaseWrite((db) async {
      deleted = await db.delete(
        'audio_detail_backup_sync',
        where: 'target_type = ? AND target_path = ? AND generation = ?',
        whereArgs: <Object?>[
          target.targetType.dbValue,
          PathMatcher.normalize(target.targetPath),
          generation,
        ],
      );
    });
    return deleted > 0;
  }

  Future<bool> recordAudioDetailBackupSyncFailure(
    AudioDetailBackupSyncRecord task, {
    required int nextAttemptAtMs,
    required String error,
  }) async {
    var updated = 0;
    await _runDatabaseWrite((db) async {
      updated = await db.update(
        'audio_detail_backup_sync',
        <String, Object?>{
          'attempt_count': task.attemptCount + 1,
          'next_attempt_at_ms': nextAttemptAtMs,
          'last_error': error,
        },
        where: 'target_type = ? AND target_path = ? AND generation = ?',
        whereArgs: <Object?>[
          task.targetType,
          PathMatcher.normalize(task.targetPath),
          task.generation,
        ],
      );
    });
    return updated > 0;
  }

  Future<void> upsertAudioDetails(Iterable<AudioDetail> details) async {
    final values = details.toList(growable: false);
    if (values.isEmpty) return;
    await _runDatabaseWrite((db) async {
      final batch = db.batch();
      for (final detail in values) {
        final row = detail.toRow();
        row['target_path'] = PathMatcher.normalize(detail.target.targetPath);
        batch.insert(
          'audio_details',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> deleteAudioDetail(AudioDetailTarget target) async {
    await _runDatabaseWrite((db) async {
      final normalizedTargetPath = PathMatcher.normalize(target.targetPath);
      final batch = db.batch();
      batch.delete(
        'audio_detail_backup_sync',
        where: 'target_type = ? AND target_path = ?',
        whereArgs: [target.targetType.dbValue, normalizedTargetPath],
      );
      batch.delete(
        'audio_details',
        where: 'target_type = ? AND target_path = ?',
        whereArgs: [target.targetType.dbValue, normalizedTargetPath],
      );
      await batch.commit(noResult: true);
    });
  }

  Future<void> deleteAudioDetails(Iterable<AudioDetailTarget> targets) async {
    final uniqueTargets = <String, AudioDetailTarget>{};
    for (final target in targets) {
      final normalizedPath = PathMatcher.normalize(target.targetPath);
      uniqueTargets['${target.targetType.dbValue}\x1F$normalizedPath'] =
          AudioDetailTarget(
            targetType: target.targetType,
            targetPath: normalizedPath,
          );
    }
    if (uniqueTargets.isEmpty) return;
    await _runDatabaseWrite((db) async {
      final batch = db.batch();
      for (final target in uniqueTargets.values) {
        batch.delete(
          'audio_detail_backup_sync',
          where: 'target_type = ? AND target_path = ?',
          whereArgs: [target.targetType.dbValue, target.targetPath],
        );
        batch.delete(
          'audio_details',
          where: 'target_type = ? AND target_path = ?',
          whereArgs: [target.targetType.dbValue, target.targetPath],
        );
      }
      await batch.commit(noResult: true);
    });
  }

  // ---- Time segment labels ----

  Future<List<TimeSegmentLabelRecord>> loadTimeSegmentLabels(
    String trackKey,
  ) async {
    return _runDatabaseRead((db) async {
      final rows = await db.query(
        'time_segment_labels',
        where: 'track_key = ?',
        whereArgs: [trackKey],
        orderBy: 'start_ms ASC, created_at_ms ASC',
      );
      return rows.map(TimeSegmentLabelRecord.fromRow).toList(growable: false);
    });
  }

  Future<void> upsertTimeSegmentLabel(TimeSegmentLabelRecord label) async {
    await _runDatabaseWrite(
      (db) => db
          .insert(
            'time_segment_labels',
            label.toRow(),
            conflictAlgorithm: ConflictAlgorithm.replace,
          )
          .then((_) {}),
    );
  }

  Future<void> deleteTimeSegmentLabel(String id) async {
    await _runDatabaseWrite(
      (db) => db
          .delete('time_segment_labels', where: 'id = ?', whereArgs: [id])
          .then((_) {}),
    );
  }

  Future<void> retargetTimeSegmentLabels({
    required String oldTrackKey,
    required String newTrackKey,
  }) async {
    if (oldTrackKey == newTrackKey) return;
    await _runDatabaseWrite((db) async {
      await db.update(
        'time_segment_labels',
        {'track_key': newTrackKey},
        where: 'track_key = ?',
        whereArgs: [oldTrackKey],
      );
    });
  }

  Future<void> retargetTimeSegmentLabelsWithinPath({
    required String oldRoot,
    required String newRoot,
  }) async {
    await _runDatabaseWrite((db) async {
      final rows = await db.query('time_segment_labels');
      final batch = db.batch();
      for (final row in rows) {
        final id = row['id'] as String;
        final trackKey = row['track_key'] as String;
        if (!PathMatcher.isWithinOrEqual(trackKey, oldRoot)) continue;
        final nextTrackKey = PathMatcher.replaceWithinOrEqual(
          trackKey,
          oldRoot,
          newRoot,
        );
        if (nextTrackKey == trackKey) continue;
        batch.update(
          'time_segment_labels',
          {'track_key': nextTrackKey},
          where: 'id = ?',
          whereArgs: [id],
        );
      }
      await batch.commit(noResult: true);
    });
  }
}
