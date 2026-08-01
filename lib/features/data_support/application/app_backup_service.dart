import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';

import '../../../core/immutable_collections.dart';
import '../../../core/media/local_library_import_sources.dart';
import '../../../core/persistence/app_database.dart';
import '../../../core/logging/app_log_service.dart';
import '../../settings/application/app_preferences.dart';
import '../../settings/application/app_update_service.dart';

class BackupManifest {
  BackupManifest({
    required this.formatVersion,
    required this.dataEpoch,
    required this.appVersion,
    required this.createdAt,
    required this.platform,
    required this.databaseSchemaVersion,
    required Map<String, BackupEntryManifest> entries,
  }) : entries = immutableMap(entries);

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
  BackupValidationResult._({
    required this.isValid,
    this.manifest,
    LocalLibraryImportSources? librarySources,
    this.error,
  }) : librarySources = librarySources ?? LocalLibraryImportSources();

  BackupValidationResult.valid(
    BackupManifest manifest, {
    LocalLibraryImportSources? librarySources,
  }) : this._(
         isValid: true,
         manifest: manifest,
         librarySources: librarySources,
       );

  BackupValidationResult.invalid(String error)
    : this._(isValid: false, error: error);

  BackupValidationResult.cancelled()
    : this._(isValid: false, error: 'restore_cancelled');

  final bool isValid;
  final BackupManifest? manifest;
  final LocalLibraryImportSources librarySources;
  final String? error;

  bool get isCancelled => error == 'restore_cancelled';
}

class _PreparedBackup {
  _PreparedBackup({
    required this.validation,
    this.temporaryDirectory,
    this.databaseFile,
    Map<String, Object?>? preferences,
    this.librarySources,
  }) : preferences = immutableJsonMap(preferences);

  final BackupValidationResult validation;
  final Directory? temporaryDirectory;
  final File? databaseFile;
  final Map<String, Object?>? preferences;
  final LocalLibraryImportSources? librarySources;

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
    Future<bool> Function(String path, int expectedSchemaVersion)?
    databaseValidator,
    Future<void> Function(String path)? databaseSanitizer,
    Future<List<String>> Function(String path)? manualFilePathReader,
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
       _databaseValidator =
           databaseValidator ??
           ((path, expectedSchemaVersion) =>
               (database ?? AppDatabase.instance).validateBackupDatabase(
                 path,
                 expectedSchemaVersion: expectedSchemaVersion,
               )),
       _databaseSanitizer =
           databaseSanitizer ??
           (database ?? AppDatabase.instance).sanitizeBackupDatabase,
       _manualFilePathReader =
           manualFilePathReader ??
           (database ?? AppDatabase.instance).readBackupManualFilePaths,
       _platformName = platformName ?? 'android';

  static const int formatVersion = 3;
  static const int _legacyPathImportFormatVersion = 2;
  static const int dataEpoch = 1;
  static const String databaseEntry = 'data/audio_player.db';
  static const String preferencesEntry = 'data/preferences.json';
  static const String librarySourcesEntry = 'data/local_library_sources.json';
  static const String manifestEntry = 'manifest.json';
  static const int maxBackupBytes = 1024 * 1024 * 1024;
  static const int maxManifestBytes = 256 * 1024;
  static const int maxPreferencesBytes = 4 * 1024 * 1024;
  static const int maxLibrarySourcesBytes = 4 * 1024 * 1024;
  static const int maxArchiveEntries = 4;
  static const int _maxCentralDirectoryBytes = 1024 * 1024;

  final Future<Map<String, Object>> Function() _exportPreferences;
  final Future<void> Function(Map<String, Object?> values) _restorePreferences;
  final Future<AppVersionInfo> Function() _appVersionProvider;
  final Future<String> Function() _databasePathProvider;
  final Future<void> Function() _closeDatabase;
  final Future<void> Function() _reopenDatabase;
  final Future<bool> Function(String path, int expectedSchemaVersion)
  _databaseValidator;
  final Future<void> Function(String path) _databaseSanitizer;
  final Future<List<String>> Function(String path) _manualFilePathReader;
  final String _platformName;
  final AppDatabase? _database;

  Future<T> _runDatabaseMaintenance<T>({
    required bool replacesDatabase,
    required Future<T> Function(String databasePath) action,
    Future<void> Function(String databasePath)? recover,
  }) async {
    final managedDatabase = _database;
    if (managedDatabase != null) {
      return managedDatabase.runExclusiveMaintenance<T>(
        replacesDatabase: replacesDatabase,
        action: action,
        recover: recover,
      );
    }
    final databasePath = await _databasePathProvider();
    await _closeDatabase();
    try {
      final result = await action(databasePath);
      await _reopenDatabase();
      return result;
    } catch (error, stackTrace) {
      try {
        if (recover != null) await recover(databasePath);
      } finally {
        await _reopenDatabase();
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<File> exportBackup(
    String outputPath, {
    LocalLibraryImportSources? librarySources,
  }) async {
    librarySources ??= LocalLibraryImportSources();
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
      await _databaseSanitizer(databaseSnapshot.path);
      final preferencesBytes = Uint8List.fromList(
        utf8.encode(
          jsonEncode(
            _withoutExcludedBackupPreferences(await _exportPreferences()),
          ),
        ),
      );
      final librarySourcesBytes = Uint8List.fromList(
        utf8.encode(jsonEncode(librarySources.toJson())),
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
          librarySourcesEntry: BackupEntryManifest(
            sha256Hash: sha256.convert(librarySourcesBytes).toString(),
            size: librarySourcesBytes.length,
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
          ArchiveFile.bytes(librarySourcesEntry, librarySourcesBytes),
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

  Future<BackupValidationResult> restoreBackup(
    String backupPath, {
    Future<LocalLibraryImportSources?> Function(LocalLibraryImportSources)?
    beforeCommit,
  }) async {
    final prepared = await _prepareBackup(backupPath);
    final validation = prepared.validation;
    if (!validation.isValid) {
      await prepared.dispose();
      return validation;
    }
    final preparedDatabase = prepared.databaseFile!;
    final preferences = prepared.preferences!;
    var librarySources = prepared.librarySources!;
    final originalPreferences = await _exportPreferences();
    File? rollbackFile;
    var originalMoved = false;
    var replacementInstalled = false;
    try {
      if (beforeCommit != null) {
        final preparedSources = await beforeCommit(librarySources);
        if (preparedSources == null) {
          return BackupValidationResult.cancelled();
        }
        librarySources = preparedSources;
      }
      final restoredResult = BackupValidationResult.valid(
        validation.manifest!,
        librarySources: librarySources,
      );
      final result = await _runDatabaseMaintenance<BackupValidationResult>(
        replacesDatabase: true,
        action: (databasePath) async {
          final databaseFile = File(databasePath);
          rollbackFile = File('$databasePath.restore-backup');
          final replacementFile = File('$databasePath.restore-new');
          if (await rollbackFile!.exists()) await rollbackFile!.delete();
          if (await replacementFile.exists()) await replacementFile.delete();
          if (await databaseFile.exists()) {
            await databaseFile.rename(rollbackFile!.path);
            originalMoved = true;
          }
          await _copyFile(preparedDatabase, replacementFile);
          await replacementFile.rename(databaseFile.path);
          replacementInstalled = true;
          await _restorePreferences(preferences);
          return restoredResult;
        },
        recover: (databasePath) async {
          final databaseFile = File(databasePath);
          final replacementFile = File('$databasePath.restore-new');
          if (replacementInstalled && await databaseFile.exists()) {
            await databaseFile.delete();
          }
          if (originalMoved && await rollbackFile!.exists()) {
            await rollbackFile!.rename(databaseFile.path);
          }
          if (await replacementFile.exists()) await replacementFile.delete();
          await _restorePreferences(originalPreferences);
        },
      );
      final committedRollback = rollbackFile;
      if (committedRollback != null && await committedRollback.exists()) {
        try {
          await committedRollback.delete();
        } catch (error, stackTrace) {
          AppLogService.warning(
            'backup_restore_rollback_cleanup_failed',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }
      return result;
    } catch (error, stackTrace) {
      AppLogService.error(
        'backup_restore_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return BackupValidationResult.invalid('restore_failed');
    } finally {
      await prepared.dispose();
    }
  }

  Future<_PreparedBackup> _prepareBackup(String backupPath) async {
    Directory? temporaryDirectory;
    InputFileStream? input;
    Archive? archive;
    try {
      final backupFile = File(backupPath);
      if (await backupFile.length() > maxBackupBytes) {
        return _invalidPrepared('backup_too_large', temporaryDirectory);
      }
      final zipPreflightError = await _preflightZip(backupFile);
      if (zipPreflightError != null) {
        return _invalidPrepared(zipPreflightError, temporaryDirectory);
      }
      temporaryDirectory = await Directory.systemTemp.createTemp(
        'nameless_audio_backup_restore_',
      );
      input = InputFileStream(backupPath);
      final archiveEntryNames = <String>{};
      String? duplicateEntryName;
      archive = ZipDecoder().decodeStream(
        input,
        verify: true,
        callback: (entry) {
          if (!archiveEntryNames.add(entry.name)) {
            duplicateEntryName ??= entry.name;
          }
        },
      );
      if (duplicateEntryName != null) {
        return _invalidPrepared('duplicate_entry', temporaryDirectory);
      }
      if (archiveEntryNames.length > maxArchiveEntries) {
        return _invalidPrepared('unexpected_entry', temporaryDirectory);
      }
      for (final entry in archive.files) {
        if (!entry.isFile || entry.isSymbolicLink) {
          return _invalidPrepared('unexpected_entry', temporaryDirectory);
        }
      }
      final manifestFile = archive.findFile(manifestEntry);
      if (manifestFile == null) {
        return _invalidPrepared('missing_manifest', temporaryDirectory);
      }
      if (manifestFile.size < 0 || manifestFile.size > maxManifestBytes) {
        return _invalidPrepared('backup_too_large', temporaryDirectory);
      }
      final extractionBudget = _BackupExtractionBudget(maxBackupBytes);
      final manifestBytes = _readArchiveFile(
        manifestFile,
        maxBytes: maxManifestBytes,
        budget: extractionBudget,
      );
      final manifest = BackupManifest.fromJson(
        (jsonDecode(utf8.decode(manifestBytes)) as Map<String, dynamic>)
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
      if (manifest.formatVersion >= formatVersion &&
          !manifest.entries.containsKey(librarySourcesEntry)) {
        return _invalidPrepared('missing_required_entry', temporaryDirectory);
      }

      final allowedDataEntries = <String>{
        databaseEntry,
        preferencesEntry,
        if (manifest.formatVersion >= _legacyPathImportFormatVersion)
          librarySourcesEntry,
      };
      if (manifest.entries.length > maxArchiveEntries - 1 ||
          manifest.entries.keys.any(
            (entryName) => !allowedDataEntries.contains(entryName),
          )) {
        return _invalidPrepared('unexpected_entry', temporaryDirectory);
      }
      final expectedArchiveEntries = <String>{
        manifestEntry,
        ...manifest.entries.keys,
      };
      if (archiveEntryNames.length != expectedArchiveEntries.length ||
          !archiveEntryNames.containsAll(expectedArchiveEntries)) {
        return _invalidPrepared('unexpected_entry', temporaryDirectory);
      }

      var declaredTotalBytes = manifestBytes.length;
      for (final manifestEntry in manifest.entries.entries) {
        final declaredSize = manifestEntry.value.size;
        if (declaredSize < 0 ||
            declaredTotalBytes > maxBackupBytes - declaredSize) {
          return _invalidPrepared('backup_too_large', temporaryDirectory);
        }
        declaredTotalBytes += declaredSize;
        final archiveFile = archive.findFile(manifestEntry.key);
        if (archiveFile == null) {
          return _invalidPrepared(
            'missing_entry:${manifestEntry.key}',
            temporaryDirectory,
          );
        }
        if (archiveFile.size != declaredSize) {
          return _invalidPrepared(
            'checksum_mismatch:${manifestEntry.key}',
            temporaryDirectory,
          );
        }
      }

      final preferencesSize = manifest.entries[preferencesEntry]!.size;
      if (preferencesSize > maxPreferencesBytes) {
        return _invalidPrepared('backup_too_large', temporaryDirectory);
      }
      final librarySourcesSize = manifest.entries[librarySourcesEntry]?.size;
      if (librarySourcesSize != null &&
          librarySourcesSize > maxLibrarySourcesBytes) {
        return _invalidPrepared('backup_too_large', temporaryDirectory);
      }

      final databaseFile = File(
        '${temporaryDirectory.path}${Platform.pathSeparator}audio_player.db',
      );
      Map<String, Object?>? preferences;
      LocalLibraryImportSources? librarySources;
      for (final entry in manifest.entries.entries) {
        final archiveFile = archive.findFile(entry.key);
        if (archiveFile == null) {
          return _invalidPrepared(
            'missing_entry:${entry.key}',
            temporaryDirectory,
          );
        }
        if (entry.key == preferencesEntry) {
          final bytes = _readArchiveFile(
            archiveFile,
            maxBytes: entry.value.size,
            budget: extractionBudget,
          );
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
        if (entry.key == librarySourcesEntry) {
          final bytes = _readArchiveFile(
            archiveFile,
            maxBytes: entry.value.size,
            budget: extractionBudget,
          );
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
          librarySources = LocalLibraryImportSources.fromJson(
            jsonDecode(utf8.decode(bytes)),
          );
          continue;
        }

        final extracted = entry.key == databaseEntry
            ? databaseFile
            : File(
                '${temporaryDirectory.path}${Platform.pathSeparator}'
                'entry_${entry.key.hashCode}.tmp',
              );
        await _extractArchiveFile(
          archiveFile,
          extracted,
          maxBytes: entry.value.size,
          budget: extractionBudget,
        );
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
      final validDatabase = await _databaseValidator(
        databaseFile.path,
        manifest.databaseSchemaVersion,
      );
      if (!validDatabase) {
        return _invalidPrepared('invalid_database', temporaryDirectory);
      }
      final restoredPreferences = preferences;
      if (restoredPreferences == null) {
        return _invalidPrepared('missing_required_entry', temporaryDirectory);
      }
      librarySources ??= LocalLibraryImportSources(
        libraries: _preferencePaths(
          restoredPreferences,
          'watched_libraries_v1',
        ),
        folders: _preferencePaths(restoredPreferences, 'watched_folders_v1'),
        files: await _manualFilePathReader(databaseFile.path),
      );
      final sanitizedPreferences = _withoutExcludedBackupPreferences(
        restoredPreferences,
      );
      await _databaseSanitizer(databaseFile.path);
      return _PreparedBackup(
        validation: BackupValidationResult.valid(
          manifest,
          librarySources: librarySources,
        ),
        temporaryDirectory: temporaryDirectory,
        databaseFile: databaseFile,
        preferences: sanitizedPreferences,
        librarySources: librarySources,
      );
    } on _BackupValidationException catch (error, stackTrace) {
      AppLogService.warning(
        'backup_validation_rejected',
        error: error,
        stackTrace: stackTrace,
      );
      return _invalidPrepared(error.code, temporaryDirectory);
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
      }
      if (input != null) {
        await input.close();
      }
    }
  }

  String? _manifestCompatibilityError(BackupManifest manifest) {
    if (manifest.formatVersion != formatVersion &&
        manifest.formatVersion != _legacyPathImportFormatVersion) {
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

  Future<String?> _preflightZip(File file) async {
    final fileLength = await file.length();
    const maximumEndRecordLength = 65535 + 22;
    final start = fileLength > maximumEndRecordLength
        ? fileLength - maximumEndRecordLength
        : 0;
    final tail = await file
        .openRead(start)
        .fold<List<int>>(<int>[], (bytes, chunk) => bytes..addAll(chunk));
    int? endRecordOffset;
    for (var index = tail.length - 22; index >= 0; index--) {
      if (tail[index] != 0x50 ||
          tail[index + 1] != 0x4b ||
          tail[index + 2] != 0x05 ||
          tail[index + 3] != 0x06) {
        continue;
      }
      final commentLength = _uint16(tail, index + 20);
      if (index + 22 + commentLength != tail.length) continue;
      endRecordOffset = index;
      break;
    }
    if (endRecordOffset == null) return 'invalid_backup';

    final diskNumber = _uint16(tail, endRecordOffset + 4);
    final centralDirectoryDisk = _uint16(tail, endRecordOffset + 6);
    final entriesOnDisk = _uint16(tail, endRecordOffset + 8);
    final entryCount = _uint16(tail, endRecordOffset + 10);
    final centralDirectorySize = _uint32(tail, endRecordOffset + 12);
    final centralDirectoryOffset = _uint32(tail, endRecordOffset + 16);
    if (diskNumber != 0 ||
        centralDirectoryDisk != 0 ||
        entriesOnDisk != entryCount ||
        entryCount == 0xffff ||
        centralDirectorySize == 0xffffffff ||
        centralDirectoryOffset == 0xffffffff) {
      return 'invalid_backup';
    }
    if (entryCount > maxArchiveEntries) return 'unexpected_entry';
    if (centralDirectorySize > _maxCentralDirectoryBytes) {
      return 'unexpected_entry';
    }
    final absoluteEndRecordOffset = start + endRecordOffset;
    if (centralDirectoryOffset > absoluteEndRecordOffset ||
        centralDirectorySize >
            absoluteEndRecordOffset - centralDirectoryOffset ||
        centralDirectoryOffset + centralDirectorySize !=
            absoluteEndRecordOffset) {
      return 'invalid_backup';
    }

    RandomAccessFile? input;
    try {
      input = await file.open();
      await input.setPosition(centralDirectoryOffset);
      final centralDirectory = await input.read(centralDirectorySize);
      if (centralDirectory.length != centralDirectorySize) {
        return 'invalid_backup';
      }
      final names = <String>{};
      final entries = <_ZipPreflightEntry>[];
      var offset = 0;
      var expandedBytes = 0;
      for (var index = 0; index < entryCount; index++) {
        if (offset > centralDirectory.length - 46 ||
            _uint32(centralDirectory, offset) != 0x02014b50) {
          return 'invalid_backup';
        }
        final versionMadeBy = _uint16(centralDirectory, offset + 4);
        final flags = _uint16(centralDirectory, offset + 8);
        final compression = _uint16(centralDirectory, offset + 10);
        final compressedSize = _uint32(centralDirectory, offset + 20);
        final uncompressedSize = _uint32(centralDirectory, offset + 24);
        final nameLength = _uint16(centralDirectory, offset + 28);
        final extraLength = _uint16(centralDirectory, offset + 30);
        final commentLength = _uint16(centralDirectory, offset + 32);
        final diskStart = _uint16(centralDirectory, offset + 34);
        final externalAttributes = _uint32(centralDirectory, offset + 38);
        final localHeaderOffset = _uint32(centralDirectory, offset + 42);
        final variableLength = nameLength + extraLength + commentLength;
        if (variableLength > centralDirectory.length - offset - 46 ||
            nameLength == 0 ||
            diskStart != 0 ||
            flags & 1 != 0 ||
            (compression != 0 && compression != 8) ||
            compressedSize == 0xffffffff ||
            uncompressedSize == 0xffffffff ||
            localHeaderOffset == 0xffffffff) {
          return 'invalid_backup';
        }
        final nameBytes = centralDirectory.sublist(
          offset + 46,
          offset + 46 + nameLength,
        );
        if (nameBytes.any((byte) => byte > 0x7f)) return 'unexpected_entry';
        final name = String.fromCharCodes(nameBytes);
        if (!_allowedArchiveEntries.contains(name) ||
            name.endsWith('/') ||
            name.endsWith(r'\')) {
          return 'unexpected_entry';
        }
        if (!names.add(name)) return 'duplicate_entry';
        final creatorSystem = versionMadeBy >> 8;
        final unixFileType = (externalAttributes >> 16) & 0xf000;
        if (creatorSystem == 3 &&
            (unixFileType == 0x4000 || unixFileType == 0xa000)) {
          return 'unexpected_entry';
        }
        final entryLimit = switch (name) {
          manifestEntry => maxManifestBytes,
          preferencesEntry => maxPreferencesBytes,
          librarySourcesEntry => maxLibrarySourcesBytes,
          _ => maxBackupBytes,
        };
        if (uncompressedSize > entryLimit ||
            expandedBytes > maxBackupBytes - uncompressedSize) {
          return 'backup_too_large';
        }
        expandedBytes += uncompressedSize;
        entries.add(
          _ZipPreflightEntry(
            name: name,
            flags: flags,
            compression: compression,
            compressedSize: compressedSize,
            uncompressedSize: uncompressedSize,
            localHeaderOffset: localHeaderOffset,
          ),
        );
        offset += 46 + variableLength;
      }
      if (offset != centralDirectory.length) return 'invalid_backup';

      for (final entry in entries) {
        if (entry.localHeaderOffset > centralDirectoryOffset - 30) {
          return 'invalid_backup';
        }
        await input.setPosition(entry.localHeaderOffset);
        final localHeader = await input.read(30);
        if (localHeader.length != 30 || _uint32(localHeader, 0) != 0x04034b50) {
          return 'invalid_backup';
        }
        final localFlags = _uint16(localHeader, 6);
        final localCompression = _uint16(localHeader, 8);
        final localCompressedSize = _uint32(localHeader, 18);
        final localUncompressedSize = _uint32(localHeader, 22);
        final localNameLength = _uint16(localHeader, 26);
        final localExtraLength = _uint16(localHeader, 28);
        if (localFlags != entry.flags ||
            localCompression != entry.compression ||
            localNameLength == 0) {
          return 'invalid_backup';
        }
        final localNameBytes = await input.read(localNameLength);
        if (localNameBytes.length != localNameLength ||
            String.fromCharCodes(localNameBytes) != entry.name) {
          return 'invalid_backup';
        }
        final usesDataDescriptor = entry.flags & 0x8 != 0;
        if (!usesDataDescriptor &&
            (localCompressedSize != entry.compressedSize ||
                localUncompressedSize != entry.uncompressedSize)) {
          return 'invalid_backup';
        }
        final dataOffset =
            entry.localHeaderOffset + 30 + localNameLength + localExtraLength;
        if (dataOffset > centralDirectoryOffset ||
            entry.compressedSize > centralDirectoryOffset - dataOffset) {
          return 'invalid_backup';
        }
      }
      return null;
    } finally {
      await input?.close();
    }
  }

  static const Set<String> _allowedArchiveEntries = <String>{
    manifestEntry,
    databaseEntry,
    preferencesEntry,
    librarySourcesEntry,
  };

  int _uint16(List<int> bytes, int offset) {
    return bytes[offset] | bytes[offset + 1] << 8;
  }

  int _uint32(List<int> bytes, int offset) {
    return _uint16(bytes, offset) | _uint16(bytes, offset + 2) << 16;
  }

  Uint8List _readArchiveFile(
    ArchiveFile source, {
    required int maxBytes,
    required _BackupExtractionBudget budget,
  }) {
    final output = OutputMemoryStream(size: source.size.clamp(0, maxBytes));
    final limitedOutput = _LimitedOutputStream(
      output,
      maxBytes: maxBytes,
      budget: budget,
    );
    source.writeContent(limitedOutput);
    return output.getBytes();
  }

  Future<void> _extractArchiveFile(
    ArchiveFile source,
    File target, {
    required int maxBytes,
    required _BackupExtractionBudget budget,
  }) async {
    await target.parent.create(recursive: true);
    final output = OutputFileStream(target.path);
    final limitedOutput = _LimitedOutputStream(
      output,
      maxBytes: maxBytes,
      budget: budget,
    );
    try {
      source.writeContent(limitedOutput);
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

final class _ZipPreflightEntry {
  const _ZipPreflightEntry({
    required this.name,
    required this.flags,
    required this.compression,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.localHeaderOffset,
  });

  final String name;
  final int flags;
  final int compression;
  final int compressedSize;
  final int uncompressedSize;
  final int localHeaderOffset;
}

final class _BackupValidationException implements Exception {
  const _BackupValidationException(this.code);

  final String code;

  @override
  String toString() => code;
}

final class _BackupExtractionBudget {
  _BackupExtractionBudget(this.maxBytes);

  final int maxBytes;
  int _writtenBytes = 0;

  void reserve(int byteCount) {
    if (byteCount < 0 || _writtenBytes > maxBytes - byteCount) {
      throw const _BackupValidationException('backup_too_large');
    }
    _writtenBytes += byteCount;
  }
}

final class _LimitedOutputStream extends OutputStream {
  _LimitedOutputStream(
    this._delegate, {
    required this.maxBytes,
    required this.budget,
  }) : super(byteOrder: _delegate.byteOrder);

  final OutputStream _delegate;
  final int maxBytes;
  final _BackupExtractionBudget budget;
  int _writtenBytes = 0;

  void _reserve(int byteCount) {
    if (byteCount < 0 || _writtenBytes > maxBytes - byteCount) {
      throw const _BackupValidationException('backup_too_large');
    }
    budget.reserve(byteCount);
    _writtenBytes += byteCount;
  }

  @override
  int get length => _delegate.length;

  @override
  bool get isOpen => _delegate.isOpen;

  @override
  void clear() => _delegate.clear();

  @override
  Future<void> close() => _delegate.close();

  @override
  void closeSync() => _delegate.closeSync();

  @override
  void flush() => _delegate.flush();

  @override
  void writeByte(int value) {
    _reserve(1);
    _delegate.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final byteCount = length ?? bytes.length;
    _reserve(byteCount);
    _delegate.writeBytes(bytes, length: byteCount);
  }

  @override
  void writeStream(InputStream stream) {
    _reserve(stream.length);
    _delegate.writeStream(stream);
  }

  @override
  Uint8List subset(int start, [int? end]) => _delegate.subset(start, end);
}

const Set<String> _localLibraryPreferenceKeys = <String>{
  'watched_folders_v1',
  'watched_libraries_v1',
  'library_node_order_v1',
  'group_order_v1',
  'library_exclusions_v1',
};

Map<String, Object?> _withoutExcludedBackupPreferences(
  Map<String, Object?> values,
) {
  return <String, Object?>{
    for (final entry in values.entries)
      if (!_localLibraryPreferenceKeys.contains(entry.key))
        entry.key: entry.value,
  };
}

List<String> _preferencePaths(Map<String, Object?> preferences, String key) {
  final value = preferences[key];
  if (value is List) return _distinctPaths(value.whereType<String>());
  if (value is! String || value.trim().isEmpty) return const <String>[];
  try {
    final decoded = jsonDecode(value);
    return decoded is Iterable
        ? _distinctPaths(decoded.whereType<String>())
        : const <String>[];
  } catch (_) {
    return const <String>[];
  }
}

List<String> _distinctPaths(Iterable<String> values) {
  final paths = <String>[];
  final seen = <String>{};
  for (final raw in values) {
    final value = raw.trim();
    if (value.isEmpty || !seen.add(value)) continue;
    paths.add(value);
  }
  return List<String>.unmodifiable(paths);
}
