import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/features/data_support/application/app_backup_service.dart';
import 'package:nameless_audio/core/persistence/app_database.dart';
import 'package:nameless_audio/features/settings/application/app_update_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tempDirectory;
  late File databaseFile;
  late Map<String, Object> preferences;
  late int closeCount;
  late int reopenCount;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  AppBackupService createService({
    Future<void> Function(Map<String, Object?> values)? restorePreferences,
    Future<void> Function()? reopenDatabase,
  }) {
    return AppBackupService(
      databasePathProvider: () async => databaseFile.path,
      closeDatabase: () async => closeCount++,
      reopenDatabase:
          reopenDatabase ??
          () async {
            reopenCount++;
          },
      exportPreferences: () async => Map<String, Object>.from(preferences),
      restorePreferences:
          restorePreferences ??
          (values) async {
            preferences = values.cast<String, Object>();
          },
      appVersionProvider: () async =>
          const AppVersionInfo(versionName: '1.2.3', buildNumber: 4),
      platformName: 'test',
    );
  }

  Future<void> createDatabase(
    File file, {
    required String marker,
    int payloadBytes = 0,
    int schemaVersion = AppDatabase.schemaVersion,
  }) async {
    if (await file.exists()) await file.delete();
    final db = await databaseFactoryFfi.openDatabase(file.path);
    try {
      await AppDatabase.createSchemaForTest(db);
      await db.setVersion(schemaVersion);
      await db.insert('app_kv_settings', <String, Object?>{
        'key': 'test_marker',
        'value': marker,
      });
      if (payloadBytes > 0) {
        await db.execute('CREATE TABLE backup_test_payload (value BLOB)');
        await db.rawInsert(
          'INSERT INTO backup_test_payload(value) VALUES(zeroblob(?))',
          <Object?>[payloadBytes],
        );
      }
    } finally {
      await db.close();
    }
  }

  Future<String?> readMarker(File file) async {
    final db = await databaseFactoryFfi.openDatabase(
      file.path,
      options: OpenDatabaseOptions(readOnly: true),
    );
    try {
      final rows = await db.query(
        'app_kv_settings',
        columns: <String>['value'],
        where: 'key = ?',
        whereArgs: <Object?>['test_marker'],
        limit: 1,
      );
      return rows.isEmpty ? null : rows.single['value'] as String?;
    } finally {
      await db.close();
    }
  }

  Future<void> seedPlaybackList(File file, {String id = 'session-1'}) async {
    final db = await databaseFactoryFfi.openDatabase(file.path);
    try {
      await db.insert('sessions', <String, Object?>{
        'id': id,
        'track_path': '/music/track.mp3',
        'loop_mode': 0,
        'sort_order': 0,
      });
      await db.insert('playback_queues', <String, Object?>{
        'session_id': id,
        'name': 'Restored queue',
      });
      await db.insert('playback_queue_entries', <String, Object?>{
        'session_id': id,
        'entry_id': 'entry-1',
        'kind': 'tracks',
        'title': 'Entry',
        'sort_order': 0,
      });
    } finally {
      await db.close();
    }
  }

  Future<int> sessionCount(File file) async {
    final db = await databaseFactoryFfi.openDatabase(
      file.path,
      options: OpenDatabaseOptions(readOnly: true),
    );
    try {
      final rows = await db.rawQuery('SELECT COUNT(*) AS count FROM sessions');
      return (rows.single['count'] as num?)?.toInt() ?? 0;
    } finally {
      await db.close();
    }
  }

  Future<File> replaceBackupDatabase(
    File backup,
    List<int> databaseBytes,
  ) async {
    final archive = ZipDecoder().decodeBytes(await backup.readAsBytes());
    final manifest =
        jsonDecode(
              utf8.decode(
                archive.findFile(AppBackupService.manifestEntry)!.content
                    as List<int>,
              ),
            )
            as Map<String, dynamic>;
    final entries = manifest['entries'] as Map<String, dynamic>;
    entries[AppBackupService.databaseEntry] = <String, Object?>{
      'sha256': sha256.convert(databaseBytes).toString(),
      'size': databaseBytes.length,
    };
    final updated = Archive();
    for (final file in archive.files) {
      if (file.name != AppBackupService.databaseEntry &&
          file.name != AppBackupService.manifestEntry) {
        updated.addFile(file);
      }
    }
    updated
      ..addFile(
        ArchiveFile.bytes(AppBackupService.databaseEntry, databaseBytes),
      )
      ..addFile(
        ArchiveFile.string(
          AppBackupService.manifestEntry,
          jsonEncode(manifest),
        ),
      );
    await backup.writeAsBytes(ZipEncoder().encode(updated), flush: true);
    return backup;
  }

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp('app_backup_test_');
    databaseFile = File('${tempDirectory.path}/audio_player.db');
    await createDatabase(databaseFile, marker: 'original database');
    preferences = <String, Object>{'language': 'zh', 'themeMode': 'dark'};
    closeCount = 0;
    reopenCount = 0;
  });

  tearDown(() => tempDirectory.delete(recursive: true));

  test('exports and validates a complete backup', () async {
    final service = createService();
    final outputPath = '${tempDirectory.path}/backup.nalbackup';

    final output = await service.exportBackup(outputPath);
    final validation = await service.validateBackup(output.path);

    expect(validation.isValid, isTrue);
    expect(validation.manifest?.formatVersion, AppBackupService.formatVersion);
    expect(validation.manifest?.dataEpoch, AppBackupService.dataEpoch);
    expect(validation.manifest?.appVersion, '1.2.3+4');
    expect(validation.manifest?.platform, 'test');
    expect(closeCount, 1);
    expect(reopenCount, 1);
  });

  test(
    'large database fixture exports validates and restores by stream',
    () async {
      const fixtureBytes = 16 * 1024 * 1024;
      await createDatabase(
        databaseFile,
        marker: 'large database',
        payloadBytes: fixtureBytes,
      );
      final expectedLength = await databaseFile.length();
      final service = createService();

      final output = await service.exportBackup(
        '${tempDirectory.path}/large.nalbackup',
      );
      final validation = await service.validateBackup(output.path);
      await createDatabase(databaseFile, marker: 'changed');
      final restore = await service.restoreBackup(output.path);

      expect(validation.isValid, isTrue);
      expect(
        validation.manifest?.entries[AppBackupService.databaseEntry]?.size,
        expectedLength,
      );
      expect(restore.isValid, isTrue);
      expect(await databaseFile.length(), expectedLength);
      final restoredDatabase = await databaseFactoryFfi.openDatabase(
        databaseFile.path,
        options: OpenDatabaseOptions(readOnly: true),
      );
      final payloadLength = await restoredDatabase.rawQuery(
        'SELECT length(value) AS size FROM backup_test_payload',
      );
      await restoredDatabase.close();
      expect(payloadLength.single['size'], fixtureBytes);
      expect(preferences, containsPair('language', 'zh'));
    },
  );

  test('stores the database entry without buffering compression', () async {
    final output = await createService().exportBackup(
      '${tempDirectory.path}/stored_database.nalbackup',
    );

    final archive = ZipDecoder().decodeBytes(await output.readAsBytes());

    expect(
      archive.findFile(AppBackupService.databaseEntry)?.compression,
      CompressionType.none,
    );
  });

  test(
    'export excludes playback sessions and queues from its database copy',
    () async {
      await seedPlaybackList(databaseFile);

      final output = await createService().exportBackup(
        '${tempDirectory.path}/without_playback_lists.nalbackup',
      );
      final archive = ZipDecoder().decodeBytes(await output.readAsBytes());
      final exportedDatabase = File('${tempDirectory.path}/exported.db');
      await exportedDatabase.writeAsBytes(
        archive.findFile(AppBackupService.databaseEntry)!.content as List<int>,
      );

      expect(await sessionCount(databaseFile), 1);
      expect(await sessionCount(exportedDatabase), 0);
    },
  );

  test(
    'restore strips playback lists from backups created by older builds',
    () async {
      final legacyDatabase = File('${tempDirectory.path}/legacy_with_queue.db');
      await createDatabase(legacyDatabase, marker: 'legacy with queue');
      await seedPlaybackList(legacyDatabase, id: 'legacy-session');
      final backup = await createService().exportBackup(
        '${tempDirectory.path}/legacy_with_queue.nalbackup',
      );
      await replaceBackupDatabase(backup, await legacyDatabase.readAsBytes());

      final result = await createService().restoreBackup(backup.path);

      expect(result.isValid, isTrue);
      expect(await readMarker(databaseFile), 'legacy with queue');
      expect(await sessionCount(databaseFile), 0);
    },
  );

  test('restores legacy backups with a deflate-compressed database', () async {
    final legacyDatabase = File('${tempDirectory.path}/legacy.db');
    await createDatabase(legacyDatabase, marker: 'legacy compressed database');
    final databaseBytes = await legacyDatabase.readAsBytes();
    final preferencesBytes = utf8.encode(
      jsonEncode(<String, Object>{'language': 'ja', 'themeMode': 'light'}),
    );
    final manifest = <String, Object?>{
      'formatVersion': AppBackupService.formatVersion,
      'dataEpoch': AppBackupService.dataEpoch,
      'appVersion': '1.2.3+4',
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'platform': 'test',
      'databaseSchemaVersion': AppDatabase.schemaVersion,
      'entries': <String, Object?>{
        AppBackupService.databaseEntry: <String, Object?>{
          'sha256': sha256.convert(databaseBytes).toString(),
          'size': databaseBytes.length,
        },
        AppBackupService.preferencesEntry: <String, Object?>{
          'sha256': sha256.convert(preferencesBytes).toString(),
          'size': preferencesBytes.length,
        },
      },
    };
    final archive = Archive()
      ..addFile(
        ArchiveFile.bytes(AppBackupService.databaseEntry, databaseBytes),
      )
      ..addFile(
        ArchiveFile.bytes(AppBackupService.preferencesEntry, preferencesBytes),
      )
      ..addFile(
        ArchiveFile.string(
          AppBackupService.manifestEntry,
          jsonEncode(manifest),
        ),
      );
    final backup = File('${tempDirectory.path}/legacy_compressed.nalbackup');
    await backup.writeAsBytes(ZipEncoder().encode(archive), flush: true);
    await createDatabase(databaseFile, marker: 'current database');

    final result = await createService().restoreBackup(backup.path);

    expect(result.isValid, isTrue);
    expect(await readMarker(databaseFile), 'legacy compressed database');
    expect(preferences, containsPair('language', 'ja'));
  });

  test('rejects a 0.x format backup', () async {
    final archive = Archive()
      ..addFile(
        ArchiveFile.string(
          AppBackupService.manifestEntry,
          jsonEncode(<String, Object?>{
            'formatVersion': 1,
            'appVersion': '0.12.4+1204',
            'createdAt': DateTime.now().toUtc().toIso8601String(),
            'platform': 'test',
            'databaseSchemaVersion': 18,
            'entries': <String, Object?>{},
          }),
        ),
      );
    final file = File('${tempDirectory.path}/legacy.nalbackup');
    await file.writeAsBytes(ZipEncoder().encode(archive));

    final validation = await createService().validateBackup(file.path);

    expect(validation.isValid, isFalse);
    expect(validation.error, 'unsupported_format_version');
  });

  test('rejects backup from another data epoch', () async {
    final service = createService();
    final backup = await service.exportBackup(
      '${tempDirectory.path}/other_epoch.nalbackup',
    );
    final archive = ZipDecoder().decodeBytes(await backup.readAsBytes());
    final manifestFile = archive.findFile(AppBackupService.manifestEntry)!;
    final manifest =
        jsonDecode(utf8.decode(manifestFile.content as List<int>))
            as Map<String, dynamic>;
    manifest['dataEpoch'] = AppBackupService.dataEpoch + 1;
    final bytes = utf8.encode(jsonEncode(manifest));
    final updatedArchive = Archive();
    for (final file in archive.files) {
      if (file.name != AppBackupService.manifestEntry) {
        updatedArchive.addFile(file);
      }
    }
    updatedArchive.addFile(
      ArchiveFile(AppBackupService.manifestEntry, bytes.length, bytes),
    );
    await backup.writeAsBytes(ZipEncoder().encode(updatedArchive), flush: true);

    final validation = await service.validateBackup(backup.path);

    expect(validation.isValid, isFalse);
    expect(validation.error, 'unsupported_data_epoch');
  });

  test('rejects backup without a manifest', () async {
    final archive = Archive()
      ..addFile(ArchiveFile.string('unexpected.txt', 'no manifest'));
    final file = File('${tempDirectory.path}/invalid.nalbackup');
    await file.writeAsBytes(ZipEncoder().encode(archive));

    final validation = await createService().validateBackup(file.path);

    expect(validation.isValid, isFalse);
    expect(validation.error, 'missing_manifest');
  });

  test('rejects a backup created by a future database schema', () async {
    final service = createService();
    final backup = await service.exportBackup(
      '${tempDirectory.path}/future.nalbackup',
    );
    final archive = ZipDecoder().decodeBytes(await backup.readAsBytes());
    final manifestFile = archive.findFile(AppBackupService.manifestEntry)!;
    final manifest =
        jsonDecode(utf8.decode(manifestFile.content as List<int>))
            as Map<String, dynamic>;
    manifest['databaseSchemaVersion'] = AppDatabase.schemaVersion + 1;
    final bytes = utf8.encode(jsonEncode(manifest));
    final updatedArchive = Archive();
    for (final file in archive.files) {
      if (file.name != AppBackupService.manifestEntry) {
        updatedArchive.addFile(file);
      }
    }
    updatedArchive.addFile(
      ArchiveFile(AppBackupService.manifestEntry, bytes.length, bytes),
    );
    await backup.writeAsBytes(ZipEncoder().encode(updatedArchive), flush: true);

    final result = await service.validateBackup(backup.path);

    expect(result.isValid, isFalse);
    expect(result.error, 'unsupported_database_version');
  });

  test('rejects corrupt SQLite before replacing current data', () async {
    final service = createService();
    final backup = await service.exportBackup(
      '${tempDirectory.path}/corrupt_database.nalbackup',
    );
    await replaceBackupDatabase(backup, utf8.encode('not a sqlite database'));
    await createDatabase(databaseFile, marker: 'current database');
    preferences = <String, Object>{'language': 'en'};

    final validation = await service.validateBackup(backup.path);
    final restore = await service.restoreBackup(backup.path);

    expect(validation.isValid, isFalse);
    expect(validation.error, 'invalid_database');
    expect(restore.error, 'invalid_database');
    expect(await readMarker(databaseFile), 'current database');
    expect(preferences, containsPair('language', 'en'));
  });

  test('rejects SQLite without the app schema', () async {
    final emptyDatabase = File('${tempDirectory.path}/empty.db');
    final db = await databaseFactoryFfi.openDatabase(emptyDatabase.path);
    await db.setVersion(AppDatabase.schemaVersion);
    await db.close();
    final service = createService();
    final backup = await service.exportBackup(
      '${tempDirectory.path}/missing_schema.nalbackup',
    );
    await replaceBackupDatabase(backup, await emptyDatabase.readAsBytes());

    final validation = await service.validateBackup(backup.path);

    expect(validation.isValid, isFalse);
    expect(validation.error, 'invalid_database');
  });

  test(
    'rejects SQLite whose actual schema version differs from manifest',
    () async {
      final mismatchedDatabase = File('${tempDirectory.path}/mismatched.db');
      await createDatabase(
        mismatchedDatabase,
        marker: 'mismatched',
        schemaVersion: AppDatabase.schemaVersion - 1,
      );
      final service = createService();
      final backup = await service.exportBackup(
        '${tempDirectory.path}/mismatched_schema.nalbackup',
      );
      await replaceBackupDatabase(
        backup,
        await mismatchedDatabase.readAsBytes(),
      );

      final validation = await service.validateBackup(backup.path);

      expect(validation.isValid, isFalse);
      expect(validation.error, 'invalid_database');
    },
  );

  test('restores database and preferences after validation', () async {
    final service = createService();
    final output = await service.exportBackup(
      '${tempDirectory.path}/backup.nalbackup',
    );
    await createDatabase(databaseFile, marker: 'changed database');
    preferences = <String, Object>{'language': 'en'};

    final result = await service.restoreBackup(output.path);

    expect(result.isValid, isTrue);
    expect(await readMarker(databaseFile), 'original database');
    expect(preferences, containsPair('language', 'zh'));
    expect(preferences, containsPair('themeMode', 'dark'));
    expect(await File('${databaseFile.path}.restore-backup').exists(), isFalse);
  });

  test('rolls database back when replacement cannot reopen', () async {
    final output = await createService().exportBackup(
      '${tempDirectory.path}/reopen_failure.nalbackup',
    );
    await createDatabase(databaseFile, marker: 'current database');
    preferences = <String, Object>{'language': 'en'};
    var attempts = 0;
    final service = createService(
      reopenDatabase: () async {
        attempts++;
        if (attempts == 1) throw StateError('open failed');
      },
    );

    final result = await service.restoreBackup(output.path);

    expect(result.isValid, isFalse);
    expect(result.error, 'restore_failed');
    expect(await readMarker(databaseFile), 'current database');
    expect(preferences, containsPair('language', 'en'));
    expect(attempts, 2);
  });

  test('rolls database back when restoring preferences fails', () async {
    final exportService = createService();
    final output = await exportService.exportBackup(
      '${tempDirectory.path}/backup.nalbackup',
    );
    await createDatabase(databaseFile, marker: 'current database');
    preferences = <String, Object>{'language': 'en'};
    var attempts = 0;
    final restoreService = createService(
      restorePreferences: (values) async {
        attempts++;
        if (attempts == 1) throw StateError('restore failed');
        preferences = (jsonDecode(jsonEncode(values)) as Map<String, dynamic>)
            .cast<String, Object>();
      },
    );

    final result = await restoreService.restoreBackup(output.path);

    expect(result.isValid, isFalse);
    expect(result.error, 'restore_failed');
    expect(await readMarker(databaseFile), 'current database');
    expect(preferences, containsPair('language', 'en'));
  });
}
