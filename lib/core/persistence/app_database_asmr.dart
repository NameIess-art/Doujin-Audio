part of 'app_database.dart';

extension AppDatabaseAsmr on AppDatabase {
  // ---- ASMR.ONE app data ----

  Future<List<String>> loadAsmrVisibleCategoryNames() async {
    return _runDatabaseRead((db) async {
      final rows = await db.query(
        'asmr_visible_categories',
        orderBy: 'sort_order ASC',
      );
      return rows
          .map((row) => row['category'] as String?)
          .whereType<String>()
          .toList(growable: false);
    });
  }

  Future<void> saveAsmrVisibleCategoryNames(List<String> categories) async {
    await _runDatabaseWrite((db) async {
      final batch = db.batch();
      batch.delete('asmr_visible_categories');
      for (var i = 0; i < categories.length; i++) {
        batch.insert('asmr_visible_categories', {
          'category': categories[i],
          'sort_order': i,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  Future<String?> loadAppSetting(String key) async {
    return _runDatabaseRead((db) async {
      final rows = await db.query(
        'app_kv_settings',
        columns: ['value'],
        where: 'key = ?',
        whereArgs: [key],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      return rows.first['value'] as String?;
    });
  }

  Future<void> saveAppSetting(String key, String? value) async {
    await _runDatabaseWrite((db) async {
      if (value == null) {
        await db.delete('app_kv_settings', where: 'key = ?', whereArgs: [key]);
        return;
      }
      await db.insert('app_kv_settings', {
        'key': key,
        'value': value,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  Future<List<AsmrWorkRecord>> loadAsmrWorkList(String listType) async {
    return _runDatabaseRead((db) async {
      final rows = await db.rawQuery(
        '''
      SELECT w.*
      FROM asmr_work_lists l
      INNER JOIN asmr_works w ON w.id = l.work_id
      WHERE l.list_type = ?
      ORDER BY l.sort_order ASC
    ''',
        [listType],
      );
      if (rows.isEmpty) return const <AsmrWorkRecord>[];
      final ids = rows.map((row) => row['id'] as int).toList(growable: false);
      final voiceActorsById = await _loadAsmrWorkTextValues(
        db,
        table: 'asmr_work_voice_actors',
        idColumn: 'work_id',
        valueColumn: 'name',
        ids: ids,
      );
      final tagsById = await _loadAsmrWorkTextValues(
        db,
        table: 'asmr_work_tags',
        idColumn: 'work_id',
        valueColumn: 'tag',
        ids: ids,
      );
      return rows
          .map(
            (row) => _asmrWorkFromRow(
              row,
              voiceActors: voiceActorsById[row['id'] as int],
              tags: tagsById[row['id'] as int],
            ),
          )
          .toList(growable: false);
    });
  }

  Future<void> saveAsmrWorkList(
    String listType,
    List<AsmrWorkRecord> works,
  ) async {
    await _runDatabaseWrite((db) async {
      final batch = db.batch();
      _replaceAsmrWorkListInBatch(batch, listType, works);
      await batch.commit(noResult: true);
    });
  }

  Future<List<AsmrSyncOperationRecord>> loadAsmrSyncOperations() async {
    return _runDatabaseRead((db) async {
      final rows = await db.query(
        'asmr_sync_operations',
        orderBy: 'sort_order ASC',
      );
      return rows
          .map(
            (row) => AsmrSyncOperationRecord(
              type: row['type'] as String? ?? '',
              workId: (row['work_id'] as num?)?.toInt() ?? 0,
              sourceId: row['source_id'] as String? ?? '',
              createdAt:
                  _dateTimeFromMs(row['created_at_ms']) ??
                  DateTime.fromMillisecondsSinceEpoch(0),
              retryCount: (row['retry_count'] as num?)?.toInt() ?? 0,
            ),
          )
          .where((operation) => operation.workId > 0)
          .toList(growable: false);
    });
  }

  Future<void> saveAsmrSyncOperations(
    List<AsmrSyncOperationRecord> operations,
  ) async {
    await _runDatabaseWrite((db) async {
      final batch = db.batch();
      _replaceAsmrSyncOperationsInBatch(batch, operations);
      await batch.commit(noResult: true);
    });
  }

  Future<void> saveAsmrWorkListAndSyncOperations(
    String listType,
    List<AsmrWorkRecord> works,
    List<AsmrSyncOperationRecord> operations,
  ) async {
    await _runDatabaseWrite((db) async {
      await db.transaction((txn) async {
        final batch = txn.batch();
        _replaceAsmrWorkListInBatch(batch, listType, works);
        _replaceAsmrSyncOperationsInBatch(batch, operations);
        await batch.commit(noResult: true);
      });
    });
  }
}
