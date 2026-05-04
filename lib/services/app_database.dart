import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/music_track.dart';

class AppDatabase {
  AppDatabase._();

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
      version: 1,
      onCreate: _onCreate,
    );
    return db;
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE tracks (
        path TEXT PRIMARY KEY,
        display_name TEXT NOT NULL,
        group_key TEXT NOT NULL,
        group_title TEXT NOT NULL,
        group_subtitle TEXT NOT NULL,
        is_single INTEGER NOT NULL DEFAULT 0
      )
    ''');
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
    final db = await database;
    final batch = db.batch();
    for (final track in tracks) {
      batch.insert('tracks', _trackToRow(track),
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
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

  // ---- Internals ----

  static Map<String, dynamic> _trackToRow(MusicTrack t) => {
        'path': t.path,
        'display_name': t.displayName,
        'group_key': t.groupKey,
        'group_title': t.groupTitle,
        'group_subtitle': t.groupSubtitle,
        'is_single': t.isSingle ? 1 : 0,
      };

  static MusicTrack _trackFromRow(Map<String, dynamic> row) => MusicTrack(
        path: row['path'] as String,
        displayName: row['display_name'] as String,
        groupKey: row['group_key'] as String,
        groupTitle: row['group_title'] as String,
        groupSubtitle: row['group_subtitle'] as String,
        isSingle: (row['is_single'] as int) == 1,
      );
}
