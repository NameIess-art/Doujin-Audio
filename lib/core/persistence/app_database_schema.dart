part of 'app_database.dart';

Future<void> _onCreate(Database db, int version) async {
  await db.execute('''
      CREATE TABLE tracks (
        path TEXT PRIMARY KEY,
        display_name TEXT NOT NULL,
        group_key TEXT NOT NULL,
        group_title TEXT NOT NULL,
        group_subtitle TEXT NOT NULL,
        is_single INTEGER NOT NULL DEFAULT 0,
        is_video INTEGER NOT NULL DEFAULT 0,
        duration_ms INTEGER NOT NULL DEFAULT 0
      )
    ''');
  await _createTrackDetailTables(db);
  await _createTrackIndexes(db);
  await _createSessionsTable(db);
  await _createSessionDetailTables(db);
  await _createQueuePathIndexes(db);
  await _createPlaybackQueueSummary(db);
  await _createAsmrTables(db);
  await _createAudioDetailsTable(db);
  await _createLibraryEntriesTable(db);
  await _createTimeSegmentLabelsTable(db);
  await _createListeningTables(db);
}

Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
  if (oldVersion >= newVersion) return;
  if (oldVersion < 14 && newVersion >= 14) await _createListeningTables(db);
  if (oldVersion < 2) {
    await _addColumnIfMissing(db, 'audio_details', 'card_cover_path', 'TEXT');
  }
  if (oldVersion < 3) {
    await _addColumnIfMissing(
      db,
      'audio_details',
      'duration_ms',
      'INTEGER NOT NULL DEFAULT 0',
    );
  }
  if (oldVersion < 4) {
    await _addColumnIfMissing(
      db,
      'audio_details',
      'card_cover_selected',
      'INTEGER NOT NULL DEFAULT 0',
    );
  }
  if (oldVersion < 6 && newVersion >= 6) {
    await _migrateAudioDetailsToV6(db);
  }
  if (oldVersion < 7 && newVersion >= 7) {
    await _addColumnIfMissing(
      db,
      'sessions',
      'is_temporary',
      'INTEGER NOT NULL DEFAULT 0',
    );
    await _addColumnIfMissing(
      db,
      'sessions',
      'retain_in_now_playing',
      'INTEGER NOT NULL DEFAULT 0',
    );
  }
  if (oldVersion < 8 && newVersion >= 8) {
    await _createSessionsTable(db, tableName: 'sessions_v8');
    await db.execute('''
      INSERT INTO sessions_v8 (
        id, track_path, is_temporary, loop_mode,
        created_at_ms, updated_at_ms, last_played_at_ms, sort_order
      )
      SELECT id, track_path, is_temporary, loop_mode,
        created_at_ms, updated_at_ms, last_played_at_ms, sort_order
      FROM sessions
    ''');
    await db.execute('DROP TABLE sessions');
    await db.execute('ALTER TABLE sessions_v8 RENAME TO sessions');
  }
  await _createTrackDetailTables(db);
  await _createTrackIndexes(db);
  await _createSessionDetailTables(db);
  if (oldVersion < 16 && newVersion >= 16) {
    await _createPlaybackQueueSummary(db);
    // Named queues already store the rest of the detached track's queue
    // under its normal entry IDs. Keep the detached occurrence only.
    await db.execute('''
      DELETE FROM playback_queue_entry_tracks
      WHERE entry_id = '__custom_queue__' AND sort_order > 0
        AND session_id IN (SELECT session_id FROM playback_queues)
    ''');
    await db.execute('''
      UPDATE playback_queues SET
        entry_count = (SELECT COUNT(*) FROM playback_queue_entries
          WHERE session_id = playback_queues.session_id),
        track_count = (SELECT COUNT(*) FROM playback_queue_entry_tracks
          WHERE session_id = playback_queues.session_id
            AND entry_id != '__custom_queue__')
    ''');
  }
  if (oldVersion < 17 && newVersion >= 17) {
    await _addColumnIfMissing(
      db,
      'session_audio_effects',
      'front_back',
      'REAL NOT NULL DEFAULT 0.0',
    );
  }
  if (oldVersion < 15 && newVersion >= 15) await _migrateAsmrIdentity(db);
  await _createAsmrTables(db);
  await _createAudioDetailsTable(db);
  await _createLibraryEntriesTable(db);
  await _createTimeSegmentLabelsTable(db);
  if (oldVersion < 12 && newVersion >= 12) {
    await _backfillTimeSegmentMatchKeys(db);
  }
  if (oldVersion < 9 && newVersion >= 9) {
    await db.execute('DROP INDEX IF EXISTS idx_track_scan_generation');
    await db.execute('DROP INDEX IF EXISTS idx_track_playback_last_played');
    await db.execute('DROP INDEX IF EXISTS idx_track_playback_favorite');
  }
  if (oldVersion < 11 && newVersion >= 11) {
    await db.execute('DROP TABLE IF EXISTS browse_snapshots');
    await db.delete(
      'app_kv_settings',
      where: 'key = ?',
      whereArgs: ['browse_page_state_v1'],
    );
  }
  if (oldVersion < 13 && newVersion >= 13) {
    for (final name in [
      'idx_session_playback_session',
      'idx_playback_queue_tracks_entry',
      'idx_audio_details_target',
    ]) {
      await db.execute('DROP INDEX IF EXISTS $name');
    }
  }
  if (oldVersion < 18 && newVersion >= 18) {
    for (final name in [
      'idx_tracks_group_key',
      'idx_tracks_display_name',
      'idx_tracks_last_played_at',
      'idx_tracks_favorite',
      'idx_track_remote_kind',
      'idx_track_tags_tag',
      'idx_library_entries_library',
      'idx_library_entries_state',
    ]) {
      await db.execute('DROP INDEX IF EXISTS $name');
    }
    if (oldVersion >= 14) {
      await db.execute('DROP INDEX IF EXISTS idx_listening_history_recent');
      await _createListeningHistoryIndex(db);
    }
  }
  if (oldVersion < 19 && newVersion >= 19) {
    await _backfillQueuePathKeys(db);
    await _createQueuePathIndexes(db);
  }
  if (oldVersion < 20 && newVersion >= 20) {
    await _repairLegacyJapaneseAsmrResources(db);
  }
}

Future<void> _createListeningTables(Database db) async {
  await db.execute(
    'CREATE TABLE IF NOT EXISTS listening_days ('
    'date TEXT PRIMARY KEY, milliseconds INTEGER NOT NULL)',
  );
  await db.execute(
    'CREATE TABLE IF NOT EXISTS listening_work_days ('
    'date TEXT NOT NULL, work_key TEXT NOT NULL, milliseconds INTEGER NOT NULL, '
    'PRIMARY KEY(date, work_key))',
  );
  await db.execute(
    'CREATE TABLE IF NOT EXISTS listening_history ('
    'work_key TEXT PRIMARY KEY, track_json TEXT NOT NULL, last_played_at_ms INTEGER NOT NULL, '
    'legacy_order INTEGER NOT NULL DEFAULT 0)',
  );
  await _createListeningHistoryIndex(db);
  await db.execute(
    'CREATE TABLE IF NOT EXISTS listening_imports (batch_id TEXT PRIMARY KEY)',
  );
}

Future<void> _createListeningHistoryIndex(Database db) => db.execute(
  'CREATE INDEX IF NOT EXISTS idx_listening_history_recent '
  'ON listening_history(last_played_at_ms DESC, legacy_order, work_key)',
);

Future<void> _addColumnIfMissing(
  Database db,
  String table,
  String column,
  String definition,
) async {
  final columns = await db.rawQuery('PRAGMA table_info($table)');
  final exists = columns.any((row) => row['name'] == column);
  if (exists) return;
  await db.execute('ALTER TABLE $table ADD COLUMN $column $definition');
}

Future<void> _createSessionsTable(
  Database db, {
  String tableName = 'sessions',
}) async {
  await db.execute('''
      CREATE TABLE $tableName (
        id TEXT PRIMARY KEY,
        track_path TEXT NOT NULL,
        is_temporary INTEGER NOT NULL DEFAULT 0,
        loop_mode INTEGER NOT NULL,
        created_at_ms INTEGER,
        updated_at_ms INTEGER,
        last_played_at_ms INTEGER,
        sort_order INTEGER NOT NULL DEFAULT 0
      )
    ''');
}

Future<void> _createTrackDetailTables(Database db) async {
  await db.execute('''
      CREATE TABLE IF NOT EXISTS track_scan_info (
        path TEXT PRIMARY KEY,
        scanned_at_ms INTEGER,
        file_size_bytes INTEGER,
        modified_at_ms INTEGER,
        scan_generation INTEGER NOT NULL DEFAULT 0
      )
    ''');
  await db.execute('''
      CREATE TABLE IF NOT EXISTS track_playback_state (
        path TEXT PRIMARY KEY,
        last_played_position_ms INTEGER NOT NULL DEFAULT 0,
        last_played_at_ms INTEGER,
        is_favorite INTEGER NOT NULL DEFAULT 0
      )
    ''');
  await db.execute('''
      CREATE TABLE IF NOT EXISTS track_assets (
        path TEXT PRIMARY KEY,
        cover_cache_path TEXT,
        lyrics_path TEXT,
        manual_cover_path TEXT,
        remote_cover_url TEXT
      )
    ''');
  await db.execute('''
      CREATE TABLE IF NOT EXISTS track_remote_metadata (
        path TEXT PRIMARY KEY,
        remote_metadata_kind TEXT,
        remote_metadata_json TEXT
      )
    ''');
  await db.execute('''
      CREATE TABLE IF NOT EXISTS track_tags (
        path TEXT NOT NULL,
        tag TEXT NOT NULL,
        sort_order INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(path, tag)
      )
    ''');
}

Future<void> _createSessionDetailTables(Database db) async {
  await db.execute('''
      CREATE TABLE IF NOT EXISTS session_playback_state (
        session_id TEXT PRIMARY KEY,
        volume REAL NOT NULL DEFAULT 1.0,
        speed REAL NOT NULL DEFAULT 1.0,
        position_ms INTEGER NOT NULL DEFAULT 0,
        duration_ms INTEGER NOT NULL DEFAULT 0,
        current_queue_index INTEGER NOT NULL DEFAULT 0,
        channel_swap INTEGER NOT NULL DEFAULT 0
      )
    ''');
  await db.execute('''
      CREATE TABLE IF NOT EXISTS session_audio_effects (
        session_id TEXT PRIMARY KEY,
        skip_silence_enabled INTEGER NOT NULL DEFAULT 0,
        noise_reduction_enabled INTEGER NOT NULL DEFAULT 0,
        volume_normalization_enabled INTEGER NOT NULL DEFAULT 0,
        eq_enabled INTEGER NOT NULL DEFAULT 0,
        eq_preset_id TEXT,
        panning REAL NOT NULL DEFAULT 0.0,
        front_back REAL NOT NULL DEFAULT 0.0
      )
    ''');
  await db.execute('''
      CREATE TABLE IF NOT EXISTS session_eq_bands (
        session_id TEXT NOT NULL,
        frequency_hz INTEGER NOT NULL,
        gain_db REAL NOT NULL,
        PRIMARY KEY(session_id, frequency_hz)
      )
    ''');
  await db.execute('''
      CREATE TABLE IF NOT EXISTS playback_queues (
        session_id TEXT PRIMARY KEY,
        name TEXT NOT NULL DEFAULT '',
        color_value INTEGER
      )
    ''');
  await db.execute('''
      CREATE TABLE IF NOT EXISTS playback_queue_entries (
        session_id TEXT NOT NULL,
        entry_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        title TEXT NOT NULL DEFAULT '',
        work_root_path TEXT,
        path_match_key TEXT,
        sort_order INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(session_id, entry_id)
      )
    ''');
  await db.execute('''
      CREATE TABLE IF NOT EXISTS playback_queue_entry_tracks (
        session_id TEXT NOT NULL,
        entry_id TEXT NOT NULL,
        track_path TEXT NOT NULL,
        path_match_key TEXT,
        display_name TEXT NOT NULL DEFAULT '',
        group_key TEXT NOT NULL DEFAULT '',
        group_title TEXT NOT NULL DEFAULT '',
        group_subtitle TEXT NOT NULL DEFAULT '',
        is_single INTEGER NOT NULL DEFAULT 0,
        is_video INTEGER NOT NULL DEFAULT 0,
        duration_ms INTEGER NOT NULL DEFAULT 0,
        file_size_bytes INTEGER,
        remote_cover_url TEXT,
        remote_metadata_kind TEXT,
        remote_metadata_json TEXT,
        duplicate_index INTEGER NOT NULL DEFAULT 0,
        sort_order INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(session_id, entry_id, sort_order)
      )
    ''');
  for (final column in <(String, String)>[
    ('display_name', "TEXT NOT NULL DEFAULT ''"),
    ('group_key', "TEXT NOT NULL DEFAULT ''"),
    ('group_title', "TEXT NOT NULL DEFAULT ''"),
    ('group_subtitle', "TEXT NOT NULL DEFAULT ''"),
    ('is_single', 'INTEGER NOT NULL DEFAULT 0'),
    ('is_video', 'INTEGER NOT NULL DEFAULT 0'),
    ('duration_ms', 'INTEGER NOT NULL DEFAULT 0'),
    ('file_size_bytes', 'INTEGER'),
    ('remote_cover_url', 'TEXT'),
    ('remote_metadata_kind', 'TEXT'),
    ('remote_metadata_json', 'TEXT'),
  ]) {
    await _addColumnIfMissing(
      db,
      'playback_queue_entry_tracks',
      column.$1,
      column.$2,
    );
  }
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_sessions_sort_order '
    'ON sessions(sort_order)',
  );
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_playback_queue_entries_order '
    'ON playback_queue_entries(session_id, sort_order)',
  );
}

Future<void> _createPlaybackQueueSummary(Database db) async {
  for (final column in ['entry_count', 'track_count']) {
    await _addColumnIfMissing(
      db,
      'playback_queues',
      column,
      'INTEGER NOT NULL DEFAULT 0',
    );
  }
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_queue_tracks_session_path '
    'ON playback_queue_entry_tracks(session_id, track_path)',
  );
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_queue_tracks_content_uri '
    "ON playback_queue_entry_tracks(track_path) WHERE track_path >= 'content://' "
    "AND track_path < 'content:/0'",
  );
}

Future<void> _createTrackIndexes(Database db) => db.execute(
  'CREATE INDEX IF NOT EXISTS idx_tracks_scan_generation '
  'ON track_scan_info(scan_generation)',
);

Future<void> _createAsmrTables(Database db) async {
  await db.execute('''
      CREATE TABLE IF NOT EXISTS app_kv_settings (
        key TEXT PRIMARY KEY,
        value TEXT
      )
    ''');
  await db.execute('''
      CREATE TABLE IF NOT EXISTS asmr_works (
        work_key TEXT PRIMARY KEY,
        id INTEGER NOT NULL,
        resources_json TEXT,
        title TEXT NOT NULL DEFAULT '',
        circle_name TEXT NOT NULL DEFAULT '',
        source_id TEXT NOT NULL DEFAULT '',
        source_type TEXT NOT NULL DEFAULT '',
        source_url TEXT NOT NULL DEFAULT '',
        cover_url TEXT NOT NULL DEFAULT '',
        thumbnail_url TEXT NOT NULL DEFAULT '',
        main_cover_url TEXT NOT NULL DEFAULT '',
        release_date_ms INTEGER,
        create_date_ms INTEGER,
        duration_ms INTEGER NOT NULL DEFAULT 0,
        dl_count INTEGER NOT NULL DEFAULT 0,
        review_count INTEGER NOT NULL DEFAULT 0,
        rating REAL NOT NULL DEFAULT 0,
        has_subtitle INTEGER NOT NULL DEFAULT 0,
        is_favorite INTEGER NOT NULL DEFAULT 0
      )
    ''');
  await db.execute('''
      CREATE TABLE IF NOT EXISTS asmr_work_voice_actors (
        work_id TEXT NOT NULL,
        name TEXT NOT NULL,
        sort_order INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(work_id, name)
      )
    ''');
  await db.execute('''
      CREATE TABLE IF NOT EXISTS asmr_work_tags (
        work_id TEXT NOT NULL,
        tag TEXT NOT NULL,
        sort_order INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(work_id, tag)
      )
    ''');
  await db.execute('''
      CREATE TABLE IF NOT EXISTS asmr_work_lists (
        list_type TEXT NOT NULL,
        work_id TEXT NOT NULL,
        sort_order INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(list_type, work_id)
      )
    ''');
  await db.execute('''
      CREATE TABLE IF NOT EXISTS asmr_visible_categories (
        category TEXT PRIMARY KEY,
        sort_order INTEGER NOT NULL DEFAULT 0
      )
    ''');
  await db.execute('''
      CREATE TABLE IF NOT EXISTS asmr_sync_operations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        type TEXT NOT NULL,
        work_id INTEGER NOT NULL,
        source_id TEXT NOT NULL DEFAULT '',
        created_at_ms INTEGER NOT NULL,
        retry_count INTEGER NOT NULL DEFAULT 0,
        sort_order INTEGER NOT NULL DEFAULT 0
      )
    ''');
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_asmr_work_lists_type_order '
    'ON asmr_work_lists(list_type, sort_order)',
  );
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_asmr_sync_operations_order '
    'ON asmr_sync_operations(sort_order)',
  );
}

Future<void> _createAudioDetailsTable(Database db) async {
  await db.execute('''
      CREATE TABLE IF NOT EXISTS audio_details (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        target_type TEXT NOT NULL,
        target_path TEXT NOT NULL,
        rj_code TEXT NOT NULL DEFAULT '',
        work_title TEXT NOT NULL DEFAULT '',
        circle_name TEXT NOT NULL DEFAULT '',
        card_cover_path TEXT,
        card_cover_selected INTEGER NOT NULL DEFAULT 0,
        release_date_ms INTEGER NOT NULL DEFAULT 0,
        duration_ms INTEGER NOT NULL DEFAULT 0,
        sales_count INTEGER,
        rating REAL,
        created_at_ms INTEGER NOT NULL DEFAULT 0,
        updated_at_ms INTEGER NOT NULL DEFAULT 0,
        UNIQUE(target_type, target_path)
      )
    ''');
  await _createAudioDetailValueTables(db);
}

Future<void> _createAudioDetailValueTables(Database db) async {
  await db.execute('''
      CREATE TABLE IF NOT EXISTS audio_detail_voice_actors (
        target_type TEXT NOT NULL,
        target_path TEXT NOT NULL,
        voice_actor TEXT NOT NULL,
        sort_order INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(target_type, target_path, voice_actor)
      )
    ''');
  await db.execute('''
      CREATE TABLE IF NOT EXISTS audio_detail_tags (
        target_type TEXT NOT NULL,
        target_path TEXT NOT NULL,
        tag TEXT NOT NULL,
        sort_order INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(target_type, target_path, tag)
      )
    ''');
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_audio_detail_voice_actors_target '
    'ON audio_detail_voice_actors(target_type, target_path, sort_order)',
  );
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_audio_detail_tags_target '
    'ON audio_detail_tags(target_type, target_path, sort_order)',
  );
}

Future<void> _migrateAudioDetailsToV6(Database db) async {
  final columns = await db.rawQuery('PRAGMA table_info(audio_details)');
  final hasLegacyLists = columns.any(
    (row) => row['name'] == 'voice_actors_json',
  );
  if (!hasLegacyLists) {
    await _createAudioDetailValueTables(db);
    await db.execute('DROP TABLE IF EXISTS audio_detail_backup_sync');
    return;
  }

  final legacyRows = await db.query('audio_details');
  await _createAudioDetailValueTables(db);
  for (final row in legacyRows) {
    final targetType = row['target_type'] as String;
    final targetPath = row['target_path'] as String;
    final voiceActors = _decodeLegacyAudioDetailList(row['voice_actors_json']);
    final tags = _decodeLegacyAudioDetailList(row['tags_json']);
    for (var index = 0; index < voiceActors.length; index++) {
      await db.insert('audio_detail_voice_actors', <String, Object?>{
        'target_type': targetType,
        'target_path': targetPath,
        'voice_actor': voiceActors[index],
        'sort_order': index,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    for (var index = 0; index < tags.length; index++) {
      await db.insert('audio_detail_tags', <String, Object?>{
        'target_type': targetType,
        'target_path': targetPath,
        'tag': tags[index],
        'sort_order': index,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  await db.execute('ALTER TABLE audio_details RENAME TO audio_details_v5');
  await _createAudioDetailsTable(db);
  await db.execute('''
      INSERT INTO audio_details (
        id, target_type, target_path, rj_code, work_title, circle_name,
        card_cover_path, card_cover_selected, release_date_ms, duration_ms,
        sales_count, rating, created_at_ms, updated_at_ms
      )
      SELECT
        id, target_type, target_path, rj_code, work_title, circle_name,
        card_cover_path, card_cover_selected, release_date_ms, duration_ms,
        sales_count, rating, created_at_ms, updated_at_ms
      FROM audio_details_v5
    ''');
  await db.execute('DROP TABLE audio_details_v5');
  await db.execute('DROP TABLE IF EXISTS audio_detail_backup_sync');
}

List<String> _decodeLegacyAudioDetailList(Object? value) {
  if (value is! String || value.trim().isEmpty) return const <String>[];
  try {
    final decoded = json.decode(value);
    if (decoded is! List) return const <String>[];
    final seen = <String>{};
    final values = <String>[];
    for (final item in decoded.whereType<String>()) {
      final normalized = item.trim();
      if (normalized.isNotEmpty && seen.add(normalized)) values.add(normalized);
    }
    return values;
  } on Object catch (error) {
    debugPrint('audio_detail_v6_list_migration_warning: $error');
    return const <String>[];
  }
}

Future<void> _createLibraryEntriesTable(Database db) async {
  await db.execute('''
      CREATE TABLE IF NOT EXISTS library_entries (
        library_path TEXT NOT NULL,
        path TEXT NOT NULL,
        kind TEXT NOT NULL,
        state TEXT NOT NULL DEFAULT 'active',
        parent_path TEXT,
        display_name TEXT NOT NULL DEFAULT '',
        group_key TEXT NOT NULL DEFAULT '',
        group_title TEXT NOT NULL DEFAULT '',
        group_subtitle TEXT NOT NULL DEFAULT '',
        is_single INTEGER NOT NULL DEFAULT 0,
        is_video INTEGER NOT NULL DEFAULT 0,
        scanned_at_ms INTEGER,
        file_size_bytes INTEGER,
        modified_at_ms INTEGER,
        scan_generation INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(library_path, path, kind)
      )
    ''');
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_library_entries_path '
    'ON library_entries(path)',
  );
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_library_entries_scan_generation '
    'ON library_entries(library_path, scan_generation)',
  );
}

Future<void> _createTimeSegmentLabelsTable(Database db) async {
  await db.execute('''
      CREATE TABLE IF NOT EXISTS time_segment_labels (
        id TEXT PRIMARY KEY,
        track_key TEXT NOT NULL,
        track_match_key TEXT NOT NULL,
        name TEXT NOT NULL,
        start_ms INTEGER NOT NULL,
        end_ms INTEGER NOT NULL,
        color_value INTEGER NOT NULL,
        created_at_ms INTEGER NOT NULL,
        updated_at_ms INTEGER NOT NULL
      )
    ''');
  await _addColumnIfMissing(
    db,
    'time_segment_labels',
    'track_match_key',
    "TEXT NOT NULL DEFAULT ''",
  );
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_time_segment_labels_track '
    'ON time_segment_labels(track_key, start_ms, created_at_ms)',
  );
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_time_segment_labels_match '
    'ON time_segment_labels(track_match_key, start_ms, created_at_ms)',
  );
}

Future<void> _backfillTimeSegmentMatchKeys(Database db) async {
  while (true) {
    final rows = await db.query(
      'time_segment_labels',
      columns: ['id', 'track_key'],
      where: "track_match_key = ''",
      limit: 500,
    );
    if (rows.isEmpty) return;
    final batch = db.batch();
    for (final row in rows) {
      batch.update(
        'time_segment_labels',
        {
          'track_match_key': PathMatcher.equivalenceKey(
            row['track_key'] as String,
          ),
        },
        where: 'id = ?',
        whereArgs: [row['id']],
      );
    }
    await batch.commit(noResult: true);
  }
}

Future<void> _backfillQueuePathKeys(Database db) async {
  for (final (table, pathColumn) in const [
    ('playback_queue_entries', 'work_root_path'),
    ('playback_queue_entry_tracks', 'track_path'),
  ]) {
    await _addColumnIfMissing(db, table, 'path_match_key', 'TEXT');
    int? lastRow;
    while (true) {
      final rows = await db.query(
        table,
        columns: ['rowid', pathColumn],
        where:
            '$pathColumn IS NOT NULL'
            '${lastRow == null ? '' : ' AND rowid > ?'}',
        whereArgs: lastRow == null ? null : [lastRow],
        orderBy: 'rowid',
        limit: 500,
      );
      if (rows.isEmpty) break;
      final batch = db.batch();
      for (final row in rows) {
        if (_queuePathMatchKey(row[pathColumn] as String) case final key?) {
          batch.update(
            table,
            {'path_match_key': key},
            where: 'rowid = ?',
            whereArgs: [row['rowid']],
          );
        }
      }
      await batch.commit(noResult: true);
      lastRow = rows.last['rowid'] as int;
    }
  }
}

Future<void> _createQueuePathIndexes(Database db) async {
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_queue_work_path_match '
    'ON playback_queue_entries(path_match_key) WHERE work_root_path IS NOT NULL',
  );
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_queue_track_path_match '
    'ON playback_queue_entry_tracks(path_match_key)',
  );
}

Future<void> _migrateAsmrIdentity(Database db) async {
  final columns = await db.rawQuery('PRAGMA table_info(asmr_works)');
  if (columns.isEmpty || columns.any((row) => row['name'] == 'work_key')) {
    return;
  }
  final works = await db.query('asmr_works');
  final actors = await db.query('asmr_work_voice_actors');
  final tags = await db.query('asmr_work_tags');
  final lists = await db.query('asmr_work_lists', orderBy: 'sort_order ASC');
  final keys = <int, String>{
    for (final work in works)
      work['id'] as int: asmrLegacyWorkKey(
        work['source_id'] as String? ?? '',
        work['id'] as int,
      ),
  };
  for (final table in [
    'asmr_work_voice_actors',
    'asmr_work_tags',
    'asmr_work_lists',
    'asmr_works',
  ]) {
    await db.execute('DROP TABLE $table');
  }
  await _createAsmrTables(db);
  final batch = db.batch();
  for (final work in works) {
    final id = work['id'] as int;
    batch.insert('asmr_works', {
      ...work,
      'work_key': keys[id],
      'resources_json': jsonEncode([
        {
          'source': 'asmrOne',
          'id': id,
          'code': work['source_id'] ?? '',
          'pageUrl': work['source_url'] ?? '',
        },
      ]),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }
  for (final entry in [
    ('asmr_work_voice_actors', actors),
    ('asmr_work_tags', tags),
    ('asmr_work_lists', lists),
  ]) {
    for (final row in entry.$2) {
      final key = keys[row['work_id']];
      if (key == null) continue;
      batch.insert(entry.$1, {
        ...row,
        'work_id': key,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }
  await batch.commit(noResult: true);
}

Future<void> _repairLegacyJapaneseAsmrResources(Database db) async {
  final works = await db.query(
    'asmr_works',
    columns: ['work_key', 'id', 'source_id', 'source_url', 'resources_json'],
    where: "source_type = 'jp-asmr' AND resources_json IS NOT NULL",
  );
  for (final work in works) {
    final id = work['id'];
    final code = work['source_id'];
    final pageUrl = work['source_url'];
    final resources = (jsonDecode(work['resources_json'] as String) as List)
        .cast<Map<String, dynamic>>();
    // The v15 migration copied these three fields into an ASMR.ONE resource.
    final mislabeled = resources
        .where(
          (resource) =>
              resource['source'] == 'asmrOne' &&
              resource['id'] == id &&
              resource['code'] == code &&
              resource['pageUrl'] == pageUrl,
        )
        .toSet();
    if (mislabeled.isEmpty) continue;
    final hasJapaneseResource = resources.any(
      (resource) =>
          resource['source'] == 'japaneseAsmr' && resource['id'] == id,
    );
    final repaired = [
      for (final resource in resources)
        if (!mislabeled.contains(resource))
          resource
        else if (!hasJapaneseResource)
          {...resource, 'source': 'japaneseAsmr'},
    ];
    final workKey = work['work_key'];
    await db.update(
      'asmr_works',
      {'resources_json': jsonEncode(repaired)},
      where: 'work_key = ?',
      whereArgs: [workKey],
    );
    final one = repaired.where((resource) => resource['source'] == 'asmrOne');
    if (!one.any((resource) => resource['id'] == id)) {
      await db.delete(
        'asmr_sync_operations',
        where: 'work_id = ? AND source_id = ?',
        whereArgs: [id, code],
      );
    }
    if (workKey != 'source:asmrOne:$id' || one.isNotEmpty) continue;
    final newKey = 'source:japaneseAsmr:$id';
    final updated = await db.update(
      'asmr_works',
      {'work_key': newKey},
      where: 'work_key = ?',
      whereArgs: [workKey],
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    if (updated == 0) continue;
    for (final table in [
      'asmr_work_lists',
      'asmr_work_tags',
      'asmr_work_voice_actors',
    ]) {
      await db.update(
        table,
        {'work_id': newKey},
        where: 'work_id = ?',
        whereArgs: [workKey],
      );
    }
  }
}
