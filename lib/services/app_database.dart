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

part 'app_database_tracks.dart';
part 'app_database_sessions.dart';
part 'app_database_audio_details.dart';
part 'app_database_library_entries.dart';
part 'app_database_asmr.dart';
part 'app_database_schema.dart';
part 'app_database_maintenance.dart';
part 'app_database_row_codecs.dart';

const int _sqliteInClauseBatchSize = 900;

class AppDatabase {
  AppDatabase._();

  static const int schemaVersion = 3;
  static const String fileName = 'audio_player.db';
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

  @visibleForTesting
  static Future<void> createSchemaForTest(Database db) => _onCreate(db, 1);

  @visibleForTesting
  static Future<void> upgradeSchemaForTest(
    Database db,
    int oldVersion,
    int newVersion,
  ) => _onUpgrade(db, oldVersion, newVersion);
}
