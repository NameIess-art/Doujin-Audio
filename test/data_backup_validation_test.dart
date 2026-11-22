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
      _inspect(_backupArchive(platform: 'other-platform'), temporaryDirectory),
      throwsA(isA<FormatException>()),
    );
  });

  test('restore rejects a newer manifest schema before staging', () async {
    await expectLater(
      _inspect(
        _backupArchive(schemaVersion: AppDatabase.schemaVersion + 1),
        temporaryDirectory,
      ),
      throwsFormatException,
    );
    expect(
      Directory('${temporaryDirectory.path}/backup_restore').existsSync(),
      isFalse,
    );
  });

  test(
    'Windows rejects Android backup before creating a pending restore',
    () async {
      await expectLater(
        _inspect(
          _backupArchive(platform: 'android'),
          temporaryDirectory,
          platform: 'windows',
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        Directory('${temporaryDirectory.path}/backup_restore').existsSync(),
        isFalse,
      );
    },
  );

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

  test(
    'restore rejects Zip-Slip when local header filename differs from central directory',
    () async {
      final bytes = ZipEncoder().encode(_backupArchive()).toList();
      final original = utf8.encode('preferences.json');
      final traversal = utf8.encode('../../pwned.json');
      expect(traversal.length, original.length);
      final localOffset = _indexOfBytes(bytes, original);
      expect(localOffset, greaterThanOrEqualTo(0));
      // Only overwrite the Local File Header filename, leaving the Central
      // Directory entry intact so preflight must check both headers.
      bytes.setRange(localOffset, localOffset + traversal.length, traversal);

      final file = File('${temporaryDirectory.path}/zip_slip.dabackup');
      await file.writeAsBytes(bytes);
      await expectLater(
        DataBackupService(
          supportDirectoryProvider: () async => temporaryDirectory,
          platformName: 'test-platform',
        ).inspectAndStageRestore(file.path),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'invalid_backup_entries',
          ),
        ),
      );
      expect(File('${temporaryDirectory.path}/pwned.json').existsSync(), isFalse);
    },
  );

  test(
    'restore rejects local header encryption flag mismatch',
    () async {
      final bytes = ZipEncoder().encode(_backupArchive()).toList();
      final localHeaderOffset = _indexOfBytes(bytes, const <int>[
        0x50,
        0x4B,
        0x03,
        0x04,
      ]);
      expect(localHeaderOffset, greaterThanOrEqualTo(0));
      // Set bit 0 (encrypted) in the local file header's general purpose flags.
      bytes[localHeaderOffset + 6] |= 1;

      final file = File('${temporaryDirectory.path}/local_encrypted.dabackup');
      await file.writeAsBytes(bytes);
      await expectLater(
        DataBackupService(
          supportDirectoryProvider: () async => temporaryDirectory,
          platformName: 'test-platform',
        ).inspectAndStageRestore(file.path),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'invalid_backup_entries',
          ),
        ),
      );
    },
  );

  test(
    'restore rejects local header compression method mismatch',
    () async {
      final bytes = ZipEncoder().encode(_backupArchive()).toList();
      final localHeaderOffset = _indexOfBytes(bytes, const <int>[
        0x50,
        0x4B,
        0x03,
        0x04,
      ]);
      expect(localHeaderOffset, greaterThanOrEqualTo(0));
      // Flip local compression method between store (0) and deflate (8).
      final current = bytes[localHeaderOffset + 8];
      bytes[localHeaderOffset + 8] = current == 0 ? 8 : 0;

      final file = File('${temporaryDirectory.path}/local_method.dabackup');
      await file.writeAsBytes(bytes);
      await expectLater(
        DataBackupService(
          supportDirectoryProvider: () async => temporaryDirectory,
          platformName: 'test-platform',
        ).inspectAndStageRestore(file.path),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'invalid_backup_entries',
          ),
        ),
      );
    },
  );
}

int _indexOfBytes(List<int> haystack, List<int> needle) {
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    var matched = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        matched = false;
        break;
      }
    }
    if (matched) return i;
  }
  return -1;
}

Archive _backupArchive({
  List<int> database = const <int>[1],
  List<int>? preferences,
  String platform = 'test-platform',
  int schemaVersion = AppDatabase.schemaVersion,
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
    databaseSchemaVersion: schemaVersion,
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
  String platform = 'test-platform',
}) async {
  final file = File('${directory.path}/candidate.dabackup');
  await file.writeAsBytes(ZipEncoder().encode(archive));
  return DataBackupService(
    supportDirectoryProvider: () async => directory,
    platformName: platform,
    maximumExpandedBytes: maximumExpandedBytes ?? 512 * 1024 * 1024,
    maximumPreferencesBytes: maximumPreferencesBytes ?? 16 * 1024 * 1024,
    maximumAccountBytes: maximumAccountBytes ?? 1024 * 1024,
  ).inspectAndStageRestore(file.path);
}
