part of 'app_database.dart';

const _listeningHistoryEditedAtKey = 'listening_history_edited_at_v1';
const _listeningActivityPlaybackAtKey = 'listening_activity_playback_at_v1';

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
      if (days.isEmpty) return true;

      final dayTotals = <String, int>{};
      final workDaysByDate = <String, Map<String, int>>{};
      final pendingHistory =
          <String, ({ListeningWorkRecord work, int legacyOrder})>{};
      for (final day in days) {
        dayTotals[day.date] = (dayTotals[day.date] ?? 0) + day.totalMs;
        if (day.works.isEmpty) continue;
        final workTotals = workDaysByDate.putIfAbsent(
          day.date,
          () => <String, int>{},
        );
        for (final work in day.works) {
          workTotals[work.workKey] =
              (workTotals[work.workKey] ?? 0) + work.milliseconds;
          final previous = pendingHistory[work.workKey];
          if (previous == null ||
              work.lastPlayedAtMs >= previous.work.lastPlayedAtMs) {
            pendingHistory[work.workKey] = (work: work, legacyOrder: 0);
          }
        }
      }

      final existingDays = await _loadExistingListeningDays(
        txn,
        dayTotals.keys.toList(growable: false),
      );
      final existingWorkDays = await _loadExistingListeningWorkDays(
        txn,
        workDaysByDate,
      );

      final batch = txn.batch();
      for (final MapEntry(key: date, value: totalMs) in dayTotals.entries) {
        if (existingDays.contains(date)) {
          batch.rawUpdate(
            'UPDATE listening_days SET milliseconds = milliseconds + ? '
            'WHERE date = ?',
            [totalMs, date],
          );
        } else {
          batch.insert('listening_days', {
            'date': date,
            'milliseconds': totalMs,
          });
        }
      }
      for (final MapEntry(key: date, value: workTotals)
          in workDaysByDate.entries) {
        final existingWorks = existingWorkDays[date];
        for (final MapEntry(key: workKey, value: milliseconds)
            in workTotals.entries) {
          if (existingWorks != null && existingWorks.contains(workKey)) {
            batch.rawUpdate(
              'UPDATE listening_work_days SET milliseconds = milliseconds + ? '
              'WHERE date = ? AND work_key = ?',
              [milliseconds, date, workKey],
            );
          } else {
            batch.insert('listening_work_days', {
              'date': date,
              'work_key': workKey,
              'milliseconds': milliseconds,
            });
          }
        }
      }
      await _enqueueListeningHistoryUpserts(txn, batch, pendingHistory);
      await batch.commit(noResult: true);
      return true;
    }),
  );

  Future<List<Map<String, Object?>>> loadListeningDays() =>
      _runDatabaseRead((db) => db.query('listening_days', orderBy: 'date'));

  Future<Map<String, int>> loadListeningWorkTotalMilliseconds(
    Iterable<String> workKeys,
  ) => _runDatabaseRead((db) async {
    final keys = workKeys.toSet().toList(growable: false);
    if (keys.isEmpty) return const <String, int>{};
    final totals = <String, int>{};
    for (final chunk in _stringChunks(keys)) {
      final placeholders = List.filled(chunk.length, '?').join(', ');
      final rows = await db.rawQuery(
        'SELECT work_key, SUM(milliseconds) AS total_ms '
        'FROM listening_work_days '
        'WHERE work_key IN ($placeholders) '
        'GROUP BY work_key',
        chunk,
      );
      for (final row in rows) {
        final key = row['work_key'] as String?;
        final total = (row['total_ms'] as num?)?.toInt() ?? 0;
        if (key != null && total > 0) {
          totals[key] = total;
        }
      }
    }
    return totals;
  });

  Future<int> countListeningHistory() => _runDatabaseRead(
    (db) async => Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM listening_history'),
    )!,
  );

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

  Future<Map<String, Object?>?> removeListeningHistoryEntry(String workKey) =>
      _runDatabaseRead(
        (db) => db.transaction((txn) async {
          final entry = await _findListeningHistoryEntry(txn, workKey);
          if (entry == null) return null;
          await txn.delete(
            'listening_history',
            where: 'work_key = ?',
            whereArgs: [workKey],
          );
          // A history deletion does not undo the underlying listening time.
          await txn.rawInsert(
            'INSERT OR REPLACE INTO app_kv_settings (key, value) '
            'VALUES (?, MAX(?, COALESCE((SELECT CAST(value AS INTEGER) '
            'FROM app_kv_settings WHERE key = ?), -1)))',
            [
              _listeningActivityPlaybackAtKey,
              entry['last_played_at_ms'],
              _listeningActivityPlaybackAtKey,
            ],
          );
          await _recordListeningHistoryEdit(txn);
          return entry;
        }),
      );

  Future<void> restoreListeningHistoryEntry(
    ListeningWorkRecord work, {
    required int legacyOrder,
  }) => _runDatabaseWrite(
    // Playback can recreate the entry while its Undo prompt is still open.
    (db) => db.transaction((txn) async {
      await txn.insert('listening_history', {
        'work_key': work.workKey,
        'track_json': jsonEncode(work.track.toJson()),
        'last_played_at_ms': work.lastPlayedAtMs,
        'legacy_order': legacyOrder,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      if (Sqflite.firstIntValue(await txn.rawQuery('SELECT changes()')) != 0) {
        await _recordListeningHistoryEdit(txn);
      }
    }),
  );

  Future<Map<String, Object?>?> findListeningTrack(String key) =>
      _runDatabaseRead((db) => _findListeningHistoryEntry(db, key));

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
      if (works.isEmpty) return;
      final pending = <String, ({ListeningWorkRecord work, int legacyOrder})>{};
      for (var index = 0; index < works.length; index++) {
        final work = works[index];
        final previous = pending[work.workKey];
        if (previous == null) {
          pending[work.workKey] = (work: work, legacyOrder: index);
        } else if (work.lastPlayedAtMs >= previous.work.lastPlayedAtMs) {
          pending[work.workKey] = (
            work: work,
            legacyOrder: previous.legacyOrder,
          );
        }
      }
      final batch = txn.batch();
      await _enqueueListeningHistoryUpserts(txn, batch, pending);
      await batch.commit(noResult: true);
    }),
  );
}

Future<Map<String, Object?>?> _findListeningHistoryEntry(
  DatabaseExecutor db,
  String workKey,
) async {
  final rows = await db.query(
    'listening_history',
    where: 'work_key = ?',
    whereArgs: [workKey],
  );
  return rows.firstOrNull;
}

Future<void> _recordListeningHistoryEdit(Transaction txn) async {
  await txn.insert('app_kv_settings', {
    'key': _listeningHistoryEditedAtKey,
    'value': DateTime.now().millisecondsSinceEpoch.toString(),
  }, conflictAlgorithm: ConflictAlgorithm.replace);
}

Future<Set<String>> _loadExistingListeningDays(
  DatabaseExecutor db,
  List<String> dates,
) async {
  final existing = <String>{};
  for (final chunk in _stringChunks(dates)) {
    final placeholders = List.filled(chunk.length, '?').join(', ');
    final rows = await db.query(
      'listening_days',
      columns: const ['date'],
      where: 'date IN ($placeholders)',
      whereArgs: chunk,
    );
    for (final row in rows) {
      existing.add(row['date']! as String);
    }
  }
  return existing;
}

Future<Map<String, Set<String>>> _loadExistingListeningWorkDays(
  DatabaseExecutor db,
  Map<String, Map<String, int>> workDaysByDate,
) async {
  final existing = <String, Set<String>>{};
  for (final MapEntry(key: date, value: workTotals) in workDaysByDate.entries) {
    final keys = workTotals.keys.toList(growable: false);
    for (final chunk in _stringChunks(keys)) {
      final placeholders = List.filled(chunk.length, '?').join(', ');
      final rows = await db.query(
        'listening_work_days',
        columns: const ['work_key'],
        where: 'date = ? AND work_key IN ($placeholders)',
        whereArgs: <Object?>[date, ...chunk],
      );
      if (rows.isEmpty) continue;
      final dateKeys = existing.putIfAbsent(date, () => <String>{});
      for (final row in rows) {
        dateKeys.add(row['work_key']! as String);
      }
    }
  }
  return existing;
}

Future<void> _enqueueListeningHistoryUpserts(
  DatabaseExecutor db,
  Batch batch,
  Map<String, ({ListeningWorkRecord work, int legacyOrder})> pending,
) async {
  if (pending.isEmpty) return;
  // Query-then-insert/update inside the enclosing transaction avoids SQLite
  // UPSERT syntax (3.24+), which older Android libsqlite builds lack.
  final existingLastPlayed = <String, int>{};
  for (final chunk in _stringChunks(pending.keys.toList(growable: false))) {
    final placeholders = List.filled(chunk.length, '?').join(', ');
    final rows = await db.query(
      'listening_history',
      columns: const ['work_key', 'last_played_at_ms'],
      where: 'work_key IN ($placeholders)',
      whereArgs: chunk,
    );
    for (final row in rows) {
      existingLastPlayed[row['work_key']! as String] =
          (row['last_played_at_ms'] as int?) ?? 0;
    }
  }
  for (final MapEntry(key: workKey, value: entry) in pending.entries) {
    final currentLastPlayed = existingLastPlayed[workKey];
    if (currentLastPlayed == null) {
      batch.insert('listening_history', {
        'work_key': entry.work.workKey,
        'track_json': jsonEncode(entry.work.track.toJson()),
        'last_played_at_ms': entry.work.lastPlayedAtMs,
        'legacy_order': entry.legacyOrder,
      });
    } else if (entry.work.lastPlayedAtMs >= currentLastPlayed) {
      batch.update(
        'listening_history',
        {
          'track_json': jsonEncode(entry.work.track.toJson()),
          'last_played_at_ms': entry.work.lastPlayedAtMs,
        },
        where: 'work_key = ?',
        whereArgs: [workKey],
      );
    }
  }
}
