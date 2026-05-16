import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/audio_detail.dart';
import '../models/library_entry.dart';
import '../models/music_track.dart';
import 'path_matcher.dart';

class AppDatabase {
  AppDatabase._();

  @visibleForTesting
  AppDatabase.test(Database db) : _db = db;

  static AppDatabase? _instance;
  static AppDatabase get instance => _instance ??= AppDatabase._();

  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _open();
    return _db!;
  }

  Future<Database> _open() async {
    final dbPath = await getDatabasesPath();
    final db = await openDatabase(
      p.join(dbPath, 'audio_player.db'),
      version: 10,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
    return db;
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
        scanned_at_ms INTEGER,
        file_size_bytes INTEGER,
        modified_at_ms INTEGER,
        last_played_position_ms INTEGER NOT NULL DEFAULT 0,
        last_played_at_ms INTEGER,
        is_favorite INTEGER NOT NULL DEFAULT 0,
        tags_json TEXT NOT NULL DEFAULT '[]',
        cover_cache_path TEXT,
        lyrics_path TEXT,
        manual_cover_path TEXT,
        duration_ms INTEGER NOT NULL DEFAULT 0,
        scan_generation INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await _createTrackIndexes(db);
    await db.execute('''
      CREATE TABLE sessions (
        id TEXT PRIMARY KEY,
        track_path TEXT NOT NULL,
        loop_mode INTEGER NOT NULL,
        volume REAL NOT NULL,
        position_ms INTEGER NOT NULL DEFAULT 0,
        duration_ms INTEGER NOT NULL DEFAULT 0,
        channel_swap INTEGER NOT NULL DEFAULT 0,
        created_at_ms INTEGER,
        updated_at_ms INTEGER,
        last_played_at_ms INTEGER,
        sort_order INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await _createAudioDetailsTable(db);
    await _createLibraryEntriesTable(db);
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

  static Future<void> _createTrackIndexes(Database db) async {
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_tracks_group_key ON tracks(group_key)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_tracks_display_name ON tracks(display_name)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_tracks_last_played_at ON tracks(last_played_at_ms)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_tracks_favorite ON tracks(is_favorite)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_tracks_scan_generation ON tracks(scan_generation)',
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

  // ---- Tracks ----

  Future<List<MusicTrack>> loadAllTracks() async {
    final db = await database;
    final rows = await db.query('tracks');
    return rows.map(_trackFromRow).toList();
  }

  Future<void> saveAllTracks(List<MusicTrack> tracks) async {
    final db = await database;
    final batch = db.batch();
    // Clear and repopulate; for very large libraries this is still
    // a single transaction and orders of magnitude faster than
    // serialising the full list as JSON into SharedPreferences.
    batch.delete('tracks');
    for (final track in tracks) {
      batch.insert('tracks', _trackToRow(track));
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
      batch.insert(
        'tracks',
        _trackToRow(track, scanGeneration: scanGeneration),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<int> nextScanGeneration() async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT COALESCE(MAX(scan_generation), 0) + 1 AS next_generation FROM tracks',
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
    await db.delete(
      'tracks',
      where: 'scan_generation != ?',
      whereArgs: [generation],
    );
  }

  Future<void> deleteTracks(List<String> paths) async {
    final db = await database;
    final batch = db.batch();
    for (final p in paths) {
      batch.delete('tracks', where: 'path = ?', whereArgs: [p]);
    }
    await batch.commit(noResult: true);
  }

  Future<void> deleteAllTracks() async {
    final db = await database;
    await db.delete('tracks');
  }

  Future<List<PersistedSession>> loadAllSessions() async {
    final db = await database;
    final rows = await db.query('sessions', orderBy: 'sort_order ASC');
    return rows.map(_sessionFromRow).toList();
  }

  Future<void> saveAllSessions(List<PersistedSession> sessions) async {
    final db = await database;
    final batch = db.batch();
    batch.delete('sessions');
    for (var i = 0; i < sessions.length; i++) {
      batch.insert('sessions', _sessionToRow(sessions[i], i));
    }
    await batch.commit(noResult: true);
  }

  Future<void> deleteAllSessions() async {
    final db = await database;
    await db.delete('sessions');
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

  // ---- SharedPreferences migration helper ----

  /// One-shot: load from the legacy SharedPreferences JSON blob and store
  /// into SQLite. Returns the deserialized track list so the caller can
  /// feed it into the in-memory library without a second parse.
  static List<MusicTrack>? tryMigrateFromJson(String? rawJson) {
    if (rawJson == null || rawJson.isEmpty) return null;
    try {
      final list = json.decode(rawJson) as List<dynamic>;
      return list
          .whereType<Map<String, dynamic>>()
          .map(MusicTrack.fromJson)
          .toList();
    } catch (_) {
      return null;
    }
  }

  static List<PersistedSession>? tryMigrateSessionsFromJson(String? rawJson) {
    if (rawJson == null || rawJson.isEmpty) return null;
    try {
      final list = json.decode(rawJson) as List<dynamic>;
      final sessions = <PersistedSession>[];
      for (var i = 0; i < list.length; i++) {
        final item = list[i];
        if (item is! Map<String, dynamic>) continue;
        final trackPath = item['path'] as String?;
        if (trackPath == null || trackPath.isEmpty) continue;
        sessions.add(
          PersistedSession(
            id: item['id'] as String? ?? 'session_$i',
            trackPath: trackPath,
            loopModeIndex: (item['loopMode'] as num?)?.toInt() ?? 1,
            volume: (item['volume'] as num?)?.toDouble() ?? 1.0,
            positionMs: (item['positionMs'] as num?)?.toInt() ?? 0,
            durationMs: (item['durationMs'] as num?)?.toInt() ?? 0,
            channelSwapEnabled: item['channelSwap'] as bool? ?? false,
            createdAtMs: (item['createdAtMs'] as num?)?.toInt(),
            updatedAtMs: (item['updatedAtMs'] as num?)?.toInt(),
            lastPlayedAtMs: (item['lastPlayedAtMs'] as num?)?.toInt(),
            sortOrder: i,
          ),
        );
      }
      return sessions;
    } catch (_) {
      return null;
    }
  }

  // ---- Internals ----

  static Map<String, dynamic> _trackToRow(
    MusicTrack t, {
    int? scanGeneration,
  }) => {
    'path': t.path,
    'display_name': t.displayName,
    'group_key': t.groupKey,
    'group_title': t.groupTitle,
    'group_subtitle': t.groupSubtitle,
    'is_single': t.isSingle ? 1 : 0,
    'is_video': t.isVideo ? 1 : 0,
    'scanned_at_ms': t.scannedAt?.millisecondsSinceEpoch,
    'file_size_bytes': t.fileSizeBytes,
    'modified_at_ms': t.modifiedAt?.millisecondsSinceEpoch,
    'last_played_position_ms': t.lastPlayedPosition.inMilliseconds,
    'last_played_at_ms': t.lastPlayedAt?.millisecondsSinceEpoch,
    'is_favorite': t.isFavorite ? 1 : 0,
    'tags_json': json.encode(t.tags),
    'cover_cache_path': t.coverCachePath,
    'lyrics_path': t.lyricsPath,
    'manual_cover_path': t.manualCoverPath,
    'duration_ms': t.duration.inMilliseconds,
    'scan_generation': scanGeneration ?? 0,
  };

  static MusicTrack _trackFromRow(Map<String, dynamic> row) => MusicTrack(
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
    tags: _decodeTags(row['tags_json']),
    coverCachePath: row['cover_cache_path'] as String?,
    lyricsPath: row['lyrics_path'] as String?,
    manualCoverPath: row['manual_cover_path'] as String?,
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

  static Map<String, dynamic> _sessionToRow(
    PersistedSession session,
    int sortOrder,
  ) => {
    'id': session.id,
    'track_path': session.trackPath,
    'loop_mode': session.loopModeIndex,
    'volume': session.volume,
    'position_ms': session.positionMs,
    'duration_ms': session.durationMs,
    'channel_swap': session.channelSwapEnabled ? 1 : 0,
    'created_at_ms': session.createdAtMs,
    'updated_at_ms': session.updatedAtMs,
    'last_played_at_ms': session.lastPlayedAtMs,
    'sort_order': sortOrder,
  };

  static PersistedSession _sessionFromRow(Map<String, dynamic> row) =>
      PersistedSession(
        id: row['id'] as String,
        trackPath: row['track_path'] as String,
        loopModeIndex: row['loop_mode'] as int,
        volume: (row['volume'] as num).toDouble(),
        positionMs: row['position_ms'] as int,
        durationMs: row['duration_ms'] as int? ?? 0,
        channelSwapEnabled: (row['channel_swap'] as int? ?? 0) == 1,
        createdAtMs: (row['created_at_ms'] as num?)?.toInt(),
        updatedAtMs: (row['updated_at_ms'] as num?)?.toInt(),
        lastPlayedAtMs: (row['last_played_at_ms'] as num?)?.toInt(),
        sortOrder: row['sort_order'] as int,
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

class PersistedSession {
  const PersistedSession({
    required this.id,
    required this.trackPath,
    required this.loopModeIndex,
    required this.volume,
    required this.positionMs,
    required this.durationMs,
    required this.channelSwapEnabled,
    required this.sortOrder,
    this.createdAtMs,
    this.updatedAtMs,
    this.lastPlayedAtMs,
  });

  final String id;
  final String trackPath;
  final int loopModeIndex;
  final double volume;
  final int positionMs;
  final int durationMs;
  final bool channelSwapEnabled;
  final int sortOrder;
  final int? createdAtMs;
  final int? updatedAtMs;
  final int? lastPlayedAtMs;
}
