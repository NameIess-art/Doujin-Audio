import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../immutable_collections.dart';
import '../media/audio_detail.dart';
import '../../features/player/domain/audio_effects.dart';
import '../../features/asmr/domain/asmr_models.dart';
import '../../features/library/domain/library_entry.dart';
import '../media/music_track.dart';
import '../../features/player/domain/playback_queue.dart';
import '../../features/player/domain/time_segment_label.dart';
import '../media/path_matcher.dart';

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
  AppDatabase._() : _beforeOperationRegistration = null;

  static const int schemaVersion = 4;
  static const String fileName = 'audio_player.db';

  @visibleForTesting
  AppDatabase.test(
    Database db, {
    Future<Database> Function()? databaseOpener,
    Future<String> Function()? filePathProvider,
    Future<void> Function()? beforeOperationRegistration,
  }) : _db = db,
       _databaseOpener = databaseOpener,
       _databasePathProvider = filePathProvider,
       _beforeOperationRegistration = beforeOperationRegistration;

  static AppDatabase? _instance;
  static AppDatabase get instance => _instance ??= AppDatabase._();

  @visibleForTesting
  static void setInstanceForTest(AppDatabase? database) {
    _instance = database;
  }

  Database? _db;
  Future<Database> Function()? _databaseOpener;
  Future<String> Function()? _databasePathProvider;
  final Future<void> Function()? _beforeOperationRegistration;
  Future<Database>? _openFuture;
  Future<void>? _maintenanceBarrier;
  Future<void> _maintenanceTail = Future<void>.value();
  final _DatabaseLifecycleGate _lifecycleGate = _DatabaseLifecycleGate();
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
    final lease = await _acquireDatabaseOperation(
      submittedEpoch: submittedEpoch,
      rejectStaleWrites: true,
    );
    if (lease == null) return;
    try {
      await operation(lease.database);
    } finally {
      lease.release();
    }
  }

  Future<T> _runDatabaseRead<T>(
    Future<T> Function(Database db) operation,
  ) async {
    while (true) {
      final lease = await _acquireDatabaseOperation();
      if (lease == null) continue;
      try {
        return await operation(lease.database);
      } finally {
        lease.release();
      }
    }
  }

  Future<_DatabaseOperationLease?> _acquireDatabaseOperation({
    int? submittedEpoch,
    bool rejectStaleWrites = false,
  }) async {
    while (true) {
      Future<void>? barrierToWait;
      final lease = await _lifecycleGate.run<_DatabaseOperationLease?>(
        () async {
          final barrier = _maintenanceBarrier;
          if (barrier != null) {
            barrierToWait = barrier;
            return null;
          }

          final db = await _openIgnoringMaintenance();
          await _beforeOperationRegistration?.call();
          final barrierAfterOpen = _maintenanceBarrier;
          if (barrierAfterOpen != null) {
            barrierToWait = barrierAfterOpen;
            return null;
          }
          if (rejectStaleWrites && submittedEpoch != _databaseEpoch) {
            return null;
          }

          _activeOperations++;
          return _DatabaseOperationLease(this, db);
        },
      );
      if (lease != null) return lease;
      if (rejectStaleWrites && submittedEpoch != _databaseEpoch) return null;
      if (barrierToWait != null) {
        await barrierToWait;
      } else {
        await Future<void>.delayed(Duration.zero);
      }
    }
  }

  void _releaseDatabaseOperation() {
    _activeOperations--;
    if (_activeOperations == 0) {
      _operationsDrained?.complete();
      _operationsDrained = null;
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

final class _DatabaseOperationLease {
  _DatabaseOperationLease(this._owner, this.database);

  final AppDatabase _owner;
  final Database database;
  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    _owner._releaseDatabaseOperation();
  }
}

final class _DatabaseLifecycleGate {
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();
  bool _locked = false;

  Future<T> run<T>(Future<T> Function() action) async {
    if (_locked) {
      final ready = Completer<void>();
      _waiters.addLast(ready);
      await ready.future;
    } else {
      _locked = true;
    }
    try {
      return await action();
    } finally {
      if (_waiters.isEmpty) {
        _locked = false;
      } else {
        _waiters.removeFirst().complete();
      }
    }
  }
}
