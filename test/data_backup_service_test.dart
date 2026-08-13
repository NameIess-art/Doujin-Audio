import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/persistence/app_database.dart';
import 'package:doujin_audio/features/asmr/application/asmr_auth_service.dart';
import 'package:doujin_audio/features/data_support/application/data_backup_service.dart';
import 'package:doujin_audio/features/settings/application/app_preferences.dart';
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

  test('staged backup restores database, preferences, and account', () async {
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
  });
}

class _FakeAppUpdateService extends AppUpdateService {
  @override
  Future<AppVersionInfo> currentAppVersion() async {
    return const AppVersionInfo(versionName: '0.17.0', buildNumber: 1700);
  }
}
