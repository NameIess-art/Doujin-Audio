import 'dart:async';
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

  static const int schemaVersion = 2;
  static const String fileName = 'audio_player.db';
  static const int _sqliteInClauseBatchSize = 900;
  static bool _platformDatabaseInitialized = false;

  @visibleForTesting
  AppDatabase.test(
    Database db, {
    Future<Database> Function()? databaseOpener,
    Future<String> Function()? filePathProvider,
  }) : _db = db,
       _databaseOpener = databaseOpener,
       _databasePathProvider = filePathProvider;

  static AppDatabase? _instance;
  static AppDatabase get instance => _instance ??= AppDatabase._();

  @visibleForTesting
  static void setInstanceForTest(AppDatabase? database) {
    _instance = database;
  }

  static void initializeForPlatform() {
    if (!AppPlatform.usesDesktopDatabase) return;
    if (_platformDatabaseInitialized) return;
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    _platformDatabaseInitialized = true;
  }

  Database? _db;
  Future<Database> Function()? _databaseOpener;
  Future<String> Function()? _databasePathProvider;
  Future<Database>? _openFuture;
  Future<void>? _maintenanceBarrier;
  Future<void> _maintenanceTail = Future<void>.value();
  int _databaseEpoch = 0;
  int _activeOperations = 0;
  Completer<void>? _operationsDrained;

  Future<Database> get _database async {
    final maintenance = _maintenanceBarrier;
    if (maintenance != null) {
      await maintenance;
    }
    if (_db != null) return _db!;
    return _openIgnoringMaintenance();
  }

  Future<Database> get databaseForTest => _database;

  Future<Database> _open() async {
    final databaseOpener = _databaseOpener;
    if (databaseOpener != null) {
      return databaseOpener();
    }
    final dbPath = await getDatabasesPath();
    final db = await openDatabase(
      p.join(dbPath, fileName),
      version: schemaVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
    return db;
  }

  Future<String> get filePath async {
    final filePathProvider = _databasePathProvider;
    if (filePathProvider != null) {
      return filePathProvider();
    }
    return p.join(await getDatabasesPath(), fileName);
  }

  Future<void> close() async {
    await _openFuture;
    final db = _db;
    _db = null;
    await db?.close();
  }

  Future<void> reopen() async {
    await _database;
  }

  Future<T> runExclusiveMaintenance<T>({
    required bool replacesDatabase,
    required Future<T> Function(String databasePath) action,
  }) async {
    final previous = _maintenanceTail;
    final turnDone = Completer<void>();
    _maintenanceTail = turnDone.future;
    await previous;

    final barrier = Completer<void>();
    _maintenanceBarrier = barrier.future;
    try {
      final opening = _openFuture;
      if (opening != null) {
        await opening;
      }
      if (_activeOperations > 0) {
        _operationsDrained ??= Completer<void>();
        await _operationsDrained!.future;
      }
      final db = _db;
      _db = null;
      await db?.close();
      final result = await action(await filePath);
      if (replacesDatabase) {
        _databaseEpoch++;
      }
      await _openIgnoringMaintenance();
      return result;
    } finally {
      try {
        if (_db == null) {
          await _openIgnoringMaintenance();
        }
      } finally {
        _maintenanceBarrier = null;
        barrier.complete();
        turnDone.complete();
      }
    }
  }

  Future<Database> _openIgnoringMaintenance() async {
    if (_db != null) return _db!;
    final opening = _openFuture ??= _open().then((db) {
      _db = db;
      return db;
    });
    try {
      return await opening;
    } finally {
      if (identical(_openFuture, opening)) {
        _openFuture = null;
      }
    }
  }

  Future<void> _runDatabaseWrite(
    Future<void> Function(Database db) operation,
  ) async {
    final submittedEpoch = _databaseEpoch;
    var db = await _database;
    final maintenance = _maintenanceBarrier;
    if (maintenance != null) {
      await maintenance;
      db = await _database;
    }
    if (submittedEpoch != _databaseEpoch) {
      return;
    }
    _activeOperations++;
    try {
      await operation(db);
    } finally {
      _activeOperations--;
      if (_activeOperations == 0) {
        _operationsDrained?.complete();
        _operationsDrained = null;
      }
    }
  }

  Future<T> _runDatabaseRead<T>(
    Future<T> Function(Database db) operation,
  ) async {
    var db = await _database;
    final maintenance = _maintenanceBarrier;
    if (maintenance != null) {
      await maintenance;
      db = await _database;
    }
    _activeOperations++;
    try {
      return await operation(db);
    } finally {
      _activeOperations--;
      if (_activeOperations == 0) {
        _operationsDrained?.complete();
        _operationsDrained = null;
      }
    }
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
    if (oldVersion >= newVersion) return;
    if (oldVersion < 2) {
      await _addColumnIfMissing(db, 'audio_details', 'card_cover_path', 'TEXT');
    }
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
        card_cover_path TEXT,
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
    return _runDatabaseRead((db) async {
      final rows = await _queryFullTrackRows(db);
      final tagsByPath = await _loadTrackTags(db);
      return rows
          .map((row) => _trackFromRow(row, tagsByPath[row['path'] as String]))
          .toList();
    });
  }

  Future<List<MusicTrack>> loadTrackSummaries() async {
    return _runDatabaseRead((db) async {
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
    });
  }

  Future<List<MusicTrack>> loadStartupTracks() async {
    return _runDatabaseRead((db) async {
      final rows = await _queryStartupTrackRows(db);
      return rows.map(_trackStartupFromRow).toList();
    });
  }

  Future<MusicTrack?> loadTrackDetail(String path) async {
    return _runDatabaseRead((db) async {
      final rows = await _queryFullTrackRows(db, path: path, limit: 1);
      if (rows.isEmpty) return null;
      final tagsByPath = await _loadTrackTags(db, paths: [path]);
      return _trackFromRow(rows.first, tagsByPath[path]);
    });
  }

  Future<void> saveAllTracks(List<MusicTrack> tracks) async {
    await _runDatabaseWrite((db) async {
      final batch = db.batch();
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
    });
  }

  Future<void> insertTracks(List<MusicTrack> tracks) async {
    await upsertTracks(tracks);
  }

  Future<void> upsertTracks(
    List<MusicTrack> tracks, {
    int? scanGeneration,
  }) async {
    await _runDatabaseWrite((db) async {
      final batch = db.batch();
      for (final track in tracks) {
        _writeTrackToBatch(batch, track, scanGeneration: scanGeneration);
      }
      await batch.commit(noResult: true);
    });
  }

  Future<int> nextScanGeneration() async {
    return _runDatabaseRead((db) async {
      final rows = await db.rawQuery(
        'SELECT COALESCE(MAX(scan_generation), 0) + 1 AS next_generation '
        'FROM track_scan_info',
      );
      return (rows.first['next_generation'] as num?)?.toInt() ?? 1;
    });
  }

  Future<void> markTracksScanned(
    List<MusicTrack> tracks, {
    required int generation,
  }) {
    return upsertTracks(tracks, scanGeneration: generation);
  }

  Future<void> deleteTracksMissingFromGeneration(int generation) async {
    await _runDatabaseWrite((db) async {
      final rows = await db.query(
        'track_scan_info',
        columns: ['path'],
        where: 'scan_generation != ?',
        whereArgs: [generation],
      );
      final paths = rows.map((row) => row['path'] as String).toList();
      if (paths.isEmpty) return;
      const chunkSize = _sqliteInClauseBatchSize;
      await db.transaction((txn) async {
        for (var start = 0; start < paths.length; start += chunkSize) {
          final end = (start + chunkSize).clamp(0, paths.length);
          final chunk = paths.sublist(start, end);
          final placeholders = List.filled(chunk.length, '?').join(', ');
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
              chunk,
            );
          }
        }
      });
    });
  }

  Future<void> deleteTracks(List<String> paths) async {
    if (paths.isEmpty) return;
    await _runDatabaseWrite((db) async {
      // Use a single DELETE ... WHERE path IN (...) instead of N individual
      // DELETE statements — much faster for large deletions.
      const chunkSize = _sqliteInClauseBatchSize;
      await db.transaction((txn) async {
        for (var start = 0; start < paths.length; start += chunkSize) {
          final end = (start + chunkSize).clamp(0, paths.length);
          final chunk = paths.sublist(start, end);
          final placeholders = List.filled(chunk.length, '?').join(', ');
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
              chunk,
            );
          }
        }
      });
    });
  }

  Future<void> deleteAllTracks() async {
    await _runDatabaseWrite((db) async {
      final batch = db.batch();
      batch.delete('track_tags');
      batch.delete('track_remote_metadata');
      batch.delete('track_assets');
      batch.delete('track_playback_state');
      batch.delete('track_scan_info');
      batch.delete('tracks');
      await batch.commit(noResult: true);
    });
  }

  Future<List<PersistedSession>> loadAllSessions() async {
    return _runDatabaseRead((db) async {
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
      if (rows.isEmpty) return const <PersistedSession>[];
      final sessionIds = rows.map((row) => row['id'] as String).toList();
      final eqBandsBySession = await _loadSessionEqBandsBySession(
        db,
        sessionIds,
      );
      final queueEntriesBySession = await _loadPlaybackQueueEntriesBySession(
        db,
        sessionIds,
      );
      final queueTracksByEntry = await _loadQueueTracksByEntry(db, sessionIds);
      final sessions = <PersistedSession>[];
      for (final row in rows) {
        final id = row['id'] as String;
        sessions.add(
          _sessionFromRow(
            row,
            customQueueTracks: _customQueueTracksForSession(
              id,
              queueTracksByEntry,
            ),
            playbackQueue: _playbackQueueForSession(
              id,
              row,
              queueEntriesBySession,
              queueTracksByEntry,
            ),
            audioEffects: _sessionAudioEffectsFromRow(
              row,
              eqBandsBySession[id] ?? const <int, double>{},
            ),
          ),
        );
      }
      return sessions;
    });
  }

  Future<void> saveAllSessions(List<PersistedSession> sessions) async {
    await _runDatabaseWrite((db) async {
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
    });
  }

  Future<void> updateSessionOrder(List<String> sessionIds) async {
    await _runDatabaseWrite((db) async {
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
    });
  }

  Future<void> updatePlaybackQueueEntryOrder(
    String sessionId,
    List<String> entryIds,
  ) async {
    await _runDatabaseWrite((db) async {
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
    });
  }

  Future<void> upsertSessionPlaybackState(PersistedSession session) async {
    await _runDatabaseWrite((db) async {
      final batch = db.batch();
      batch.insert(
        'session_playback_state',
        _sessionPlaybackStateRow(session),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await batch.commit(noResult: true);
    });
  }

  Future<void> deleteAllSessions() async {
    await _runDatabaseWrite((db) async {
      final batch = db.batch();
      batch.delete('playback_queue_entry_tracks');
      batch.delete('playback_queue_entries');
      batch.delete('playback_queues');
      batch.delete('session_eq_bands');
      batch.delete('session_audio_effects');
      batch.delete('session_playback_state');
      batch.delete('sessions');
      await batch.commit(noResult: true);
    });
  }

  Future<AudioDetail?> loadAudioDetail(AudioDetailTarget target) async {
    return _runDatabaseRead((db) async {
      final normalizedTargetPath = PathMatcher.normalize(target.targetPath);
      final rows = await db.query(
        'audio_details',
        where: 'target_type = ? AND target_path = ?',
        whereArgs: [target.targetType.dbValue, normalizedTargetPath],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      return AudioDetail.fromRow(rows.first);
    });
  }

  Future<List<AudioDetail>> loadAudioDetails(
    Iterable<AudioDetailTarget> targets,
  ) async {
    return _runDatabaseRead((db) async {
      final pathsByType = <String, Set<String>>{};
      for (final target in targets) {
        pathsByType
            .putIfAbsent(target.targetType.dbValue, () => <String>{})
            .add(PathMatcher.normalize(target.targetPath));
      }
      if (pathsByType.isEmpty) return const <AudioDetail>[];

      final details = <AudioDetail>[];
      for (final entry in pathsByType.entries) {
        final paths = entry.value.toList(growable: false);
        if (paths.isEmpty) continue;
        const chunkSize = 900;
        for (var start = 0; start < paths.length; start += chunkSize) {
          final end = (start + chunkSize).clamp(0, paths.length);
          final chunk = paths.sublist(start, end);
          final placeholders = List.filled(chunk.length, '?').join(', ');
          final rows = await db.query(
            'audio_details',
            where: 'target_type = ? AND target_path IN ($placeholders)',
            whereArgs: [entry.key, ...chunk],
          );
          details.addAll(rows.map(AudioDetail.fromRow));
        }
      }
      return details;
    });
  }

  Future<void> upsertAudioDetail(AudioDetail detail) async {
    await _runDatabaseWrite((db) async {
      final row = detail.toRow();
      row['target_path'] = PathMatcher.normalize(detail.target.targetPath);
      await db.insert(
        'audio_details',
        row,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  Future<void> deleteAudioDetail(AudioDetailTarget target) async {
    await _runDatabaseWrite((db) async {
      final normalizedTargetPath = PathMatcher.normalize(target.targetPath);
      await db.delete(
        'audio_details',
        where: 'target_type = ? AND target_path = ?',
        whereArgs: [target.targetType.dbValue, normalizedTargetPath],
      );
    });
  }

  // ---- Time segment labels ----

  Future<List<TimeSegmentLabel>> loadTimeSegmentLabels(String trackKey) async {
    return _runDatabaseRead((db) async {
      final rows = await db.query(
        'time_segment_labels',
        where: 'track_key = ?',
        whereArgs: [trackKey],
        orderBy: 'start_ms ASC, created_at_ms ASC',
      );
      return rows.map(TimeSegmentLabel.fromRow).toList(growable: false);
    });
  }

  Future<void> upsertTimeSegmentLabel(TimeSegmentLabel label) async {
    await _runDatabaseWrite(
      (db) => db
          .insert(
            'time_segment_labels',
            label.toRow(),
            conflictAlgorithm: ConflictAlgorithm.replace,
          )
          .then((_) {}),
    );
  }

  Future<void> deleteTimeSegmentLabel(String id) async {
    await _runDatabaseWrite(
      (db) => db
          .delete('time_segment_labels', where: 'id = ?', whereArgs: [id])
          .then((_) {}),
    );
  }

  Future<void> retargetTimeSegmentLabels({
    required String oldTrackKey,
    required String newTrackKey,
  }) async {
    if (oldTrackKey == newTrackKey) return;
    await _runDatabaseWrite((db) async {
      await db.update(
        'time_segment_labels',
        {'track_key': newTrackKey},
        where: 'track_key = ?',
        whereArgs: [oldTrackKey],
      );
    });
  }

  Future<void> retargetTimeSegmentLabelsWithinPath({
    required String oldRoot,
    required String newRoot,
  }) async {
    await _runDatabaseWrite((db) async {
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
    });
  }

  // ---- Library entries ----

  Future<List<LibraryEntry>> loadAllLibraryEntries() async {
    return _runDatabaseRead((db) async {
      final rows = await db.query('library_entries');
      return rows.map(_libraryEntryFromRow).toList();
    });
  }

  Future<List<LibraryEntry>> loadLibraryEntries(String libraryPath) async {
    return _runDatabaseRead((db) async {
      final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
      final rows = await db.query(
        'library_entries',
        where: 'library_path = ?',
        whereArgs: [normalizedLibraryPath],
      );
      return rows.map(_libraryEntryFromRow).toList();
    });
  }

  Future<void> upsertLibraryEntries(
    List<LibraryEntry> entries, {
    int? scanGeneration,
  }) async {
    if (entries.isEmpty) return;
    await _runDatabaseWrite((db) async {
      final batch = db.batch();
      for (final entry in entries) {
        batch.insert(
          'library_entries',
          _libraryEntryToRow(entry, scanGeneration: scanGeneration),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<int> nextLibraryEntryScanGeneration(String libraryPath) async {
    return _runDatabaseRead((db) async {
      final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
      final rows = await db.rawQuery(
        'SELECT COALESCE(MAX(scan_generation), 0) + 1 AS next_generation '
        'FROM library_entries WHERE library_path = ?',
        [normalizedLibraryPath],
      );
      return (rows.first['next_generation'] as num?)?.toInt() ?? 1;
    });
  }

  Future<void> deleteLibraryEntriesForLibrary(String libraryPath) async {
    await _runDatabaseWrite((db) async {
      await db.delete(
        'library_entries',
        where: 'library_path = ?',
        whereArgs: [PathMatcher.normalize(libraryPath)],
      );
    });
  }

  Future<void> deleteLibraryEntries(
    String libraryPath,
    Iterable<String> paths,
  ) async {
    final normalizedPaths = paths.map(PathMatcher.normalize).toSet();
    if (normalizedPaths.isEmpty) return;
    await _runDatabaseWrite((db) async {
      final batch = db.batch();
      for (final entryPath in normalizedPaths) {
        batch.delete(
          'library_entries',
          where: 'library_path = ? AND path = ?',
          whereArgs: [PathMatcher.normalize(libraryPath), entryPath],
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> setLibraryEntriesState(
    String libraryPath,
    Iterable<String> entryPaths,
    LibraryEntryState state,
  ) async {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    final paths = entryPaths.map(PathMatcher.normalize).toSet();
    if (paths.isEmpty) return;
    await _runDatabaseWrite((db) async {
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
    });
  }

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

  Future<List<AsmrWork>> loadAsmrWorkList(String listType) async {
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
    });
  }

  Future<void> saveAsmrWorkList(String listType, List<AsmrWork> works) async {
    await _runDatabaseWrite((db) async {
      final batch = db.batch();
      _replaceAsmrWorkListInBatch(batch, listType, works);
      await batch.commit(noResult: true);
    });
  }

  Future<List<AsmrSyncOperation>> loadAsmrSyncOperations() async {
    return _runDatabaseRead((db) async {
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
    });
  }

  Future<void> saveAsmrSyncOperations(
    List<AsmrSyncOperation> operations,
  ) async {
    await _runDatabaseWrite((db) async {
      final batch = db.batch();
      _replaceAsmrSyncOperationsInBatch(batch, operations);
      await batch.commit(noResult: true);
    });
  }

  Future<void> saveAsmrWorkListAndSyncOperations(
    String listType,
    List<AsmrWork> works,
    List<AsmrSyncOperation> operations,
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

  static Future<List<Map<String, dynamic>>> _queryStartupTrackRows(
    DatabaseExecutor db,
  ) {
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
        playback.last_played_position_ms,
        playback.last_played_at_ms,
        playback.is_favorite,
        assets.cover_cache_path,
        assets.lyrics_path,
        assets.manual_cover_path,
        assets.remote_cover_url,
        remote.remote_metadata_kind
      FROM tracks t
      LEFT JOIN track_scan_info scan ON scan.path = t.path
      LEFT JOIN track_playback_state playback ON playback.path = t.path
      LEFT JOIN track_assets assets ON assets.path = t.path
      LEFT JOIN track_remote_metadata remote ON remote.path = t.path
    ''');
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

  static MusicTrack _trackStartupFromRow(Map<String, dynamic> row) =>
      MusicTrack(
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
        coverCachePath: row['cover_cache_path'] as String?,
        lyricsPath: row['lyrics_path'] as String?,
        manualCoverPath: row['manual_cover_path'] as String?,
        remoteCoverUrl: row['remote_cover_url'] as String?,
        remoteMetadataKind: row['remote_metadata_kind'] as String?,
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

  static void _replaceAsmrWorkListInBatch(
    Batch batch,
    String listType,
    List<AsmrWork> works,
  ) {
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
  }

  static void _replaceAsmrSyncOperationsInBatch(
    Batch batch,
    List<AsmrSyncOperation> operations,
  ) {
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

  static Future<Map<String, Map<int, double>>> _loadSessionEqBandsBySession(
    DatabaseExecutor db,
    List<String> sessionIds,
  ) async {
    final levelsBySession = <String, Map<int, double>>{};
    for (final ids in _sessionIdChunks(sessionIds)) {
      final placeholders = List.filled(ids.length, '?').join(', ');
      final rows = await db.rawQuery('''
        SELECT session_id, frequency_hz, gain_db
        FROM session_eq_bands
        WHERE session_id IN ($placeholders)
        ORDER BY session_id ASC, frequency_hz ASC
      ''', ids);
      for (final row in rows) {
        final sessionId = row['session_id'] as String?;
        final frequency = (row['frequency_hz'] as num?)?.toInt();
        final gain = (row['gain_db'] as num?)?.toDouble();
        if (sessionId == null || frequency == null || gain == null) continue;
        levelsBySession.putIfAbsent(
          sessionId,
          () => <int, double>{},
        )[frequency] = gain;
      }
    }
    return levelsBySession;
  }

  static Future<Map<String, List<Map<String, dynamic>>>>
  _loadPlaybackQueueEntriesBySession(
    DatabaseExecutor db,
    List<String> sessionIds,
  ) async {
    final entriesBySession = <String, List<Map<String, dynamic>>>{};
    for (final ids in _sessionIdChunks(sessionIds)) {
      final placeholders = List.filled(ids.length, '?').join(', ');
      final rows = await db.rawQuery('''
        SELECT session_id, entry_id, kind, title, work_root_path, sort_order
        FROM playback_queue_entries
        WHERE session_id IN ($placeholders)
        ORDER BY session_id ASC, sort_order ASC
      ''', ids);
      for (final row in rows) {
        final sessionId = row['session_id'] as String?;
        if (sessionId == null) continue;
        entriesBySession
            .putIfAbsent(sessionId, () => <Map<String, dynamic>>[])
            .add(row);
      }
    }
    return entriesBySession;
  }

  static Future<Map<String, List<Map<String, dynamic>>>>
  _loadQueueTracksByEntry(DatabaseExecutor db, List<String> sessionIds) async {
    final tracksByEntry = <String, List<Map<String, dynamic>>>{};
    for (final ids in _sessionIdChunks(sessionIds)) {
      final placeholders = List.filled(ids.length, '?').join(', ');
      final rows = await db.rawQuery('''
        SELECT
          session_id,
          entry_id,
          track_path,
          display_name,
          group_key,
          group_title,
          group_subtitle,
          is_single,
          is_video,
          duration_ms,
          file_size_bytes,
          remote_cover_url,
          remote_metadata_kind,
          remote_metadata_json,
          duplicate_index,
          sort_order
        FROM playback_queue_entry_tracks
        WHERE session_id IN ($placeholders)
        ORDER BY session_id ASC, entry_id ASC, sort_order ASC
      ''', ids);
      for (final row in rows) {
        final sessionId = row['session_id'] as String?;
        final entryId = row['entry_id'] as String?;
        if (sessionId == null || entryId == null) continue;
        tracksByEntry
            .putIfAbsent(
              _queueEntryKey(sessionId, entryId),
              () => <Map<String, dynamic>>[],
            )
            .add(row);
      }
    }
    return tracksByEntry;
  }

  static AudioEffectsState _sessionAudioEffectsFromRow(
    Map<String, dynamic> row,
    Map<int, double> levels,
  ) {
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

  static List<MusicTrack>? _customQueueTracksForSession(
    String sessionId,
    Map<String, List<Map<String, dynamic>>> queueTracksByEntry,
  ) {
    final rows =
        queueTracksByEntry[_queueEntryKey(sessionId, '__custom_queue__')];
    if (rows == null) return null;
    if (rows.isEmpty) return null;
    return rows.map(_queueTrackFromRow).toList(growable: false);
  }

  static PlaybackQueueDefinition? _playbackQueueForSession(
    String sessionId,
    Map<String, dynamic> sessionRow,
    Map<String, List<Map<String, dynamic>>> queueEntriesBySession,
    Map<String, List<Map<String, dynamic>>> queueTracksByEntry,
  ) {
    final queueName = sessionRow['queue_name'] as String?;
    if (queueName == null) return null;
    final entryRows =
        queueEntriesBySession[sessionId] ?? const <Map<String, dynamic>>[];
    final entries = <PlaybackQueueEntry>[];
    for (final entryRow in entryRows) {
      final entryId = entryRow['entry_id'] as String;
      final trackRows =
          queueTracksByEntry[_queueEntryKey(sessionId, entryId)] ??
          const <Map<String, dynamic>>[];
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

  static Iterable<List<String>> _sessionIdChunks(
    List<String> sessionIds,
  ) sync* {
    for (
      var start = 0;
      start < sessionIds.length;
      start += _sqliteInClauseBatchSize
    ) {
      final end = (start + _sqliteInClauseBatchSize).clamp(
        0,
        sessionIds.length,
      );
      yield sessionIds.sublist(start, end);
    }
  }

  static String _queueEntryKey(String sessionId, String entryId) =>
      '$sessionId\n$entryId';

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
