import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../../../core/persistence/app_database.dart';
import '../../asmr/application/asmr_auth_service.dart';
import '../../settings/application/app_preferences.dart';
import '../../settings/application/app_update_service.dart';

const _backupFormatVersion = 1;
const _defaultMaximumBackupArchiveBytes = 512 * 1024 * 1024;
const _defaultMaximumExpandedBackupBytes = 512 * 1024 * 1024;
const _defaultMaximumManifestBytes = 1024 * 1024;
const _defaultMaximumPreferencesBytes = 16 * 1024 * 1024;
const _defaultMaximumAccountBytes = 1024 * 1024;
const _manifestName = 'manifest.json';
const _databaseName = 'database.sqlite';
const _preferencesName = 'preferences.json';
const _accountName = 'asmr-account.json';
const _allowedArchiveEntries = <String>{
  _manifestName,
  _databaseName,
  _preferencesName,
  _accountName,
};

class BackupFileRecord {
  const BackupFileRecord({required this.length, required this.sha256});

  final int length;
  final String sha256;

  Map<String, Object> toJson() => <String, Object>{
    'length': length,
    'sha256': sha256,
  };

  factory BackupFileRecord.fromJson(Map<String, Object?> json) {
    final length = (json['length'] as num?)?.toInt();
    final digest = json['sha256'];
    if (length == null || length < 0 || digest is! String || digest.isEmpty) {
      throw const FormatException('invalid_backup_manifest');
    }
    return BackupFileRecord(length: length, sha256: digest);
  }
}

class BackupManifest {
  const BackupManifest({
    required this.formatVersion,
    required this.appVersion,
    required this.databaseSchemaVersion,
    required this.platform,
    required this.createdAt,
    required this.containsSensitiveAccountData,
    required this.files,
  });

  final int formatVersion;
  final String appVersion;
  final int databaseSchemaVersion;
  final String platform;
  final DateTime createdAt;
  final bool containsSensitiveAccountData;
  final Map<String, BackupFileRecord> files;

  Map<String, Object?> toJson() => <String, Object?>{
    'formatVersion': formatVersion,
    'appVersion': appVersion,
    'databaseSchemaVersion': databaseSchemaVersion,
    'platform': platform,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'containsSensitiveAccountData': containsSensitiveAccountData,
    'files': files.map((key, value) => MapEntry(key, value.toJson())),
  };

  factory BackupManifest.fromJson(Map<String, Object?> json) {
    final rawFiles = json['files'];
    final createdAt = DateTime.tryParse(json['createdAt']?.toString() ?? '');
    if (rawFiles is! Map || createdAt == null) {
      throw const FormatException('invalid_backup_manifest');
    }
    final files = <String, BackupFileRecord>{};
    for (final entry in rawFiles.entries) {
      if (entry.key is! String || entry.value is! Map) {
        throw const FormatException('invalid_backup_manifest');
      }
      files[entry.key as String] = BackupFileRecord.fromJson(
        Map<String, Object?>.from(entry.value as Map),
      );
    }
    return BackupManifest(
      formatVersion: (json['formatVersion'] as num?)?.toInt() ?? -1,
      appVersion: json['appVersion']?.toString() ?? '',
      databaseSchemaVersion:
          (json['databaseSchemaVersion'] as num?)?.toInt() ?? -1,
      platform: json['platform']?.toString() ?? '',
      createdAt: createdAt,
      containsSensitiveAccountData:
          json['containsSensitiveAccountData'] == true,
      files: Map<String, BackupFileRecord>.unmodifiable(files),
    );
  }
}

class BackupValidationResult {
  const BackupValidationResult({required this.manifest});

  final BackupManifest manifest;
}

class PendingRestoreJournal {
  const PendingRestoreJournal({required this.phase, required this.createdAt});

  final String phase;
  final DateTime createdAt;

  Map<String, Object> toJson() => <String, Object>{
    'phase': phase,
    'createdAt': createdAt.toUtc().toIso8601String(),
  };
}

class StartupRestoreOutcome {
  const StartupRestoreOutcome._({required this.succeeded, this.errorCode});

  const StartupRestoreOutcome.succeeded() : this._(succeeded: true);
  const StartupRestoreOutcome.failed(String errorCode)
    : this._(succeeded: false, errorCode: errorCode);

  final bool succeeded;
  final String? errorCode;
}

class DataBackupService {
  DataBackupService({
    AppDatabase? database,
    SecureAsmrTokenStore? accountStore,
    AppUpdateService? appUpdateService,
    Future<Directory> Function()? supportDirectoryProvider,
    Future<String> Function()? databasesPathProvider,
    Future<void> Function()? beforeExport,
    DateTime Function()? clock,
    String? platformName,
    int maximumArchiveBytes = _defaultMaximumBackupArchiveBytes,
    int maximumExpandedBytes = _defaultMaximumExpandedBackupBytes,
    int maximumManifestBytes = _defaultMaximumManifestBytes,
    int maximumPreferencesBytes = _defaultMaximumPreferencesBytes,
    int maximumAccountBytes = _defaultMaximumAccountBytes,
  }) : _database = database ?? AppDatabase.instance,
       _accountStore = accountStore ?? SecureAsmrTokenStore(),
       _appVersionProvider =
           (appUpdateService ?? AppUpdateService()).currentAppVersion,
       _supportDirectoryProvider =
           supportDirectoryProvider ?? getApplicationSupportDirectory,
       _databasesPathProvider = databasesPathProvider ?? getDatabasesPath,
       _beforeExport = beforeExport,
       _clock = clock ?? DateTime.now,
       _platformName = platformName ?? Platform.operatingSystem,
       _maximumArchiveBytes = maximumArchiveBytes,
       _maximumExpandedBytes = maximumExpandedBytes,
       _maximumManifestBytes = maximumManifestBytes,
       _maximumPreferencesBytes = maximumPreferencesBytes,
       _maximumAccountBytes = maximumAccountBytes;

  final AppDatabase _database;
  final SecureAsmrTokenStore _accountStore;
  final Future<AppVersionInfo> Function() _appVersionProvider;
  final Future<Directory> Function() _supportDirectoryProvider;
  final Future<String> Function() _databasesPathProvider;
  final Future<void> Function()? _beforeExport;
  final DateTime Function() _clock;
  final String _platformName;
  final int _maximumArchiveBytes;
  final int _maximumExpandedBytes;
  final int _maximumManifestBytes;
  final int _maximumPreferencesBytes;
  final int _maximumAccountBytes;

  Future<File> exportBackup(String outputPath) async {
    await _beforeExport?.call();
    final workDirectory = await _newWorkDirectory('export');
    final databaseFile = File(path.join(workDirectory.path, _databaseName));
    final output = File(outputPath);
    final temporaryOutput = File('$outputPath.part');
    try {
      await _database.createPortableSnapshot(databaseFile.path);
      final preferences = await AppPreferences.snapshot(
        excludedKeys: const <String>{'timer_runtime_v1'},
      );
      final account = await _accountStore.exportBackupSnapshot();
      final preferencesFile = File(
        path.join(workDirectory.path, _preferencesName),
      );
      final accountFile = File(path.join(workDirectory.path, _accountName));
      await _writeLimitedJson(
        preferencesFile,
        preferences,
        _maximumPreferencesBytes,
      );
      await _writeLimitedJson(
        accountFile,
        account.toJson(),
        _maximumAccountBytes,
      );
      final payloads = <String, File>{
        _databaseName: databaseFile,
        _preferencesName: preferencesFile,
        _accountName: accountFile,
      };
      final records = <String, BackupFileRecord>{};
      var expandedBytes = 0;
      for (final entry in payloads.entries) {
        final record = await _recordFile(entry.value);
        records[entry.key] = record;
        expandedBytes = _checkedExpandedTotal(expandedBytes, record.length);
      }
      final version = await _appVersionProvider();
      final manifest = BackupManifest(
        formatVersion: _backupFormatVersion,
        appVersion: '${version.versionName}+${version.buildNumber}',
        databaseSchemaVersion: AppDatabase.schemaVersion,
        platform: _platformName,
        createdAt: _clock().toUtc(),
        containsSensitiveAccountData: true,
        files: records,
      );
      final manifestBytes = utf8.encode(
        const JsonEncoder.withIndent('  ').convert(manifest.toJson()),
      );
      if (manifestBytes.length > _maximumManifestBytes) {
        throw const FormatException('backup_too_large');
      }
      _checkedExpandedTotal(expandedBytes, manifestBytes.length);

      await output.parent.create(recursive: true);
      if (await temporaryOutput.exists()) await temporaryOutput.delete();
      final outputStream = OutputFileStream(temporaryOutput.path);
      try {
        final encoder = ZipEncoder()..startEncode(outputStream);
        encoder.add(ArchiveFile.bytes(_manifestName, manifestBytes));
        _addFileToArchive(
          encoder,
          databaseFile,
          _databaseName,
          compression: CompressionType.none,
        );
        _addFileToArchive(encoder, preferencesFile, _preferencesName);
        _addFileToArchive(encoder, accountFile, _accountName);
        encoder.endEncode();
      } finally {
        await outputStream.close();
      }
      if (await temporaryOutput.length() > _maximumArchiveBytes) {
        throw const FormatException('backup_too_large');
      }
      if (await output.exists()) await output.delete();
      await temporaryOutput.rename(output.path);
      return output;
    } finally {
      if (await temporaryOutput.exists()) await temporaryOutput.delete();
      await _deleteDirectory(workDirectory);
    }
  }

  Future<BackupValidationResult> inspectAndStageRestore(
    String sourcePath,
  ) async {
    final source = File(sourcePath);
    final validationDirectory = await _newWorkDirectory('validation');
    try {
      final decoded = await _decodeAndValidate(source, validationDirectory);
      final restoreDirectory = await _restoreDirectory();
      await restoreDirectory.create(recursive: true);
      final pending = File(
        path.join(restoreDirectory.path, 'pending.dabackup'),
      );
      final temporary = File('${pending.path}.part');
      if (await temporary.exists()) await temporary.delete();
      try {
        await source.openRead().pipe(temporary.openWrite());
        if (await pending.exists()) await pending.delete();
        await temporary.rename(pending.path);
        await _writeJournal(
          restoreDirectory,
          PendingRestoreJournal(phase: 'prepared', createdAt: _clock()),
        );
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
      return BackupValidationResult(manifest: decoded.manifest);
    } finally {
      await _deleteDirectory(validationDirectory);
    }
  }

  Future<StartupRestoreOutcome?> applyAtStartup() async {
    final restoreDirectory = await _restoreDirectory();
    final pending = File(path.join(restoreDirectory.path, 'pending.dabackup'));
    if (!await pending.exists()) return null;

    final rollbackDirectory = Directory(
      path.join(restoreDirectory.path, 'rollback'),
    );
    var commitStarted = false;
    try {
      final journal = await _readJournal(restoreDirectory);
      if (journal?.phase == 'committed') {
        await _deleteDirectory(restoreDirectory);
        return const StartupRestoreOutcome.succeeded();
      }
      final resumeCommit =
          journal?.phase == 'committing' &&
          await File(
            path.join(rollbackDirectory.path, _preferencesName),
          ).exists() &&
          await File(path.join(rollbackDirectory.path, _accountName)).exists();
      commitStarted = resumeCommit;
      final decoded = await _decodeAndValidate(
        pending,
        Directory(path.join(restoreDirectory.path, 'decoded')),
      );
      final databaseDirectory = Directory(await _databasesPathProvider());
      await databaseDirectory.create(recursive: true);
      final currentDatabase = File(
        path.join(databaseDirectory.path, AppDatabase.fileName),
      );
      final rollbackDatabase = File(
        path.join(rollbackDirectory.path, AppDatabase.fileName),
      );
      if (!resumeCommit) {
        await _deleteDirectory(rollbackDirectory);
        await rollbackDirectory.create(recursive: true);
        final previousPreferences = await AppPreferences.snapshot();
        final previousAccount = await _accountStore.exportBackupSnapshot();
        await File(
          path.join(rollbackDirectory.path, _preferencesName),
        ).writeAsString(jsonEncode(previousPreferences), flush: true);
        await File(
          path.join(rollbackDirectory.path, _accountName),
        ).writeAsString(jsonEncode(previousAccount.toJson()), flush: true);

        await _database.databaseForTest;
        await _database.close();
        if (await currentDatabase.exists()) {
          await currentDatabase.copy(rollbackDatabase.path);
        }
      }

      await _writeJournal(
        restoreDirectory,
        PendingRestoreJournal(phase: 'committing', createdAt: _clock()),
      );
      commitStarted = true;
      await _deleteDatabaseFiles(currentDatabase);
      await decoded.databaseFile.rename(currentDatabase.path);
      await AppPreferences.replaceSnapshot(decoded.preferences);
      await _accountStore.replaceFromBackup(decoded.account);

      await _writeJournal(
        restoreDirectory,
        PendingRestoreJournal(phase: 'committed', createdAt: _clock()),
      );
      await _deleteDirectory(restoreDirectory);
      return const StartupRestoreOutcome.succeeded();
    } catch (_) {
      if (!commitStarted) {
        await _deleteDirectory(restoreDirectory);
        return const StartupRestoreOutcome.failed('restore_validation_failed');
      }
      try {
        await _rollback(rollbackDirectory);
        await _deleteDirectory(restoreDirectory);
        return const StartupRestoreOutcome.failed('restore_failed_rolled_back');
      } catch (_) {
        throw StateError('backup_restore_rollback_failed');
      }
    }
  }

  Future<_DecodedBackup> _decodeAndValidate(
    File source,
    Directory decodeDirectory,
  ) async {
    if (!await source.exists()) throw const FormatException('backup_missing');
    final archiveLength = await source.length();
    if (archiveLength > _maximumArchiveBytes) {
      throw const FormatException('backup_too_large');
    }
    _preflightArchive(source, archiveLength);
    await _deleteDirectory(decodeDirectory);
    await decodeDirectory.create(recursive: true);
    final input = InputFileStream(source.path);
    Archive? archive;
    try {
      archive = ZipDecoder().decodeStream(input);

      var actualExpandedBytes = 0;
      final extractedFiles = <String, File>{};
      for (final entry in archive.files) {
        final file = File(path.join(decodeDirectory.path, entry.name));
        final output = _LimitedOutputFileStream(file.path, entry.size, (count) {
          actualExpandedBytes = _checkedExpandedTotal(
            actualExpandedBytes,
            count,
          );
        });
        try {
          entry.writeContent(output);
        } finally {
          output.closeSync();
        }
        if (output.length != entry.size) {
          throw const FormatException('invalid_backup_entry_length');
        }
        extractedFiles[entry.name] = file;
      }

      final manifest = BackupManifest.fromJson(
        Map<String, Object?>.from(
          jsonDecode(await extractedFiles[_manifestName]!.readAsString())
              as Map,
        ),
      );
      if (manifest.formatVersion != _backupFormatVersion ||
          manifest.platform != _platformName ||
          manifest.databaseSchemaVersion > AppDatabase.schemaVersion ||
          !manifest.containsSensitiveAccountData ||
          manifest.files.keys.toSet().length != 3 ||
          !manifest.files.keys.toSet().containsAll(<String>{
            _databaseName,
            _preferencesName,
            _accountName,
          })) {
        throw const FormatException('incompatible_backup');
      }
      for (final name in const <String>[
        _databaseName,
        _preferencesName,
        _accountName,
      ]) {
        final record = manifest.files[name];
        final actual = await _recordFile(extractedFiles[name]!);
        if (record == null ||
            record.length != actual.length ||
            record.sha256 != actual.sha256) {
          throw const FormatException('backup_checksum_mismatch');
        }
      }
      final preferencesRaw = jsonDecode(
        await extractedFiles[_preferencesName]!.readAsString(),
      );
      if (preferencesRaw is! Map) {
        throw const FormatException('invalid_preferences_backup');
      }
      final preferences = Map<String, Object?>.from(preferencesRaw)
        ..remove('timer_runtime_v1');
      final accountRaw = jsonDecode(
        await extractedFiles[_accountName]!.readAsString(),
      );
      if (accountRaw is! Map) {
        throw const FormatException('invalid_account_backup');
      }
      final account = AsmrAccountBackupSnapshot.fromJson(
        Map<String, Object?>.from(accountRaw),
      );
      final databaseFile = extractedFiles[_databaseName]!;
      await _database.validateAndMigrateRestoreCandidate(databaseFile.path);
      return _DecodedBackup(
        manifest: manifest,
        databaseFile: databaseFile,
        preferences: preferences,
        account: account,
      );
    } catch (_) {
      await _deleteDirectory(decodeDirectory);
      rethrow;
    } finally {
      archive?.clearSync();
      input.closeSync();
    }
  }

  void _preflightArchive(File source, int archiveLength) {
    final input = InputFileStream(source.path);
    final directory = ZipDirectory();
    try {
      directory.read(input);
      final names = <String>{};
      var declaredExpandedBytes = 0;
      for (final header in directory.fileHeaders) {
        final name = header.filename;
        final unixMode = header.externalFileAttributes >> 16;
        final isSymbolicLink =
            header.versionMadeBy >> 8 == 3 && unixMode & 0xf000 == 0xa000;
        if (name.endsWith('/') ||
            name.endsWith('\\') ||
            isSymbolicLink ||
            header.generalPurposeBitFlag & 1 != 0 ||
            !_allowedArchiveEntries.contains(name) ||
            !names.add(name) ||
            (header.compressionMethod != ZipFile.zipCompressionStore &&
                header.compressionMethod != ZipFile.zipCompressionDeflate)) {
          throw const FormatException('invalid_backup_entries');
        }
        if (header.uncompressedSize < 0 ||
            header.uncompressedSize > _maximumEntryBytes(name) ||
            header.compressedSize < 0 ||
            header.compressedSize > archiveLength) {
          throw const FormatException('backup_too_large');
        }
        declaredExpandedBytes = _checkedExpandedTotal(
          declaredExpandedBytes,
          header.uncompressedSize,
        );
      }
      if (directory.totalCentralDirectoryEntries !=
              directory.fileHeaders.length ||
          !names.containsAll(_allowedArchiveEntries) ||
          names.length != _allowedArchiveEntries.length) {
        throw const FormatException('invalid_backup_entries');
      }
    } finally {
      for (final header in directory.fileHeaders) {
        header.file?.closeSync();
      }
      input.closeSync();
    }
  }

  int _maximumEntryBytes(String name) => switch (name) {
    _manifestName => _maximumManifestBytes,
    _preferencesName => _maximumPreferencesBytes,
    _accountName => _maximumAccountBytes,
    _databaseName => _maximumExpandedBytes,
    _ => 0,
  };

  int _checkedExpandedTotal(int current, int additional) {
    if (additional < 0 || current > _maximumExpandedBytes - additional) {
      throw const FormatException('backup_too_large');
    }
    return current + additional;
  }

  Future<void> _writeLimitedJson(File file, Object? value, int limit) async {
    final bytes = utf8.encode(jsonEncode(value));
    if (bytes.length > limit) {
      throw const FormatException('backup_too_large');
    }
    await file.writeAsBytes(bytes, flush: true);
  }

  Future<BackupFileRecord> _recordFile(File file) async {
    final length = await file.length();
    final digest = await sha256.bind(file.openRead()).first;
    return BackupFileRecord(length: length, sha256: digest.toString());
  }

  void _addFileToArchive(
    ZipEncoder encoder,
    File file,
    String name, {
    CompressionType? compression,
  }) {
    final entry = ArchiveFile.stream(name, InputFileStream(file.path))
      ..compression = compression;
    encoder.add(entry);
  }

  Future<void> _rollback(Directory rollbackDirectory) async {
    final preferencesFile = File(
      path.join(rollbackDirectory.path, _preferencesName),
    );
    final accountFile = File(path.join(rollbackDirectory.path, _accountName));
    if (!await preferencesFile.exists() || !await accountFile.exists()) {
      throw StateError('restore_rollback_missing');
    }
    final databaseDirectory = Directory(await _databasesPathProvider());
    final currentDatabase = File(
      path.join(databaseDirectory.path, AppDatabase.fileName),
    );
    final rollbackDatabase = File(
      path.join(rollbackDirectory.path, AppDatabase.fileName),
    );
    await _database.close();
    if (await rollbackDatabase.exists()) {
      await _deleteDatabaseFiles(currentDatabase);
      await rollbackDatabase.copy(currentDatabase.path);
    } else {
      await _deleteDatabaseFiles(currentDatabase);
    }
    await AppPreferences.replaceSnapshot(
      Map<String, Object?>.from(
        jsonDecode(await preferencesFile.readAsString()) as Map,
      ),
    );
    await _accountStore.restoreSnapshotForRollback(
      AsmrAccountBackupSnapshot.fromJson(
        Map<String, Object?>.from(
          jsonDecode(await accountFile.readAsString()) as Map,
        ),
      ),
    );
  }

  Future<Directory> _restoreDirectory() async {
    final support = await _supportDirectoryProvider();
    return Directory(path.join(support.path, 'backup_restore'));
  }

  Future<Directory> _newWorkDirectory(String prefix) async {
    final support = await _supportDirectoryProvider();
    final directory = Directory(
      path.join(
        support.path,
        'backup_work',
        '${prefix}_${_clock().microsecondsSinceEpoch}',
      ),
    );
    await directory.create(recursive: true);
    return directory;
  }

  Future<void> _writeJournal(
    Directory directory,
    PendingRestoreJournal journal,
  ) async {
    final file = File(path.join(directory.path, 'journal.json'));
    final temporary = File('${file.path}.part');
    await temporary.writeAsString(jsonEncode(journal.toJson()), flush: true);
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }

  Future<PendingRestoreJournal?> _readJournal(Directory directory) async {
    final file = File(path.join(directory.path, 'journal.json'));
    if (!await file.exists()) return null;
    final json = jsonDecode(await file.readAsString());
    if (json is! Map) return null;
    final phase = json['phase'];
    final createdAt = DateTime.tryParse(json['createdAt']?.toString() ?? '');
    if (phase is! String || createdAt == null) return null;
    return PendingRestoreJournal(phase: phase, createdAt: createdAt);
  }

  Future<void> _deleteDirectory(Directory directory) async {
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  Future<void> _deleteDatabaseFiles(File database) async {
    for (final suffix in const <String>['', '-wal', '-shm']) {
      final file = File('${database.path}$suffix');
      if (await file.exists()) await file.delete();
    }
  }
}

class _DecodedBackup {
  const _DecodedBackup({
    required this.manifest,
    required this.databaseFile,
    required this.preferences,
    required this.account,
  });

  final BackupManifest manifest;
  final File databaseFile;
  final Map<String, Object?> preferences;
  final AsmrAccountBackupSnapshot account;
}

class _LimitedOutputFileStream extends OutputFileStream {
  _LimitedOutputFileStream(String filePath, this.maximumLength, this.onWrite)
    : super.withFileHandle(FileHandle(filePath, mode: FileAccess.write));

  final int maximumLength;
  final void Function(int count) onWrite;

  void _reserve(int count) {
    if (count < 0 || length > maximumLength - count) {
      throw const FormatException('invalid_backup_entry_length');
    }
    onWrite(count);
  }

  @override
  void writeByte(int value) {
    _reserve(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final count = length ?? bytes.length;
    _reserve(count);
    super.writeBytes(bytes, length: count);
  }
}
