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
            var offset = 0;
            while (true) {
              final values = await sourceTxn.query(
                table,
                limit: 500,
                offset: offset,
              );
              if (values.isEmpty) break;
              final batch = targetTxn.batch();
              for (final value in values) {
                batch.insert(
                  table,
                  value,
                  conflictAlgorithm: ConflictAlgorithm.replace,
                );
              }
              await batch.commit(noResult: true);
              offset += values.length;
            }
          }
          await targetTxn.update('track_assets', <String, Object?>{
            'cover_cache_path': null,
          });
          await targetTxn.insert('app_kv_settings', <String, Object?>{
            'key': 'audio_detail_document_read_only_import_v2',
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
      final tables = (await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      )).map((row) => row['name']).whereType<String>().toSet();
      const requiredTables = <String>{
        'tracks',
        'sessions',
        'audio_details',
        'library_entries',
        'app_kv_settings',
        'asmr_works',
      };
      if (!tables.containsAll(requiredTables)) {
        throw const FormatException('missing_database_tables');
      }
      await db.update('track_assets', <String, Object?>{
        'cover_cache_path': null,
      });
      await db.insert('app_kv_settings', <String, Object?>{
        'key': 'audio_detail_document_read_only_import_v2',
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
