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
      await db.delete(
        'audio_details',
        where: 'target_type = ? AND target_path = ?',
        whereArgs: [target.targetType.dbValue, normalizedTargetPath],
      );
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
          'audio_details',
          where: 'target_type = ? AND target_path = ?',
          whereArgs: [target.targetType.dbValue, target.targetPath],
        );
      }
      await batch.commit(noResult: true);
    });
  }

  // ---- Time segment labels ----

  Future<List<TimeSegmentLabel>> loadTimeSegmentLabels(String trackKey) async {
    return _runDatabaseRead((db) async {
      final rows = await db.query(
        'time_segment_labels',
        where: 'track_key = ?',
        whereArgs: [trackKey],
        orderBy: 'start_ms ASC, created_at_ms ASC',
      );
      return rows.map(TimeSegmentLabel.fromRow).toList(growable: false);
    });
  }

  Future<void> upsertTimeSegmentLabel(TimeSegmentLabel label) async {
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
