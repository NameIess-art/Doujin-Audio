part of 'app_database.dart';

extension AppDatabaseTracks on AppDatabase {
  // ---- Tracks ----

  Future<List<MusicTrack>> loadAllTracks() async {
    return _runDatabaseRead((db) async {
      final rows = await _queryFullTrackRows(db);
      final tagsByPath = await _loadTrackTags(db);
      return rows
          .map((row) => _trackFromRow(row, tagsByPath[row['path'] as String]))
          .toList();
    });
  }

  Future<List<MusicTrack>> loadTracksForRecommendations() async {
    final rows = await _runDatabaseRead((db) async {
      final tracks = await db.rawQuery('''
        SELECT
          t.path,
          t.display_name,
          t.group_key,
          t.group_title,
          t.group_subtitle,
          t.is_single,
          remote.remote_metadata_json
        FROM tracks t
        LEFT JOIN track_remote_metadata remote ON remote.path = t.path
      ''');
      final tags = await db.rawQuery(
        'SELECT path, tag FROM track_tags ORDER BY sort_order ASC',
      );
      return (tracks, tags);
    });
    // Recommendation metadata can contain large remote track trees. Decode and
    // freeze only the ranking inputs away from the UI isolate.
    return compute(_recommendationTracksFromRows, rows);
  }

  Future<List<MusicTrack>> loadTrackSummaries() async {
    return _runDatabaseRead((db) async {
      final rows = await db.query(
        'tracks',
        columns: [
          'path',
          'display_name',
          'group_key',
          'group_title',
          'group_subtitle',
          'is_single',
          'is_video',
          'duration_ms',
        ],
      );
      return rows.map((row) => _trackSummaryFromRow(row)).toList();
    });
  }

  Future<List<MusicTrack>> loadStartupTracks() async {
    final rows = await _runDatabaseRead(_queryStartupTrackRows);
    return compute(_startupTracksFromRows, rows);
  }

  Future<MusicTrack?> loadTrackDetail(String path) async {
    return _runDatabaseRead((db) async {
      final rows = await _queryFullTrackRows(db, path: path, limit: 1);
      if (rows.isEmpty) return null;
      final tagsByPath = await _loadTrackTags(db, paths: [path]);
      return _trackFromRow(rows.first, tagsByPath[path]);
    });
  }

  Future<void> saveAllTracks(List<MusicTrack> tracks) async {
    await _runDatabaseWrite((db) async {
      final batch = db.batch();
      batch.delete('track_tags');
      batch.delete('track_remote_metadata');
      batch.delete('track_assets');
      batch.delete('track_playback_state');
      batch.delete('track_scan_info');
      batch.delete('tracks');
      for (final track in tracks) {
        _writeTrackToBatch(batch, track);
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> insertTracks(List<MusicTrack> tracks) async {
    await upsertTracks(tracks);
  }

  /// Replaces a complete, authoritative record, including empty tags/metadata.
  /// A startup projection must use the field-scoped or catalog write methods.
  Future<void> upsertTracks(
    List<MusicTrack> tracks, {
    int? scanGeneration,
  }) async {
    if (tracks.isEmpty) return;
    await _runDatabaseWrite((db) async {
      // Keep messages small enough to encode between frames, while a failure
      // in a later chunk still rolls back every earlier chunk.
      await db.transaction((txn) async {
        await _upsertTrackChunks(txn, tracks, scanGeneration: scanGeneration);
      });
    });
  }

  Future<void> upsertCatalogTracks(
    List<MusicTrack> tracks, {
    int? scanGeneration,
  }) async {
    if (tracks.isEmpty) return;
    await _runDatabaseWrite(
      (db) => db.transaction((txn) async {
        await _upsertCatalogTrackChunks(
          txn,
          tracks,
          scanGeneration: scanGeneration,
        );
      }),
    );
  }

  /// Duration probes and native snapshots only fill an unknown duration.
  Future<void> updateTrackDurations(Map<String, Duration> durations) async {
    if (durations.isEmpty) return;
    await _runDatabaseWrite(
      (db) => db.transaction((txn) async {
        final batch = txn.batch();
        for (final entry in durations.entries) {
          batch.update(
            'tracks',
            {'duration_ms': entry.value.inMilliseconds},
            where: 'path = ? AND duration_ms <= 0',
            whereArgs: [entry.key],
          );
        }
        await batch.commit(noResult: true);
      }),
    );
  }

  Future<void> updateTrackManualCoverPaths(Map<String, String> paths) async {
    if (paths.isEmpty) return;
    await _runDatabaseWrite(
      (db) => db.transaction((txn) async {
        final batch = txn.batch();
        for (final entry in paths.entries) {
          batch.update(
            'track_assets',
            {'manual_cover_path': entry.value},
            where:
                'path = ? AND EXISTS (SELECT 1 FROM tracks WHERE tracks.path = track_assets.path)',
            whereArgs: [entry.key],
          );
        }
        await batch.commit(noResult: true);
      }),
    );
  }

  Future<void> updateTrackPlaybackHistory(List<MusicTrack> tracks) async {
    if (tracks.isEmpty) return;
    await _runDatabaseWrite(
      (db) => db.transaction((txn) async {
        final batch = txn.batch();
        for (final track in tracks) {
          batch.update(
            'track_playback_state',
            {
              'last_played_position_ms':
                  track.lastPlayedPosition.inMilliseconds,
              'last_played_at_ms': track.lastPlayedAt?.millisecondsSinceEpoch,
            },
            where:
                'path = ? AND EXISTS (SELECT 1 FROM tracks WHERE tracks.path = track_playback_state.path)',
            whereArgs: [track.path],
          );
        }
        await batch.commit(noResult: true);
      }),
    );
  }

  Future<void> replaceTrackPaths(Map<String, MusicTrack> replacements) async {
    if (replacements.isEmpty) return;
    final normalizedDestinations = <String>{};
    for (final entry in replacements.entries) {
      if (entry.key.trim().isEmpty || entry.value.path.trim().isEmpty) {
        throw ArgumentError('Track replacement paths must not be empty.');
      }
      if (!normalizedDestinations.add(
        PathMatcher.equivalenceKey(entry.value.path),
      )) {
        throw ArgumentError('Track replacement paths must be unique.');
      }
    }

    await _runDatabaseWrite((db) async {
      await db.transaction((txn) async {
        final sources = replacements.keys.toList(growable: false);
        final sourceRows = await _queryTrackRowsForPaths(
          txn,
          'tracks',
          sources,
        );
        final sourceByPath = {
          for (final row in sourceRows) row['path'] as String: row,
        };
        final sourcePaths = sourceByPath.keys.toSet();
        if (sources.any((path) => !sourcePaths.contains(path))) {
          throw StateError('Track replacement source does not exist.');
        }
        final destinations = await _queryTrackRowsForPaths(
          txn,
          'tracks',
          replacements.values.map((track) => track.path).toList(),
        );
        if (destinations.any((row) => !sourcePaths.contains(row['path']))) {
          throw StateError('Track replacement destination already exists.');
        }
        // Startup tracks omit these fields. Move the raw rows so neither JSON
        // decoding nor an empty in-memory projection can alter durable details.
        final deferredRows = <String, List<Map<String, Object?>>>{
          for (final table in [
            'track_tags',
            'track_remote_metadata',
            'track_playback_state',
            'track_scan_info',
          ])
            table: await _queryTrackRowsForPaths(txn, table, sources),
        };
        await AppDatabaseTracks._deleteTrackPaths(txn, sources);
        final batch = txn.batch();
        for (final entry in replacements.entries) {
          final track = entry.value.copyWith(
            duration: Duration(
              milliseconds: (sourceByPath[entry.key]!['duration_ms'] as num)
                  .toInt(),
            ),
          );
          _writeTrackToBatch(batch, track, writeDeferredDetails: false);
        }
        for (final entry in deferredRows.entries) {
          for (final row in entry.value) {
            batch.insert(entry.key, {
              ...row,
              'path': replacements[row['path']]!.path,
            }, conflictAlgorithm: ConflictAlgorithm.replace);
          }
        }
        await batch.commit(noResult: true);
      });
    });
  }

  Future<int> nextScanGeneration() async {
    return _runDatabaseRead((db) async {
      final rows = await db.rawQuery(
        'SELECT COALESCE(MAX(scan_generation), 0) + 1 AS next_generation '
        'FROM track_scan_info',
      );
      return (rows.first['next_generation'] as num?)?.toInt() ?? 1;
    });
  }

  Future<void> markTracksScanned(
    List<MusicTrack> tracks, {
    required int generation,
  }) {
    return upsertCatalogTracks(tracks, scanGeneration: generation);
  }

  Future<void> deleteTracksMissingFromGeneration(int generation) async {
    await _runDatabaseWrite((db) async {
      final rows = await db.query(
        'track_scan_info',
        columns: ['path'],
        where: 'scan_generation != ?',
        whereArgs: [generation],
      );
      final paths = rows.map((row) => row['path'] as String).toList();
      if (paths.isEmpty) return;
      await db.transaction((txn) async {
        await AppDatabaseTracks._deleteTrackPaths(txn, paths);
      });
    });
  }

  static Future<void> _deleteTrackPaths(
    DatabaseExecutor database,
    List<String> paths,
  ) async {
    for (
      var start = 0;
      start < paths.length;
      start += _sqliteInClauseBatchSize
    ) {
      final end = (start + _sqliteInClauseBatchSize).clamp(0, paths.length);
      final chunk = paths.sublist(start, end);
      final placeholders = List.filled(chunk.length, '?').join(', ');
      for (final table in <String>[
        'track_tags',
        'track_remote_metadata',
        'track_assets',
        'track_playback_state',
        'track_scan_info',
        'tracks',
      ]) {
        await database.rawDelete(
          'DELETE FROM $table WHERE path IN ($placeholders)',
          chunk,
        );
      }
    }
  }

  Future<void> deleteTracks(List<String> paths) async {
    if (paths.isEmpty) return;
    await _runDatabaseWrite((db) async {
      // Use a single DELETE ... WHERE path IN (...) instead of N individual
      // DELETE statements — much faster for large deletions.
      await db.transaction((txn) async {
        await AppDatabaseTracks._deleteTrackPaths(txn, paths);
      });
    });
  }

  Future<void> deleteAllTracks() async {
    await _runDatabaseWrite((db) async {
      final batch = db.batch();
      batch.delete('track_tags');
      batch.delete('track_remote_metadata');
      batch.delete('track_assets');
      batch.delete('track_playback_state');
      batch.delete('track_scan_info');
      batch.delete('tracks');
      await batch.commit(noResult: true);
    });
  }
}

Future<List<Map<String, Object?>>> _queryTrackRowsForPaths(
  DatabaseExecutor database,
  String table,
  List<String> paths,
) async {
  final rows = <Map<String, Object?>>[];
  for (var start = 0; start < paths.length; start += _sqliteInClauseBatchSize) {
    final chunk = paths.sublist(
      start,
      (start + _sqliteInClauseBatchSize).clamp(0, paths.length),
    );
    rows.addAll(
      await database.query(
        table,
        where: 'path IN (${List.filled(chunk.length, '?').join(',')})',
        whereArgs: chunk,
      ),
    );
  }
  return rows;
}

Future<void> _upsertCatalogTrackChunks(
  DatabaseExecutor database,
  List<MusicTrack> tracks, {
  int? scanGeneration,
}) async {
  const chunkSize = 120;
  for (var start = 0; start < tracks.length; start += chunkSize) {
    await Future<void>.delayed(Duration.zero);
    final chunk = tracks.sublist(
      start,
      (start + chunkSize).clamp(0, tracks.length),
    );
    final existing = (await database.query(
      'tracks',
      columns: ['path'],
      where: 'path IN (${List.filled(chunk.length, '?').join(',')})',
      whereArgs: chunk.map((track) => track.path).toList(),
    )).map((row) => row['path'] as String).toSet();
    final batch = database.batch();
    for (final track in chunk) {
      if (existing.add(track.path)) {
        _writeTrackToBatch(batch, track, scanGeneration: scanGeneration);
        continue;
      }
      // Catalog scans own names and file metadata, not playback, artwork, or
      // deferred details. In particular, omitted tags/JSON are not deletions.
      final core = _trackCoreRow(track)..remove('duration_ms');
      batch.update('tracks', core, where: 'path = ?', whereArgs: [track.path]);
      batch.insert(
        'track_scan_info',
        _trackScanRow(track, scanGeneration: scanGeneration),
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      final scan = _trackScanRow(track, scanGeneration: scanGeneration);
      if (scanGeneration == null) scan.remove('scan_generation');
      batch.update(
        'track_scan_info',
        scan,
        where: 'path = ?',
        whereArgs: [track.path],
      );
    }
    await batch.commit(noResult: true);
  }
}

Future<void> _upsertTrackChunks(
  DatabaseExecutor database,
  List<MusicTrack> tracks, {
  int? scanGeneration,
}) async {
  const chunkSize = 120;
  for (var start = 0; start < tracks.length; start += chunkSize) {
    await Future<void>.delayed(Duration.zero);
    final batch = database.batch();
    final end = (start + chunkSize).clamp(0, tracks.length);
    for (var index = start; index < end; index++) {
      _writeTrackToBatch(batch, tracks[index], scanGeneration: scanGeneration);
    }
    await batch.commit(noResult: true);
  }
}
