part of 'app_database.dart';

extension AppDatabaseMaintenance on AppDatabase {
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
      final result = await action(await filePath);
      if (replacesDatabase) {
        _databaseEpoch++;
      }
      await _openIgnoringMaintenance();
      return result;
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
