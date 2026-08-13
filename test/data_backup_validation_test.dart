import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/persistence/app_database.dart';
import 'package:doujin_audio/features/data_support/application/data_backup_service.dart';

void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'doujin_backup_validation_test_',
    );
  });

  tearDown(() async {
    await temporaryDirectory.delete(recursive: true);
  });

  test('restore rejects duplicate archive entries before staging', () async {
    final archive = Archive()
      ..addFile(ArchiveFile.string('manifest.json', '{}'))
      ..addFile(ArchiveFile.string('manifest.json', '{}'));

    await expectLater(
      _inspect(archive, temporaryDirectory),
      throwsA(isA<FormatException>()),
    );
    expect(
      File(
        '${temporaryDirectory.path}/backup_restore/pending.dabackup',
      ).existsSync(),
      isFalse,
    );
  });

  test('restore rejects path traversal entries before staging', () async {
    final archive = Archive()
      ..addFile(ArchiveFile.string('../manifest.json', '{}'));

    await expectLater(
      _inspect(archive, temporaryDirectory),
      throwsA(isA<FormatException>()),
    );
  });

  test('restore rejects a backup from another platform', () async {
    await expectLater(
      _inspect(
        _backupArchive(platform: 'other-platform'),
        temporaryDirectory,
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('restore preflights cumulative expanded size', () async {
    final archive = _backupArchive(database: List<int>.filled(1024, 0));

    await expectLater(
      _inspect(archive, temporaryDirectory, maximumExpandedBytes: 512),
      throwsA(isA<FormatException>()),
    );
    final workDirectory = Directory('${temporaryDirectory.path}/backup_work');
    expect(
      workDirectory.existsSync()
          ? workDirectory.listSync()
          : const <FileSystemEntity>[],
      isEmpty,
    );
  });

  test('restore enforces the preferences entry limit', () async {
    final archive = _backupArchive(preferences: utf8.encode('{}'));

    await expectLater(
      _inspect(archive, temporaryDirectory, maximumPreferencesBytes: 1),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      _inspect(archive, temporaryDirectory, maximumAccountBytes: 1),
      throwsA(isA<FormatException>()),
    );
  });

  test(
    'restore rejects actual output beyond the declared entry size',
    () async {
      final archive = _backupArchive()
        ..addFile(ArchiveFile('preferences.json', 1, utf8.encode('{}')));

      await expectLater(
        _inspect(archive, temporaryDirectory),
        throwsA(isA<FormatException>()),
      );
      final restoreDirectory = Directory(
        '${temporaryDirectory.path}/backup_restore',
      );
      expect(restoreDirectory.existsSync(), isFalse);
    },
  );
}

Archive _backupArchive({
  List<int> database = const <int>[1],
  List<int>? preferences,
  String platform = 'test-platform',
}) {
  final preferenceBytes = preferences ?? utf8.encode('{}');
  final account = utf8.encode(
    jsonEncode(<String, Object?>{
      'name': null,
      'password': null,
      'token': null,
      'createdAt': DateTime.utc(2026, 8, 8).toIso8601String(),
    }),
  );
  final manifest = BackupManifest(
    formatVersion: 1,
    appVersion: '0.17.0+1700',
    databaseSchemaVersion: AppDatabase.schemaVersion,
    platform: platform,
    createdAt: DateTime.utc(2026, 8, 8),
    containsSensitiveAccountData: true,
    files: <String, BackupFileRecord>{
      'database.sqlite': _record(database),
      'preferences.json': _record(preferenceBytes),
      'asmr-account.json': _record(account),
    },
  );
  return Archive()
    ..addFile(ArchiveFile.string('manifest.json', jsonEncode(manifest)))
    ..addFile(ArchiveFile('database.sqlite', database.length, database))
    ..addFile(
      ArchiveFile('preferences.json', preferenceBytes.length, preferenceBytes),
    )
    ..addFile(ArchiveFile('asmr-account.json', account.length, account));
}

BackupFileRecord _record(List<int> bytes) => BackupFileRecord(
  length: bytes.length,
  sha256: sha256.convert(bytes).toString(),
);

Future<BackupValidationResult> _inspect(
  Archive archive,
  Directory directory, {
  int? maximumExpandedBytes,
  int? maximumPreferencesBytes,
  int? maximumAccountBytes,
}) async {
  final file = File('${directory.path}/candidate.dabackup');
  await file.writeAsBytes(ZipEncoder().encode(archive));
  return DataBackupService(
    supportDirectoryProvider: () async => directory,
    platformName: 'test-platform',
    maximumExpandedBytes: maximumExpandedBytes ?? 512 * 1024 * 1024,
    maximumPreferencesBytes: maximumPreferencesBytes ?? 16 * 1024 * 1024,
    maximumAccountBytes: maximumAccountBytes ?? 1024 * 1024,
  ).inspectAndStageRestore(file.path);
}
