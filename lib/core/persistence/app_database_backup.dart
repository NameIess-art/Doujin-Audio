part of 'app_database.dart';

const _listeningRestoreColumns = {
  'listening_days': 'date, milliseconds',
  'listening_work_days': 'date, work_key, milliseconds',
  'listening_history': 'work_key, track_json, last_played_at_ms, legacy_order',
  'listening_imports': 'batch_id',
};

// The portable database contains no external audio detail documents.
const _localDurationDocumentSyncKey = 'audio_detail_duration_document_v1';
const _databaseFileSuffixes = <String>['', '-wal', '-shm', '-journal'];

extension AppDatabaseBackup on AppDatabase {
  Future<void> openBeforeRestore() async {
    await _database;
  }

  Future<File> resolveDatabaseFile({
    Future<String> Function()? databasesPathProvider,
  }) async {
    final directory = Directory(
      await (databasesPathProvider ?? getDatabasesPath)(),
    );
    await directory.create(recursive: true);
    return File(p.join(directory.path, AppDatabase.fileName));
  }

  Future<void> backupDatabaseFiles({
    required File source,
    required File destination,
  }) async {
    await destination.parent.create(recursive: true);
    await deleteDatabaseFiles(destination);
    for (final suffix in _databaseFileSuffixes) {
      final file = File('${source.path}$suffix');
      if (await file.exists()) {
        await file.copy('${destination.path}$suffix');
      }
    }
  }

  Future<void> deleteDatabaseFiles(File database) async {
    for (final suffix in _databaseFileSuffixes) {
      final file = File('${database.path}$suffix');
      if (await file.exists()) await file.delete();
    }
  }

  Future<void> replaceDatabaseFile({
    required File candidate,
    required File target,
    @visibleForTesting
    Future<File> Function(File source, String newPath)? renameFile,
  }) async {
    await target.parent.create(recursive: true);
    await deleteDatabaseFiles(target);
    final doRename =
        renameFile ?? (File source, String newPath) => source.rename(newPath);
    try {
      await doRename(candidate, target.path);
    } on FileSystemException {
      // Cross-volume renames (e.g. EXDEV / ERROR_NOT_SAME_DEVICE) fail on
      // Windows and Android; stage on the destination volume then swap.
      final staged = File('${target.path}.restore.part');
      if (await staged.exists()) await staged.delete();
      try {
        await candidate.copy(staged.path);
        await staged.rename(target.path);
      } catch (_) {
        if (await staged.exists()) await staged.delete();
        rethrow;
      }
      try {
        if (await candidate.exists()) await candidate.delete();
      } on FileSystemException catch (error, stackTrace) {
        AppLogService.warning(
          'backup_restore_candidate_cleanup_failed',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
  }

  Future<File> createPortableSnapshot(String outputPath) async {
    final source = await _database;
    final output = File(outputPath);
    await output.parent.create(recursive: true);
    if (await output.exists()) {
      if (p.isAbsolute(source.path) &&
          await FileSystemEntity.identical(source.path, output.path)) {
        throw ArgumentError.value(
          outputPath,
          'outputPath',
          'Must differ from the live database',
        );
      }
      await output.delete();
    }
    final target = await openDatabase(
      output.path,
      version: AppDatabase.schemaVersion,
      singleInstance: false,
      onConfigure: (db) async {
        // Use rawQuery for PRAGMAs that return a result row on Android SQLite.
        await db.rawQuery('PRAGMA busy_timeout = 5000');
        await db.rawQuery('PRAGMA secure_delete = ON');
        await db.execute('PRAGMA synchronous = NORMAL');
      },
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
    try {
      final tables = (await target.rawQuery(
        "SELECT name FROM sqlite_master "
        "WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
      )).map((row) => row['name'] as String).toList(growable: false);
      if (p.isAbsolute(source.path)) {
        await _copyAttachedSnapshot(source.path, target, tables);
      } else {
        await _copyInMemorySnapshot(source, target, tables);
      }
      await _materializeSnapshotSyncLedgers(target);
      await _writePortableDatabaseFlags(target);
      final integrity = await target.rawQuery('PRAGMA integrity_check');
      if (integrity.singleOrNull?['integrity_check'] != 'ok') {
        throw StateError('database_snapshot_integrity_failed');
      }
    } finally {
      await target.close();
    }
    return output;
  }

  Future<int> validateAndMigrateRestoreCandidate(String path) async {
    final inspection = await openDatabase(
      path,
      readOnly: true,
      singleInstance: false,
    );
    late final int sourceVersion;
    try {
      final versionRows = await inspection.rawQuery('PRAGMA user_version');
      sourceVersion =
          (versionRows.firstOrNull?['user_version'] as num?)?.toInt() ?? -1;
      if (sourceVersion < 1 || sourceVersion > AppDatabase.schemaVersion) {
        throw const FormatException('unsupported_database_schema');
      }
      // Validate tables present in the source version before migration can
      // recreate them and hide data loss.
      await _validateRestoreSchema(inspection, version: sourceVersion);
    } finally {
      await inspection.close();
    }
    final db = await openDatabase(
      path,
      version: AppDatabase.schemaVersion,
      singleInstance: false,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
    try {
      final integrity = await db.rawQuery('PRAGMA integrity_check');
      if (integrity.singleOrNull?['integrity_check'] != 'ok') {
        throw const FormatException('invalid_database');
      }
      if (sourceVersion < AppDatabase.schemaVersion) {
        await _validateRestoreSchema(db);
      }
      await _writePortableDatabaseFlags(db);
      return sourceVersion;
    } finally {
      await db.close();
    }
  }

  Future<void> preserveNewerListeningData({
    required String localPath,
    required String candidatePath,
    required Map<String, String> interestCatalogKeys,
    required bool Function(String local, String? backup) keepLocalInterest,
  }) async {
    final candidate = await openDatabase(candidatePath, singleInstance: false);
    try {
      await candidate.delete(
        'app_kv_settings',
        where: 'key = ?',
        whereArgs: [_crossPlatformSyncDeviceIdKey],
      );
      if (!await _attachReadableRestoreSource(candidate, localPath)) return;
      await candidate.transaction((txn) async {
        final localActivity = await _listeningRecency(txn, 'local_restore');
        final backupActivity = await _listeningRecency(txn, 'main');
        final keepLocalActivity =
            localActivity.lastPlayed > backupActivity.lastPlayed ||
            (localActivity.lastPlayed == backupActivity.lastPlayed &&
                localActivity.totalMs > backupActivity.totalMs);
        final keepLocalHistory =
            localActivity.historyChanged == backupActivity.historyChanged
            ? keepLocalActivity
            : localActivity.historyChanged > backupActivity.historyChanged;
        for (final MapEntry(key: table, value: columns)
            in _listeningRestoreColumns.entries) {
          if (table == 'listening_history'
              ? keepLocalHistory
              : keepLocalActivity) {
            await txn.rawDelete('DELETE FROM main.$table');
            await txn.execute(
              'INSERT INTO main.$table ($columns) '
              'SELECT $columns FROM local_restore.$table',
            );
          }
        }
        if (keepLocalActivity) {
          final localLedgerTables = (await txn.rawQuery(
            "SELECT name FROM local_restore.sqlite_master WHERE type = 'table' "
            "AND name IN ('sync_listening_day_ledger', 'sync_listening_work_ledger')",
          )).map((row) => row['name'] as String).toSet();
          if (localLedgerTables.contains('sync_listening_day_ledger')) {
            await txn.rawDelete('DELETE FROM main.sync_listening_day_ledger');
            await txn.execute(
              'INSERT INTO main.sync_listening_day_ledger (device_id, date, milliseconds) '
              'SELECT device_id, date, milliseconds FROM local_restore.sync_listening_day_ledger',
            );
          }
          if (localLedgerTables.contains('sync_listening_work_ledger')) {
            await txn.rawDelete('DELETE FROM main.sync_listening_work_ledger');
            await txn.execute(
              'INSERT INTO main.sync_listening_work_ledger (device_id, date, work_key, milliseconds) '
              'SELECT device_id, date, work_key, milliseconds FROM local_restore.sync_listening_work_ledger',
            );
          }
        }
        final localSettings = [
          if (keepLocalActivity) _listeningActivityPlaybackAtKey,
          if (keepLocalHistory) _listeningHistoryEditedAtKey,
        ];
        for (final key in localSettings) {
          await txn.delete(
            'app_kv_settings',
            where: 'key = ?',
            whereArgs: [key],
          );
          await txn.execute(
            'INSERT INTO main.app_kv_settings (key, value) '
            'SELECT key, value FROM local_restore.app_kv_settings WHERE key = ?',
            [key],
          );
        }
        if (keepLocalActivity) {
          await txn.execute(
            'INSERT INTO main.app_kv_settings (key, value) '
            'SELECT key, value FROM local_restore.app_kv_settings WHERE key = ?',
            [_crossPlatformSyncDeviceIdKey],
          );
        }
        if (keepLocalActivity != keepLocalHistory) {
          // The chosen history may omit the latest play in the chosen totals.
          final lastPlayed = keepLocalActivity
              ? localActivity.lastPlayed
              : backupActivity.lastPlayed;
          await txn.insert('app_kv_settings', {
            'key': _listeningActivityPlaybackAtKey,
            'value': lastPlayed.toString(),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        for (final MapEntry(key: key, value: catalogKey)
            in interestCatalogKeys.entries) {
          final local = await _readRestoreSetting(txn, 'local_restore', key);
          if (local == null) continue;
          final backup = await _readRestoreSetting(txn, 'main', key);
          if (keepLocalInterest(local, backup)) {
            await txn.insert('app_kv_settings', {
              'key': key,
              'value': local,
            }, conflictAlgorithm: ConflictAlgorithm.replace);
            final catalog = await _readRestoreSetting(
              txn,
              'local_restore',
              catalogKey,
            );
            if (catalog == null) {
              await txn.delete(
                'app_kv_settings',
                where: 'key = ?',
                whereArgs: [catalogKey],
              );
            } else {
              await txn.insert('app_kv_settings', {
                'key': catalogKey,
                'value': catalog,
              }, conflictAlgorithm: ConflictAlgorithm.replace);
            }
          }
        }
      });
    } finally {
      await candidate.close();
    }
  }

  /// Clears the active sync device ID on a fresh full-restore candidate while
  /// keeping `sync_listening_*_ledger` historical totals intact so the restored
  /// installation mints a distinct device ID without double-counting past hours.
  Future<void> clearActiveSyncDeviceIdInCandidate(String candidatePath) async {
    final candidate = await openDatabase(candidatePath, singleInstance: false);
    try {
      await candidate.delete(
        'app_kv_settings',
        where: 'key = ?',
        whereArgs: [_crossPlatformSyncDeviceIdKey],
      );
    } finally {
      await candidate.close();
    }
  }

  /// Extracts platform-independent sync state and portable ASMR preferences
  /// from an already validated backup SQLite candidate.
  Future<
    ({
      PersistedCrossPlatformSyncSnapshot syncSnapshot,
      String? asmrContentLanguage,
      List<String>? asmrVisibleCategories,
    })
  >
  extractPortableBackupData({
    required String candidatePath,
    required String fallbackDeviceId,
    required Iterable<String> interestSettingKeys,
  }) async {
    final candidate = await openDatabase(candidatePath, singleInstance: false);
    try {
      return await candidate.transaction((txn) async {
        final syncSnapshot = await _exportSyncSnapshotInTxn(
          txn,
          generateDeviceId: () => fallbackDeviceId,
          interestSettingKeys: interestSettingKeys,
        );
        final langRows = await txn.query(
          'app_kv_settings',
          columns: const ['value'],
          where: 'key = ?',
          whereArgs: const ['asmr_content_language_v1'],
          limit: 1,
        );
        final rawLang = langRows.firstOrNull?['value'] as String?;
        final categoryRows = await txn.query(
          'asmr_visible_categories',
          columns: const ['category'],
          orderBy: 'sort_order ASC',
        );
        final categories = categoryRows
            .map((r) => r['category'] as String?)
            .whereType<String>()
            .where((c) => c.trim().isNotEmpty)
            .toList(growable: false);
        return (
          syncSnapshot: syncSnapshot,
          asmrContentLanguage: (rawLang != null && rawLang.trim().isNotEmpty)
              ? rawLang.trim()
              : null,
          asmrVisibleCategories: categories.isEmpty ? null : categories,
        );
      });
    } finally {
      await candidate.close();
    }
  }

  Future<void> applyPortableBackupDatabaseSettings({
    String? asmrContentLanguage,
    List<String>? asmrVisibleCategories,
  }) async {
    if (asmrContentLanguage == null &&
        (asmrVisibleCategories == null || asmrVisibleCategories.isEmpty)) {
      return;
    }
    await _runDatabaseWrite((db) async {
      await db.transaction((txn) async {
        final batch = txn.batch();
        if (asmrContentLanguage != null) {
          batch.insert(
            'app_kv_settings',
            <String, Object?>{
              'key': 'asmr_content_language_v1',
              'value': asmrContentLanguage,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        if (asmrVisibleCategories != null &&
            asmrVisibleCategories.isNotEmpty) {
          batch.delete('asmr_visible_categories');
          for (var i = 0; i < asmrVisibleCategories.length; i++) {
            batch.insert(
              'asmr_visible_categories',
              <String, Object?>{
                'category': asmrVisibleCategories[i],
                'sort_order': i,
              },
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          }
        }
        await batch.commit(noResult: true);
      });
    });
  }

  Future<void> ensureSyncDeviceIdWhenListeningPresent() =>
      _runDatabaseRead((db) async {
        await db.transaction((txn) async {
          final idRows = await txn.query(
            'app_kv_settings',
            columns: const ['value'],
            where: 'key = ?',
            whereArgs: const [_crossPlatformSyncDeviceIdKey],
            limit: 1,
          );
          final existing = (idRows.firstOrNull?['value'] as String?)?.trim();
          if (existing != null && existing.isNotEmpty) return;
          final hasListening =
              (await txn.query('listening_days', limit: 1)).isNotEmpty ||
              (await txn.query('listening_work_days', limit: 1)).isNotEmpty;
          if (!hasListening) return;
          await txn.insert(
            'app_kv_settings',
            <String, Object?>{
              'key': _crossPlatformSyncDeviceIdKey,
              'value': _generateSnapshotLedgerUuidV4(),
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        });
      });
}

Future<void> _materializeSnapshotSyncLedgers(Database target) =>
    target.transaction((txn) async {
      final idRows = await txn.query(
        'app_kv_settings',
        columns: const ['value'],
        where: 'key = ?',
        whereArgs: const [_crossPlatformSyncDeviceIdKey],
        limit: 1,
      );
      final existingId = (idRows.firstOrNull?['value'] as String?)?.trim();
      var deviceId = (existingId != null && existingId.isNotEmpty)
          ? existingId
          : null;
      if (deviceId == null) {
        final hasDays =
            (await txn.query('listening_days', limit: 1)).isNotEmpty ||
            (await txn.query('listening_work_days', limit: 1)).isNotEmpty;
        if (!hasDays) return;
        deviceId = _generateSnapshotLedgerUuidV4();
        await txn.insert(
          'app_kv_settings',
          <String, Object?>{
            'key': _crossPlatformSyncDeviceIdKey,
            'value': deviceId,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await _snapshotDayLedgerInTxn(txn, deviceId);
      await _snapshotWorkDayLedgerInTxn(txn, deviceId);
    });

String _generateSnapshotLedgerUuidV4() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  String hex(int start, int end) => bytes
      .sublist(start, end)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
}

Future<void> _writePortableDatabaseFlags(Database db) =>
    db.transaction((txn) async {
      final batch = txn.batch();
      batch.update(
        'track_assets',
        {'cover_cache_path': null},
        where: 'cover_cache_path IS NOT NULL',
      );
      batch.delete(
        'app_kv_settings',
        where: 'key = ?',
        whereArgs: [_localDurationDocumentSyncKey],
      );
      for (final key in const [
        'audio_detail_document_read_only_import_v3',
        'backup_restore_authoritative_v1',
      ]) {
        batch.insert('app_kv_settings', {
          'key': key,
          'value': '1',
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });

Future<void> _copyAttachedSnapshot(
  String sourcePath,
  Database target,
  List<String> tables,
) async {
  final columnsByTable = <String, String>{};
  for (final table in tables) {
    final columns = await target.rawQuery('PRAGMA table_info("$table")');
    columnsByTable[table] = columns.map((row) => '"${row['name']}"').join(', ');
  }
  await target.execute('ATTACH DATABASE ? AS snapshot_source', [sourcePath]);
  var inTransaction = false;
  try {
    // Use BEGIN DEFERRED instead of target.transaction() (which emits BEGIN
    // IMMEDIATE and would take a write lock on the attached live database).
    // Reading from snapshot_source inside a deferred transaction only takes a
    // WAL read snapshot while writing to main, keeping all tables consistent
    // without blocking concurrent live writes.
    await target.execute('BEGIN DEFERRED');
    inTransaction = true;
    final batch = target.batch();
    for (final MapEntry(key: table, value: columns)
        in columnsByTable.entries) {
      batch.execute(
        'INSERT OR REPLACE INTO main."$table" ($columns) '
        'SELECT $columns FROM snapshot_source."$table" ORDER BY rowid',
      );
    }
    await batch.apply(noResult: true);
    await target.execute('COMMIT');
    inTransaction = false;
  } catch (_) {
    if (inTransaction) {
      try {
        await target.execute('ROLLBACK');
      } catch (_) {
        // SQLite may have already rolled back on certain errors.
      }
    }
    rethrow;
  } finally {
    await target.execute('DETACH DATABASE snapshot_source');
  }
}

Future<void> _copyInMemorySnapshot(
  Database source,
  Database target,
  List<String> tables,
) => source.transaction((sourceTxn) async {
  await target.transaction((targetTxn) async {
    for (final table in tables) {
      int? lastRowId;
      while (true) {
        final values = await sourceTxn.rawQuery(
          'SELECT rowid AS __snapshot_rowid, * FROM "$table" '
          '${lastRowId == null ? '' : 'WHERE rowid > ? '}'
          'ORDER BY rowid LIMIT 500',
          lastRowId == null ? null : [lastRowId],
        );
        if (values.isEmpty) break;
        final batch = targetTxn.batch();
        for (final value in values) {
          batch.insert(
            table,
            Map<String, Object?>.of(value)..remove('__snapshot_rowid'),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await batch.commit(noResult: true);
        lastRowId = values.last['__snapshot_rowid']! as int;
      }
    }
  });
});

Future<bool> _attachReadableRestoreSource(
  Database candidate,
  String localPath,
) async {
  try {
    await candidate.execute('ATTACH DATABASE ? AS local_restore', [localPath]);
    final check = await candidate.rawQuery(
      'PRAGMA local_restore.quick_check(1)',
    );
    if (check.singleOrNull?['quick_check'] != 'ok') {
      throw const FormatException('invalid_local_database');
    }
    // An open handle and SQLite integrity check do not guarantee that the
    // local copy still has the tables needed for the optional data merge.
    for (final entry in _listeningRestoreColumns.entries) {
      await candidate.rawQuery(
        'SELECT ${entry.value} FROM local_restore.${entry.key} LIMIT 0',
      );
    }
    await candidate.rawQuery(
      'SELECT key, value FROM local_restore.app_kv_settings LIMIT 0',
    );
    return true;
  } on Exception catch (error, stackTrace) {
    AppLogService.warning(
      'backup_restore_local_data_unavailable',
      error: error,
      stackTrace: stackTrace,
    );
    return false;
  }
}

Future<({int lastPlayed, int historyChanged, int totalMs})> _listeningRecency(
  Transaction txn,
  String schema,
) async {
  final row = (await txn.rawQuery(
    'SELECT (SELECT MAX(last_played_at_ms) FROM $schema.listening_history) '
    'AS last_played, (SELECT SUM(milliseconds) FROM $schema.listening_days) '
    'AS total_ms, (SELECT value FROM $schema.app_kv_settings WHERE key = ?) '
    'AS history_edited_at, (SELECT value FROM $schema.app_kv_settings '
    'WHERE key = ?) AS activity_playback_at',
    [_listeningHistoryEditedAtKey, _listeningActivityPlaybackAtKey],
  )).single;
  final lastVisible = (row['last_played'] as int?) ?? -1;
  final historyEdited = int.tryParse(row['history_edited_at'] as String? ?? '');
  final lastRecorded = int.tryParse(
    row['activity_playback_at'] as String? ?? '',
  );
  return (
    lastPlayed: lastRecorded != null && lastRecorded > lastVisible
        ? lastRecorded
        : lastVisible,
    historyChanged: historyEdited != null && historyEdited > lastVisible
        ? historyEdited
        : lastVisible,
    totalMs: (row['total_ms'] as int?) ?? 0,
  );
}

Future<String?> _readRestoreSetting(
  Transaction txn,
  String schema,
  String key,
) async {
  final rows = await txn.rawQuery(
    'SELECT value FROM $schema.app_kv_settings WHERE key = ?',
    [key],
  );
  return rows.singleOrNull?['value'] as String?;
}

Future<void> _validateRestoreSchema(
  Database candidate, {
  int version = AppDatabase.schemaVersion,
}) async {
  // Derive requirements from the production schema so new persistence tables
  // and constraints cannot silently be omitted from restore validation.
  final reference = await openDatabase(
    inMemoryDatabasePath,
    version: AppDatabase.schemaVersion,
    singleInstance: false,
    onCreate: _onCreate,
  );
  try {
    final requiredTables = await reference.rawQuery(
      "SELECT name FROM sqlite_master "
      "WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
    );
    final candidateTables = (await candidate.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    )).map((row) => row['name']).toSet();
    for (final table in requiredTables) {
      final name = table['name']! as String;
      if (version < 22 && name.startsWith('sync_')) continue;
      if (version < 14 && name.startsWith('listening_')) continue;
      if (version < 6 && name.startsWith('audio_detail_')) continue;
      if (!candidateTables.contains(name)) {
        throw const FormatException('missing_database_tables');
      }
      var requiredColumns = await reference.rawQuery(
        'PRAGMA table_info("$name")',
      );
      requiredColumns = requiredColumns.where((column) {
        final columnName = column['name'];
        return switch (name) {
          'audio_details' =>
            (version >= 2 || columnName != 'card_cover_path') &&
                (version >= 3 || columnName != 'duration_ms') &&
                (version >= 4 || columnName != 'card_cover_selected') &&
                (version >= 21 ||
                    !const {
                      'listen_status',
                      'user_rating',
                      'review_text',
                      'review_updated_at_ms',
                    }.contains(columnName)),
          'asmr_works' =>
            version >= 21 ||
                !const {
                  'listen_status',
                  'user_rating',
                  'review_text',
                  'review_updated_at_ms',
                }.contains(columnName),
          'asmr_sync_operations' =>
            version >= 21 ||
                !const {
                  'progress',
                  'user_rating',
                  'review_text',
                  'has_review_payload',
                }.contains(columnName),
          'sessions' => version >= 7 || columnName != 'is_temporary',
          'session_audio_effects' =>
            version >= 17 || columnName != 'front_back',
          'playback_queues' =>
            version >= 16 ||
                !const {'entry_count', 'track_count'}.contains(columnName),
          'playback_queue_entries' || 'playback_queue_entry_tracks' =>
            version >= 19 || columnName != 'path_match_key',
          'time_segment_labels' =>
            version >= 12 || columnName != 'track_match_key',
          _ => true,
        };
      }).toList();
      if (version < 6 && name == 'audio_details') {
        requiredColumns = [
          ...requiredColumns,
          for (final column in ['voice_actors_json', 'tags_json'])
            {'name': column, 'type': 'TEXT', 'notnull': 1, 'pk': 0},
        ];
      }
      if (version < 15 && name == 'asmr_works') {
        requiredColumns = requiredColumns
            .where(
              (column) =>
                  column['name'] != 'work_key' &&
                  column['name'] != 'resources_json',
            )
            .map(
              (column) => column['name'] == 'id'
                  ? {...column, 'notnull': 0, 'pk': 1}
                  : column,
            )
            .toList();
      } else if (version < 15 &&
          const {
            'asmr_work_voice_actors',
            'asmr_work_tags',
            'asmr_work_lists',
          }.contains(name)) {
        requiredColumns = requiredColumns
            .map(
              (column) => column['name'] == 'work_id'
                  ? {...column, 'type': 'INTEGER'}
                  : column,
            )
            .toList();
      }
      final actualColumns = await candidate.rawQuery(
        'PRAGMA table_info("$name")',
      );
      final actualByName = {
        for (final column in actualColumns) column['name']: column,
      };
      for (final required in requiredColumns) {
        final actual = actualByName[required['name']];
        // Defaults can differ after ALTER TABLE migrations, but column types,
        // nullability and primary-key positions must preserve the contract.
        if (actual == null ||
            actual['type'] != required['type'] ||
            actual['notnull'] != required['notnull'] ||
            actual['pk'] != required['pk']) {
          throw const FormatException('invalid_database_columns');
        }
      }
      final requiredPrimaryKey = requiredColumns
          .where((column) => (column['pk']! as int) > 0)
          .length;
      final actualPrimaryKey = actualColumns
          .where((column) => (column['pk']! as int) > 0)
          .length;
      if (requiredPrimaryKey != actualPrimaryKey) {
        throw const FormatException('invalid_database_primary_key');
      }
      final requiredUniqueKeys = version < 15 && name == 'asmr_works'
          ? <String>{}
          : await _restoreUniqueKeys(reference, name);
      final actualUniqueKeys = await _restoreUniqueKeys(candidate, name);
      if (!actualUniqueKeys.containsAll(requiredUniqueKeys)) {
        throw const FormatException('invalid_database_unique_constraints');
      }
    }
  } finally {
    await reference.close();
  }
}

Future<Set<String>> _restoreUniqueKeys(Database db, String table) async {
  final indexes = await db.rawQuery('PRAGMA index_list("$table")');
  final keys = <String>{};
  for (final index in indexes) {
    if (index['unique'] != 1 || index['partial'] != 0) continue;
    final name = (index['name']! as String).replaceAll('"', '""');
    final columns = await db.rawQuery('PRAGMA index_xinfo("$name")');
    keys.add(
      jsonEncode([
        for (final column in columns)
          if (column['key'] == 1)
            [column['name'], column['desc'], column['coll']],
      ]),
    );
  }
  return keys;
}
