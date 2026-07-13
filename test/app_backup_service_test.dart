import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/features/data_support/application/app_backup_service.dart';
import 'package:nameless_audio/core/persistence/app_database.dart';
import 'package:nameless_audio/features/settings/application/app_update_service.dart';

void main() {
  late Directory tempDirectory;
  late File databaseFile;
  late Map<String, Object> preferences;
  late int closeCount;
  late int reopenCount;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp('app_backup_test_');
    databaseFile = File('${tempDirectory.path}/audio_player.db');
    await databaseFile.writeAsString('original database');
    preferences = <String, Object>{'language': 'zh', 'themeMode': 'dark'};
    closeCount = 0;
    reopenCount = 0;
  });

  tearDown(() => tempDirectory.delete(recursive: true));

  AppBackupService createService({
    Future<void> Function(Map<String, Object?> values)? restorePreferences,
  }) {
    return AppBackupService(
      databasePathProvider: () async => databaseFile.path,
      closeDatabase: () async => closeCount++,
      reopenDatabase: () async => reopenCount++,
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

  Future<void> writePatternFile(File file, int byteCount) async {
    final chunk = List<int>.generate(64 * 1024, (index) => index & 0xff);
    final output = await file.open(mode: FileMode.write);
    try {
      var remaining = byteCount;
      while (remaining > 0) {
        final length = remaining < chunk.length ? remaining : chunk.length;
        await output.writeFrom(chunk, 0, length);
        remaining -= length;
      }
      await output.flush();
    } finally {
      await output.close();
    }
  }

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
      await writePatternFile(databaseFile, fixtureBytes);
      final expectedDigest = await sha256.bind(databaseFile.openRead()).first;
      final service = createService();

      final output = await service.exportBackup(
        '${tempDirectory.path}/large.nalbackup',
      );
      final validation = await service.validateBackup(output.path);
      await databaseFile.writeAsString('changed');
      final restore = await service.restoreBackup(output.path);

      expect(validation.isValid, isTrue);
      expect(
        validation.manifest?.entries[AppBackupService.databaseEntry]?.size,
        fixtureBytes,
      );
      expect(restore.isValid, isTrue);
      expect(await databaseFile.length(), fixtureBytes);
      expect(await sha256.bind(databaseFile.openRead()).first, expectedDigest);
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

  test('restores legacy backups with a deflate-compressed database', () async {
    final databaseBytes = utf8.encode('legacy compressed database');
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
    await databaseFile.writeAsString('current database');

    final result = await createService().restoreBackup(backup.path);

    expect(result.isValid, isTrue);
    expect(await databaseFile.readAsString(), 'legacy compressed database');
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

  test('restores database and preferences after validation', () async {
    final service = createService();
    final output = await service.exportBackup(
      '${tempDirectory.path}/backup.nalbackup',
    );
    await databaseFile.writeAsString('changed database');
    preferences = <String, Object>{'language': 'en'};

    final result = await service.restoreBackup(output.path);

    expect(result.isValid, isTrue);
    expect(await databaseFile.readAsString(), 'original database');
    expect(preferences, containsPair('language', 'zh'));
    expect(preferences, containsPair('themeMode', 'dark'));
  });

  test('rolls database back when restoring preferences fails', () async {
    final exportService = createService();
    final output = await exportService.exportBackup(
      '${tempDirectory.path}/backup.nalbackup',
    );
    await databaseFile.writeAsString('current database');
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
    expect(await databaseFile.readAsString(), 'current database');
    expect(preferences, containsPair('language', 'en'));
  });
}
