part of 'app_database.dart';

extension AppDatabaseMaintenance on AppDatabase {
  Future<bool> validateBackupDatabase(
    String databasePath, {
    required int expectedSchemaVersion,
  }) async {
    Database? candidate;
    try {
      candidate = await openDatabase(databasePath, readOnly: true);
      return await _isValidAppDatabase(
        candidate,
        expectedSchemaVersion: expectedSchemaVersion,
      );
    } catch (_) {
      return false;
    } finally {
      await candidate?.close();
    }
  }

  Future<void> close() async {
    await _openFuture;
    final db = _db;
    _db = null;
    await db?.close();
  }

  Future<void> reopen() async {
    await _database;
  }

  Future<T> runExclusiveMaintenance<T>({
    required bool replacesDatabase,
    required Future<T> Function(String databasePath) action,
    Future<void> Function(String databasePath)? recover,
  }) async {
    final previous = _maintenanceTail;
    final turnDone = Completer<void>();
    _maintenanceTail = turnDone.future;
    await previous;

    final barrier = Completer<void>();
    _maintenanceBarrier = barrier.future;
    try {
      final opening = _openFuture;
      if (opening != null) {
        await opening;
      }
      if (_activeOperations > 0) {
        _operationsDrained ??= Completer<void>();
        await _operationsDrained!.future;
      }
      final db = _db;
      _db = null;
      await db?.close();
      final databasePath = await filePath;
      try {
        final result = await action(databasePath);
        final opened = await _openIgnoringMaintenance();
        if (replacesDatabase) {
          final valid = await _isValidAppDatabase(
            opened,
            expectedSchemaVersion: AppDatabase.schemaVersion,
          );
          if (!valid) {
            throw StateError('Replacement database validation failed.');
          }
          _databaseEpoch++;
        }
        return result;
      } catch (error, stackTrace) {
        final opened = _db;
        _db = null;
        await opened?.close();
        if (recover != null) {
          await recover(databasePath);
          await _openIgnoringMaintenance();
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
    } finally {
      try {
        if (_db == null) {
          await _openIgnoringMaintenance();
        }
      } finally {
        _maintenanceBarrier = null;
        barrier.complete();
        turnDone.complete();
      }
    }
  }
}

const Set<String> _requiredAppDatabaseTables = <String>{
  'app_kv_settings',
  'asmr_sync_operations',
  'asmr_visible_categories',
  'asmr_work_lists',
  'asmr_work_tags',
  'asmr_work_voice_actors',
  'asmr_works',
  'audio_details',
  'library_entries',
  'playback_queue_entries',
  'playback_queue_entry_tracks',
  'playback_queues',
  'session_audio_effects',
  'session_eq_bands',
  'session_playback_state',
  'sessions',
  'time_segment_labels',
  'track_assets',
  'track_playback_state',
  'track_remote_metadata',
  'track_scan_info',
  'track_tags',
  'tracks',
};

Future<bool> _isValidAppDatabase(
  Database database, {
  required int expectedSchemaVersion,
}) async {
  if (await database.getVersion() != expectedSchemaVersion) return false;
  final quickCheck = await database.rawQuery('PRAGMA quick_check');
  if (quickCheck.length != 1 || quickCheck.first.values.single != 'ok') {
    return false;
  }
  final tableRows = await database.rawQuery(
    "SELECT name FROM sqlite_master WHERE type = 'table'",
  );
  final tables = tableRows
      .map((row) => row['name'])
      .whereType<String>()
      .toSet();
  return tables.containsAll(_requiredAppDatabaseTables);
}
