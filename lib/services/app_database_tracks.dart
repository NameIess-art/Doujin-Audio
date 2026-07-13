part of 'app_database.dart';

extension AppDatabaseTracks on AppDatabase {
  // ---- Tracks ----

  Future<List<MusicTrack>> loadAllTracks() async {
    return _runDatabaseRead((db) async {
      final rows = await AppDatabase._queryFullTrackRows(db);
      final tagsByPath = await AppDatabase._loadTrackTags(db);
      return rows
          .map(
            (row) => AppDatabase._trackFromRow(
              row,
              tagsByPath[row['path'] as String],
            ),
          )
          .toList();
    });
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
      return rows.map((row) => AppDatabase._trackSummaryFromRow(row)).toList();
    });
  }

  Future<List<MusicTrack>> loadStartupTracks() async {
    final rows = await _runDatabaseRead(AppDatabase._queryStartupTrackRows);
    return compute(_startupTracksFromRows, rows);
  }

  Future<MusicTrack?> loadTrackDetail(String path) async {
    return _runDatabaseRead((db) async {
      final rows = await AppDatabase._queryFullTrackRows(
        db,
        path: path,
        limit: 1,
      );
      if (rows.isEmpty) return null;
      final tagsByPath = await AppDatabase._loadTrackTags(db, paths: [path]);
      return AppDatabase._trackFromRow(rows.first, tagsByPath[path]);
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
        AppDatabase._writeTrackToBatch(batch, track);
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> insertTracks(List<MusicTrack> tracks) async {
    await upsertTracks(tracks);
  }

  Future<void> upsertTracks(
    List<MusicTrack> tracks, {
    int? scanGeneration,
  }) async {
    await _runDatabaseWrite((db) async {
      final batch = db.batch();
      for (final track in tracks) {
        AppDatabase._writeTrackToBatch(
          batch,
          track,
          scanGeneration: scanGeneration,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> replaceTrackPaths(Map<String, MusicTrack> replacements) async {
    if (replacements.isEmpty) return;
    final normalizedDestinations = <String>{};
    for (final entry in replacements.entries) {
      if (entry.key.trim().isEmpty || entry.value.path.trim().isEmpty) {
        throw ArgumentError('Track replacement paths must not be empty.');
      }
      if (!normalizedDestinations.add(
        PathMatcher.normalize(entry.value.path),
      )) {
        throw ArgumentError('Track replacement paths must be unique.');
      }
    }

    await _runDatabaseWrite((db) async {
      await db.transaction((txn) async {
        await AppDatabaseTracks._deleteTrackPaths(
          txn,
          replacements.keys.toList(growable: false),
        );
        final batch = txn.batch();
        for (final track in replacements.values) {
          AppDatabase._writeTrackToBatch(batch, track);
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
    return upsertTracks(tracks, scanGeneration: generation);
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
      start += AppDatabase._sqliteInClauseBatchSize
    ) {
      final end = (start + AppDatabase._sqliteInClauseBatchSize).clamp(
        0,
        paths.length,
      );
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
