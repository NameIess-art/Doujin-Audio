import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
const _maximumExpandedBackupBytes = 512 * 1024 * 1024;
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
    Future<void> Function()? beforeExport,
    DateTime Function()? clock,
    String? platformName,
  }) : _database = database ?? AppDatabase.instance,
       _accountStore = accountStore ?? SecureAsmrTokenStore(),
       _appVersionProvider =
           (appUpdateService ?? AppUpdateService()).currentAppVersion,
       _supportDirectoryProvider =
           supportDirectoryProvider ?? getApplicationSupportDirectory,
       _beforeExport = beforeExport,
       _clock = clock ?? DateTime.now,
       _platformName = platformName ?? Platform.operatingSystem;

  final AppDatabase _database;
  final SecureAsmrTokenStore _accountStore;
  final Future<AppVersionInfo> Function() _appVersionProvider;
  final Future<Directory> Function() _supportDirectoryProvider;
  final Future<void> Function()? _beforeExport;
  final DateTime Function() _clock;
  final String _platformName;

  Future<File> exportBackup(String outputPath) async {
    await _beforeExport?.call();
    final workDirectory = await _newWorkDirectory('export');
    final databaseFile = File(path.join(workDirectory.path, _databaseName));
    try {
      await _database.createPortableSnapshot(databaseFile.path);
      final preferences = await AppPreferences.snapshot(
        excludedKeys: const <String>{'timer_runtime_v1'},
      );
      final account = await _accountStore.exportBackupSnapshot();
      final payloads = <String, Uint8List>{
        _databaseName: await databaseFile.readAsBytes(),
        _preferencesName: Uint8List.fromList(
          utf8.encode(jsonEncode(preferences)),
        ),
        _accountName: Uint8List.fromList(
          utf8.encode(jsonEncode(account.toJson())),
        ),
      };
      final version = await _appVersionProvider();
      final manifest = BackupManifest(
        formatVersion: _backupFormatVersion,
        appVersion: '${version.versionName}+${version.buildNumber}',
        databaseSchemaVersion: AppDatabase.schemaVersion,
        platform: _platformName,
        createdAt: _clock().toUtc(),
        containsSensitiveAccountData: true,
        files: <String, BackupFileRecord>{
          for (final entry in payloads.entries)
            entry.key: BackupFileRecord(
              length: entry.value.length,
              sha256: sha256.convert(entry.value).toString(),
            ),
        },
      );
      final archive = Archive()
        ..addFile(
          ArchiveFile.string(
            _manifestName,
            const JsonEncoder.withIndent('  ').convert(manifest.toJson()),
          ),
        );
      for (final entry in payloads.entries) {
        archive.addFile(
          ArchiveFile(entry.key, entry.value.length, entry.value),
        );
      }
      final output = File(outputPath);
      await output.parent.create(recursive: true);
      await output.writeAsBytes(ZipEncoder().encode(archive), flush: true);
      return output;
    } finally {
      await _deleteDirectory(workDirectory);
    }
  }

  Future<BackupValidationResult> inspectAndStageRestore(
    String sourcePath,
  ) async {
    final source = File(sourcePath);
    final decoded = await _decodeAndValidate(source);
    final restoreDirectory = await _restoreDirectory();
    await restoreDirectory.create(recursive: true);
    final pending = File(path.join(restoreDirectory.path, 'pending.dabackup'));
    final temporary = File('${pending.path}.part');
    if (await temporary.exists()) await temporary.delete();
    await source.openRead().pipe(temporary.openWrite());
    if (await pending.exists()) await pending.delete();
    await temporary.rename(pending.path);
    await _writeJournal(
      restoreDirectory,
      PendingRestoreJournal(phase: 'prepared', createdAt: _clock()),
    );
    return BackupValidationResult(manifest: decoded.manifest);
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
      final decoded = await _decodeAndValidate(pending);
      final databaseDirectory = Directory(await getDatabasesPath());
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
      final candidate = File(path.join(restoreDirectory.path, 'candidate.db'));
      await candidate.writeAsBytes(decoded.databaseBytes, flush: true);
      await _database.validateAndMigrateRestoreCandidate(candidate.path);

      await _deleteDatabaseFiles(currentDatabase);
      await candidate.rename(currentDatabase.path);
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

  Future<_DecodedBackup> _decodeAndValidate(File source) async {
    if (!await source.exists()) throw const FormatException('backup_missing');
    if (await source.length() > _maximumExpandedBackupBytes) {
      throw const FormatException('backup_too_large');
    }
    final archive = ZipDecoder().decodeBytes(await source.readAsBytes());
    final names = <String>{};
    var expandedBytes = 0;
    final files = <String, Uint8List>{};
    for (final entry in archive.files) {
      final name = entry.name;
      if (!entry.isFile ||
          !_allowedArchiveEntries.contains(name) ||
          !names.add(name)) {
        throw const FormatException('invalid_backup_entries');
      }
      expandedBytes += entry.size;
      if (entry.size < 0 || expandedBytes > _maximumExpandedBackupBytes) {
        throw const FormatException('backup_too_large');
      }
      final content = Uint8List.fromList(entry.content as List<int>);
      if (content.length != entry.size) {
        throw const FormatException('invalid_backup_entry_length');
      }
      files[name] = content;
    }
    if (!names.containsAll(_allowedArchiveEntries) ||
        names.length != _allowedArchiveEntries.length) {
      throw const FormatException('invalid_backup_entries');
    }
    final manifest = BackupManifest.fromJson(
      Map<String, Object?>.from(
        jsonDecode(utf8.decode(files[_manifestName]!)) as Map,
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
      final bytes = files[name]!;
      final record = manifest.files[name];
      if (record == null ||
          record.length != bytes.length ||
          record.sha256 != sha256.convert(bytes).toString()) {
        throw const FormatException('backup_checksum_mismatch');
      }
    }
    final preferencesRaw = jsonDecode(utf8.decode(files[_preferencesName]!));
    if (preferencesRaw is! Map) {
      throw const FormatException('invalid_preferences_backup');
    }
    final preferences = Map<String, Object?>.from(preferencesRaw);
    preferences.remove('timer_runtime_v1');
    final accountRaw = jsonDecode(utf8.decode(files[_accountName]!));
    if (accountRaw is! Map) {
      throw const FormatException('invalid_account_backup');
    }
    final account = AsmrAccountBackupSnapshot.fromJson(
      Map<String, Object?>.from(accountRaw),
    );

    final validationDirectory = await _newWorkDirectory('validation');
    try {
      final candidate = File(
        path.join(validationDirectory.path, 'candidate.db'),
      );
      await candidate.writeAsBytes(files[_databaseName]!, flush: true);
      await _database.validateAndMigrateRestoreCandidate(candidate.path);
    } finally {
      await _deleteDirectory(validationDirectory);
    }
    return _DecodedBackup(
      manifest: manifest,
      databaseBytes: files[_databaseName]!,
      preferences: preferences,
      account: account,
    );
  }

  Future<void> _rollback(Directory rollbackDirectory) async {
    final preferencesFile = File(
      path.join(rollbackDirectory.path, _preferencesName),
    );
    final accountFile = File(path.join(rollbackDirectory.path, _accountName));
    if (!await preferencesFile.exists() || !await accountFile.exists()) {
      throw StateError('restore_rollback_missing');
    }
    final databaseDirectory = Directory(await getDatabasesPath());
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
    required this.databaseBytes,
    required this.preferences,
    required this.account,
  });

  final BackupManifest manifest;
  final Uint8List databaseBytes;
  final Map<String, Object?> preferences;
  final AsmrAccountBackupSnapshot account;
}
