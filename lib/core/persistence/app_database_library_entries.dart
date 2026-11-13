part of 'app_database.dart';

extension AppDatabaseLibraryEntries on AppDatabase {
  // ---- Library entries ----

  Future<Iterable<LibraryEntryRecord>> loadAllLibraryEntries() async {
    final rows = await _runDatabaseRead((db) => db.query('library_entries'));
    // Startup consumes this iterable in its snapshot worker, keeping record
    // decoding, domain mapping and index preparation in one isolate task.
    return rows.map(_libraryEntryFromRow);
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
      if (removedEntryPaths.isNotEmpty) {
        final batch = txn.batch();
        for (final entry in removedEntryPaths.entries) {
          _changeLibraryEntryPaths(batch, entry.key, entry.value);
        }
        await batch.commit(noResult: true);
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
    if (paths.isEmpty) return;
    await _runDatabaseWrite((db) async {
      final batch = db.batch();
      _changeLibraryEntryPaths(batch, libraryPath, paths);
      await batch.commit(noResult: true);
    });
  }

  Future<void> setLibraryEntriesState(
    String libraryPath,
    Iterable<String> entryPaths,
    String state,
  ) async {
    if (entryPaths.isEmpty) return;
    await _runDatabaseWrite((db) async {
      final batch = db.batch();
      _changeLibraryEntryPaths(batch, libraryPath, entryPaths, state: state);
      await batch.commit(noResult: true);
    });
  }
}

void _changeLibraryEntryPaths(
  Batch batch,
  String libraryPath,
  Iterable<String> entryPaths, {
  String? state,
}) {
  final root = PathMatcher.normalize(libraryPath);
  final paths = entryPaths.map(PathMatcher.normalize).toSet().toList();
  for (var start = 0; start < paths.length; start += _sqliteInClauseBatchSize) {
    final end = (start + _sqliteInClauseBatchSize).clamp(0, paths.length);
    final chunk = paths.sublist(start, end);
    final placeholders = List.filled(chunk.length, '?').join(', ');
    final where = 'library_path = ? AND path IN ($placeholders)';
    final args = [root, ...chunk];
    if (state == null) {
      batch.delete('library_entries', where: where, whereArgs: args);
    } else {
      batch.update(
        'library_entries',
        {'state': state},
        where: where,
        whereArgs: args,
      );
    }
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
