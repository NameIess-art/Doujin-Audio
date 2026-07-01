import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/audio_detail.dart';
import '../models/audio_effects.dart';
import '../models/asmr_models.dart';
import '../models/library_entry.dart';
import '../models/music_track.dart';
import '../models/playback_queue.dart';
import '../models/time_segment_label.dart';
import '../platform/app_platform.dart';
import 'path_matcher.dart';

class AppDatabase {
  AppDatabase._();

  static const int schemaVersion = 18;
  static const String fileName = 'audio_player.db';
  static bool _platformDatabaseInitialized = false;

  @visibleForTesting
  AppDatabase.test(Database db) : _db = db;

  static AppDatabase? _instance;
  static AppDatabase get instance => _instance ??= AppDatabase._();

  static void initializeForPlatform() {
    if (!AppPlatform.usesDesktopDatabase) return;
    if (_platformDatabaseInitialized) return;
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    _platformDatabaseInitialized = true;
  }

  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _open();
    return _db!;
  }

  Future<Database> _open() async {
    final dbPath = await getDatabasesPath();
    final db = await openDatabase(
      p.join(dbPath, fileName),
      version: schemaVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
      onOpen: _ensureCompatibilityColumns,
    );
    return db;
  }

  Future<String> get filePath async =>
      p.join(await getDatabasesPath(), fileName);

  Future<void> close() async {
    final db = _db;
    _db = null;
    await db?.close();
  }

  Future<void> reopen() async {
    await database;
  }

  static Future<void> _onCreate(Database db, int version) async {
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
    await _createLibraryEntriesTable(db);
    await _createTimeSegmentLabelsTable(db);
  }

  static Future<void> _onUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      await db.execute('''
        CREATE TABLE sessions (
          id TEXT PRIMARY KEY,
          track_path TEXT NOT NULL,
          loop_mode INTEGER NOT NULL,
          volume REAL NOT NULL,
          position_ms INTEGER NOT NULL DEFAULT 0,
          sort_order INTEGER NOT NULL DEFAULT 0
        )
      ''');
    }
    if (oldVersion < 3) {
      await db.execute('''
        ALTER TABLE sessions
        ADD COLUMN channel_swap INTEGER NOT NULL DEFAULT 0
      ''');
    }
    if (oldVersion < 4) {
      await _addColumnIfMissing(db, 'tracks', 'scanned_at_ms', 'INTEGER');
      await _addColumnIfMissing(db, 'tracks', 'file_size_bytes', 'INTEGER');
      await _addColumnIfMissing(db, 'tracks', 'modified_at_ms', 'INTEGER');
      await _addColumnIfMissing(
        db,
        'tracks',
        'last_played_position_ms',
        'INTEGER NOT NULL DEFAULT 0',
      );
      await _addColumnIfMissing(db, 'tracks', 'last_played_at_ms', 'INTEGER');
      await _addColumnIfMissing(
        db,
        'tracks',
        'is_favorite',
        'INTEGER NOT NULL DEFAULT 0',
      );
      await _addColumnIfMissing(
        db,
        'tracks',
        'tags_json',
        "TEXT NOT NULL DEFAULT '[]'",
      );
      await _addColumnIfMissing(db, 'tracks', 'cover_cache_path', 'TEXT');
      await _addColumnIfMissing(db, 'tracks', 'lyrics_path', 'TEXT');
      await _addColumnIfMissing(db, 'sessions', 'created_at_ms', 'INTEGER');
      await _addColumnIfMissing(db, 'sessions', 'updated_at_ms', 'INTEGER');
      await _addColumnIfMissing(db, 'sessions', 'last_played_at_ms', 'INTEGER');
    }
    if (oldVersion < 5) {
      await _addColumnIfMissing(
        db,
        'tracks',
        'scan_generation',
        'INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (oldVersion < 6) {
      await _addColumnIfMissing(db, 'tracks', 'manual_cover_path', 'TEXT');
    }
    if (oldVersion < 7) {
      await _addColumnIfMissing(
        db,
        'tracks',
        'duration_ms',
        'INTEGER NOT NULL DEFAULT 0',
      );
      await _addColumnIfMissing(
        db,
        'sessions',
        'duration_ms',
        'INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (oldVersion < 8) {
      await _createAudioDetailsTable(db);
    }
    if (oldVersion < 9) {
      await _addColumnIfMissing(
        db,
        'tracks',
        'is_video',
        'INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (oldVersion < 10) {
      await _createLibraryEntriesTable(db);
    }
    if (oldVersion < 11) {
      await _addColumnIfMissing(
        db,
        'sessions',
        'custom_queue_tracks_json',
        'TEXT',
      );
    }
    if (oldVersion < 12) {
      await _createTimeSegmentLabelsTable(db);
    }
    if (oldVersion < 13) {
      await _addColumnIfMissing(
        db,
        'audio_details',
        'release_date_ms',
        'INTEGER NOT NULL DEFAULT 0',
      );
      await _addColumnIfMissing(db, 'audio_details', 'sales_count', 'INTEGER');
      await _addColumnIfMissing(db, 'audio_details', 'rating', 'REAL');
    }
    if (oldVersion < 14) {
      await _addColumnIfMissing(
        db,
        'sessions',
        'speed',
        'REAL NOT NULL DEFAULT 1.0',
      );
    }
    if (oldVersion < 15) {
      await _addColumnIfMissing(db, 'sessions', 'audio_effects_json', 'TEXT');
    }
    if (oldVersion < 16) {
      await _addColumnIfMissing(db, 'sessions', 'playback_queue_json', 'TEXT');
      await _addColumnIfMissing(
        db,
        'sessions',
        'current_queue_index',
        'INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (oldVersion < 17) {
      await _addRemoteTrackMetadataColumns(db);
    }
    if (oldVersion < 18) {
      await _createTrackDetailTables(db);
      await _createSessionDetailTables(db);
      await _migrateSplitTrackTables(db);
      await _migrateSplitSessionTables(db);
    }
    await _createTrackDetailTables(db);
    await _createSessionDetailTables(db);
    await _createAsmrTables(db);
    await _createTrackIndexes(db);
  }

  static Future<void> _ensureCompatibilityColumns(Database db) async {
    await _createTrackDetailTables(db);
    await _createSessionDetailTables(db);
    await _createAsmrTables(db);
    await _createTrackIndexes(db);
  }

  @visibleForTesting
  static Future<void> createSchemaForTest(Database db) => _onCreate(db, 1);

  static Future<void> _addColumnIfMissing(
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

  static Future<bool> _hasColumn(
    Database db,
    String table,
    String column,
  ) async {
    final columns = await db.rawQuery('PRAGMA table_info($table)');
    return columns.any((row) => row['name'] == column);
  }

  static Future<void> _migrateSplitTrackTables(Database db) async {
    if (!await _hasColumn(db, 'tracks', 'scanned_at_ms')) return;
    await db.execute('''
      INSERT OR REPLACE INTO track_scan_info (
        path,
        scanned_at_ms,
        file_size_bytes,
        modified_at_ms,
        scan_generation
      )
      SELECT
        path,
        scanned_at_ms,
        file_size_bytes,
        modified_at_ms,
        COALESCE(scan_generation, 0)
      FROM tracks
    ''');
    await db.execute('''
      INSERT OR REPLACE INTO track_playback_state (
        path,
        last_played_position_ms,
        last_played_at_ms,
        is_favorite
      )
      SELECT
        path,
        COALESCE(last_played_position_ms, 0),
        last_played_at_ms,
        COALESCE(is_favorite, 0)
      FROM tracks
    ''');
    await db.execute('''
      INSERT OR REPLACE INTO track_assets (
        path,
        cover_cache_path,
        lyrics_path,
        manual_cover_path,
        remote_cover_url
      )
      SELECT
        path,
        cover_cache_path,
        lyrics_path,
        manual_cover_path,
        remote_cover_url
      FROM tracks
    ''');
    await db.execute('''
      INSERT OR REPLACE INTO track_remote_metadata (
        path,
        remote_metadata_kind,
        remote_metadata_json
      )
      SELECT path, remote_metadata_kind, remote_metadata_json
      FROM tracks
    ''');

    final rows = await db.query('tracks', columns: ['path', 'tags_json']);
    final batch = db.batch();
    for (final row in rows) {
      final path = row['path'] as String?;
      if (path == null || path.isEmpty) continue;
      final tags = _decodeTags(row['tags_json']);
      for (var i = 0; i < tags.length; i++) {
        batch.insert('track_tags', {
          'path': path,
          'tag': tags[i],
          'sort_order': i,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    }
    await batch.commit(noResult: true);
  }

  static Future<void> _migrateSplitSessionTables(Database db) async {
    if (!await _hasColumn(db, 'sessions', 'volume')) return;
    await db.execute('''
      INSERT OR REPLACE INTO session_playback_state (
        session_id,
        volume,
        speed,
        position_ms,
        duration_ms,
        current_queue_index,
        channel_swap
      )
      SELECT
        id,
        COALESCE(volume, 1.0),
        COALESCE(speed, 1.0),
        COALESCE(position_ms, 0),
        COALESCE(duration_ms, 0),
        COALESCE(current_queue_index, 0),
        COALESCE(channel_swap, 0)
      FROM sessions
    ''');

    final rows = await db.query('sessions');
    final batch = db.batch();
    for (final row in rows) {
      final session = _sessionFromLegacyRow(row);
      _writeSessionDetailsToBatch(batch, session);
    }
    await batch.commit(noResult: true);
  }

  static Future<void> _addRemoteTrackMetadataColumns(Database db) async {
    await _addColumnIfMissing(db, 'tracks', 'remote_cover_url', 'TEXT');
    await _addColumnIfMissing(db, 'tracks', 'remote_metadata_kind', 'TEXT');
    await _addColumnIfMissing(db, 'tracks', 'remote_metadata_json', 'TEXT');
  }

  static Future<void> _createTrackDetailTables(Database db) async {
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

  static Future<void> _createSessionDetailTables(Database db) async {
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

  static Future<void> _createTrackIndexes(Database db) async {
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

  static Future<void> _createAsmrTables(Database db) async {
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

  static Future<void> _createAudioDetailsTable(Database db) async {
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
        release_date_ms INTEGER NOT NULL DEFAULT 0,
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

  static Future<void> _createLibraryEntriesTable(Database db) async {
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

  static Future<void> _createTimeSegmentLabelsTable(Database db) async {
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

  // ---- Tracks ----

  Future<List<MusicTrack>> loadAllTracks() async {
    final db = await database;
    final rows = await _queryFullTrackRows(db);
    final tagsByPath = await _loadTrackTags(db);
    return rows
        .map((row) => _trackFromRow(row, tagsByPath[row['path'] as String]))
        .toList();
  }

  Future<List<MusicTrack>> loadTrackSummaries() async {
    final db = await database;
    final rows = await db.query(
      'tracks',
      columns: [
        'path',
        'display_name',
        'group_key',
        'group_title',
        'group_subtitle',
        'is_single',
        'is_video',
        'duration_ms',
      ],
    );
    return rows.map((row) => _trackSummaryFromRow(row)).toList();
  }

  Future<MusicTrack?> loadTrackDetail(String path) async {
    final db = await database;
    final rows = await _queryFullTrackRows(db, path: path, limit: 1);
    if (rows.isEmpty) return null;
    final tagsByPath = await _loadTrackTags(db, paths: [path]);
    return _trackFromRow(rows.first, tagsByPath[path]);
  }

  Future<void> saveAllTracks(List<MusicTrack> tracks) async {
    final db = await database;
    final batch = db.batch();
    // Clear and repopulate; for very large libraries this is still
    // a single transaction and orders of magnitude faster than
    // serialising the full list as JSON into SharedPreferences.
    batch.delete('track_tags');
    batch.delete('track_remote_metadata');
    batch.delete('track_assets');
    batch.delete('track_playback_state');
    batch.delete('track_scan_info');
    batch.delete('tracks');
    for (final track in tracks) {
      _writeTrackToBatch(batch, track);
    }
    await batch.commit(noResult: true);
  }

  Future<void> insertTracks(List<MusicTrack> tracks) async {
    await upsertTracks(tracks);
  }

  Future<void> upsertTracks(
    List<MusicTrack> tracks, {
    int? scanGeneration,
  }) async {
    final db = await database;
    final batch = db.batch();
    for (final track in tracks) {
      _writeTrackToBatch(batch, track, scanGeneration: scanGeneration);
    }
    await batch.commit(noResult: true);
  }

  Future<int> nextScanGeneration() async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT COALESCE(MAX(scan_generation), 0) + 1 AS next_generation '
      'FROM track_scan_info',
    );
    return (rows.first['next_generation'] as num?)?.toInt() ?? 1;
  }

  Future<void> markTracksScanned(
    List<MusicTrack> tracks, {
    required int generation,
  }) {
    return upsertTracks(tracks, scanGeneration: generation);
  }

  Future<void> deleteTracksMissingFromGeneration(int generation) async {
    final db = await database;
    final rows = await db.query(
      'track_scan_info',
      columns: ['path'],
      where: 'scan_generation != ?',
      whereArgs: [generation],
    );
    await deleteTracks(rows.map((row) => row['path'] as String).toList());
  }

  Future<void> deleteTracks(List<String> paths) async {
    if (paths.isEmpty) return;
    final db = await database;
    // Use a single DELETE ... WHERE path IN (...) instead of N individual
    // DELETE statements — much faster for large deletions.
    final placeholders = List.filled(paths.length, '?').join(', ');
    await db.transaction((txn) async {
      for (final table in [
        'track_tags',
        'track_remote_metadata',
        'track_assets',
        'track_playback_state',
        'track_scan_info',
        'tracks',
      ]) {
        await txn.rawDelete(
          'DELETE FROM $table WHERE path IN ($placeholders)',
          paths,
        );
      }
    });
  }

  Future<void> deleteAllTracks() async {
    final db = await database;
    final batch = db.batch();
    batch.delete('track_tags');
    batch.delete('track_remote_metadata');
    batch.delete('track_assets');
    batch.delete('track_playback_state');
    batch.delete('track_scan_info');
    batch.delete('tracks');
    await batch.commit(noResult: true);
  }

  Future<List<PersistedSession>> loadAllSessions() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT
        s.id,
        s.track_path,
        s.loop_mode,
        s.created_at_ms,
        s.updated_at_ms,
        s.last_played_at_ms,
        s.sort_order,
        playback.volume,
        playback.speed,
        playback.position_ms,
        playback.duration_ms,
        playback.current_queue_index,
        playback.channel_swap,
        effects.skip_silence_enabled,
        effects.noise_reduction_enabled,
        effects.volume_normalization_enabled,
        effects.eq_enabled,
        effects.eq_preset_id,
        effects.panning,
        queue.name AS queue_name,
        queue.color_value AS queue_color_value
      FROM sessions s
      LEFT JOIN session_playback_state playback ON playback.session_id = s.id
      LEFT JOIN session_audio_effects effects ON effects.session_id = s.id
      LEFT JOIN playback_queues queue ON queue.session_id = s.id
      ORDER BY s.sort_order ASC
    ''');
    final sessions = <PersistedSession>[];
    for (final row in rows) {
      final id = row['id'] as String;
      sessions.add(
        _sessionFromRow(
          row,
          customQueueTracks: await _loadSessionCustomQueueTracks(db, id),
          playbackQueue: await _loadPlaybackQueue(db, id, row),
          audioEffects: await _loadSessionAudioEffects(db, id, row),
        ),
      );
    }
    return sessions;
  }

  Future<void> saveAllSessions(List<PersistedSession> sessions) async {
    final db = await database;
    final batch = db.batch();
    batch.delete('playback_queue_entry_tracks');
    batch.delete('playback_queue_entries');
    batch.delete('playback_queues');
    batch.delete('session_eq_bands');
    batch.delete('session_audio_effects');
    batch.delete('session_playback_state');
    batch.delete('sessions');
    for (var i = 0; i < sessions.length; i++) {
      _writeSessionToBatch(batch, sessions[i], i);
    }
    await batch.commit(noResult: true);
  }

  Future<void> updateSessionOrder(List<String> sessionIds) async {
    final db = await database;
    final batch = db.batch();
    for (var i = 0; i < sessionIds.length; i++) {
      batch.update(
        'sessions',
        {'sort_order': i},
        where: 'id = ?',
        whereArgs: [sessionIds[i]],
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> updatePlaybackQueueEntryOrder(
    String sessionId,
    List<String> entryIds,
  ) async {
    final db = await database;
    final batch = db.batch();
    for (var i = 0; i < entryIds.length; i++) {
      batch.update(
        'playback_queue_entries',
        {'sort_order': i},
        where: 'session_id = ? AND entry_id = ?',
        whereArgs: [sessionId, entryIds[i]],
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> upsertSessionPlaybackState(PersistedSession session) async {
    final db = await database;
    final batch = db.batch();
    batch.insert(
      'session_playback_state',
      _sessionPlaybackStateRow(session),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await batch.commit(noResult: true);
  }

  Future<void> deleteAllSessions() async {
    final db = await database;
    final batch = db.batch();
    batch.delete('playback_queue_entry_tracks');
    batch.delete('playback_queue_entries');
    batch.delete('playback_queues');
    batch.delete('session_eq_bands');
    batch.delete('session_audio_effects');
    batch.delete('session_playback_state');
    batch.delete('sessions');
    await batch.commit(noResult: true);
  }

  Future<AudioDetail?> loadAudioDetail(AudioDetailTarget target) async {
    final db = await database;
    final normalizedTargetPath = PathMatcher.normalize(target.targetPath);
    final rows = await db.query(
      'audio_details',
      where: 'target_type = ? AND target_path = ?',
      whereArgs: [target.targetType.dbValue, normalizedTargetPath],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return AudioDetail.fromRow(rows.first);
  }

  Future<void> upsertAudioDetail(AudioDetail detail) async {
    final db = await database;
    final row = detail.toRow();
    row['target_path'] = PathMatcher.normalize(detail.target.targetPath);
    await db.insert(
      'audio_details',
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteAudioDetail(AudioDetailTarget target) async {
    final db = await database;
    final normalizedTargetPath = PathMatcher.normalize(target.targetPath);
    await db.delete(
      'audio_details',
      where: 'target_type = ? AND target_path = ?',
      whereArgs: [target.targetType.dbValue, normalizedTargetPath],
    );
  }

  // ---- Time segment labels ----

  Future<List<TimeSegmentLabel>> loadTimeSegmentLabels(String trackKey) async {
    final db = await database;
    final rows = await db.query(
      'time_segment_labels',
      where: 'track_key = ?',
      whereArgs: [trackKey],
      orderBy: 'start_ms ASC, created_at_ms ASC',
    );
    return rows.map(TimeSegmentLabel.fromRow).toList(growable: false);
  }

  Future<void> upsertTimeSegmentLabel(TimeSegmentLabel label) async {
    final db = await database;
    await db.insert(
      'time_segment_labels',
      label.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteTimeSegmentLabel(String id) async {
    final db = await database;
    await db.delete('time_segment_labels', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> retargetTimeSegmentLabels({
    required String oldTrackKey,
    required String newTrackKey,
  }) async {
    if (oldTrackKey == newTrackKey) return;
    final db = await database;
    await db.update(
      'time_segment_labels',
      {'track_key': newTrackKey},
      where: 'track_key = ?',
      whereArgs: [oldTrackKey],
    );
  }

  Future<void> retargetTimeSegmentLabelsWithinPath({
    required String oldRoot,
    required String newRoot,
  }) async {
    final db = await database;
    final rows = await db.query('time_segment_labels');
    final batch = db.batch();
    for (final row in rows) {
      final id = row['id'] as String;
      final trackKey = row['track_key'] as String;
      if (!PathMatcher.isWithinOrEqual(trackKey, oldRoot)) continue;
      final nextTrackKey = PathMatcher.replaceWithinOrEqual(
        trackKey,
        oldRoot,
        newRoot,
      );
      if (nextTrackKey == trackKey) continue;
      batch.update(
        'time_segment_labels',
        {'track_key': nextTrackKey},
        where: 'id = ?',
        whereArgs: [id],
      );
    }
    await batch.commit(noResult: true);
  }

  // ---- Library entries ----

  Future<List<LibraryEntry>> loadAllLibraryEntries() async {
    final db = await database;
    final rows = await db.query('library_entries');
    return rows.map(_libraryEntryFromRow).toList();
  }

  Future<List<LibraryEntry>> loadLibraryEntries(String libraryPath) async {
    final db = await database;
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    final rows = await db.query(
      'library_entries',
      where: 'library_path = ?',
      whereArgs: [normalizedLibraryPath],
    );
    return rows.map(_libraryEntryFromRow).toList();
  }

  Future<void> upsertLibraryEntries(
    List<LibraryEntry> entries, {
    int? scanGeneration,
  }) async {
    if (entries.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final entry in entries) {
      batch.insert(
        'library_entries',
        _libraryEntryToRow(entry, scanGeneration: scanGeneration),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<int> nextLibraryEntryScanGeneration(String libraryPath) async {
    final db = await database;
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    final rows = await db.rawQuery(
      'SELECT COALESCE(MAX(scan_generation), 0) + 1 AS next_generation '
      'FROM library_entries WHERE library_path = ?',
      [normalizedLibraryPath],
    );
    return (rows.first['next_generation'] as num?)?.toInt() ?? 1;
  }

  Future<void> deleteLibraryEntriesForLibrary(String libraryPath) async {
    final db = await database;
    await db.delete(
      'library_entries',
      where: 'library_path = ?',
      whereArgs: [PathMatcher.normalize(libraryPath)],
    );
  }

  Future<void> deleteLibraryEntries(
    String libraryPath,
    Iterable<String> paths,
  ) async {
    final normalizedPaths = paths.map(PathMatcher.normalize).toSet();
    if (normalizedPaths.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final entryPath in normalizedPaths) {
      batch.delete(
        'library_entries',
        where: 'library_path = ? AND path = ?',
        whereArgs: [PathMatcher.normalize(libraryPath), entryPath],
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> setLibraryEntriesState(
    String libraryPath,
    Iterable<String> entryPaths,
    LibraryEntryState state,
  ) async {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    final paths = entryPaths.map(PathMatcher.normalize).toSet();
    if (paths.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final entryPath in paths) {
      batch.update(
        'library_entries',
        {'state': state.dbValue},
        where: 'library_path = ? AND path = ?',
        whereArgs: [normalizedLibraryPath, entryPath],
      );
    }
    await batch.commit(noResult: true);
  }

  // ---- ASMR.ONE app data ----

  Future<List<String>> loadAsmrVisibleCategoryNames() async {
    final db = await database;
    final rows = await db.query(
      'asmr_visible_categories',
      orderBy: 'sort_order ASC',
    );
    return rows
        .map((row) => row['category'] as String?)
        .whereType<String>()
        .toList(growable: false);
  }

  Future<void> saveAsmrVisibleCategoryNames(List<String> categories) async {
    final db = await database;
    final batch = db.batch();
    batch.delete('asmr_visible_categories');
    for (var i = 0; i < categories.length; i++) {
      batch.insert('asmr_visible_categories', {
        'category': categories[i],
        'sort_order': i,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<String?> loadAppSetting(String key) async {
    final db = await database;
    final rows = await db.query(
      'app_kv_settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  Future<void> saveAppSetting(String key, String? value) async {
    final db = await database;
    if (value == null) {
      await db.delete('app_kv_settings', where: 'key = ?', whereArgs: [key]);
      return;
    }
    await db.insert('app_kv_settings', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<AsmrWork>> loadAsmrWorkList(String listType) async {
    final db = await database;
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
    if (rows.isEmpty) return const <AsmrWork>[];
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
  }

  Future<void> saveAsmrWorkList(String listType, List<AsmrWork> works) async {
    final db = await database;
    final batch = db.batch();
    batch.delete(
      'asmr_work_lists',
      where: 'list_type = ?',
      whereArgs: [listType],
    );
    for (var i = 0; i < works.length; i++) {
      _writeAsmrWorkToBatch(batch, works[i]);
      batch.insert('asmr_work_lists', {
        'list_type': listType,
        'work_id': works[i].id,
        'sort_order': i,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<List<AsmrSyncOperation>> loadAsmrSyncOperations() async {
    final db = await database;
    final rows = await db.query(
      'asmr_sync_operations',
      orderBy: 'sort_order ASC',
    );
    return rows
        .map(
          (row) => AsmrSyncOperation(
            type: AsmrSyncOperationType.fromName(row['type'] as String?),
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
  }

  Future<void> saveAsmrSyncOperations(
    List<AsmrSyncOperation> operations,
  ) async {
    final db = await database;
    final batch = db.batch();
    batch.delete('asmr_sync_operations');
    for (var i = 0; i < operations.length; i++) {
      final operation = operations[i];
      batch.insert('asmr_sync_operations', {
        'type': operation.type.name,
        'work_id': operation.workId,
        'source_id': operation.sourceId,
        'created_at_ms': operation.createdAt.millisecondsSinceEpoch,
        'retry_count': operation.retryCount,
        'sort_order': i,
      });
    }
    await batch.commit(noResult: true);
  }

  // ---- Internals ----

  static Future<List<Map<String, dynamic>>> _queryFullTrackRows(
    DatabaseExecutor db, {
    String? path,
    int? limit,
  }) {
    final where = path == null ? '' : 'WHERE t.path = ?';
    final limitSql = limit == null ? '' : 'LIMIT $limit';
    return db.rawQuery('''
      SELECT
        t.path,
        t.display_name,
        t.group_key,
        t.group_title,
        t.group_subtitle,
        t.is_single,
        t.is_video,
        t.duration_ms,
        scan.scanned_at_ms,
        scan.file_size_bytes,
        scan.modified_at_ms,
        scan.scan_generation,
        playback.last_played_position_ms,
        playback.last_played_at_ms,
        playback.is_favorite,
        assets.cover_cache_path,
        assets.lyrics_path,
        assets.manual_cover_path,
        assets.remote_cover_url,
        remote.remote_metadata_kind,
        remote.remote_metadata_json
      FROM tracks t
      LEFT JOIN track_scan_info scan ON scan.path = t.path
      LEFT JOIN track_playback_state playback ON playback.path = t.path
      LEFT JOIN track_assets assets ON assets.path = t.path
      LEFT JOIN track_remote_metadata remote ON remote.path = t.path
      $where
      $limitSql
    ''', path == null ? null : [path]);
  }

  static Future<Map<String, List<String>>> _loadTrackTags(
    DatabaseExecutor db, {
    Iterable<String>? paths,
  }) async {
    final args = paths?.toList(growable: false);
    final where = args == null || args.isEmpty
        ? ''
        : 'WHERE path IN (${List.filled(args.length, '?').join(', ')})';
    final rows = await db.rawQuery(
      'SELECT path, tag FROM track_tags $where ORDER BY sort_order ASC',
      args,
    );
    final tagsByPath = <String, List<String>>{};
    for (final row in rows) {
      final path = row['path'] as String;
      final tag = row['tag'] as String;
      tagsByPath.putIfAbsent(path, () => <String>[]).add(tag);
    }
    return tagsByPath.map(
      (path, tags) => MapEntry(path, List<String>.unmodifiable(tags)),
    );
  }

  static void _writeTrackToBatch(
    Batch batch,
    MusicTrack track, {
    int? scanGeneration,
  }) {
    batch.insert(
      'tracks',
      _trackCoreRow(track),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    batch.insert(
      'track_scan_info',
      _trackScanRow(track, scanGeneration: scanGeneration),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    batch.insert(
      'track_playback_state',
      _trackPlaybackRow(track),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    batch.insert(
      'track_assets',
      _trackAssetsRow(track),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    batch.insert(
      'track_remote_metadata',
      _trackRemoteMetadataRow(track),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    batch.delete('track_tags', where: 'path = ?', whereArgs: [track.path]);
    for (var i = 0; i < track.tags.length; i++) {
      batch.insert('track_tags', {
        'path': track.path,
        'tag': track.tags[i],
        'sort_order': i,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  static Map<String, dynamic> _trackCoreRow(MusicTrack t) => {
    'path': t.path,
    'display_name': t.displayName,
    'group_key': t.groupKey,
    'group_title': t.groupTitle,
    'group_subtitle': t.groupSubtitle,
    'is_single': t.isSingle ? 1 : 0,
    'is_video': t.isVideo ? 1 : 0,
    'duration_ms': t.duration.inMilliseconds,
  };

  static Map<String, dynamic> _trackScanRow(
    MusicTrack t, {
    int? scanGeneration,
  }) => {
    'path': t.path,
    'scanned_at_ms': t.scannedAt?.millisecondsSinceEpoch,
    'file_size_bytes': t.fileSizeBytes,
    'modified_at_ms': t.modifiedAt?.millisecondsSinceEpoch,
    'scan_generation': scanGeneration ?? 0,
  };

  static Map<String, dynamic> _trackPlaybackRow(MusicTrack t) => {
    'path': t.path,
    'last_played_position_ms': t.lastPlayedPosition.inMilliseconds,
    'last_played_at_ms': t.lastPlayedAt?.millisecondsSinceEpoch,
    'is_favorite': t.isFavorite ? 1 : 0,
  };

  static Map<String, dynamic> _trackAssetsRow(MusicTrack t) => {
    'path': t.path,
    'cover_cache_path': t.coverCachePath,
    'lyrics_path': t.lyricsPath,
    'manual_cover_path': t.manualCoverPath,
    'remote_cover_url': t.remoteCoverUrl,
  };

  static Map<String, dynamic> _trackRemoteMetadataRow(MusicTrack t) => {
    'path': t.path,
    'remote_metadata_kind': t.remoteMetadataKind,
    'remote_metadata_json': _encodeJsonMap(t.remoteMetadata),
  };

  static MusicTrack _trackSummaryFromRow(Map<String, dynamic> row) =>
      MusicTrack(
        path: row['path'] as String,
        displayName: row['display_name'] as String,
        groupKey: row['group_key'] as String,
        groupTitle: row['group_title'] as String,
        groupSubtitle: row['group_subtitle'] as String,
        isSingle: (row['is_single'] as int) == 1,
        isVideo: (row['is_video'] as int? ?? 0) == 1,
        duration: Duration(
          milliseconds: (row['duration_ms'] as num?)?.toInt() ?? 0,
        ),
      );

  static MusicTrack _trackFromRow(
    Map<String, dynamic> row,
    List<String>? tags,
  ) => MusicTrack(
    path: row['path'] as String,
    displayName: row['display_name'] as String,
    groupKey: row['group_key'] as String,
    groupTitle: row['group_title'] as String,
    groupSubtitle: row['group_subtitle'] as String,
    isSingle: (row['is_single'] as int) == 1,
    isVideo: (row['is_video'] as int? ?? 0) == 1,
    scannedAt: _dateTimeFromMs(row['scanned_at_ms']),
    fileSizeBytes: (row['file_size_bytes'] as num?)?.toInt(),
    modifiedAt: _dateTimeFromMs(row['modified_at_ms']),
    lastPlayedPosition: Duration(
      milliseconds: (row['last_played_position_ms'] as num?)?.toInt() ?? 0,
    ),
    lastPlayedAt: _dateTimeFromMs(row['last_played_at_ms']),
    isFavorite: (row['is_favorite'] as int? ?? 0) == 1,
    tags: tags ?? const <String>[],
    coverCachePath: row['cover_cache_path'] as String?,
    lyricsPath: row['lyrics_path'] as String?,
    manualCoverPath: row['manual_cover_path'] as String?,
    remoteCoverUrl: row['remote_cover_url'] as String?,
    remoteMetadataKind: row['remote_metadata_kind'] as String?,
    remoteMetadata: _decodeJsonMap(row['remote_metadata_json']),
    duration: Duration(
      milliseconds: (row['duration_ms'] as num?)?.toInt() ?? 0,
    ),
  );

  static Map<String, dynamic> _libraryEntryToRow(
    LibraryEntry entry, {
    int? scanGeneration,
  }) => {
    'library_path': PathMatcher.normalize(entry.libraryPath),
    'path': PathMatcher.normalize(entry.path),
    'kind': entry.kind.dbValue,
    'state': entry.state.dbValue,
    'parent_path': entry.parentPath == null
        ? null
        : PathMatcher.normalize(entry.parentPath!),
    'display_name': entry.displayName,
    'group_key': entry.groupKey,
    'group_title': entry.groupTitle,
    'group_subtitle': entry.groupSubtitle,
    'is_single': entry.isSingle ? 1 : 0,
    'is_video': entry.isVideo ? 1 : 0,
    'scanned_at_ms': entry.scannedAt?.millisecondsSinceEpoch,
    'file_size_bytes': entry.fileSizeBytes,
    'modified_at_ms': entry.modifiedAt?.millisecondsSinceEpoch,
    'scan_generation': scanGeneration ?? 0,
  };

  static LibraryEntry _libraryEntryFromRow(Map<String, dynamic> row) {
    return LibraryEntry(
      libraryPath: row['library_path'] as String,
      path: row['path'] as String,
      kind: LibraryEntryKind.fromDbValue(row['kind'] as String),
      state: LibraryEntryState.fromDbValue(row['state'] as String),
      parentPath: row['parent_path'] as String?,
      displayName: row['display_name'] as String? ?? '',
      groupKey: row['group_key'] as String? ?? '',
      groupTitle: row['group_title'] as String? ?? '',
      groupSubtitle: row['group_subtitle'] as String? ?? '',
      isSingle: (row['is_single'] as int? ?? 0) == 1,
      isVideo: (row['is_video'] as int? ?? 0) == 1,
      scannedAt: _dateTimeFromMs(row['scanned_at_ms']),
      fileSizeBytes: (row['file_size_bytes'] as num?)?.toInt(),
      modifiedAt: _dateTimeFromMs(row['modified_at_ms']),
    );
  }

  static Future<Map<int, List<String>>> _loadAsmrWorkTextValues(
    DatabaseExecutor db, {
    required String table,
    required String idColumn,
    required String valueColumn,
    required List<int> ids,
  }) async {
    if (ids.isEmpty) return const <int, List<String>>{};
    final placeholders = List.filled(ids.length, '?').join(', ');
    final rows = await db.rawQuery(
      'SELECT $idColumn, $valueColumn FROM $table '
      'WHERE $idColumn IN ($placeholders) ORDER BY sort_order ASC',
      ids,
    );
    final valuesById = <int, List<String>>{};
    for (final row in rows) {
      final id = (row[idColumn] as num?)?.toInt();
      final value = row[valueColumn] as String?;
      if (id == null || value == null) continue;
      valuesById.putIfAbsent(id, () => <String>[]).add(value);
    }
    return valuesById.map(
      (id, values) => MapEntry(id, List<String>.unmodifiable(values)),
    );
  }

  static void _writeAsmrWorkToBatch(Batch batch, AsmrWork work) {
    batch.insert('asmr_works', {
      'id': work.id,
      'title': work.title,
      'circle_name': work.circleName,
      'source_id': work.sourceId,
      'source_type': work.sourceType,
      'source_url': work.sourceUrl,
      'cover_url': work.coverUrl,
      'thumbnail_url': work.thumbnailUrl,
      'main_cover_url': work.mainCoverUrl,
      'release_date_ms': work.releaseDate?.millisecondsSinceEpoch,
      'create_date_ms': work.createDate?.millisecondsSinceEpoch,
      'duration_ms': work.duration.inMilliseconds,
      'dl_count': work.dlCount,
      'review_count': work.reviewCount,
      'rating': work.rating,
      'has_subtitle': work.hasSubtitle ? 1 : 0,
      'is_favorite': work.isFavorite ? 1 : 0,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    batch.delete(
      'asmr_work_voice_actors',
      where: 'work_id = ?',
      whereArgs: [work.id],
    );
    for (var i = 0; i < work.voiceActors.length; i++) {
      batch.insert('asmr_work_voice_actors', {
        'work_id': work.id,
        'name': work.voiceActors[i],
        'sort_order': i,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    batch.delete('asmr_work_tags', where: 'work_id = ?', whereArgs: [work.id]);
    for (var i = 0; i < work.tags.length; i++) {
      batch.insert('asmr_work_tags', {
        'work_id': work.id,
        'tag': work.tags[i],
        'sort_order': i,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  static AsmrWork _asmrWorkFromRow(
    Map<String, dynamic> row, {
    List<String>? voiceActors,
    List<String>? tags,
  }) {
    return AsmrWork(
      id: (row['id'] as num?)?.toInt() ?? 0,
      title: row['title'] as String? ?? '',
      circleName: row['circle_name'] as String? ?? '',
      sourceId: row['source_id'] as String? ?? '',
      sourceType: row['source_type'] as String? ?? '',
      sourceUrl: row['source_url'] as String? ?? '',
      coverUrl: row['cover_url'] as String? ?? '',
      thumbnailUrl: row['thumbnail_url'] as String? ?? '',
      mainCoverUrl: row['main_cover_url'] as String? ?? '',
      releaseDate: _dateTimeFromMs(row['release_date_ms']),
      createDate: _dateTimeFromMs(row['create_date_ms']),
      duration: Duration(
        milliseconds: (row['duration_ms'] as num?)?.toInt() ?? 0,
      ),
      dlCount: (row['dl_count'] as num?)?.toInt() ?? 0,
      reviewCount: (row['review_count'] as num?)?.toInt() ?? 0,
      rating: (row['rating'] as num?)?.toDouble() ?? 0,
      voiceActors: voiceActors ?? const <String>[],
      tags: tags ?? const <String>[],
      hasSubtitle: (row['has_subtitle'] as int? ?? 0) == 1,
      isFavorite: (row['is_favorite'] as int? ?? 0) == 1,
    );
  }

  static Map<String, dynamic> _sessionCoreRow(
    PersistedSession session,
    int sortOrder,
  ) => {
    'id': session.id,
    'track_path': session.trackPath,
    'loop_mode': session.loopModeIndex,
    'created_at_ms': session.createdAtMs,
    'updated_at_ms': session.updatedAtMs,
    'last_played_at_ms': session.lastPlayedAtMs,
    'sort_order': sortOrder,
  };

  static Map<String, dynamic> _sessionPlaybackStateRow(
    PersistedSession session,
  ) => {
    'session_id': session.id,
    'volume': session.volume,
    'speed': session.speed,
    'position_ms': session.positionMs,
    'duration_ms': session.durationMs,
    'current_queue_index': session.currentQueueIndex,
    'channel_swap': session.channelSwapEnabled ? 1 : 0,
  };

  static Map<String, dynamic> _sessionAudioEffectsRow(
    PersistedSession session,
  ) => {
    'session_id': session.id,
    'skip_silence_enabled': session.audioEffects.skipSilenceEnabled ? 1 : 0,
    'noise_reduction_enabled': session.audioEffects.noiseReductionEnabled
        ? 1
        : 0,
    'volume_normalization_enabled':
        session.audioEffects.volumeNormalizationEnabled ? 1 : 0,
    'eq_enabled': session.audioEffects.eqEnabled ? 1 : 0,
    'eq_preset_id': session.audioEffects.eqPresetId,
    'panning': session.audioEffects.panning,
  };

  static void _writeSessionToBatch(
    Batch batch,
    PersistedSession session,
    int sortOrder,
  ) {
    batch.insert(
      'sessions',
      _sessionCoreRow(session, sortOrder),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _writeSessionDetailsToBatch(batch, session);
  }

  static void _writeSessionDetailsToBatch(
    Batch batch,
    PersistedSession session,
  ) {
    batch.insert(
      'session_playback_state',
      _sessionPlaybackStateRow(session),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    batch.insert(
      'session_audio_effects',
      _sessionAudioEffectsRow(session),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    batch.delete(
      'session_eq_bands',
      where: 'session_id = ?',
      whereArgs: [session.id],
    );
    for (final entry in session.audioEffects.eqBandLevels.entries) {
      batch.insert('session_eq_bands', {
        'session_id': session.id,
        'frequency_hz': entry.key,
        'gain_db': entry.value,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    _writePlaybackQueueToBatch(batch, session);
  }

  static void _writePlaybackQueueToBatch(
    Batch batch,
    PersistedSession session,
  ) {
    batch.delete(
      'playback_queue_entry_tracks',
      where: 'session_id = ?',
      whereArgs: [session.id],
    );
    batch.delete(
      'playback_queue_entries',
      where: 'session_id = ?',
      whereArgs: [session.id],
    );
    batch.delete(
      'playback_queues',
      where: 'session_id = ?',
      whereArgs: [session.id],
    );
    final queue = session.playbackQueue;
    if (queue == null) {
      final customTracks = session.customQueueTracks;
      if (customTracks == null) return;
      for (var i = 0; i < customTracks.length; i++) {
        batch.insert(
          'playback_queue_entry_tracks',
          _queueTrackRow(
            sessionId: session.id,
            entryId: '__custom_queue__',
            track: customTracks[i],
            duplicateIndex: i,
            sortOrder: i,
          ),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      return;
    }
    batch.insert('playback_queues', {
      'session_id': session.id,
      'name': queue.name,
      'color_value': queue.colorValue,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    for (var entryIndex = 0; entryIndex < queue.entries.length; entryIndex++) {
      final entry = queue.entries[entryIndex];
      batch.insert('playback_queue_entries', {
        'session_id': session.id,
        'entry_id': entry.id,
        'kind': entry.kind.name,
        'title': entry.title,
        'work_root_path': entry.workRootPath,
        'sort_order': entryIndex,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      for (var trackIndex = 0; trackIndex < entry.tracks.length; trackIndex++) {
        batch.insert(
          'playback_queue_entry_tracks',
          _queueTrackRow(
            sessionId: session.id,
            entryId: entry.id,
            track: entry.tracks[trackIndex],
            duplicateIndex: trackIndex,
            sortOrder: trackIndex,
          ),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    }
  }

  static Map<String, dynamic> _queueTrackRow({
    required String sessionId,
    required String entryId,
    required MusicTrack track,
    required int duplicateIndex,
    required int sortOrder,
  }) => {
    'session_id': sessionId,
    'entry_id': entryId,
    'track_path': track.path,
    'display_name': track.displayName,
    'group_key': track.groupKey,
    'group_title': track.groupTitle,
    'group_subtitle': track.groupSubtitle,
    'is_single': track.isSingle ? 1 : 0,
    'is_video': track.isVideo ? 1 : 0,
    'duration_ms': track.duration.inMilliseconds,
    'file_size_bytes': track.fileSizeBytes,
    'remote_cover_url': track.remoteCoverUrl,
    'remote_metadata_kind': track.remoteMetadataKind,
    'remote_metadata_json': _encodeJsonMap(track.remoteMetadata),
    'duplicate_index': duplicateIndex,
    'sort_order': sortOrder,
  };

  static PersistedSession _sessionFromLegacyRow(Map<String, dynamic> row) {
    return PersistedSession(
      id: row['id'] as String,
      trackPath: row['track_path'] as String,
      loopModeIndex: row['loop_mode'] as int,
      volume: (row['volume'] as num?)?.toDouble() ?? 1.0,
      speed: (row['speed'] as num?)?.toDouble() ?? 1.0,
      positionMs: (row['position_ms'] as num?)?.toInt() ?? 0,
      durationMs: (row['duration_ms'] as num?)?.toInt() ?? 0,
      customQueueTracks: _decodeTracks(row['custom_queue_tracks_json']),
      playbackQueue: _decodePlaybackQueue(row['playback_queue_json']),
      currentQueueIndex: (row['current_queue_index'] as num?)?.toInt() ?? 0,
      channelSwapEnabled: (row['channel_swap'] as int? ?? 0) == 1,
      audioEffects: AudioEffectsState.fromJson(row['audio_effects_json']),
      createdAtMs: (row['created_at_ms'] as num?)?.toInt(),
      updatedAtMs: (row['updated_at_ms'] as num?)?.toInt(),
      lastPlayedAtMs: (row['last_played_at_ms'] as num?)?.toInt(),
      sortOrder: (row['sort_order'] as num?)?.toInt() ?? 0,
    );
  }

  static PersistedSession _sessionFromRow(
    Map<String, dynamic> row, {
    required List<MusicTrack>? customQueueTracks,
    required PlaybackQueueDefinition? playbackQueue,
    required AudioEffectsState audioEffects,
  }) => PersistedSession(
    id: row['id'] as String,
    trackPath: row['track_path'] as String,
    loopModeIndex: row['loop_mode'] as int,
    volume: (row['volume'] as num?)?.toDouble() ?? 1.0,
    speed: (row['speed'] as num?)?.toDouble() ?? 1.0,
    positionMs: (row['position_ms'] as num?)?.toInt() ?? 0,
    durationMs: (row['duration_ms'] as num?)?.toInt() ?? 0,
    customQueueTracks: customQueueTracks,
    playbackQueue: playbackQueue,
    currentQueueIndex: (row['current_queue_index'] as num?)?.toInt() ?? 0,
    channelSwapEnabled: (row['channel_swap'] as int? ?? 0) == 1,
    audioEffects: audioEffects,
    createdAtMs: (row['created_at_ms'] as num?)?.toInt(),
    updatedAtMs: (row['updated_at_ms'] as num?)?.toInt(),
    lastPlayedAtMs: (row['last_played_at_ms'] as num?)?.toInt(),
    sortOrder: (row['sort_order'] as num?)?.toInt() ?? 0,
  );

  static Future<AudioEffectsState> _loadSessionAudioEffects(
    DatabaseExecutor db,
    String sessionId,
    Map<String, dynamic> row,
  ) async {
    final bandRows = await db.query(
      'session_eq_bands',
      where: 'session_id = ?',
      whereArgs: [sessionId],
    );
    final levels = <int, double>{};
    for (final band in bandRows) {
      final frequency = (band['frequency_hz'] as num?)?.toInt();
      final gain = (band['gain_db'] as num?)?.toDouble();
      if (frequency == null || gain == null) continue;
      levels[frequency] = gain;
    }
    return AudioEffectsState(
      skipSilenceEnabled: (row['skip_silence_enabled'] as int? ?? 0) == 1,
      noiseReductionEnabled: (row['noise_reduction_enabled'] as int? ?? 0) == 1,
      volumeNormalizationEnabled:
          (row['volume_normalization_enabled'] as int? ?? 0) == 1,
      eqEnabled: (row['eq_enabled'] as int? ?? 0) == 1,
      eqPresetId: (row['eq_preset_id'] as String?)?.trim().isEmpty ?? true
          ? null
          : row['eq_preset_id'] as String?,
      eqBandLevels: Map<int, double>.unmodifiable(levels),
      panning: (row['panning'] as num?)?.toDouble() ?? 0.0,
    );
  }

  static Future<List<MusicTrack>?> _loadSessionCustomQueueTracks(
    DatabaseExecutor db,
    String sessionId,
  ) async {
    final rows = await db.query(
      'playback_queue_entry_tracks',
      where: 'session_id = ? AND entry_id = ?',
      whereArgs: [sessionId, '__custom_queue__'],
      orderBy: 'sort_order ASC',
    );
    if (rows.isEmpty) return null;
    return rows.map(_queueTrackFromRow).toList(growable: false);
  }

  static Future<PlaybackQueueDefinition?> _loadPlaybackQueue(
    DatabaseExecutor db,
    String sessionId,
    Map<String, dynamic> sessionRow,
  ) async {
    final queueName = sessionRow['queue_name'] as String?;
    if (queueName == null) return null;
    final entryRows = await db.query(
      'playback_queue_entries',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'sort_order ASC',
    );
    final entries = <PlaybackQueueEntry>[];
    for (final entryRow in entryRows) {
      final entryId = entryRow['entry_id'] as String;
      final trackRows = await db.query(
        'playback_queue_entry_tracks',
        where: 'session_id = ? AND entry_id = ?',
        whereArgs: [sessionId, entryId],
        orderBy: 'sort_order ASC',
      );
      entries.add(
        PlaybackQueueEntry(
          id: entryId,
          kind: PlaybackQueueEntryKind.values.firstWhere(
            (kind) => kind.name == entryRow['kind'],
            orElse: () => PlaybackQueueEntryKind.track,
          ),
          title: entryRow['title'] as String? ?? '',
          workRootPath: entryRow['work_root_path'] as String?,
          tracks: trackRows.map(_queueTrackFromRow).toList(growable: false),
        ),
      );
    }
    return PlaybackQueueDefinition(
      name: queueName,
      colorValue: (sessionRow['queue_color_value'] as num?)?.toInt(),
      entries: entries,
    );
  }

  static MusicTrack _queueTrackFromRow(Map<String, dynamic> row) => MusicTrack(
    path: row['track_path'] as String,
    displayName: row['display_name'] as String? ?? '',
    groupKey: row['group_key'] as String? ?? '',
    groupTitle: row['group_title'] as String? ?? '',
    groupSubtitle: row['group_subtitle'] as String? ?? '',
    isSingle: (row['is_single'] as int? ?? 0) == 1,
    isVideo: (row['is_video'] as int? ?? 0) == 1,
    duration: Duration(
      milliseconds: (row['duration_ms'] as num?)?.toInt() ?? 0,
    ),
    fileSizeBytes: (row['file_size_bytes'] as num?)?.toInt(),
    remoteCoverUrl: row['remote_cover_url'] as String?,
    remoteMetadataKind: row['remote_metadata_kind'] as String?,
    remoteMetadata: _decodeJsonMap(row['remote_metadata_json']),
  );
}

DateTime? _dateTimeFromMs(Object? value) {
  if (value is num && value > 0) {
    return DateTime.fromMillisecondsSinceEpoch(value.toInt());
  }
  return null;
}

List<String> _decodeTags(Object? value) {
  if (value is! String || value.isEmpty) return const <String>[];
  try {
    return (json.decode(value) as List<dynamic>).whereType<String>().toList(
      growable: false,
    );
  } catch (_) {
    return const <String>[];
  }
}

String? _encodeJsonMap(Map<String, Object?>? value) {
  if (value == null || value.isEmpty) return null;
  return json.encode(value);
}

Map<String, Object?>? _decodeJsonMap(Object? value) {
  if (value is! String || value.isEmpty) return null;
  try {
    final raw = json.decode(value);
    if (raw is! Map) return null;
    return raw.cast<String, Object?>();
  } catch (_) {
    return null;
  }
}

List<MusicTrack>? _decodeTracks(Object? value) {
  if (value is! String || value.isEmpty) return null;
  try {
    final raw = json.decode(value);
    if (raw is! List<dynamic>) return null;
    final tracks = raw
        .whereType<Map<String, dynamic>>()
        .map(MusicTrack.fromJson)
        .toList(growable: false);
    return tracks.isEmpty ? null : tracks;
  } catch (_) {
    return null;
  }
}

PlaybackQueueDefinition? _decodePlaybackQueue(Object? value) {
  if (value is! String || value.isEmpty) return null;
  try {
    final raw = json.decode(value);
    if (raw is! Map<String, dynamic>) return null;
    return PlaybackQueueDefinition.fromJson(raw);
  } catch (_) {
    return null;
  }
}

class PersistedSession {
  const PersistedSession({
    required this.id,
    required this.trackPath,
    required this.loopModeIndex,
    required this.volume,
    this.speed = 1.0,
    required this.positionMs,
    required this.durationMs,
    required this.customQueueTracks,
    this.playbackQueue,
    this.currentQueueIndex = 0,
    required this.channelSwapEnabled,
    this.audioEffects = AudioEffectsState.flat,
    required this.sortOrder,
    this.createdAtMs,
    this.updatedAtMs,
    this.lastPlayedAtMs,
  });

  final String id;
  final String trackPath;
  final int loopModeIndex;
  final double volume;
  final double speed;
  final int positionMs;
  final int durationMs;
  final List<MusicTrack>? customQueueTracks;
  final PlaybackQueueDefinition? playbackQueue;
  final int currentQueueIndex;
  final bool channelSwapEnabled;
  final AudioEffectsState audioEffects;
  final int sortOrder;
  final int? createdAtMs;
  final int? updatedAtMs;
  final int? lastPlayedAtMs;
}
