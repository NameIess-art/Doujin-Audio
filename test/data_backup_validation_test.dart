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
    final database = <int>[1];
    final preferences = utf8.encode('{}');
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
      platform: 'other-platform',
      createdAt: DateTime.utc(2026, 8, 8),
      containsSensitiveAccountData: true,
      files: <String, BackupFileRecord>{
        'database.sqlite': _record(database),
        'preferences.json': _record(preferences),
        'asmr-account.json': _record(account),
      },
    );
    final archive = Archive()
      ..addFile(ArchiveFile.string('manifest.json', jsonEncode(manifest)))
      ..addFile(ArchiveFile('database.sqlite', database.length, database))
      ..addFile(
        ArchiveFile('preferences.json', preferences.length, preferences),
      )
      ..addFile(ArchiveFile('asmr-account.json', account.length, account));

    await expectLater(
      _inspect(archive, temporaryDirectory),
      throwsA(isA<FormatException>()),
    );
  });
}

BackupFileRecord _record(List<int> bytes) => BackupFileRecord(
  length: bytes.length,
  sha256: sha256.convert(bytes).toString(),
);

Future<BackupValidationResult> _inspect(
  Archive archive,
  Directory directory,
) async {
  final file = File('${directory.path}/candidate.dabackup');
  await file.writeAsBytes(ZipEncoder().encode(archive));
  return DataBackupService(
    supportDirectoryProvider: () async => directory,
    platformName: 'test-platform',
  ).inspectAndStageRestore(file.path);
}
