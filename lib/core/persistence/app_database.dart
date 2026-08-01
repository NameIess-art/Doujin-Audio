import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../media/audio_detail.dart';
import '../media/music_track.dart';
import '../media/path_matcher.dart';
import 'persistence_records.dart';

part 'app_database_tracks.dart';
part 'app_database_sessions.dart';
part 'app_database_audio_details.dart';
part 'app_database_library_entries.dart';
part 'app_database_asmr.dart';
part 'app_database_schema.dart';
part 'app_database_row_codecs.dart';

const int _sqliteInClauseBatchSize = 900;

class AppDatabase {
  AppDatabase._();

  static const int schemaVersion = 5;
  static const String fileName = 'audio_player.db';

  @visibleForTesting
  AppDatabase.test(Database db) : _db = db;

  static AppDatabase? _instance;
  static AppDatabase get instance => _instance ??= AppDatabase._();

  @visibleForTesting
  static void setInstanceForTest(AppDatabase? database) {
    _instance = database;
  }

  Database? _db;
  Future<Database>? _openFuture;

  Future<Database> get _database async {
    if (_db != null) return _db!;
    return _openDatabase();
  }

  Future<Database> get databaseForTest => _database;

  Future<Database> _open() async {
    final dbPath = await getDatabasesPath();
    final db = await openDatabase(
      p.join(dbPath, fileName),
      version: schemaVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
    return db;
  }

  Future<Database> _openDatabase() async {
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
    await operation(await _database);
  }

  Future<T> _runDatabaseRead<T>(Future<T> Function(Database db) operation) {
    return _database.then(operation);
  }

  Future<void> close() async {
    await _openFuture;
    final db = _db;
    _db = null;
    await db?.close();
  }

  @visibleForTesting
  static Future<void> createSchemaForTest(Database db) => _onCreate(db, 1);

  @visibleForTesting
  static Future<void> upgradeSchemaForTest(
    Database db,
    int oldVersion,
    int newVersion,
  ) => _onUpgrade(db, oldVersion, newVersion);
}
