import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../logging/app_log_service.dart';
import '../media/cross_platform_media_identity.dart';
import '../media/music_track.dart';
import '../media/path_matcher.dart';
import 'persistence_records.dart';

part 'app_database_tracks.dart';
part 'app_database_backup.dart';
part 'app_database_sessions.dart';
part 'app_database_audio_details.dart';
part 'app_database_library_entries.dart';
part 'app_database_asmr.dart';
part 'app_database_schema.dart';
part 'app_database_row_codecs.dart';
part 'app_database_listening.dart';
part 'app_database_sync.dart';

const int _sqliteInClauseBatchSize = 900;

class AppDatabase {
  AppDatabase._({Future<Database> Function()? opener}) : _opener = opener;

  static const int schemaVersion = 24;
  static const String fileName = 'audio_player.db';

  @visibleForTesting
  AppDatabase.test(Database db, {Future<Database> Function()? opener})
    : _db = db,
      _opener = opener;

  @visibleForTesting
  AppDatabase.forTest({Future<Database> Function()? opener}) : _opener = opener;

  static AppDatabase? _instance;
  static AppDatabase get instance => _instance ??= AppDatabase._();

  @visibleForTesting
  static void setInstanceForTest(AppDatabase? database) {
    _instance = database;
  }

  final Future<Database> Function()? _opener;
  Database? _db;
  Future<Database>? _openFuture;
  Future<void>? _closeFuture;
  int _generation = 0;

  Future<Database> get _database async {
    if (_db != null && _closeFuture == null) return _db!;
    return _openDatabase();
  }

  Future<Database> get databaseForTest => _database;

  Future<Database> _open() async {
    if (_opener != null) return _opener();
    final dbPath = await getDatabasesPath();
    final db = await openDatabase(
      p.join(dbPath, fileName),
      version: schemaVersion,
      onConfigure: _onConfigure,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
    return db;
  }

  Future<void> _onConfigure(Database db) async {
    // Use rawQuery for PRAGMAs that return a result row on Android SQLite.
    await db.rawQuery('PRAGMA busy_timeout = 5000');
    await db.rawQuery('PRAGMA journal_mode = WAL');
    await db.execute('PRAGMA synchronous = NORMAL');
    await db.execute('PRAGMA cache_size = -8192');
    await db.execute('PRAGMA temp_store = MEMORY');
  }

  Future<Database> _openDatabase() async {
    while (true) {
      final pendingClose = _closeFuture;
      if (pendingClose != null) {
        await pendingClose;
      }
      final existing = _db;
      if (existing != null && _closeFuture == null) return existing;

      final generation = _generation;
      final opening = _openFuture ??= _open().then((db) {
        if (generation == _generation && _closeFuture == null) {
          _db = db;
        }
        return db;
      });
      final Database db;
      try {
        db = await opening;
      } finally {
        if (identical(_openFuture, opening)) {
          _openFuture = null;
        }
      }
      if (generation == _generation && identical(_db, db)) {
        return db;
      }
      // close() intervened while _open() was pending; wait for it to finish
      // closing `db` before opening a fresh connection.
      final activeClose = _closeFuture;
      if (activeClose != null) {
        await activeClose;
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
    _generation++;
    final pendingClose = _closeFuture;
    if (pendingClose != null) {
      await pendingClose;
    }
    final closing = _closeInternal();
    _closeFuture = closing;
    try {
      await closing;
    } finally {
      if (identical(_closeFuture, closing)) {
        _closeFuture = null;
      }
    }
  }

  Future<void> _closeInternal() async {
    final open = _openFuture;
    if (open != null) {
      try {
        final db = await open;
        if (identical(_db, db)) _db = null;
        if (db.isOpen) await db.close();
      } catch (_) {
        // Failed opens have no open database handle to close.
      } finally {
        if (identical(_openFuture, open)) {
          _openFuture = null;
        }
      }
    }
    final db = _db;
    _db = null;
    if (db != null && db.isOpen) {
      await db.close();
    }
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
