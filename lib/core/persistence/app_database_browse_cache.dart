part of 'app_database.dart';

extension AppDatabaseBrowseCache on AppDatabase {
  Future<int> logicalBrowseCacheBytes() => _runDatabaseRead((db) async {
    final rows = await db.rawQuery('''
      SELECT (SELECT COALESCE(SUM(LENGTH(CAST(payload AS BLOB))), 0) FROM browse_snapshots)
        + (SELECT COALESCE(SUM(LENGTH(CAST(value AS BLOB))), 0) FROM app_kv_settings
           WHERE key = 'browse_page_state_v1') AS bytes
    ''');
    return (rows.single['bytes'] as num).toInt();
  });

  Future<Map<String, Object?>?> loadBrowseSnapshot({
    required String kind,
    required String scope,
    required String key,
  }) => _runDatabaseRead((db) async {
    final rows = await db.query(
      'browse_snapshots',
      columns: ['payload'],
      where: 'kind = ? AND scope = ? AND cache_key = ?',
      whereArgs: [kind, scope, key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Map<String, Object?>.from(
      jsonDecode(rows.single['payload'] as String) as Map,
    );
  });

  Future<void> saveBrowseSnapshot({
    required String kind,
    required String scope,
    required String key,
    required Map<String, Object?> payload,
  }) => _runDatabaseWrite((db) async {
    await db.insert('browse_snapshots', {
      'kind': kind,
      'scope': scope,
      'cache_key': key,
      'payload': jsonEncode(payload),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  });

  Future<void> clearBrowseSnapshots({String? kind, String? scope}) =>
      _runDatabaseWrite((db) async {
        final clauses = <String>[];
        final arguments = <String>[];
        if (kind != null) {
          clauses.add('kind = ?');
          arguments.add(kind);
        }
        if (scope != null) {
          clauses.add('scope = ?');
          arguments.add(scope);
        }
        await db.delete(
          'browse_snapshots',
          where: clauses.isEmpty ? null : clauses.join(' AND '),
          whereArgs: arguments,
        );
      });
}
