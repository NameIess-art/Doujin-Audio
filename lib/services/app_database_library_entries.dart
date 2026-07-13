part of 'app_database.dart';

extension AppDatabaseLibraryEntries on AppDatabase {
  // ---- Library entries ----

  Future<List<LibraryEntry>> loadAllLibraryEntries() async {
    return _runDatabaseRead((db) async {
      final rows = await db.query('library_entries');
      return rows.map(_libraryEntryFromRow).toList();
    });
  }

  Future<List<LibraryEntry>> loadLibraryEntries(String libraryPath) async {
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
    List<LibraryEntry> entries, {
    int? scanGeneration,
  }) async {
    if (entries.isEmpty) return;
    await _runDatabaseWrite((db) async {
      final batch = db.batch();
      for (final entry in entries) {
        batch.insert(
          'library_entries',
          _libraryEntryToRow(entry, scanGeneration: scanGeneration),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

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
    final normalizedPaths = paths.map(PathMatcher.normalize).toSet();
    if (normalizedPaths.isEmpty) return;
    await _runDatabaseWrite((db) async {
      final batch = db.batch();
      for (final entryPath in normalizedPaths) {
        batch.delete(
          'library_entries',
          where: 'library_path = ? AND path = ?',
          whereArgs: [PathMatcher.normalize(libraryPath), entryPath],
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> setLibraryEntriesState(
    String libraryPath,
    Iterable<String> entryPaths,
    LibraryEntryState state,
  ) async {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    final paths = entryPaths.map(PathMatcher.normalize).toSet();
    if (paths.isEmpty) return;
    await _runDatabaseWrite((db) async {
      final batch = db.batch();
      for (final entryPath in paths) {
        batch.update(
          'library_entries',
          {'state': state.dbValue},
          where: 'library_path = ? AND path = ?',
          whereArgs: [normalizedLibraryPath, entryPath],
        );
      }
      await batch.commit(noResult: true);
    });
  }
}
