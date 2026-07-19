import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';

import '../../../core/persistence/app_database.dart';
import '../../../core/logging/app_log_service.dart';
import '../../settings/application/app_preferences.dart';
import '../../settings/application/app_update_service.dart';

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

class _PreparedBackup {
  const _PreparedBackup({
    required this.validation,
    this.temporaryDirectory,
    this.databaseFile,
    this.preferences,
  });

  final BackupValidationResult validation;
  final Directory? temporaryDirectory;
  final File? databaseFile;
  final Map<String, Object?>? preferences;

  Future<void> dispose() async {
    final directory = temporaryDirectory;
    if (directory != null && await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }
}

class AppBackupService {
  AppBackupService({
    AppDatabase? database,
    Future<Map<String, Object>> Function()? exportPreferences,
    Future<void> Function(Map<String, Object?> values)? restorePreferences,
    Future<AppVersionInfo> Function()? appVersionProvider,
    AppUpdateService? appUpdateService,
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
           appVersionProvider ??
           (appUpdateService ?? AppUpdateService()).currentAppVersion,
       _databasePathProvider =
           databasePathProvider ??
           (() => (database ?? AppDatabase.instance).filePath),
       _closeDatabase =
           closeDatabase ?? (database ?? AppDatabase.instance).close,
       _reopenDatabase =
           reopenDatabase ?? (database ?? AppDatabase.instance).reopen,
       _platformName = platformName ?? 'android';

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
    final output = File(outputPath);
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'nameless_audio_backup_export_',
    );
    final databaseSnapshot = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}audio_player.db',
    );
    try {
      await _runDatabaseMaintenance<void>(
        replacesDatabase: false,
        action: (databasePath) =>
            _copyFile(File(databasePath), databaseSnapshot),
      );
      final preferencesBytes = Uint8List.fromList(
        utf8.encode(jsonEncode(await _exportPreferences())),
      );
      final version = await _appVersionProvider();
      final manifest = BackupManifest(
        formatVersion: formatVersion,
        dataEpoch: dataEpoch,
        appVersion: '${version.versionName}+${version.buildNumber}',
        createdAt: DateTime.now(),
        platform: _platformName,
        databaseSchemaVersion: AppDatabase.schemaVersion,
        entries: <String, BackupEntryManifest>{
          databaseEntry: BackupEntryManifest(
            sha256Hash: await _sha256File(databaseSnapshot),
            size: await databaseSnapshot.length(),
          ),
          preferencesEntry: BackupEntryManifest(
            sha256Hash: sha256.convert(preferencesBytes).toString(),
            size: preferencesBytes.length,
          ),
        },
      );

      await output.parent.create(recursive: true);
      final encoder = ZipFileEncoder()..create(output.path);
      var encoderClosed = false;
      try {
        final databaseInput = InputFileStream(databaseSnapshot.path);
        try {
          final databaseArchiveFile = ArchiveFile.stream(
            databaseEntry,
            databaseInput,
          )..compression = CompressionType.none;
          encoder.addArchiveFile(databaseArchiveFile);
        } finally {
          await databaseInput.close();
        }
        encoder.addArchiveFile(
          ArchiveFile.bytes(preferencesEntry, preferencesBytes),
        );
        encoder.addArchiveFile(
          ArchiveFile.string(manifestEntry, jsonEncode(manifest.toJson())),
        );
        await encoder.close();
        encoderClosed = true;
      } catch (error, stackTrace) {
        if (!encoderClosed) {
          try {
            await encoder.close();
          } catch (_) {
            // Preserve the primary export failure after releasing the handle.
          }
        }
        if (await output.exists()) await output.delete();
        Error.throwWithStackTrace(error, stackTrace);
      }
      return output;
    } finally {
      if (await temporaryDirectory.exists()) {
        await temporaryDirectory.delete(recursive: true);
      }
    }
  }

  Future<BackupValidationResult> validateBackup(String backupPath) async {
    final prepared = await _prepareBackup(backupPath);
    try {
      return prepared.validation;
    } finally {
      await prepared.dispose();
    }
  }

  Future<BackupValidationResult> restoreBackup(String backupPath) async {
    final prepared = await _prepareBackup(backupPath);
    final validation = prepared.validation;
    if (!validation.isValid) {
      await prepared.dispose();
      return validation;
    }
    final preparedDatabase = prepared.databaseFile!;
    final preferences = prepared.preferences!;
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
            await _copyFile(preparedDatabase, replacementFile);
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
    } finally {
      await prepared.dispose();
    }
  }

  Future<_PreparedBackup> _prepareBackup(String backupPath) async {
    Directory? temporaryDirectory;
    InputFileStream? input;
    Archive? archive;
    try {
      temporaryDirectory = await Directory.systemTemp.createTemp(
        'nameless_audio_backup_restore_',
      );
      input = InputFileStream(backupPath);
      archive = ZipDecoder().decodeStream(input, verify: true);
      final manifestFile = archive.findFile(manifestEntry);
      if (manifestFile == null) {
        return _invalidPrepared('missing_manifest', temporaryDirectory);
      }
      final manifest = BackupManifest.fromJson(
        (jsonDecode(utf8.decode(manifestFile.content)) as Map<String, dynamic>)
            .cast<String, Object?>(),
      );
      final compatibilityError = _manifestCompatibilityError(manifest);
      if (compatibilityError != null) {
        return _invalidPrepared(compatibilityError, temporaryDirectory);
      }
      if (!manifest.entries.containsKey(databaseEntry) ||
          !manifest.entries.containsKey(preferencesEntry)) {
        return _invalidPrepared('missing_required_entry', temporaryDirectory);
      }

      final databaseFile = File(
        '${temporaryDirectory.path}${Platform.pathSeparator}audio_player.db',
      );
      Map<String, Object?>? preferences;
      for (final entry in manifest.entries.entries) {
        final archiveFile = archive.findFile(entry.key);
        if (archiveFile == null) {
          return _invalidPrepared(
            'missing_entry:${entry.key}',
            temporaryDirectory,
          );
        }
        if (entry.key == preferencesEntry) {
          final bytes = archiveFile.content;
          if (!_matchesManifest(
            bytes.length,
            sha256.convert(bytes),
            entry.value,
          )) {
            return _invalidPrepared(
              'checksum_mismatch:${entry.key}',
              temporaryDirectory,
            );
          }
          preferences = (jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>)
              .cast<String, Object?>();
          continue;
        }

        final extracted = entry.key == databaseEntry
            ? databaseFile
            : File(
                '${temporaryDirectory.path}${Platform.pathSeparator}'
                'entry_${entry.key.hashCode}.tmp',
              );
        await _extractArchiveFile(archiveFile, extracted);
        final matches = _matchesManifest(
          await extracted.length(),
          await _sha256Digest(extracted),
          entry.value,
        );
        if (!matches) {
          return _invalidPrepared(
            'checksum_mismatch:${entry.key}',
            temporaryDirectory,
          );
        }
        if (entry.key != databaseEntry && await extracted.exists()) {
          await extracted.delete();
        }
      }
      return _PreparedBackup(
        validation: BackupValidationResult.valid(manifest),
        temporaryDirectory: temporaryDirectory,
        databaseFile: databaseFile,
        preferences: preferences,
      );
    } catch (error, stackTrace) {
      AppLogService.warning(
        'backup_validation_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return _invalidPrepared('invalid_backup', temporaryDirectory);
    } finally {
      if (archive != null) {
        await archive.clear();
      } else if (input != null) {
        await input.close();
      }
    }
  }

  String? _manifestCompatibilityError(BackupManifest manifest) {
    if (manifest.formatVersion != formatVersion) {
      return 'unsupported_format_version';
    }
    if (manifest.dataEpoch != dataEpoch) return 'unsupported_data_epoch';
    if (manifest.databaseSchemaVersion > AppDatabase.schemaVersion) {
      return 'unsupported_database_version';
    }
    return null;
  }

  _PreparedBackup _invalidPrepared(String error, Directory? directory) {
    return _PreparedBackup(
      validation: BackupValidationResult.invalid(error),
      temporaryDirectory: directory,
    );
  }

  bool _matchesManifest(int size, Digest digest, BackupEntryManifest manifest) {
    return size == manifest.size && digest.toString() == manifest.sha256Hash;
  }

  Future<void> _copyFile(File source, File target) async {
    await target.parent.create(recursive: true);
    await source.openRead().pipe(target.openWrite());
  }

  Future<void> _extractArchiveFile(ArchiveFile source, File target) async {
    await target.parent.create(recursive: true);
    final output = OutputFileStream(target.path);
    try {
      source.writeContent(output);
    } finally {
      await output.close();
    }
  }

  Future<String> _sha256File(File file) async {
    return (await _sha256Digest(file)).toString();
  }

  Future<Digest> _sha256Digest(File file) async {
    return sha256.bind(file.openRead()).first;
  }
}
