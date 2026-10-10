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
      await db.transaction((txn) async {
        final batch = txn.batch();
        _replaceAsmrWorkListInBatch(batch, listType, works);
        _deleteUnreferencedAsmrWorksInBatch(batch);
        await batch.commit(noResult: true);
      });
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

  Future<void> saveAsmrAccountSyncState(
    List<AsmrWorkRecord> favoriteWorks,
    List<AsmrWorkRecord> historyWorks,
    List<AsmrSyncOperationRecord> operations,
  ) async {
    await _runDatabaseWrite((db) async {
      await db.transaction((txn) async {
        final batch = txn.batch();
        final historyById = <int, AsmrWorkRecord>{
          for (final work in historyWorks) work.id: work,
        };
        final favoriteById = <int, AsmrWorkRecord>{
          for (final work in favoriteWorks) work.id: work,
        };
        final workById = <int, AsmrWorkRecord>{...historyById, ...favoriteById};
        for (final work in workById.values) {
          _writeAsmrWorkToBatch(
            batch,
            work,
            isFavorite: favoriteById.containsKey(work.id),
          );
        }
        _replaceAsmrWorkListMembershipInBatch(
          batch,
          'favorites',
          favoriteById.keys.toList(growable: false),
        );
        _replaceAsmrWorkListMembershipInBatch(
          batch,
          'history',
          historyById.keys.toList(growable: false),
        );
        _deleteUnreferencedAsmrWorksInBatch(batch);
        _replaceAsmrSyncOperationsInBatch(batch, operations);
        await batch.commit(noResult: true);
      });
    });
  }

  Future<void> saveAsmrHistoryState(
    AsmrWorkRecord work,
    List<int> historyWorkIds,
    AsmrSyncOperationRecord operation,
  ) async {
    await _runDatabaseWrite((db) async {
      await db.transaction((txn) async {
        final previousHistory = await txn.query(
          'asmr_work_lists',
          columns: ['work_id'],
          where: 'list_type = ?',
          whereArgs: ['history'],
        );
        final favorite = await txn.query(
          'asmr_work_lists',
          columns: ['work_id'],
          where: 'list_type = ? AND work_id = ?',
          whereArgs: ['favorites', work.id],
          limit: 1,
        );
        final lastOperation = await txn.query(
          'asmr_sync_operations',
          columns: ['sort_order'],
          orderBy: 'sort_order DESC',
          limit: 1,
        );
        final nextOrder = lastOperation.isEmpty
            ? 0
            : (lastOperation.single['sort_order'] as int) + 1;
        final batch = txn.batch();
        // A favorite's saved metadata is authoritative for the shared work row.
        if (favorite.isEmpty) {
          _writeAsmrWorkToBatch(batch, work, isFavorite: false);
        }
        _replaceAsmrWorkListMembershipInBatch(batch, 'history', historyWorkIds);
        final retainedIds = historyWorkIds.toSet();
        _deleteUnreferencedAsmrWorksInBatch(
          batch,
          workIds: previousHistory
              .map((row) => row['work_id'] as int)
              .where((id) => !retainedIds.contains(id))
              .toList(growable: false),
        );
        batch.delete(
          'asmr_sync_operations',
          where: 'type = ? AND work_id = ?',
          whereArgs: [operation.type, operation.workId],
        );
        _writeAsmrSyncOperationToBatch(batch, operation, nextOrder);
        await batch.commit(noResult: true);
      });
    });
  }

  Future<void> saveAsmrFavoriteState(
    List<AsmrWorkRecord> works,
    bool favorite,
    List<AsmrSyncOperationRecord> operations,
  ) async {
    if (works.isEmpty) return;
    await _runDatabaseWrite((db) async {
      await db.transaction((txn) async {
        final firstFavorite = await txn.query(
          'asmr_work_lists',
          columns: ['sort_order'],
          where: 'list_type = ?',
          whereArgs: ['favorites'],
          orderBy: 'sort_order ASC',
          limit: 1,
        );
        var favoriteOrder = firstFavorite.isEmpty
            ? 0
            : firstFavorite.single['sort_order'] as int;
        final lastOperation = await txn.query(
          'asmr_sync_operations',
          columns: ['sort_order'],
          orderBy: 'sort_order DESC',
          limit: 1,
        );
        var operationOrder = lastOperation.isEmpty
            ? 0
            : (lastOperation.single['sort_order'] as int) + 1;
        final batch = txn.batch();
        for (final work in works) {
          if (favorite) {
            _writeAsmrWorkToBatch(batch, work, isFavorite: true);
            // Prepending does not require rewriting every existing membership.
            batch.insert('asmr_work_lists', {
              'list_type': 'favorites',
              'work_id': work.id,
              'sort_order': --favoriteOrder,
            }, conflictAlgorithm: ConflictAlgorithm.replace);
          } else {
            batch.delete(
              'asmr_work_lists',
              where: 'list_type = ? AND work_id = ?',
              whereArgs: ['favorites', work.id],
            );
            batch.update(
              'asmr_works',
              {'is_favorite': 0},
              where: 'id = ?',
              whereArgs: [work.id],
            );
          }
        }
        if (!favorite) {
          final workIds = works.map((work) => work.id).toList(growable: false);
          for (
            var start = 0;
            start < workIds.length;
            start += _sqliteInClauseBatchSize
          ) {
            _deleteUnreferencedAsmrWorksInBatch(
              batch,
              workIds: workIds.sublist(
                start,
                (start + _sqliteInClauseBatchSize).clamp(0, workIds.length),
              ),
            );
          }
        }
        for (final operation in operations) {
          batch.delete(
            'asmr_sync_operations',
            where: 'work_id = ? AND type IN (?, ?)',
            whereArgs: [operation.workId, 'favoriteAdd', 'favoriteRemove'],
          );
          _writeAsmrSyncOperationToBatch(batch, operation, operationOrder++);
        }
        await batch.commit(noResult: true);
      });
    });
  }
}
