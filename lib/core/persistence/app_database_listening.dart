part of 'app_database.dart';

extension AppDatabaseListening on AppDatabase {
  Future<bool> importListeningBatch(
    String batchId,
    List<ListeningDayRecord> days,
  ) => _runDatabaseRead(
    (db) => db.transaction((txn) async {
      await txn.rawInsert(
        'INSERT OR IGNORE INTO listening_imports(batch_id) VALUES (?)',
        [batchId],
      );
      // SQLite's last_insert_rowid survives INSERT OR IGNORE; changes() does not.
      final changes = Sqflite.firstIntValue(
        await txn.rawQuery('SELECT changes()'),
      );
      if (changes == 0) return false;
      for (final day in days) {
        await txn.rawInsert(
          'INSERT INTO listening_days(date, milliseconds) VALUES (?, ?) '
          'ON CONFLICT(date) DO UPDATE SET milliseconds = milliseconds + excluded.milliseconds',
          [day.date, day.totalMs],
        );
        for (final work in day.works) {
          await txn.rawInsert(
            'INSERT INTO listening_work_days(date, work_key, milliseconds) VALUES (?, ?, ?) '
            'ON CONFLICT(date, work_key) DO UPDATE SET milliseconds = milliseconds + excluded.milliseconds',
            [day.date, work.workKey, work.milliseconds],
          );
          await _upsertListeningHistory(txn, work);
        }
      }
      return true;
    }),
  );

  Future<List<Map<String, Object?>>> loadListeningDays() =>
      _runDatabaseRead((db) => db.query('listening_days', orderBy: 'date'));

  Future<List<Map<String, Object?>>> loadListeningHistory({
    int offset = 0,
    int limit = 40,
  }) => _runDatabaseRead(
    (db) => db.query(
      'listening_history',
      orderBy: 'last_played_at_ms DESC, legacy_order, work_key',
      offset: offset,
      limit: limit,
    ),
  );

  Future<Map<String, Object?>?> findListeningTrack(String key) =>
      _runDatabaseRead((db) async {
        final rows = await db.query(
          'listening_history',
          where: 'work_key = ?',
          whereArgs: [key],
        );
        return rows.isEmpty ? null : rows.first;
      });

  Future<void> seedListeningHistory(
    List<ListeningWorkRecord> works,
  ) => _runDatabaseWrite(
    (db) => db.transaction((txn) async {
      await txn.rawInsert(
        'INSERT OR IGNORE INTO listening_imports(batch_id) VALUES (?)',
        ['legacy-history'],
      );
      if (Sqflite.firstIntValue(await txn.rawQuery('SELECT changes()')) == 0) {
        return;
      }
      for (var index = 0; index < works.length; index++) {
        await _upsertListeningHistory(txn, works[index], legacyOrder: index);
      }
    }),
  );
}

Future<void> _upsertListeningHistory(
  DatabaseExecutor db,
  ListeningWorkRecord work, {
  int legacyOrder = 0,
}) async {
  await db.rawInsert(
    'INSERT INTO listening_history(work_key, track_json, last_played_at_ms, legacy_order) VALUES (?, ?, ?, ?) '
    'ON CONFLICT(work_key) DO UPDATE SET '
    'track_json = CASE WHEN excluded.last_played_at_ms >= last_played_at_ms THEN excluded.track_json ELSE track_json END, '
    'last_played_at_ms = MAX(last_played_at_ms, excluded.last_played_at_ms)',
    [
      work.workKey,
      jsonEncode(work.track.toJson()),
      work.lastPlayedAtMs,
      legacyOrder,
    ],
  );
}
