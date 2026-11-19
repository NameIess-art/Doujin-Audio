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
        final updatedDays = await txn.rawUpdate(
          'UPDATE listening_days SET milliseconds = milliseconds + ? WHERE date = ?',
          [day.totalMs, day.date],
        );
        if (updatedDays == 0) {
          await txn.insert('listening_days', {
            'date': day.date,
            'milliseconds': day.totalMs,
          });
        }
        for (final work in day.works) {
          final updatedWorkDays = await txn.rawUpdate(
            'UPDATE listening_work_days SET milliseconds = milliseconds + ? '
            'WHERE date = ? AND work_key = ?',
            [work.milliseconds, day.date, work.workKey],
          );
          if (updatedWorkDays == 0) {
            await txn.insert('listening_work_days', {
              'date': day.date,
              'work_key': work.workKey,
              'milliseconds': work.milliseconds,
            });
          }
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
  // Query-then-insert/update inside the enclosing transaction avoids SQLite
  // UPSERT syntax (3.24+), which older Android libsqlite builds lack.
  final existing = await db.query(
    'listening_history',
    columns: ['last_played_at_ms'],
    where: 'work_key = ?',
    whereArgs: [work.workKey],
    limit: 1,
  );
  if (existing.isEmpty) {
    await db.insert('listening_history', {
      'work_key': work.workKey,
      'track_json': jsonEncode(work.track.toJson()),
      'last_played_at_ms': work.lastPlayedAtMs,
      'legacy_order': legacyOrder,
    });
    return;
  }
  final currentLastPlayed = (existing.single['last_played_at_ms'] as int?) ?? 0;
  if (work.lastPlayedAtMs >= currentLastPlayed) {
    await db.update(
      'listening_history',
      {
        'track_json': jsonEncode(work.track.toJson()),
        'last_played_at_ms': work.lastPlayedAtMs,
      },
      where: 'work_key = ?',
      whereArgs: [work.workKey],
    );
  }
}
