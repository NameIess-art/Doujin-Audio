import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/music_track.dart';

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
      version: 7,
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
    duration: Duration(milliseconds: (row['duration_ms'] as num?)?.toInt() ?? 0),
  );

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
