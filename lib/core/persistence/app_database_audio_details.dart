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
    if (normalized.isEmpty) return const <AudioDetailRecord>[];
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
  }) => deleteAudioDetailRecords([(targetType, targetPath)]);

  Future<void> deleteAudioDetailRecords(
    Iterable<(String, String)> targets,
  ) async {
    final pathsByType = <String, Set<String>>{};
    for (final (type, path) in targets) {
      pathsByType
          .putIfAbsent(type, () => <String>{})
          .add(PathMatcher.normalize(path));
    }
    if (pathsByType.isEmpty) return;
    await _runDatabaseWrite((db) async {
      final batch = db.batch();
      for (final entry in pathsByType.entries) {
        for (final chunk in _stringChunks(
          entry.value.toList(growable: false),
        )) {
          final placeholders = List.filled(chunk.length, '?').join(', ');
          final args = <Object?>[entry.key, ...chunk];
          for (final table in const [
            'audio_detail_voice_actors',
            'audio_detail_tags',
            'audio_details',
          ]) {
            batch.delete(
              table,
              where: 'target_type = ? AND target_path IN ($placeholders)',
              whereArgs: args,
            );
          }
        }
      }
      await batch.commit(noResult: true);
    });
  }

  Future<List<TimeSegmentLabelRecord>> loadTimeSegmentLabelsForTarget(
    String targetPath, {
    required bool isFolder,
  }) => _runDatabaseRead((db) async {
    final rows = await _queryTimeSegmentLabelRowsForTarget(
      db,
      targetPath,
      isFolder: isFolder,
      orderBy: 'start_ms ASC, created_at_ms ASC',
    );
    return rows.map(TimeSegmentLabelRecord.fromRow).toList(growable: false);
  });

  Future<void> importAudioDetails(
    Iterable<AudioDetailRecord> details,
    Iterable<TimeSegmentLabelRecord> labels,
  ) => _runDatabaseWrite(
    (db) => db.transaction((transaction) async {
      final batch = transaction.batch();
      for (final detail in details) {
        _writeAudioDetailRecordToBatch(batch, detail);
      }
      await batch.commit(noResult: true);
      final labelList = [
        for (final label in labels)
          (
            label: label,
            suffix:
                '@${base64Url.encode(utf8.encode(PathMatcher.equivalenceKey(label.trackKey)))}',
          ),
      ];
      if (labelList.isEmpty) return;
      final existingById = <String, ({String trackKey, int updatedAtMs})?>{};
      Future<void> loadConflicts(List<String> ids) async {
        final placeholders = List.filled(ids.length, '?').join(', ');
        final rows = await transaction.query(
          'time_segment_labels',
          columns: const ['id', 'track_key', 'updated_at_ms'],
          where: 'id IN ($placeholders)',
          whereArgs: ids,
        );
        for (final id in ids) {
          existingById[id] = null;
        }
        for (final row in rows) {
          existingById[row['id'] as String] = (
            trackKey: row['track_key'] as String,
            updatedAtMs: (row['updated_at_ms'] as num).toInt(),
          );
        }
      }

      final ids = {
        for (final item in labelList) ...[
          item.label.id,
          '${item.label.id}${item.suffix}',
        ],
      }.toList(growable: false);
      for (
        var offset = 0;
        offset < ids.length;
        offset += _sqliteInClauseBatchSize
      ) {
        final end = (offset + _sqliteInClauseBatchSize).clamp(0, ids.length);
        await loadConflicts(ids.sublist(offset, end));
      }
      final labelBatch = transaction.batch();
      var hasLabelWrites = false;
      for (final (:label, :suffix) in labelList) {
        var id = label.id;
        var existing = existingById[id];
        // A copied work keeps its remapped ID even after the original label
        // has been deleted from the source work.
        if (existing == null) {
          final mappedId = '$id$suffix';
          final mappedExisting = existingById[mappedId];
          if (mappedExisting != null) {
            id = mappedId;
            existing = mappedExisting;
          }
        }
        while (existing != null &&
            !PathMatcher.equalsNormalized(existing.trackKey, label.trackKey)) {
          id += suffix;
          // Imported IDs may themselves contain an earlier collision suffix.
          if (!existingById.containsKey(id)) await loadConflicts([id]);
          existing = existingById[id];
        }
        if (existing != null && existing.updatedAtMs >= label.updatedAtMs) {
          continue;
        }
        existingById[id] = (
          trackKey: label.trackKey,
          updatedAtMs: label.updatedAtMs,
        );
        labelBatch.insert('time_segment_labels', {
          ..._timeSegmentLabelRow(label),
          'id': id,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        hasLabelWrites = true;
      }
      if (hasLabelWrites) {
        await labelBatch.commit(noResult: true);
      }
    }),
  );

  // ---- Time segment labels ----

  Future<List<TimeSegmentLabelRecord>> loadTimeSegmentLabels(
    String trackKey,
  ) async => (await loadTimeSegmentLabelsForTarget(trackKey, isFolder: false))
      .map(
        (record) => TimeSegmentLabelRecord.fromRow({
          ...record.toRow(),
          'track_key': trackKey,
        }),
      )
      .toList(growable: false);

  Future<void> upsertTimeSegmentLabel(TimeSegmentLabelRecord label) async {
    await _runDatabaseWrite(
      (db) => db
          .insert(
            'time_segment_labels',
            _timeSegmentLabelRow(label),
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
        {
          'track_key': newTrackKey,
          'track_match_key': PathMatcher.equivalenceKey(newTrackKey),
        },
        where: 'track_key = ?',
        whereArgs: [oldTrackKey],
      );
    });
  }

  Future<void> retargetTimeSegmentLabelsWithinPath({
    required String oldRoot,
    required String newRoot,
  }) => _runDatabaseWrite(
    (db) => db.transaction((txn) async {
      final rows = await _queryTimeSegmentLabelRowsForTarget(
        txn,
        oldRoot,
        isFolder: true,
        columns: const ['id', 'track_key'],
      );
      final batch = txn.batch();
      for (final row in rows) {
        final id = row['id'] as String;
        final trackKey = row['track_key'] as String;
        final nextTrackKey = PathMatcher.replaceWithinOrEqual(
          trackKey,
          oldRoot,
          newRoot,
        );
        if (nextTrackKey == trackKey) continue;
        batch.update(
          'time_segment_labels',
          {
            'track_key': nextTrackKey,
            'track_match_key': PathMatcher.equivalenceKey(nextTrackKey),
          },
          where: 'id = ?',
          whereArgs: [id],
        );
      }
      await batch.commit(noResult: true);
    }),
  );
}

Future<Iterable<Map<String, Object?>>> _queryTimeSegmentLabelRowsForTarget(
  DatabaseExecutor db,
  String targetPath, {
  required bool isFolder,
  List<String>? columns,
  String? orderBy,
}) async {
  final key = PathMatcher.equivalenceKey(targetPath);
  final bounds = isFolder ? _descendantMatchKeyBounds(key) : null;
  final rows = await db.query(
    'time_segment_labels',
    columns: columns,
    where: bounds != null
        ? 'track_match_key = ? OR (track_match_key >= ? AND track_match_key < ?)'
        : 'track_match_key = ?',
    whereArgs: [
      key,
      if (bounds != null) ...[bounds.$1, bounds.$2],
    ],
    orderBy: orderBy,
  );
  return rows.where(
    (row) => isFolder
        ? PathMatcher.isWithinOrEqual(row['track_key'] as String, targetPath)
        : PathMatcher.equalsNormalized(row['track_key'] as String, targetPath),
  );
}

(String, String)? _descendantMatchKeyBounds(String key) {
  if (key.startsWith('remote:')) return null;
  // Binary prefix bounds keep '%' literal. SAF volume roots join the child
  // immediately after ':'.
  final volumeRoot = key.startsWith('content:') && key.endsWith(':');
  final prefix = key.endsWith('/') || volumeRoot ? key : '$key/';
  return (
    prefix,
    '${prefix.substring(0, prefix.length - 1)}${volumeRoot ? ';' : '0'}',
  );
}

Map<String, Object?> _timeSegmentLabelRow(TimeSegmentLabelRecord label) => {
  ...label.toRow(),
  'track_match_key': PathMatcher.equivalenceKey(label.trackKey),
};

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

  final matchedPathsByType = <String, List<String>>{};
  for (final row in parentRows) {
    matchedPathsByType
        .putIfAbsent(row['target_type'] as String, () => <String>[])
        .add(row['target_path'] as String);
  }

  final valuesByTable = <String, Map<String, List<String>>>{};
  for (final (table, valueColumn) in [
    ('audio_detail_voice_actors', 'voice_actor'),
    ('audio_detail_tags', 'tag'),
  ]) {
    final byTarget = <String, List<String>>{};
    for (final entry in matchedPathsByType.entries) {
      final paths = entry.value;
      for (
        var start = 0;
        start < paths.length;
        start += _sqliteInClauseBatchSize
      ) {
        final end = (start + _sqliteInClauseBatchSize).clamp(0, paths.length);
        final chunk = paths.sublist(start, end);
        final placeholders = List.filled(chunk.length, '?').join(', ');
        final rows = await db.query(
          table,
          columns: ['target_path', valueColumn],
          where: 'target_type = ? AND target_path IN ($placeholders)',
          whereArgs: [entry.key, ...chunk],
          orderBy: 'target_path, sort_order',
        );
        for (final row in rows) {
          final key = '${entry.key}\x1F${row['target_path']}';
          byTarget
              .putIfAbsent(key, () => <String>[])
              .add(row[valueColumn]! as String);
        }
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
