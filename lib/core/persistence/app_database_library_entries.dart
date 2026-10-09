part of 'app_database.dart';

extension AppDatabaseLibraryEntries on AppDatabase {
  // ---- Library entries ----

  Future<List<LibraryEntryRecord>> loadAllLibraryEntries() async {
    return _runDatabaseRead((db) async {
      final rows = await db.query('library_entries');
      return rows.map(_libraryEntryFromRow).toList();
    });
  }

  Future<List<LibraryEntryRecord>> loadLibraryEntries(
    String libraryPath,
  ) async {
    return _runDatabaseRead((db) async {
      final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
      final rows = await db.query(
        'library_entries',
        where: 'library_path = ?',
        whereArgs: [normalizedLibraryPath],
      );
      return rows.map(_libraryEntryFromRow).toList();
    });
  }

  Future<void> upsertLibraryEntries(
    Iterable<LibraryEntryRecord> entries, {
    int? scanGeneration,
  }) async {
    await _runDatabaseWrite((db) async {
      await db.transaction((txn) async {
        await _upsertEntryChunks(txn, entries, scanGeneration: scanGeneration);
      });
    });
  }

  Future<void> commitLibraryBatch({
    required List<MusicTrack> tracks,
    required Iterable<LibraryEntryRecord> entries,
    required Map<String, String> catalogSettings,
    List<String> removedTrackPaths = const <String>[],
    Map<String, List<String>> removedEntryPaths =
        const <String, List<String>>{},
  }) => _runDatabaseWrite(
    (db) => db.transaction((txn) async {
      await AppDatabaseTracks._deleteTrackPaths(txn, removedTrackPaths);
      for (final entry in removedEntryPaths.entries) {
        for (var start = 0; start < entry.value.length; start += 120) {
          await Future<void>.delayed(Duration.zero);
          final paths = entry.value.sublist(
            start,
            (start + 120).clamp(0, entry.value.length),
          );
          await txn.delete(
            'library_entries',
            where:
                'library_path = ? AND path IN (${List.filled(paths.length, '?').join(',')})',
            whereArgs: [
              PathMatcher.normalize(entry.key),
              ...paths.map(PathMatcher.normalize),
            ],
          );
        }
      }
      await _upsertCatalogTrackChunks(txn, tracks);
      await _upsertEntryChunks(txn, entries);
      final batch = txn.batch();
      for (final setting in catalogSettings.entries) {
        batch.insert('app_kv_settings', {
          'key': setting.key,
          'value': setting.value,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    }),
  );

  Future<int> nextLibraryEntryScanGeneration(String libraryPath) async {
    return _runDatabaseRead((db) async {
      final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
      final rows = await db.rawQuery(
        'SELECT COALESCE(MAX(scan_generation), 0) + 1 AS next_generation '
        'FROM library_entries WHERE library_path = ?',
        [normalizedLibraryPath],
      );
      return (rows.first['next_generation'] as num?)?.toInt() ?? 1;
    });
  }

  Future<void> deleteLibraryEntriesForLibrary(String libraryPath) async {
    await _runDatabaseWrite((db) async {
      await db.delete(
        'library_entries',
        where: 'library_path = ?',
        whereArgs: [PathMatcher.normalize(libraryPath)],
      );
    });
  }

  Future<void> deleteLibraryEntries(
    String libraryPath,
    Iterable<String> paths,
  ) async {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    final normalizedPaths = paths.map(PathMatcher.normalize).toSet();
    if (normalizedPaths.isEmpty) return;
    await _runDatabaseWrite((db) async {
      final batch = db.batch();
      for (final entryPath in normalizedPaths) {
        batch.delete(
          'library_entries',
          where: 'library_path = ? AND path = ?',
          whereArgs: [normalizedLibraryPath, entryPath],
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> setLibraryEntriesState(
    String libraryPath,
    Iterable<String> entryPaths,
    String state,
  ) async {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    final paths = entryPaths.map(PathMatcher.normalize).toSet();
    if (paths.isEmpty) return;
    await _runDatabaseWrite((db) async {
      final batch = db.batch();
      for (final entryPath in paths) {
        batch.update(
          'library_entries',
          {'state': state},
          where: 'library_path = ? AND path = ?',
          whereArgs: [normalizedLibraryPath, entryPath],
        );
      }
      await batch.commit(noResult: true);
    });
  }
}

Future<void> _upsertEntryChunks(
  DatabaseExecutor database,
  Iterable<LibraryEntryRecord> entries, {
  int? scanGeneration,
}) async {
  final iterator = entries.iterator;
  while (iterator.moveNext()) {
    await Future<void>.delayed(Duration.zero);
    final batch = database.batch();
    var count = 0;
    do {
      batch.insert(
        'library_entries',
        _libraryEntryToRow(iterator.current, scanGeneration: scanGeneration),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      count++;
    } while (count < 120 && iterator.moveNext());
    await batch.commit(noResult: true);
  }
}
