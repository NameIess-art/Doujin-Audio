import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/services/app_backup_service.dart';
import 'package:nameless_audio/services/app_database.dart';
import 'package:nameless_audio/services/app_update_service.dart';

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
    preferences = <String, Object>{'language': 'zh', 'isDarkMode': true};
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

  test('exports and validates a complete backup', () async {
    final service = createService();
    final outputPath = '${tempDirectory.path}/backup.nalbackup';

    final output = await service.exportBackup(outputPath);
    final validation = await service.validateBackup(output.path);

    expect(validation.isValid, isTrue);
    expect(validation.manifest?.appVersion, '1.2.3+4');
    expect(validation.manifest?.platform, 'test');
    expect(closeCount, 1);
    expect(reopenCount, 1);
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
    expect(preferences, containsPair('isDarkMode', true));
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
