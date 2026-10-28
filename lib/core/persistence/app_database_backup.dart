part of 'app_database.dart';

extension AppDatabaseBackup on AppDatabase {
  Future<File> createPortableSnapshot(String outputPath) async {
    final output = File(outputPath);
    await output.parent.create(recursive: true);
    if (await output.exists()) await output.delete();
    final target = await openDatabase(
      output.path,
      version: AppDatabase.schemaVersion,
      singleInstance: false,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
    try {
      final source = await _database;
      await source.transaction((sourceTxn) async {
        final targetTables = await target.rawQuery(
          "SELECT name FROM sqlite_master "
          "WHERE type = 'table' AND name NOT LIKE 'sqlite_%' "
          'ORDER BY name',
        );
        await target.transaction((targetTxn) async {
          for (final row in targetTables) {
            final table = row['name'] as String;
            // Every application table is a rowid table, including tables with
            // text/composite primary keys. Seek instead of rescanning OFFSET
            // rows on each page; the first page must also include negative IDs.
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
          await targetTxn.update('track_assets', <String, Object?>{
            'cover_cache_path': null,
          });
          await targetTxn.insert('app_kv_settings', <String, Object?>{
            'key': 'audio_detail_document_read_only_import_v3',
            'value': '1',
          }, conflictAlgorithm: ConflictAlgorithm.replace);
          await targetTxn.insert('app_kv_settings', <String, Object?>{
            'key': 'backup_restore_authoritative_v1',
            'value': '1',
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        });
      });
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
      await db.update('track_assets', <String, Object?>{
        'cover_cache_path': null,
      });
      await db.insert('app_kv_settings', <String, Object?>{
        'key': 'audio_detail_document_read_only_import_v3',
        'value': '1',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await db.insert('app_kv_settings', <String, Object?>{
        'key': 'backup_restore_authoritative_v1',
        'value': '1',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      return sourceVersion;
    } finally {
      await db.close();
    }
  }
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
                (version >= 4 || columnName != 'card_cover_selected'),
          'sessions' => version >= 7 || columnName != 'is_temporary',
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
