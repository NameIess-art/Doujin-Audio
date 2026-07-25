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
  await db.execute('''
      CREATE TABLE sessions (
        id TEXT PRIMARY KEY,
        track_path TEXT NOT NULL,
        loop_mode INTEGER NOT NULL,
        created_at_ms INTEGER,
        updated_at_ms INTEGER,
        last_played_at_ms INTEGER,
        sort_order INTEGER NOT NULL DEFAULT 0
      )
    ''');
  await _createSessionDetailTables(db);
  await _createAsmrTables(db);
  await _createAudioDetailsTable(db);
  await _createAudioDetailBackupSyncTable(db);
  await _createLibraryEntriesTable(db);
  await _createTimeSegmentLabelsTable(db);
}

Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
  if (oldVersion >= newVersion) return;
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
  if (oldVersion < 5) {
    await _createAudioDetailBackupSyncTable(db);
  }
}

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
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_track_scan_generation '
    'ON track_scan_info(scan_generation)',
  );
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_track_playback_last_played '
    'ON track_playback_state(last_played_at_ms)',
  );
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_track_playback_favorite '
    'ON track_playback_state(is_favorite)',
  );
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_track_remote_kind '
    'ON track_remote_metadata(remote_metadata_kind)',
  );
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_track_tags_tag ON track_tags(tag)',
  );
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
        panning REAL NOT NULL DEFAULT 0.0
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
        sort_order INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(session_id, entry_id)
      )
    ''');
  await db.execute('''
      CREATE TABLE IF NOT EXISTS playback_queue_entry_tracks (
        session_id TEXT NOT NULL,
        entry_id TEXT NOT NULL,
        track_path TEXT NOT NULL,
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
    'CREATE INDEX IF NOT EXISTS idx_session_playback_session '
    'ON session_playback_state(session_id)',
  );
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_playback_queue_entries_order '
    'ON playback_queue_entries(session_id, sort_order)',
  );
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_playback_queue_tracks_entry '
    'ON playback_queue_entry_tracks(session_id, entry_id, sort_order)',
  );
}

Future<void> _createTrackIndexes(Database db) async {
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_tracks_group_key ON tracks(group_key)',
  );
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_tracks_display_name ON tracks(display_name)',
  );
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_tracks_last_played_at '
    'ON track_playback_state(last_played_at_ms)',
  );
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_tracks_favorite '
    'ON track_playback_state(is_favorite)',
  );
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_tracks_scan_generation '
    'ON track_scan_info(scan_generation)',
  );
}

Future<void> _createAsmrTables(Database db) async {
  await db.execute('''
      CREATE TABLE IF NOT EXISTS app_kv_settings (
        key TEXT PRIMARY KEY,
        value TEXT
      )
    ''');
  await db.execute('''
      CREATE TABLE IF NOT EXISTS asmr_works (
        id INTEGER PRIMARY KEY,
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
        work_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        sort_order INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(work_id, name)
      )
    ''');
  await db.execute('''
      CREATE TABLE IF NOT EXISTS asmr_work_tags (
        work_id INTEGER NOT NULL,
        tag TEXT NOT NULL,
        sort_order INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(work_id, tag)
      )
    ''');
  await db.execute('''
      CREATE TABLE IF NOT EXISTS asmr_work_lists (
        list_type TEXT NOT NULL,
        work_id INTEGER NOT NULL,
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
        voice_actors_json TEXT NOT NULL DEFAULT '[]',
        tags_json TEXT NOT NULL DEFAULT '[]',
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
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_audio_details_target '
    'ON audio_details(target_type, target_path)',
  );
}

Future<void> _createAudioDetailBackupSyncTable(Database db) async {
  await db.execute('''
      CREATE TABLE IF NOT EXISTS audio_detail_backup_sync (
        target_type TEXT NOT NULL,
        target_path TEXT NOT NULL,
        generation INTEGER NOT NULL DEFAULT 1,
        attempt_count INTEGER NOT NULL DEFAULT 0,
        next_attempt_at_ms INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        PRIMARY KEY(target_type, target_path)
      )
    ''');
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_audio_detail_backup_sync_due '
    'ON audio_detail_backup_sync(next_attempt_at_ms)',
  );
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
    'CREATE INDEX IF NOT EXISTS idx_library_entries_library '
    'ON library_entries(library_path)',
  );
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_library_entries_state '
    'ON library_entries(library_path, state)',
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
        name TEXT NOT NULL,
        start_ms INTEGER NOT NULL,
        end_ms INTEGER NOT NULL,
        color_value INTEGER NOT NULL,
        created_at_ms INTEGER NOT NULL,
        updated_at_ms INTEGER NOT NULL
      )
    ''');
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_time_segment_labels_track '
    'ON time_segment_labels(track_key, start_ms, created_at_ms)',
  );
}
