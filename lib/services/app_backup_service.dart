import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import '../platform/app_platform.dart';
import 'app_database.dart';
import 'app_log_service.dart';
import 'app_preferences.dart';
import 'app_update_service.dart';

class BackupManifest {
  const BackupManifest({
    required this.formatVersion,
    required this.dataEpoch,
    required this.appVersion,
    required this.createdAt,
    required this.platform,
    required this.databaseSchemaVersion,
    required this.entries,
  });

  factory BackupManifest.fromJson(Map<String, Object?> json) {
    final entries = (json['entries'] as Map<Object?, Object?>?)?.map(
      (key, value) => MapEntry(
        key.toString(),
        BackupEntryManifest.fromJson(
          (value as Map<Object?, Object?>).cast<String, Object?>(),
        ),
      ),
    );
    return BackupManifest(
      formatVersion: (json['formatVersion'] as num?)?.toInt() ?? 0,
      dataEpoch: (json['dataEpoch'] as num?)?.toInt() ?? 0,
      appVersion: json['appVersion'] as String? ?? '',
      createdAt: DateTime.parse(json['createdAt'] as String),
      platform: json['platform'] as String? ?? '',
      databaseSchemaVersion:
          (json['databaseSchemaVersion'] as num?)?.toInt() ?? 0,
      entries: entries ?? const <String, BackupEntryManifest>{},
    );
  }

  final int formatVersion;
  final int dataEpoch;
  final String appVersion;
  final DateTime createdAt;
  final String platform;
  final int databaseSchemaVersion;
  final Map<String, BackupEntryManifest> entries;

  Map<String, Object?> toJson() => <String, Object?>{
    'formatVersion': formatVersion,
    'dataEpoch': dataEpoch,
    'appVersion': appVersion,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'platform': platform,
    'databaseSchemaVersion': databaseSchemaVersion,
    'entries': entries.map((key, value) => MapEntry(key, value.toJson())),
  };
}

class BackupEntryManifest {
  const BackupEntryManifest({required this.sha256Hash, required this.size});

  factory BackupEntryManifest.fromJson(Map<String, Object?> json) {
    return BackupEntryManifest(
      sha256Hash: json['sha256'] as String? ?? '',
      size: (json['size'] as num?)?.toInt() ?? -1,
    );
  }

  final String sha256Hash;
  final int size;

  Map<String, Object?> toJson() => <String, Object?>{
    'sha256': sha256Hash,
    'size': size,
  };
}

class BackupValidationResult {
  const BackupValidationResult._({
    required this.isValid,
    this.manifest,
    this.error,
  });

  const BackupValidationResult.valid(BackupManifest manifest)
    : this._(isValid: true, manifest: manifest);

  const BackupValidationResult.invalid(String error)
    : this._(isValid: false, error: error);

  final bool isValid;
  final BackupManifest? manifest;
  final String? error;
}

class _BackupRestoreFailed implements Exception {
  const _BackupRestoreFailed();
}

class AppBackupService {
  AppBackupService({
    AppDatabase? database,
    Future<Map<String, Object>> Function()? exportPreferences,
    Future<void> Function(Map<String, Object?> values)? restorePreferences,
    Future<AppVersionInfo> Function()? appVersionProvider,
    Future<String> Function()? databasePathProvider,
    Future<void> Function()? closeDatabase,
    Future<void> Function()? reopenDatabase,
    String? platformName,
  }) : _database =
           database != null ||
               (databasePathProvider == null &&
                   closeDatabase == null &&
                   reopenDatabase == null)
           ? (database ?? AppDatabase.instance)
           : null,
       _exportPreferences =
           exportPreferences ?? AppPreferences.exportSafeValues,
       _restorePreferences =
           restorePreferences ?? AppPreferences.restoreSafeValues,
       _appVersionProvider =
           appVersionProvider ?? AppUpdateService.currentAppVersion,
       _databasePathProvider =
           databasePathProvider ??
           (() => (database ?? AppDatabase.instance).filePath),
       _closeDatabase =
           closeDatabase ?? (database ?? AppDatabase.instance).close,
       _reopenDatabase =
           reopenDatabase ?? (database ?? AppDatabase.instance).reopen,
       _platformName =
           platformName ??
           (AppPlatform.isAndroid
               ? 'android'
               : AppPlatform.isWindows
               ? 'windows'
               : AppPlatform.isDesktopLinux
               ? 'linux'
               : 'unknown');

  static const int formatVersion = 2;
  static const int dataEpoch = 1;
  static const String databaseEntry = 'data/audio_player.db';
  static const String preferencesEntry = 'data/preferences.json';
  static const String manifestEntry = 'manifest.json';

  final Future<Map<String, Object>> Function() _exportPreferences;
  final Future<void> Function(Map<String, Object?> values) _restorePreferences;
  final Future<AppVersionInfo> Function() _appVersionProvider;
  final Future<String> Function() _databasePathProvider;
  final Future<void> Function() _closeDatabase;
  final Future<void> Function() _reopenDatabase;
  final String _platformName;
  final AppDatabase? _database;

  Future<T> _runDatabaseMaintenance<T>({
    required bool replacesDatabase,
    required Future<T> Function(String databasePath) action,
  }) async {
    final managedDatabase = _database;
    if (managedDatabase != null) {
      return managedDatabase.runExclusiveMaintenance<T>(
        replacesDatabase: replacesDatabase,
        action: action,
      );
    }
    final databasePath = await _databasePathProvider();
    await _closeDatabase();
    try {
      return await action(databasePath);
    } finally {
      await _reopenDatabase();
    }
  }

  Future<File> exportBackup(String outputPath) async {
    final databaseBytes = await _runDatabaseMaintenance<Uint8List>(
      replacesDatabase: false,
      action: (databasePath) => File(databasePath).readAsBytes(),
    );

    final preferencesBytes = Uint8List.fromList(
      utf8.encode(jsonEncode(await _exportPreferences())),
    );
    final version = await _appVersionProvider();
    final entryBytes = <String, Uint8List>{
      databaseEntry: databaseBytes,
      preferencesEntry: preferencesBytes,
    };
    final manifest = BackupManifest(
      formatVersion: formatVersion,
      dataEpoch: dataEpoch,
      appVersion: '${version.versionName}+${version.buildNumber}',
      createdAt: DateTime.now(),
      platform: _platformName,
      databaseSchemaVersion: AppDatabase.schemaVersion,
      entries: entryBytes.map(
        (name, bytes) => MapEntry(
          name,
          BackupEntryManifest(
            sha256Hash: sha256.convert(bytes).toString(),
            size: bytes.length,
          ),
        ),
      ),
    );

    final archive = Archive();
    for (final entry in entryBytes.entries) {
      archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
    }
    final manifestBytes = utf8.encode(jsonEncode(manifest.toJson()));
    archive.addFile(
      ArchiveFile(manifestEntry, manifestBytes.length, manifestBytes),
    );
    final encoded = ZipEncoder().encode(archive);
    final output = File(outputPath);
    await output.parent.create(recursive: true);
    await output.writeAsBytes(encoded, flush: true);
    return output;
  }

  Future<BackupValidationResult> validateBackup(String backupPath) async {
    try {
      final archive = ZipDecoder().decodeBytes(
        await File(backupPath).readAsBytes(),
        verify: true,
      );
      final manifestFile = archive.findFile(manifestEntry);
      if (manifestFile == null) {
        return const BackupValidationResult.invalid('missing_manifest');
      }
      final manifest = BackupManifest.fromJson(
        (jsonDecode(utf8.decode(manifestFile.content as List<int>))
                as Map<String, dynamic>)
            .cast<String, Object?>(),
      );
      if (manifest.formatVersion != formatVersion) {
        return const BackupValidationResult.invalid(
          'unsupported_format_version',
        );
      }
      if (manifest.dataEpoch != dataEpoch) {
        return const BackupValidationResult.invalid('unsupported_data_epoch');
      }
      if (manifest.databaseSchemaVersion > AppDatabase.schemaVersion) {
        return const BackupValidationResult.invalid(
          'unsupported_database_version',
        );
      }
      for (final entry in manifest.entries.entries) {
        final file = archive.findFile(entry.key);
        if (file == null) {
          return BackupValidationResult.invalid('missing_entry:${entry.key}');
        }
        final bytes = file.content as List<int>;
        if (bytes.length != entry.value.size ||
            sha256.convert(bytes).toString() != entry.value.sha256Hash) {
          return BackupValidationResult.invalid(
            'checksum_mismatch:${entry.key}',
          );
        }
      }
      if (!manifest.entries.containsKey(databaseEntry) ||
          !manifest.entries.containsKey(preferencesEntry)) {
        return const BackupValidationResult.invalid('missing_required_entry');
      }
      return BackupValidationResult.valid(manifest);
    } catch (error, stackTrace) {
      AppLogService.warning(
        'backup_validation_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return const BackupValidationResult.invalid('invalid_backup');
    }
  }

  Future<BackupValidationResult> restoreBackup(String backupPath) async {
    final validation = await validateBackup(backupPath);
    if (!validation.isValid) return validation;

    final archive = ZipDecoder().decodeBytes(
      await File(backupPath).readAsBytes(),
      verify: true,
    );
    final databaseBytes = archive.findFile(databaseEntry)!.content as List<int>;
    final preferences =
        (jsonDecode(
                  utf8.decode(
                    archive.findFile(preferencesEntry)!.content as List<int>,
                  ),
                )
                as Map<String, dynamic>)
            .cast<String, Object?>();
    final originalPreferences = await _exportPreferences();
    try {
      return await _runDatabaseMaintenance<BackupValidationResult>(
        replacesDatabase: true,
        action: (databasePath) async {
          final databaseFile = File(databasePath);
          final rollbackFile = File('$databasePath.restore-backup');
          final replacementFile = File('$databasePath.restore-new');
          try {
            if (await rollbackFile.exists()) await rollbackFile.delete();
            if (await replacementFile.exists()) await replacementFile.delete();
            if (await databaseFile.exists()) {
              await databaseFile.rename(rollbackFile.path);
            }
            await replacementFile.writeAsBytes(databaseBytes, flush: true);
            await replacementFile.rename(databaseFile.path);
            await _restorePreferences(preferences);
            if (await rollbackFile.exists()) await rollbackFile.delete();
            return validation;
          } catch (error, stackTrace) {
            AppLogService.error(
              'backup_restore_failed',
              error: error,
              stackTrace: stackTrace,
            );
            if (await databaseFile.exists()) await databaseFile.delete();
            if (await rollbackFile.exists()) {
              await rollbackFile.rename(databaseFile.path);
            }
            await _restorePreferences(originalPreferences);
            throw const _BackupRestoreFailed();
          } finally {
            if (await replacementFile.exists()) await replacementFile.delete();
          }
        },
      );
    } on _BackupRestoreFailed {
      return const BackupValidationResult.invalid('restore_failed');
    }
  }
}
