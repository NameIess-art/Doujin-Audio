part of 'app_database.dart';

extension AppDatabaseAudioDetails on AppDatabase {
  Future<AudioDetailRecord?> loadAudioDetailRecord({
    required String targetType,
    required String targetPath,
  }) async {
    return _runDatabaseRead((db) async {
      final records = await _loadAudioDetailRecords(db, <(String, String)>[
        (targetType, PathMatcher.normalize(targetPath)),
      ]);
      return records.isEmpty ? null : records.first;
    });
  }

  Future<List<AudioDetailRecord>> loadAudioDetailRecords(
    Iterable<(String, String)> targets,
  ) async {
    final normalized = targets
        .map((target) => (target.$1, PathMatcher.normalize(target.$2)))
        .toList(growable: false);
    return _runDatabaseRead((db) => _loadAudioDetailRecords(db, normalized));
  }

  Future<void> upsertAudioDetailRecord(AudioDetailRecord detail) async {
    await _runDatabaseWrite((db) async {
      await db.transaction((transaction) async {
        final batch = transaction.batch();
        _writeAudioDetailRecordToBatch(batch, detail);
        await batch.commit(noResult: true);
      });
    });
  }

  Future<void> upsertAudioDetailRecords(
    Iterable<AudioDetailRecord> details,
  ) async {
    final values = details.toList(growable: false);
    if (values.isEmpty) return;
    await _runDatabaseWrite((db) async {
      await db.transaction((transaction) async {
        final batch = transaction.batch();
        for (final detail in values) {
          _writeAudioDetailRecordToBatch(batch, detail);
        }
        await batch.commit(noResult: true);
      });
    });
  }

  Future<void> deleteAudioDetailRecord({
    required String targetType,
    required String targetPath,
  }) async {
    await _runDatabaseWrite((db) async {
      await db.transaction((transaction) async {
        await _deleteAudioDetailRows(
          transaction,
          targetType,
          PathMatcher.normalize(targetPath),
        );
      });
    });
  }

  Future<void> deleteAudioDetailRecords(
    Iterable<(String, String)> targets,
  ) async {
    final uniqueTargets = <String, (String, String)>{};
    for (final target in targets) {
      final normalizedPath = PathMatcher.normalize(target.$2);
      uniqueTargets['${target.$1}\x1F$normalizedPath'] = (
        target.$1,
        normalizedPath,
      );
    }
    if (uniqueTargets.isEmpty) return;
    await _runDatabaseWrite((db) async {
      await db.transaction((transaction) async {
        for (final target in uniqueTargets.values) {
          await _deleteAudioDetailRows(transaction, target.$1, target.$2);
        }
      });
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

Future<List<AudioDetailRecord>> _loadAudioDetailRecords(
  DatabaseExecutor db,
  Iterable<(String, String)> targets,
) async {
  final pathsByType = <String, Set<String>>{};
  for (final target in targets) {
    pathsByType.putIfAbsent(target.$1, () => <String>{}).add(target.$2);
  }
  if (pathsByType.isEmpty) return const <AudioDetailRecord>[];

  final parentRows = <Map<String, Object?>>[];
  for (final entry in pathsByType.entries) {
    final paths = entry.value.toList(growable: false);
    for (
      var start = 0;
      start < paths.length;
      start += _sqliteInClauseBatchSize
    ) {
      final end = (start + _sqliteInClauseBatchSize).clamp(0, paths.length);
      final chunk = paths.sublist(start, end);
      final placeholders = List.filled(chunk.length, '?').join(', ');
      parentRows.addAll(
        await db.query(
          'audio_details',
          where: 'target_type = ? AND target_path IN ($placeholders)',
          whereArgs: <Object?>[entry.key, ...chunk],
        ),
      );
    }
  }
  if (parentRows.isEmpty) return const <AudioDetailRecord>[];

  final valuesByTable = <String, Map<String, List<String>>>{};
  for (final table in <String>[
    'audio_detail_voice_actors',
    'audio_detail_tags',
  ]) {
    final byTarget = <String, List<String>>{};
    for (
      var start = 0;
      start < parentRows.length;
      start += _sqliteInClauseBatchSize ~/ 2
    ) {
      final end = (start + _sqliteInClauseBatchSize ~/ 2).clamp(
        0,
        parentRows.length,
      );
      final chunk = parentRows.sublist(start, end);
      final clauses = List.filled(
        chunk.length,
        '(target_type = ? AND target_path = ?)',
      ).join(' OR ');
      final args = <Object?>[];
      for (final row in chunk) {
        args
          ..add(row['target_type'])
          ..add(row['target_path']);
      }
      final rows = await db.query(
        table,
        where: clauses,
        whereArgs: args,
        orderBy: 'target_type, target_path, sort_order',
      );
      final valueColumn = table == 'audio_detail_tags' ? 'tag' : 'voice_actor';
      for (final row in rows) {
        final key = '${row['target_type']}\x1F${row['target_path']}';
        byTarget
            .putIfAbsent(key, () => <String>[])
            .add(row[valueColumn]! as String);
      }
    }
    valuesByTable[table] = byTarget;
  }

  return parentRows
      .map((row) {
        final key = '${row['target_type']}\x1F${row['target_path']}';
        final durationMs = (row['duration_ms'] as num?)?.toInt() ?? 0;
        return AudioDetailRecord(
          targetType: row['target_type']! as String,
          targetPath: row['target_path']! as String,
          rjCode: row['rj_code'] as String? ?? '',
          workTitle: row['work_title'] as String? ?? '',
          circleName: row['circle_name'] as String? ?? '',
          voiceActors:
              valuesByTable['audio_detail_voice_actors']?[key] ??
              const <String>[],
          tags: valuesByTable['audio_detail_tags']?[key] ?? const <String>[],
          cardCoverPath: row['card_cover_path'] as String?,
          cardCoverSelected: (row['card_cover_selected'] as num?)?.toInt() == 1,
          releaseDate: _dateTimeFromMs(row['release_date_ms']),
          duration: durationMs <= 0 ? null : Duration(milliseconds: durationMs),
          salesCount: (row['sales_count'] as num?)?.toInt(),
          rating: (row['rating'] as num?)?.toDouble(),
          createdAt: _dateTimeFromMs(row['created_at_ms']),
          updatedAt: _dateTimeFromMs(row['updated_at_ms']),
        );
      })
      .toList(growable: false);
}

void _writeAudioDetailRecordToBatch(Batch batch, AudioDetailRecord detail) {
  final targetPath = PathMatcher.normalize(detail.targetPath);
  batch.insert('audio_details', <String, Object?>{
    'target_type': detail.targetType,
    'target_path': targetPath,
    'rj_code': detail.rjCode,
    'work_title': detail.workTitle,
    'circle_name': detail.circleName,
    'card_cover_path': detail.cardCoverPath,
    'card_cover_selected': detail.cardCoverSelected ? 1 : 0,
    'release_date_ms': detail.releaseDate?.millisecondsSinceEpoch ?? 0,
    'duration_ms': detail.duration?.inMilliseconds ?? 0,
    'sales_count': detail.salesCount,
    'rating': detail.rating,
    'created_at_ms': detail.createdAt?.millisecondsSinceEpoch ?? 0,
    'updated_at_ms': detail.updatedAt?.millisecondsSinceEpoch ?? 0,
  }, conflictAlgorithm: ConflictAlgorithm.replace);
  for (final table in <String>[
    'audio_detail_voice_actors',
    'audio_detail_tags',
  ]) {
    batch.delete(
      table,
      where: 'target_type = ? AND target_path = ?',
      whereArgs: <Object?>[detail.targetType, targetPath],
    );
  }
  for (var index = 0; index < detail.voiceActors.length; index++) {
    batch.insert('audio_detail_voice_actors', <String, Object?>{
      'target_type': detail.targetType,
      'target_path': targetPath,
      'voice_actor': detail.voiceActors[index],
      'sort_order': index,
    });
  }
  for (var index = 0; index < detail.tags.length; index++) {
    batch.insert('audio_detail_tags', <String, Object?>{
      'target_type': detail.targetType,
      'target_path': targetPath,
      'tag': detail.tags[index],
      'sort_order': index,
    });
  }
}

Future<void> _deleteAudioDetailRows(
  DatabaseExecutor db,
  String targetType,
  String targetPath,
) async {
  for (final table in <String>[
    'audio_detail_voice_actors',
    'audio_detail_tags',
    'audio_details',
  ]) {
    await db.delete(
      table,
      where: 'target_type = ? AND target_path = ?',
      whereArgs: <Object?>[targetType, targetPath],
    );
  }
}
