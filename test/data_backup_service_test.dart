import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:doujin_audio/app/theme/theme_provider.dart';
import 'package:doujin_audio/features/settings/application/settings_repository.dart';
import 'package:doujin_audio/core/persistence/app_database.dart';
import 'package:doujin_audio/core/persistence/persistence_records.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/features/asmr/application/asmr_auth_service.dart';
import 'package:doujin_audio/features/data_support/application/data_backup_service.dart';
import 'package:doujin_audio/core/persistence/app_preferences.dart';
import 'package:doujin_audio/features/settings/application/app_update_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory temporaryDirectory;
  late Directory databaseDirectory;
  late Database sourceDatabase;
  late AppDatabase appDatabase;
  late SecureAsmrTokenStore accountStore;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'doujin_backup_test_',
    );
    databaseDirectory = Directory('${temporaryDirectory.path}/databases');
    sourceDatabase = await databaseFactoryFfi.openDatabase(
      '${temporaryDirectory.path}/source.db',
    );
    await AppDatabase.createSchemaForTest(sourceDatabase);
    await sourceDatabase.execute('PRAGMA user_version = 6');
    appDatabase = AppDatabase.test(sourceDatabase);
    accountStore = SecureAsmrTokenStore();
    SharedPreferences.setMockInitialValues(<String, Object>{
      'themeMode': 'dark',
      'timer_runtime_v1': 'transient',
      'subtitle_positions': <String>['session|0.5'],
    });
    await AppPreferences.init();
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'asmr_one_jwt_token_v1': 'account-token',
      'asmr_one_name_v1': 'account-name',
      'asmr_one_pass_v1': 'account-password',
    });
  });

  tearDown(() async {
    if (sourceDatabase.isOpen) await sourceDatabase.close();
    await temporaryDirectory.delete(recursive: true);
  });

  test(
    'export waits for queued settings and theme before taking preferences',
    () async {
      final settingsGate = Completer<void>();
      final themeGate = Completer<void>();
      final settings = SettingsRepository(
        readProxyPassword: () async => null,
        writeProxyPassword: (_) => settingsGate.future,
      );
      final theme = ThemeProvider(
        preferenceWriter: (key, value) async {
          await themeGate.future;
          return AppPreferences.setString(key, value as String);
        },
      );
      addTearDown(settings.dispose);
      addTearDown(theme.dispose);
      final first = settings.setNetworkRouteSettings(
        settings.networkRouteSettings,
        password: 'queued-password',
      );
      final last = settings.setAllowVideoPlayback(false);
      final themeWrite = theme.setThemeMode(ThemeMode.light);
      final service = DataBackupService(
        database: appDatabase,
        accountStore: accountStore,
        appUpdateService: _FakeAppUpdateService(),
        supportDirectoryProvider: () async => temporaryDirectory,
        beforeExport: () => Future.wait([
          settings.flushPendingWrites(),
          theme.flushPendingWrites(),
        ]),
      );
      final outputPath = '${temporaryDirectory.path}/queued.dabackup';
      final exporting = service.exportBackup(outputPath);
      await Future<void>.delayed(Duration.zero);
      expect(await File(outputPath).exists(), isFalse);
      settingsGate.complete();
      themeGate.complete();
      final backup = await exporting;
      await Future.wait([first, last, themeWrite]);
      final archive = ZipDecoder().decodeBytes(await backup.readAsBytes());
      final preferences =
          jsonDecode(
                utf8.decode(
                  archive.findFile('preferences.json')!.content as List<int>,
                ),
              )
              as Map<String, dynamic>;
      expect(preferences['themeMode'], 'light');
      expect(
        (jsonDecode(preferences['playback_settings_v1'] as String)
            as Map)['allowVideoPlayback'],
        isFalse,
      );
    },
  );

  test('startup removes abandoned work without a pending restore', () async {
    for (final name in ['export_interrupted', 'validation_interrupted']) {
      final file = File(
        '${temporaryDirectory.path}/backup_work/$name/database.sqlite',
      );
      await file.parent.create(recursive: true);
      await file.writeAsString('abandoned');
    }
    final unrelated = Directory(
      '${temporaryDirectory.path}/backup_work/unrelated',
    );
    await unrelated.create();

    final outcome = await DataBackupService(
      supportDirectoryProvider: () async => temporaryDirectory,
    ).applyAtStartup();

    expect(outcome, isNull);
    expect(
      Directory('${temporaryDirectory.path}/backup_work').listSync(),
      hasLength(1),
    );
    expect(unrelated.existsSync(), isTrue);
  });

  test('work cleanup preserves pending restore and rollback files', () async {
    final abandoned = Directory(
      '${temporaryDirectory.path}/backup_work/export_interrupted',
    );
    await abandoned.create(recursive: true);
    final restoreFiles = [
      for (final name in [
        'pending.dabackup',
        'rollback/database.sqlite',
        'decoded/database.sqlite',
      ])
        File('${temporaryDirectory.path}/backup_restore/$name'),
    ];
    for (final file in restoreFiles) {
      await file.parent.create(recursive: true);
      await file.writeAsString('preserved');
    }

    await DataBackupService(
      database: appDatabase,
      accountStore: accountStore,
      appUpdateService: _FakeAppUpdateService(),
      supportDirectoryProvider: () async => temporaryDirectory,
    ).exportBackup('${temporaryDirectory.path}/backup.dabackup');

    expect(abandoned.existsSync(), isFalse);
    for (final file in restoreFiles) {
      expect(await file.readAsString(), 'preserved');
    }
  });

  test('instances preserve concurrent export and validation work', () async {
    final source = await DataBackupService(
      database: appDatabase,
      accountStore: accountStore,
      appUpdateService: _FakeAppUpdateService(),
      supportDirectoryProvider: () async =>
          Directory('${temporaryDirectory.path}/source_support'),
      platformName: 'test-platform',
    ).exportBackup('${temporaryDirectory.path}/source.dabackup');
    final exportStarted = Completer<void>();
    final validationStarted = Completer<void>();
    final resumeExport = Completer<void>();
    final resumeValidation = Completer<void>();
    DataBackupService service() => DataBackupService(
      database: appDatabase,
      accountStore: accountStore,
      appUpdateService: _FakeAppUpdateService(),
      supportDirectoryProvider: () async => temporaryDirectory,
      platformName: 'test-platform',
      clock: () => DateTime.utc(2026, 8, 8),
    );
    final exporting = DataBackupService(
      database: appDatabase,
      accountStore: accountStore,
      appUpdateService: _FakeAppUpdateService(
        beforeRead: () async {
          exportStarted.complete();
          await resumeExport.future;
        },
      ),
      supportDirectoryProvider: () async => temporaryDirectory,
    ).exportBackup('${temporaryDirectory.path}/concurrent.dabackup');
    await exportStarted.future;
    var supportReads = 0;
    final validating = DataBackupService(
      database: appDatabase,
      accountStore: accountStore,
      supportDirectoryProvider: () async {
        if (++supportReads == 2) {
          validationStarted.complete();
          await resumeValidation.future;
        }
        return temporaryDirectory;
      },
      platformName: 'test-platform',
    ).inspectAndStageRestore(source.path);
    try {
      await validationStarted.future;
      final active = Directory(
        '${temporaryDirectory.path}/backup_work',
      ).listSync();
      expect(active, hasLength(2));
      expect(await service().applyAtStartup(), isNull);
      for (final directory in active) {
        expect(directory.existsSync(), isTrue);
      }
    } finally {
      resumeExport.complete();
      resumeValidation.complete();
      await Future.wait<Object>([exporting, validating]);
    }
    expect(
      Directory('${temporaryDirectory.path}/backup_work').listSync(),
      isEmpty,
    );
    expect(
      File(
        '${temporaryDirectory.path}/backup_restore/pending.dabackup',
      ).existsSync(),
      isTrue,
    );
  });

  test('work cleanup does not follow directory links', () async {
    final outside = Directory('${temporaryDirectory.path}/outside');
    await outside.create();
    final kept = File('${outside.path}/keep.txt');
    await kept.writeAsString('keep');
    final work = Directory('${temporaryDirectory.path}/backup_work');
    await work.create();
    final link = Link('${work.path}/export_link');
    try {
      await link.create(outside.path);
    } on FileSystemException catch (error) {
      markTestSkipped('Directory links are unavailable: $error');
      return;
    }
    try {
      final abandoned = Directory('${work.path}/validation_interrupted');
      await abandoned.create();
      await Link('${abandoned.path}/nested').create(outside.path);
      await DataBackupService(
        supportDirectoryProvider: () async => temporaryDirectory,
      ).applyAtStartup();
      expect(await kept.readAsString(), 'keep');
      expect(await FileSystemEntity.isLink(link.path), isTrue);
      expect(abandoned.existsSync(), isFalse);
    } finally {
      await link.delete();
    }
  });

  test('a linked work root cannot redirect backup writes', () async {
    final outside = Directory('${temporaryDirectory.path}/outside');
    await outside.create();
    final kept = File('${outside.path}/keep.txt');
    await kept.writeAsString('keep');
    final link = Link('${temporaryDirectory.path}/backup_work');
    try {
      await link.create(outside.path);
    } on FileSystemException catch (error) {
      markTestSkipped('Directory links are unavailable: $error');
      return;
    }
    try {
      final service = DataBackupService(
        supportDirectoryProvider: () async => temporaryDirectory,
      );
      expect(await service.applyAtStartup(), isNull);
      await expectLater(
        service.exportBackup('${temporaryDirectory.path}/backup.dabackup'),
        throwsA(isA<FileSystemException>()),
      );
      expect(await kept.readAsString(), 'keep');
      expect(outside.listSync(), hasLength(1));
    } finally {
      await link.delete();
    }
  });

  test(
    'export contains consistent database, preferences, and account',
    () async {
      await sourceDatabase.insert('tracks', <String, Object?>{
        'path': '/audio/test.mp3',
        'display_name': 'Test',
        'group_key': '/audio',
        'group_title': 'Audio',
        'group_subtitle': '',
        'is_single': 0,
        'is_video': 0,
        'duration_ms': 1000,
      });
      await sourceDatabase.insert('track_assets', <String, Object?>{
        'path': '/audio/test.mp3',
        'cover_cache_path': '/stale/cache.jpg',
      });
      final service = DataBackupService(
        database: appDatabase,
        accountStore: accountStore,
        appUpdateService: _FakeAppUpdateService(),
        supportDirectoryProvider: () async => temporaryDirectory,
        platformName: 'test-platform',
        clock: () => DateTime.utc(2026, 8, 8),
      );
      final output = await service.exportBackup(
        '${temporaryDirectory.path}/backup.dabackup',
      );

      final archive = ZipDecoder().decodeBytes(await output.readAsBytes());
      final files = <String, ArchiveFile>{
        for (final file in archive.files) file.name: file,
      };
      expect(files.keys, <String>{
        'manifest.json',
        'database.sqlite',
        'preferences.json',
        'asmr-account.json',
      });
      final manifest = BackupManifest.fromJson(
        Map<String, Object?>.from(
          jsonDecode(utf8.decode(files['manifest.json']!.content as List<int>))
              as Map,
        ),
      );
      expect(manifest.platform, 'test-platform');
      expect(manifest.containsSensitiveAccountData, isTrue);
      expect(files['database.sqlite']!.compression, CompressionType.none);
      final databaseBytes = files['database.sqlite']!.content as List<int>;
      expect(manifest.files['database.sqlite']?.length, databaseBytes.length);
      expect(
        manifest.files['database.sqlite']?.sha256,
        sha256.convert(databaseBytes).toString(),
      );

      final preferences = Map<String, Object?>.from(
        jsonDecode(utf8.decode(files['preferences.json']!.content as List<int>))
            as Map,
      );
      expect(preferences['themeMode'], 'dark');
      expect(preferences, isNot(contains('timer_runtime_v1')));

      final account = Map<String, Object?>.from(
        jsonDecode(
              utf8.decode(files['asmr-account.json']!.content as List<int>),
            )
            as Map,
      );
      expect(account['name'], 'account-name');
      expect(account['password'], 'account-password');
      expect(account['token'], 'account-token');

      final snapshotPath = '${temporaryDirectory.path}/snapshot.db';
      await File(
        snapshotPath,
      ).writeAsBytes(files['database.sqlite']!.content as List<int>);
      final snapshot = await databaseFactoryFfi.openDatabase(snapshotPath);
      addTearDown(snapshot.close);
      expect(
        await snapshot.query(
          'tracks',
          where: 'path = ?',
          whereArgs: <Object?>['/audio/test.mp3'],
        ),
        hasLength(1),
      );
      expect(
        (await snapshot.query('track_assets')).single['cover_cache_path'],
        isNull,
      );

      final rejectedPath = '${temporaryDirectory.path}/rejected.dabackup';
      await expectLater(
        DataBackupService(
          database: appDatabase,
          accountStore: accountStore,
          appUpdateService: _FakeAppUpdateService(),
          supportDirectoryProvider: () async => temporaryDirectory,
          platformName: 'test-platform',
          maximumArchiveBytes: 1,
        ).exportBackup(rejectedPath),
        throwsA(isA<FormatException>()),
      );
      expect(File(rejectedPath).existsSync(), isFalse);
      expect(File('$rejectedPath.part').existsSync(), isFalse);
    },
  );

  test(
    'paged backup restores sparse rowids and text and composite primary keys',
    () async {
      final rowIds = [
        -9223372036854775808,
        for (var index = 0; index < 1001; index++) (index - 500) * 7,
        9223372036854775807,
      ];
      await sourceDatabase.transaction((txn) async {
        final batch = txn.batch();
        for (var index = 0; index < rowIds.length; index++) {
          // Text and composite primary keys retain their independent sparse rowids.
          batch.insert('asmr_works', {
            'rowid': rowIds[index],
            'work_key': 'source:asmrOne:${rowIds[index]}',
            'id': rowIds[index],
            'title': 'Work $index',
          });
          batch.insert('track_tags', {
            'rowid': rowIds[index],
            'path': '/audio/$index.mp3',
            'tag': 'Tag $index',
            'sort_order': index,
          });
          if (index < 500) {
            batch.insert('app_kv_settings', {
              'rowid': rowIds[index],
              'key': 'setting_$index',
              'value': 'Value $index',
            });
          }
        }
        await batch.commit(noResult: true);
      });
      await sourceDatabase.insert('track_assets', {
        'path': '/audio/0.mp3',
        'cover_cache_path': '/automatic/cover.jpg',
        'manual_cover_path': '/user/cover.jpg',
      });
      final expected = <String, List<Map<String, Object?>>>{
        for (final entry in {
          'asmr_works': 'id',
          'track_tags': 'path, tag',
          'app_kv_settings': 'key',
        }.entries)
          entry.key: await sourceDatabase.query(
            entry.key,
            orderBy: entry.value,
          ),
      };
      final service = DataBackupService(
        database: appDatabase,
        accountStore: accountStore,
        appUpdateService: _FakeAppUpdateService(),
        supportDirectoryProvider: () async => temporaryDirectory,
        databasesPathProvider: () async => databaseDirectory.path,
        platformName: 'test-platform',
      );

      final backup = await service.exportBackup(
        '${temporaryDirectory.path}/paged.dabackup',
      );
      await service.inspectAndStageRestore(backup.path);
      // Staging cannot rewrite live rows; applying at startup closes this DB.
      for (final entry in {
        'asmr_works': 'id',
        'track_tags': 'path, tag',
        'app_kv_settings': 'key',
      }.entries) {
        expect(
          await sourceDatabase.query(entry.key, orderBy: entry.value),
          expected[entry.key],
          reason: entry.key,
        );
      }
      final outcome = await service.applyAtStartup();

      expect(outcome?.succeeded, isTrue);
      final restored = await databaseFactoryFfi.openDatabase(
        '${databaseDirectory.path}/${AppDatabase.fileName}',
      );
      addTearDown(restored.close);
      for (final entry in {
        'asmr_works': 'id',
        'track_tags': 'path, tag',
      }.entries) {
        expect(
          await restored.query(entry.key, orderBy: entry.value),
          expected[entry.key],
          reason: entry.key,
        );
      }
      expect(
        await restored.query(
          'app_kv_settings',
          where: 'key LIKE ?',
          whereArgs: ['setting_%'],
          orderBy: 'key',
        ),
        expected['app_kv_settings'],
      );
      final assets = (await restored.query('track_assets')).single;
      expect(assets['cover_cache_path'], isNull);
      expect(assets['manual_cover_path'], '/user/cover.jpg');
      final restoredSettings = {
        for (final row in await restored.query('app_kv_settings'))
          row['key']: row['value'],
      };
      expect(restoredSettings['backup_restore_authoritative_v1'], '1');
      expect(
        restoredSettings['audio_detail_document_read_only_import_v3'],
        '1',
      );
      expect(await restored.rawQuery('PRAGMA integrity_check'), [
        {'integrity_check': 'ok'},
      ]);
    },
  );

  for (final (keepLocalActivity, resumeCommit) in [
    (true, false),
    (false, false),
    (true, true),
  ]) {
    test(
      'restore selects newer My data (local activity: $keepLocalActivity, retry: $resumeCommit)',
      () async {
        final backupTime = DateTime.utc(2026, 11, 16).millisecondsSinceEpoch;
        final localTime = DateTime.utc(
          2026,
          11,
          keepLocalActivity ? 17 : 15,
        ).millisecondsSinceEpoch;
        Future<void> seedListening(Database db, String name, int time) async {
          final totalMs = name == 'local' ? 120000 : 60000;
          final work = ListeningWorkRecord(
            workKey: name,
            track: MusicTrack(
              path: '/$name.mp3',
              displayName: name,
              groupKey: name,
              groupTitle: name,
              groupSubtitle: '',
              isSingle: true,
            ),
            milliseconds: totalMs,
            lastPlayedAtMs: time,
          );
          await AppDatabase.test(db).importListeningBatch('$name:1', [
            ListeningDayRecord(
              date: '2026-11-16',
              totalMs: totalMs,
              works: [work],
            ),
          ]);
        }

        Future<void> seedInterest(
          Database db,
          String kind,
          Map<String, Object> data,
        ) => AppDatabase.test(
          db,
        ).saveAppSetting('asmr_${kind}_preferences_v1', jsonEncode(data));

        await seedListening(sourceDatabase, 'backup', backupTime);
        await seedInterest(sourceDatabase, 'tag', {
          'manualInterests': ['backup'],
          'updatedAtMs': backupTime,
        });
        await seedInterest(sourceDatabase, 'voice_actor', {
          'excluded': ['backup'],
          'updatedAtMs': backupTime,
        });
        await seedInterest(sourceDatabase, 'circle', {
          'learned': {'backup': 1},
        });
        await appDatabase.saveAppSetting('ordinary_setting', 'backup');

        final exporter = DataBackupService(
          database: appDatabase,
          accountStore: accountStore,
          appUpdateService: _FakeAppUpdateService(),
          supportDirectoryProvider: () async => temporaryDirectory,
          clock: () => DateTime.utc(2026, 11, 18),
          platformName: 'test-platform',
        );
        final backup = await exporter.exportBackup(
          '${temporaryDirectory.path}/my-data.dabackup',
        );

        await databaseDirectory.create();
        final localPath = '${databaseDirectory.path}/${AppDatabase.fileName}';
        final local = await databaseFactoryFfi.openDatabase(localPath);
        addTearDown(() async {
          if (local.isOpen) await local.close();
        });
        await local.rawQuery('PRAGMA journal_mode = WAL');
        await AppDatabase.createSchemaForTest(local);
        await seedListening(local, 'local', localTime);
        final localAppDatabase = AppDatabase.test(local);
        await seedInterest(local, 'tag', {
          'manualInterests': <String>[],
          'updatedAtMs': backupTime + 1,
        });
        await seedInterest(local, 'voice_actor', {
          'excluded': ['local'],
          'updatedAtMs': backupTime - 1,
        });
        await seedInterest(local, 'circle', {
          'learned': {'local': 2},
        });
        await localAppDatabase.saveAppSetting('ordinary_setting', 'local');

        final restorer = DataBackupService(
          database: localAppDatabase,
          accountStore: accountStore,
          supportDirectoryProvider: () async => temporaryDirectory,
          databasesPathProvider: () async => databaseDirectory.path,
          platformName: 'test-platform',
        );
        await restorer.inspectAndStageRestore(backup.path);
        if (resumeCommit) {
          final pending = Directory(
            '${temporaryDirectory.path}/backup_restore',
          );
          final rollback = await Directory('${pending.path}/rollback').create();
          await local.close();
          await File(
            localPath,
          ).rename('${rollback.path}/${AppDatabase.fileName}');
          for (final name in ['preferences.json', 'asmr-account.json']) {
            await File('${rollback.path}/$name').writeAsString('{}');
          }
          await File('${pending.path}/journal.json').writeAsString(
            jsonEncode({
              'phase': 'committing',
              'createdAt': DateTime.utc(2026, 11, 18).toIso8601String(),
            }),
          );
          await appDatabase.createPortableSnapshot(localPath);
        }
        expect((await restorer.applyAtStartup())?.succeeded, isTrue);

        final restored = await databaseFactoryFfi.openDatabase(localPath);
        addTearDown(restored.close);
        final restoredAppDatabase = AppDatabase.test(restored);
        final expectedWork = keepLocalActivity ? 'local' : 'backup';
        final history = await restoredAppDatabase.loadListeningHistory();
        expect(history.single['work_key'], expectedWork);
        expect((await restoredAppDatabase.loadListeningDays()).single, {
          'date': '2026-11-16',
          'milliseconds': keepLocalActivity ? 120000 : 60000,
        });
        expect(
          (await restored.query('listening_work_days')).single['work_key'],
          expectedWork,
        );
        expect(
          (await restored.query('listening_imports')).single['batch_id'],
          '$expectedWork:1',
        );

        Future<Map<String, dynamic>> restoredInterest(String kind) async =>
            jsonDecode(
                  (await restoredAppDatabase.loadAppSetting(
                    'asmr_${kind}_preferences_v1',
                  ))!,
                )
                as Map<String, dynamic>;
        expect((await restoredInterest('tag'))['manualInterests'], isEmpty);
        expect((await restoredInterest('voice_actor'))['excluded'], ['backup']);
        expect((await restoredInterest('circle'))['learned'], {'local': 2});
        expect(
          await restoredAppDatabase.loadAppSetting('ordinary_setting'),
          'backup',
        );
      },
    );
  }

  for (final schemaVersion in [8, 12, AppDatabase.schemaVersion]) {
    test(
      'staged schema $schemaVersion backup restores database, preferences, and account',
      () async {
        await sourceDatabase.insert('tracks', <String, Object?>{
          'path': '/audio/restored.mp3',
          'display_name': 'Restored',
          'group_key': '/audio',
          'group_title': 'Audio',
          'group_subtitle': '',
          'is_single': 0,
          'is_video': 0,
          'duration_ms': 2000,
        });
        final service = DataBackupService(
          database: appDatabase,
          accountStore: accountStore,
          appUpdateService: _FakeAppUpdateService(),
          supportDirectoryProvider: () async => temporaryDirectory,
          databasesPathProvider: () async => databaseDirectory.path,
          platformName: 'test-platform',
          clock: () => DateTime.utc(2026, 8, 8),
        );
        final backup = await service.exportBackup(
          '${temporaryDirectory.path}/restore-source.dabackup',
        );
        final exported = ZipDecoder().decodeBytes(await backup.readAsBytes());
        if (schemaVersion < AppDatabase.schemaVersion) {
          final legacyDatabaseFile = File(
            '${temporaryDirectory.path}/v$schemaVersion.db',
          );
          await legacyDatabaseFile.writeAsBytes(
            exported.find('database.sqlite')!.content as List<int>,
          );
          final legacyDatabase = await databaseFactoryFfi.openDatabase(
            legacyDatabaseFile.path,
          );
          for (final table in ['asmr_works', 'asmr_work_lists', 'asmr_work_tags', 'asmr_work_voice_actors']) {
            var sql = (await legacyDatabase.rawQuery("SELECT sql FROM sqlite_master WHERE name = ?", [table])).single['sql']! as String;
            if (table == 'asmr_works') {
              sql = sql.replaceFirst('work_key TEXT PRIMARY KEY,', '').replaceFirst('resources_json TEXT,', '').replaceFirst('id INTEGER NOT NULL,', 'id INTEGER PRIMARY KEY,');
            } else {
              sql = sql.replaceFirst('work_id TEXT NOT NULL', 'work_id INTEGER NOT NULL');
            }
            await legacyDatabase.execute('DROP TABLE $table');
            await legacyDatabase.execute(sql);
          }
          await legacyDatabase.setVersion(schemaVersion);
          final legacyIndexes = schemaVersion == 8
              ? {
                  'idx_track_scan_generation':
                      'track_scan_info(scan_generation)',
                  'idx_track_playback_last_played':
                      'track_playback_state(last_played_at_ms)',
                  'idx_track_playback_favorite':
                      'track_playback_state(is_favorite)',
                }
              : {
                  'idx_session_playback_session':
                      'session_playback_state(session_id)',
                  'idx_playback_queue_tracks_entry':
                      'playback_queue_entry_tracks(session_id, entry_id, sort_order)',
                  'idx_audio_details_target':
                      'audio_details(target_type, target_path)',
                };
          for (final entry in legacyIndexes.entries) {
            await legacyDatabase.execute(
              'CREATE INDEX ${entry.key} ON ${entry.value}',
            );
          }
          await legacyDatabase.close();
          final bytes = await legacyDatabaseFile.readAsBytes();
          final manifest =
              jsonDecode(
                    utf8.decode(
                      exported.find('manifest.json')!.content as List<int>,
                    ),
                  )
                  as Map<String, dynamic>;
          manifest['databaseSchemaVersion'] = schemaVersion;
          (manifest['files'] as Map<String, dynamic>)['database.sqlite'] = {
            'length': bytes.length,
            'sha256': sha256.convert(bytes).toString(),
          };
          exported.addFile(ArchiveFile('database.sqlite', bytes.length, bytes));
          exported.addFile(
            ArchiveFile.string('manifest.json', jsonEncode(manifest)),
          );
        }
        final legacyArchive = Archive();
        for (final entry in exported.files) {
          legacyArchive.addFile(
            ArchiveFile(entry.name, entry.size, entry.content as List<int>),
          );
        }
        final legacyBackup = File('${temporaryDirectory.path}/legacy.dabackup');
        await legacyBackup.writeAsBytes(ZipEncoder().encode(legacyArchive));
        final legacyDecoded = ZipDecoder().decodeBytes(
          await legacyBackup.readAsBytes(),
        );
        expect(
          legacyDecoded.find('database.sqlite')?.compression,
          CompressionType.deflate,
        );

        await AppPreferences.replaceSnapshot(<String, Object?>{
          'themeMode': 'light',
          'timer_runtime_v1': 'current-runtime',
        });
        await accountStore.replaceFromBackup(
          AsmrAccountBackupSnapshot(
            token: 'current-token',
            name: 'current-name',
            password: 'current-password',
            createdAt: DateTime.utc(2026, 8, 9),
          ),
        );

        final expandedSize = legacyDecoded.files.fold<int>(
          0,
          (total, entry) => total + entry.size,
        );
        final restoreService = DataBackupService(
          database: appDatabase,
          accountStore: accountStore,
          supportDirectoryProvider: () async => temporaryDirectory,
          databasesPathProvider: () async => databaseDirectory.path,
          platformName: 'test-platform',
          maximumExpandedBytes: expandedSize,
        );
        final staged = await restoreService.inspectAndStageRestore(
          legacyBackup.path,
        );
        final outcome = await restoreService.applyAtStartup();

        expect(staged.manifest.platform, 'test-platform');
        expect(staged.manifest.databaseSchemaVersion, schemaVersion);
        expect(outcome?.succeeded, isTrue);
        expect(outcome?.errorCode, isNull);
        expect(
          Directory('${temporaryDirectory.path}/backup_restore').existsSync(),
          isFalse,
        );

        final restoredDatabase = await databaseFactoryFfi.openDatabase(
          '${databaseDirectory.path}/${AppDatabase.fileName}',
        );
        addTearDown(restoredDatabase.close);
        expect(await restoredDatabase.getVersion(), AppDatabase.schemaVersion);
        final indexes = (await restoredDatabase.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'index'",
        )).map((row) => row['name']).toSet();
        expect(
          indexes,
          containsAll([
            'idx_tracks_scan_generation',
            'idx_tracks_last_played_at',
            'idx_tracks_favorite',
          ]),
        );
        expect(
          indexes.intersection({
            'idx_track_scan_generation',
            'idx_track_playback_last_played',
            'idx_track_playback_favorite',
            'idx_session_playback_session',
            'idx_playback_queue_tracks_entry',
            'idx_audio_details_target',
          }),
          isEmpty,
        );
        expect(
          await restoredDatabase.query(
            'tracks',
            where: 'path = ?',
            whereArgs: <Object?>['/audio/restored.mp3'],
          ),
          hasLength(1),
        );
        expect(await AppPreferences.getString('themeMode'), 'dark');
        expect(await AppPreferences.getString('timer_runtime_v1'), isNull);
        expect(await accountStore.readToken(), 'account-token');
        expect(await accountStore.readCredentials(), <String, String>{
          'name': 'account-name',
          'password': 'account-password',
        });
      },
    );
  }

  for (final defect in ['table', 'column', 'unique constraint']) {
    test('invalid restore $defect leaves all current data intact', () async {
      await appDatabase.saveAppSetting('existing_setting', 'keep');
      final service = DataBackupService(
        database: appDatabase,
        accountStore: accountStore,
        appUpdateService: _FakeAppUpdateService(),
        supportDirectoryProvider: () async => temporaryDirectory,
        databasesPathProvider: () async => databaseDirectory.path,
        platformName: 'test-platform',
      );
      final backup = await service.exportBackup(
        '${temporaryDirectory.path}/backup.dabackup',
      );
      final archive = ZipDecoder().decodeBytes(await backup.readAsBytes());
      final damagedFile = File('${temporaryDirectory.path}/damaged.db');
      await damagedFile.writeAsBytes(
        archive.find('database.sqlite')!.content as List<int>,
      );
      final damaged = await databaseFactoryFfi.openDatabase(damagedFile.path);
      switch (defect) {
        case 'table':
          await damaged.execute('DROP TABLE session_eq_bands');
        case 'column':
          await damaged.execute('ALTER TABLE tracks DROP COLUMN duration_ms');
        case 'unique constraint':
          final schema =
              (await damaged.rawQuery(
                    "SELECT sql FROM sqlite_master WHERE name = 'audio_details'",
                  )).single['sql']!
                  as String;
          await damaged.execute('DROP TABLE audio_details');
          await damaged.execute(
            schema.replaceFirst('UNIQUE(target_type, target_path)', 'CHECK(1)'),
          );
      }
      await damaged.setVersion(12);
      await damaged.close();
      final damagedBytes = await damagedFile.readAsBytes();
      final manifest =
          jsonDecode(
                utf8.decode(
                  archive.find('manifest.json')!.content as List<int>,
                ),
              )
              as Map<String, dynamic>;
      manifest['databaseSchemaVersion'] = 12;
      (manifest['files'] as Map<String, dynamic>)['database.sqlite'] = {
        'length': damagedBytes.length,
        'sha256': sha256.convert(damagedBytes).toString(),
      };
      final malformed = Archive();
      for (final entry in archive.files) {
        final bytes = switch (entry.name) {
          'manifest.json' => utf8.encode(jsonEncode(manifest)),
          'database.sqlite' => damagedBytes,
          _ => entry.content as List<int>,
        };
        malformed.addFile(ArchiveFile(entry.name, bytes.length, bytes));
      }
      await backup.writeAsBytes(ZipEncoder().encode(malformed));
      await databaseDirectory.create();
      final current = await appDatabase.createPortableSnapshot(
        '${databaseDirectory.path}/${AppDatabase.fileName}',
      );
      final currentBefore = await current.readAsBytes();

      await expectLater(
        service.inspectAndStageRestore(backup.path),
        throwsFormatException,
      );
      final restoreDirectory = Directory(
        '${temporaryDirectory.path}/backup_restore',
      );
      expect(restoreDirectory.existsSync(), isFalse);

      // A pending archive can also become damaged between staging and restart.
      await restoreDirectory.create();
      await backup.copy('${restoreDirectory.path}/pending.dabackup');
      final outcome = await service.applyAtStartup();

      expect(outcome?.errorCode, 'restore_validation_failed');
      expect(await current.readAsBytes(), currentBefore);
      expect(await appDatabase.loadAppSetting('existing_setting'), 'keep');
      expect(await AppPreferences.getString('themeMode'), 'dark');
      expect(await accountStore.readToken(), 'account-token');
      expect(await accountStore.readCredentials(), {
        'name': 'account-name',
        'password': 'account-password',
      });
    });
  }

  test(
    'startup restore replaces a corrupted local database without deleting staged restore',
    () async {
      await sourceDatabase.insert('tracks', <String, Object?>{
        'path': '/audio/recovered.mp3',
        'display_name': 'Recovered',
        'group_key': '/audio',
        'group_title': 'Audio',
        'group_subtitle': '',
        'is_single': 0,
        'is_video': 0,
        'duration_ms': 3000,
      });
      final exporter = DataBackupService(
        database: appDatabase,
        accountStore: accountStore,
        appUpdateService: _FakeAppUpdateService(),
        supportDirectoryProvider: () async => temporaryDirectory,
        databasesPathProvider: () async => databaseDirectory.path,
        platformName: 'test-platform',
      );
      final backup = await exporter.exportBackup(
        '${temporaryDirectory.path}/valid.dabackup',
      );

      await databaseDirectory.create(recursive: true);
      final localPath = '${databaseDirectory.path}/${AppDatabase.fileName}';
      await File(localPath).writeAsString('not-a-sqlite-database');
      await File('$localPath-wal').writeAsString('corrupted-wal');

      final damagedAppDatabase = AppDatabase.forTest(
        opener: () => databaseFactoryFfi.openDatabase(localPath),
      );
      addTearDown(damagedAppDatabase.close);
      final restorer = DataBackupService(
        database: damagedAppDatabase,
        accountStore: accountStore,
        supportDirectoryProvider: () async => temporaryDirectory,
        databasesPathProvider: () async => databaseDirectory.path,
        platformName: 'test-platform',
      );
      await restorer.inspectAndStageRestore(backup.path);

      final outcome = await restorer.applyAtStartup();

      expect(outcome?.succeeded, isTrue);
      expect(
        Directory('${temporaryDirectory.path}/backup_restore').existsSync(),
        isFalse,
      );
      expect(File('$localPath-wal').existsSync(), isFalse);
      final restored = await databaseFactoryFfi.openDatabase(localPath);
      addTearDown(restored.close);
      expect(
        await restored.query(
          'tracks',
          where: 'path = ?',
          whereArgs: ['/audio/recovered.mp3'],
        ),
        hasLength(1),
      );
    },
  );
}

class _FakeAppUpdateService extends AppUpdateService {
  _FakeAppUpdateService({this.beforeRead});

  final Future<void> Function()? beforeRead;

  @override
  Future<AppVersionInfo> currentAppVersion() async {
    await beforeRead?.call();
    return const AppVersionInfo(versionName: '0.17.0', buildNumber: 1700);
  }
}
