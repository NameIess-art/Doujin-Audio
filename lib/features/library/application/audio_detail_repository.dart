import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../../core/media/audio_detail.dart';
import '../../../infrastructure/sqlite/sqlite_library_repository.dart';
import '../domain/library_persistence_repository.dart';
import '../../../core/persistence/app_database.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/platform/file_cache_platform_gateway.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/media/path_display.dart';
import 'cover_image_cache_policy.dart';

class AudioDetailLoadResult {
  const AudioDetailLoadResult({required this.detail});

  final AudioDetail detail;
}

class AudioDetailSaveResult {
  const AudioDetailSaveResult({
    required this.detail,
    required this.backupAttempted,
    required this.backupSaved,
    this.coverPortabilitySkipped = false,
    this.backupError,
    this.backupRetryAt,
  });

  final AudioDetail detail;
  final bool backupAttempted;
  final bool backupSaved;
  final bool coverPortabilitySkipped;
  final Object? backupError;
  final DateTime? backupRetryAt;

  bool get backupFailed => backupAttempted && !backupSaved;
}

class AudioDetailBackupImportResult {
  const AudioDetailBackupImportResult({
    this.changedDetails = const <AudioDetail>[],
    this.importedCount = 0,
    this.mirroredCount = 0,
    this.failureCount = 0,
    this.nextRetryAt,
  });

  final List<AudioDetail> changedDetails;
  final int importedCount;
  final int mirroredCount;
  final int failureCount;
  final DateTime? nextRetryAt;
}

class AudioDetailBackupSyncFlushResult {
  const AudioDetailBackupSyncFlushResult({
    this.succeededCount = 0,
    this.failedCount = 0,
    this.nextRetryAt,
  });

  final int succeededCount;
  final int failedCount;
  final DateTime? nextRetryAt;
}

enum AudioDetailSaveOrigin { user, automatic }

final class AudioDetailOperationCancelled implements Exception {
  const AudioDetailOperationCancelled();
}

final Object _audioDetailCommitGuardZoneKey = Object();

class AudioDetailRepository {
  AudioDetailRepository({
    LibraryPersistenceRepository? databaseRepository,
    FileCachePlatformGateway? fileCacheGateway,
    DateTime Function()? now,
    Future<Directory> Function()? portableCoverDirectory,
  }) : _databaseRepository =
           databaseRepository ??
           SqliteLibraryRepository(database: AppDatabase.instance),
       _fileCacheGateway =
           fileCacheGateway ?? FileCachePlatformGateway.instance,
       _now = now ?? DateTime.now,
       _portableCoverDirectory =
           portableCoverDirectory ?? _defaultPortableCoverDirectory;

  static const backupFileName = 'nameless-audio.json';
  static const _cardCoverRelativePathKey = 'cardCoverRelativePath';
  static const _cardCoverEmbeddedKey = 'cardCoverEmbedded';
  final LibraryPersistenceRepository _databaseRepository;
  final FileCachePlatformGateway _fileCacheGateway;
  final DateTime Function() _now;
  final Future<Directory> Function() _portableCoverDirectory;
  final Map<String, Future<void>> _backupSourceTails = <String, Future<void>>{};

  static Future<T> runWithCommitGuard<T>(
    bool Function() canCommit,
    Future<T> Function() operation,
  ) {
    return runZoned(
      operation,
      zoneValues: <Object, Object>{_audioDetailCommitGuardZoneKey: canCommit},
    );
  }

  bool get _canCommit {
    final guard = Zone.current[_audioDetailCommitGuardZoneKey];
    return guard is! bool Function() || guard();
  }

  void _ensureCanCommit() {
    if (!_canCommit) throw const AudioDetailOperationCancelled();
  }

  static Future<Directory> _defaultPortableCoverDirectory() async {
    final supportDirectory = await getApplicationSupportDirectory();
    return Directory(path.join(supportDirectory.path, 'portable_card_covers'));
  }

  Future<AudioDetailLoadResult> load(AudioDetailTarget target) async {
    final normalizedTarget = _normalizeTarget(target);
    final databaseDetail = await _databaseRepository.loadAudioDetail(
      normalizedTarget,
    );
    return AudioDetailLoadResult(
      detail: databaseDetail ?? AudioDetail.empty(normalizedTarget),
    );
  }

  Future<List<AudioDetailLoadResult>> loadMany(
    Iterable<AudioDetailTarget> targets,
  ) async {
    final normalizedTargets = targets
        .map(_normalizeTarget)
        .toList(growable: false);
    if (normalizedTargets.isEmpty) return const <AudioDetailLoadResult>[];

    final targetsByKey = <String, AudioDetailTarget>{
      for (final target in normalizedTargets)
        _detailKeyForTarget(target): target,
    };
    final loadedDatabaseDetails = await _databaseRepository.loadAudioDetails(
      targetsByKey.values,
    );
    final databaseDetailsByKey = <String, AudioDetail>{
      for (final detail in loadedDatabaseDetails)
        _detailKeyForTarget(detail.target): detail,
    };
    return <AudioDetailLoadResult>[
      for (final target in normalizedTargets)
        AudioDetailLoadResult(
          detail:
              databaseDetailsByKey[_detailKeyForTarget(target)] ??
              AudioDetail.empty(target),
        ),
    ];
  }

  Future<AudioDetailSaveResult> save(
    AudioDetail detail, {
    AudioDetailSaveOrigin origin = AudioDetailSaveOrigin.user,
  }) async {
    var candidate = detail.copyWith(target: _normalizeTarget(detail.target));
    if (origin == AudioDetailSaveOrigin.automatic) {
      await importBackupsMany(<AudioDetailTarget>[candidate.target]);
      _ensureCanCommit();
      final current = (await load(candidate.target)).detail;
      candidate = await _mergePreferredDetail(current, candidate);
    }
    _ensureCanCommit();
    var normalized = candidate.normalizedForSave(_now());
    final persistedCover = await _persistDerivedCover(normalized);
    normalized = persistedCover.detail;
    final coverPortabilitySkipped = persistedCover.portabilitySkipped;
    _ensureCanCommit();
    final task = await _databaseRepository
        .upsertAudioDetailAndEnqueueBackupSync(normalized);
    try {
      _ensureCanCommit();
      await _writeBackupDetailsForSource(<AudioDetail>[normalized]);
      await _databaseRepository.deleteAudioDetailBackupSyncTask(
        task.target,
        generation: task.generation,
      );
      return AudioDetailSaveResult(
        detail: normalized,
        backupAttempted: true,
        backupSaved: true,
        coverPortabilitySkipped: coverPortabilitySkipped,
      );
    } on AudioDetailOperationCancelled {
      rethrow;
    } catch (error) {
      final retryAt = await _recordSyncFailure(task, error);
      return AudioDetailSaveResult(
        detail: normalized,
        backupAttempted: true,
        backupSaved: false,
        coverPortabilitySkipped: coverPortabilitySkipped,
        backupError: error,
        backupRetryAt: retryAt,
      );
    }
  }

  Future<AudioDetailBackupImportResult> importBackupsMany(
    Iterable<AudioDetailTarget> targets,
  ) async {
    final normalizedByKey = <String, AudioDetailTarget>{};
    for (final target in targets.map(_normalizeTarget)) {
      normalizedByKey[_detailKeyForTarget(target)] = target;
    }
    if (normalizedByKey.isEmpty) {
      return const AudioDetailBackupImportResult();
    }
    return AppLogService.measureAsync(
      'audio_detail_backup_import',
      () async {
        final groups = <String, List<AudioDetailTarget>>{};
        for (final target in normalizedByKey.values) {
          groups.putIfAbsent(_backupSourceKey(target), () => []).add(target);
        }
        final changed = <AudioDetail>[];
        var importedCount = 0;
        var failureCount = 0;
        for (final entry in groups.entries) {
          try {
            final result = await _runBackupSourceSerialized(
              entry.value.first,
              () => _importBackupSource(entry.value),
            );
            changed.addAll(result.changedDetails);
            importedCount += result.importedCount;
            failureCount += result.failureCount;
          } catch (error, stackTrace) {
            failureCount += entry.value.length;
            AppLogService.warning(
              'audio_detail_backup_import_source_failed',
              error: error,
              stackTrace: stackTrace,
            );
          }
        }
        final flush = await flushPendingBackupSync();
        return AudioDetailBackupImportResult(
          changedDetails: List<AudioDetail>.unmodifiable(changed),
          importedCount: importedCount,
          mirroredCount: flush.succeededCount,
          failureCount: failureCount + flush.failedCount,
          nextRetryAt: flush.nextRetryAt,
        );
      },
      details: <String, Object?>{'targets': normalizedByKey.length},
    );
  }

  Future<AudioDetailBackupSyncFlushResult> flushPendingBackupSync() {
    return AppLogService.measureAsync(
      'audio_detail_backup_sync_flush',
      () async {
        final now = _now();
        final tasks = await _databaseRepository
            .loadDueAudioDetailBackupSyncTasks(
              nowMs: now.millisecondsSinceEpoch,
            );
        if (tasks.isEmpty) {
          final nextAt = await _databaseRepository
              .loadNextAudioDetailBackupSyncAtMs();
          return AudioDetailBackupSyncFlushResult(
            nextRetryAt: nextAt == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(nextAt),
          );
        }

        final groups = <String, List<AudioDetailBackupSyncTask>>{};
        for (final task in tasks) {
          groups.putIfAbsent(_backupSourceKey(task.target), () => []).add(task);
        }
        var succeeded = 0;
        var failed = 0;
        for (final groupedTasks in groups.values) {
          final outcome = await _runBackupSourceSerialized(
            groupedTasks.first.target,
            () => _flushBackupSourceTasks(
              groupedTasks,
              nowMs: now.millisecondsSinceEpoch,
            ),
          );
          succeeded += outcome.succeeded;
          failed += outcome.failed;
        }
        final nextAt = await _databaseRepository
            .loadNextAudioDetailBackupSyncAtMs();
        return AudioDetailBackupSyncFlushResult(
          succeededCount: succeeded,
          failedCount: failed,
          nextRetryAt: nextAt == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(nextAt),
        );
      },
    );
  }

  Future<({int succeeded, int failed})> _flushBackupSourceTasks(
    List<AudioDetailBackupSyncTask> requestedTasks, {
    required int nowMs,
  }) async {
    final requestedKeys = requestedTasks
        .map((task) => _detailKeyForTarget(task.target))
        .toSet();
    final currentTasks =
        (await _databaseRepository.loadDueAudioDetailBackupSyncTasks(
              nowMs: nowMs,
            ))
            .where(
              (task) =>
                  requestedKeys.contains(_detailKeyForTarget(task.target)) &&
                  _backupSourceKey(task.target) ==
                      _backupSourceKey(requestedTasks.first.target),
            )
            .toList(growable: false);
    if (currentTasks.isEmpty) return (succeeded: 0, failed: 0);

    final details = await _databaseRepository.loadAudioDetails(
      currentTasks.map((task) => task.target),
    );
    final detailsByKey = <String, AudioDetail>{
      for (final detail in details) _detailKeyForTarget(detail.target): detail,
    };
    final writableTasks = <AudioDetailBackupSyncTask>[];
    final writableDetails = <AudioDetail>[];
    var succeeded = 0;
    for (final task in currentTasks) {
      final detail = detailsByKey[_detailKeyForTarget(task.target)];
      if (detail == null) {
        if (await _databaseRepository.deleteAudioDetailBackupSyncTask(
          task.target,
          generation: task.generation,
        )) {
          succeeded++;
        }
        continue;
      }
      writableTasks.add(task);
      writableDetails.add(detail);
    }
    if (writableTasks.isEmpty) return (succeeded: succeeded, failed: 0);

    try {
      await _writeBackupDetailsForSourceUnlocked(writableDetails);
      for (final task in writableTasks) {
        if (await _databaseRepository.deleteAudioDetailBackupSyncTask(
          task.target,
          generation: task.generation,
        )) {
          succeeded++;
        }
      }
      return (succeeded: succeeded, failed: 0);
    } catch (error, stackTrace) {
      for (final task in writableTasks) {
        await _recordSyncFailure(task, error);
      }
      AppLogService.warning(
        'audio_detail_backup_sync_source_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return (succeeded: succeeded, failed: writableTasks.length);
    }
  }

  Future<void> removeBackupMirror(AudioDetailTarget target) async {
    final normalized = _normalizeTarget(target);
    if (normalized.isLibraryRootFolder) return;
    await _runBackupSourceSerialized(normalized, () async {
      final raw = await _readSingleFileBackupJson(normalized);
      if (raw == null) return;
      final decoded = json.decode(raw);
      if (decoded is! List) {
        throw const FormatException('Shared audio detail backup is invalid.');
      }
      final entries = _stringKeyedMapList(decoded);
      final index = _singleFileBackupEntryIndex(normalized, entries);
      if (index < 0) return;
      entries.removeAt(index);
      final payload = const JsonEncoder.withIndent('  ').convert(entries);
      _ensureCanCommit();
      if (PathMatcher.isContentUri(normalized.targetPath)) {
        final saved = await _fileCacheGateway.writeSingleFileDetailBackup(
          filePath: normalized.targetPath,
          json: payload,
        );
        if (!saved) {
          throw const FileSystemException(
            'Single-file content backup was not saved.',
          );
        }
      } else {
        await _writeFileAtomically(
          _singleDirBackupFile(normalized.targetPath),
          payload,
        );
      }
    });
  }

  Future<AudioDetailBackupImportResult> _importBackupSource(
    List<AudioDetailTarget> targets,
  ) async {
    final first = targets.first;
    final raw = first.isLibraryRootFolder
        ? await _readFolderBackupJson(first)
        : await _readSingleFileBackupJson(first);
    Map<String, dynamic>? folderBackup;
    _SingleFileBackupIndex? singleFileIndex;
    if (raw != null) {
      if (raw.trim().isEmpty) {
        throw const FormatException('Audio detail backup is empty.');
      }
      final decoded = json.decode(raw);
      if (first.isLibraryRootFolder) {
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('Folder audio detail backup is invalid.');
        }
        folderBackup = decoded;
      } else {
        if (decoded is! List) {
          throw const FormatException('Shared audio detail backup is invalid.');
        }
        singleFileIndex = _SingleFileBackupIndex(_stringKeyedMapList(decoded));
      }
    }

    final databaseDetails = await _databaseRepository.loadAudioDetails(targets);
    final databaseByKey = <String, AudioDetail>{
      for (final detail in databaseDetails)
        _detailKeyForTarget(detail.target): detail,
    };
    final changed = <AudioDetail>[];
    final mirrorTargets = <AudioDetailTarget>[];
    for (final target in targets) {
      final databaseDetail = databaseByKey[_detailKeyForTarget(target)];
      final backupDetail = first.isLibraryRootFolder
          ? await _detailFromFolderBackup(target, folderBackup)
          : await _detailFromSingleFileIndex(target, singleFileIndex);
      if (backupDetail == null) {
        if (databaseDetail != null) mirrorTargets.add(target);
        continue;
      }
      if (databaseDetail == null ||
          _shouldPreferBackup(databaseDetail, backupDetail)) {
        final imported = databaseDetail == null
            ? _normalizeImportedDetail(backupDetail)
            : _normalizeImportedDetail(
                await _mergePreferredDetail(backupDetail, databaseDetail),
              );
        changed.add(imported);
        continue;
      }
      final merged = await _restoreMissingDatabaseCoverFromBackup(
        await _mergePreferredDetail(databaseDetail, backupDetail),
        backupDetail,
      );
      if (_metadataScore(merged) > _metadataScore(databaseDetail) ||
          merged.cardCoverPath != databaseDetail.cardCoverPath ||
          merged.cardCoverSelected != databaseDetail.cardCoverSelected) {
        changed.add(_normalizeImportedDetail(merged));
      }
      mirrorTargets.add(target);
    }
    _ensureCanCommit();
    await _databaseRepository.upsertAudioDetails(changed);
    for (final target in mirrorTargets) {
      _ensureCanCommit();
      await _databaseRepository.enqueueAudioDetailBackupSync(target);
    }
    return AudioDetailBackupImportResult(
      changedDetails: List<AudioDetail>.unmodifiable(changed),
      importedCount: changed.length,
    );
  }

  AudioDetail _normalizeImportedDetail(AudioDetail detail) {
    final updatedAt = detail.updatedAt;
    final createdAt = detail.createdAt;
    final normalized = detail.normalizedForSave(_now());
    return normalized.copyWith(
      createdAt: createdAt ?? normalized.createdAt,
      updatedAt: updatedAt ?? normalized.updatedAt,
    );
  }

  Future<DateTime> _recordSyncFailure(
    AudioDetailBackupSyncTask task,
    Object error,
  ) async {
    const delays = <Duration>[
      Duration(seconds: 5),
      Duration(seconds: 30),
      Duration(minutes: 2),
      Duration(minutes: 10),
      Duration(hours: 1),
    ];
    final delay = delays[task.attemptCount.clamp(0, delays.length - 1)];
    final message = error.toString();
    final retryAt = _now().add(delay);
    await _databaseRepository.recordAudioDetailBackupSyncFailure(
      task,
      nextAttemptAtMs: retryAt.millisecondsSinceEpoch,
      error: message.length <= 1000 ? message : message.substring(0, 1000),
    );
    return retryAt;
  }

  Future<void> delete(AudioDetailTarget target) {
    _ensureCanCommit();
    return _databaseRepository.deleteAudioDetail(_normalizeTarget(target));
  }

  Future<void> deleteMany(Iterable<AudioDetailTarget> targets) {
    _ensureCanCommit();
    return _databaseRepository.deleteAudioDetails(
      targets.map(_normalizeTarget),
    );
  }

  Future<AudioDetailSaveResult?> prefillRjCodeFromText(
    AudioDetailTarget target,
    String text,
  ) async {
    final rjCode = AudioDetail.findRjCodeInText(text);
    if (rjCode == null) return null;

    final result = await load(target);
    if (result.detail.rjCode.trim().isNotEmpty) return null;

    return save(
      result.detail.copyWith(rjCode: rjCode),
      origin: AudioDetailSaveOrigin.automatic,
    );
  }

  // ---------------------------------------------------------------------------
  // Single-file backup helpers
  // ---------------------------------------------------------------------------

  /// Returns the directory that contains [audioFilePath].
  String _dirOf(String audioFilePath) => path.dirname(audioFilePath);

  /// The shared backup file for all standalone audio files in the same
  /// directory as [audioFilePath].
  File _singleDirBackupFile(String audioFilePath) {
    return File(path.join(_dirOf(audioFilePath), backupFileName));
  }

  /// Reads the array-format backup file for the directory containing
  /// [audioFilePath] and returns the entry whose targetPath matches, or null.
  Future<String?> _readSingleFileBackupJson(AudioDetailTarget target) async {
    if (PathMatcher.isContentUri(target.targetPath)) {
      return _fileCacheGateway.readSingleFileDetailBackup(target.targetPath);
    }
    final backupFile = _singleDirBackupFile(target.targetPath);
    if (!await backupFile.exists()) return null;
    return backupFile.readAsString();
  }

  /// Parses [raw] JSON and returns the entry whose
  /// targetPath matches [target.targetPath], or null.
  /// Writes [detail] into the shared `nameless-audio.json` in the same
  /// directory as the audio file, updating the matching entry or appending.
  Future<void> _writeBackupDetailsForSource(List<AudioDetail> details) {
    if (details.isEmpty) return Future<void>.value();
    return _runBackupSourceSerialized(
      details.first.target,
      () => _writeBackupDetailsForSourceUnlocked(details),
    );
  }

  Future<void> _writeBackupDetailsForSourceUnlocked(
    List<AudioDetail> details,
  ) async {
    final first = details.first;
    final sourceKey = _backupSourceKey(first.target);
    if (details.any((detail) => _backupSourceKey(detail.target) != sourceKey)) {
      throw ArgumentError('Audio detail backups must share one source.');
    }
    if (first.target.isLibraryRootFolder) {
      final existing = await _readFolderBackupJson(first.target);
      if (existing != null && json.decode(existing) is! Map<String, dynamic>) {
        throw const FormatException('Folder audio detail backup is invalid.');
      }
      final payload = const JsonEncoder.withIndent(
        '  ',
      ).convert(await _backupJson(first));
      _ensureCanCommit();
      if (PathMatcher.isContentUri(first.target.targetPath)) {
        final saved = await _fileCacheGateway.writeAudioDetailBackup(
          folder: first.target.targetPath,
          json: payload,
        );
        if (!saved) {
          throw const FileSystemException('Content backup was not saved.');
        }
      } else {
        await _writeFileAtomically(
          _folderBackupFile(first.target.targetPath),
          payload,
        );
      }
      return;
    }

    final existing = await _readSingleFileBackupJson(first.target);
    final entries = <Map<String, dynamic>>[];
    if (existing != null) {
      final decoded = json.decode(existing);
      if (decoded is! List) {
        throw const FormatException('Shared audio detail backup is invalid.');
      }
      entries.addAll(_stringKeyedMapList(decoded));
    }
    for (final detail in details) {
      final backup = await _backupJson(detail);
      final index = _singleFileBackupEntryIndex(detail.target, entries);
      if (index >= 0) {
        entries[index] = backup;
      } else {
        entries.add(backup);
      }
    }
    final payload = const JsonEncoder.withIndent('  ').convert(entries);
    _ensureCanCommit();
    if (PathMatcher.isContentUri(first.target.targetPath)) {
      final saved = await _fileCacheGateway.writeSingleFileDetailBackup(
        filePath: first.target.targetPath,
        json: payload,
      );
      if (!saved) {
        throw const FileSystemException(
          'Single-file content backup was not saved.',
        );
      }
    } else {
      await _writeFileAtomically(
        _singleDirBackupFile(first.target.targetPath),
        payload,
      );
    }
  }

  Future<void> _writeFileAtomically(File destination, String payload) async {
    final temporary = File('${destination.path}.tmp');
    try {
      await temporary.writeAsString(payload, flush: true);
      _ensureCanCommit();
      await temporary.rename(destination.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<T> _runBackupSourceSerialized<T>(
    AudioDetailTarget target,
    Future<T> Function() operation,
  ) {
    final key = _backupSourceKey(target);
    final previous = _backupSourceTails[key] ?? Future<void>.value();
    final future = previous.then((_) => operation());
    final tail = future.then<void>((_) {}, onError: (_, _) {});
    _backupSourceTails[key] = tail;
    unawaited(
      tail.then((_) {
        if (identical(_backupSourceTails[key], tail)) {
          _backupSourceTails.remove(key);
        }
      }),
    );
    return future;
  }

  // ---------------------------------------------------------------------------
  // Shared backup helpers
  // ---------------------------------------------------------------------------

  String _backupSourceKey(AudioDetailTarget target) {
    return target.isLibraryRootFolder
        ? 'root|${PathMatcher.equivalenceKey(target.targetPath)}'
        : 'single|${PathMatcher.parentEquivalenceKey(target.targetPath)}';
  }

  Future<AudioDetail?> _detailFromFolderBackup(
    AudioDetailTarget target,
    Map<String, dynamic>? decoded,
  ) async {
    if (decoded == null) return null;
    try {
      final detail = await _detailFromBackup(target, decoded);
      return detail.target.targetType == target.targetType
          ? detail.copyWith(target: target)
          : null;
    } catch (error, stackTrace) {
      AppLogService.warning(
        'audio_detail_backup_invalid',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  Future<AudioDetail?> _detailFromSingleFileIndex(
    AudioDetailTarget target,
    _SingleFileBackupIndex? index,
  ) async {
    final entry = index?.match(target);
    if (entry == null) return null;
    try {
      final detail = await _detailFromBackup(target, entry);
      return detail.target.targetType == target.targetType
          ? detail.copyWith(target: target)
          : null;
    } catch (error, stackTrace) {
      AppLogService.warning(
        'audio_detail_backup_invalid',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  Future<String?> _readFolderBackupJson(AudioDetailTarget target) async {
    if (PathMatcher.isContentUri(target.targetPath)) {
      return _fileCacheGateway.readAudioDetailBackup(target.targetPath);
    }
    final backupFile = _folderBackupFile(target.targetPath);
    if (!await backupFile.exists()) return null;
    return backupFile.readAsString();
  }

  Future<Map<String, dynamic>> _backupJson(AudioDetail detail) async {
    final backup = detail.toBackupJson();
    final coverPath = detail.cardCoverPath;
    if (coverPath == null) return backup;
    final portableBasePath = _portableBasePath(
      detail.target.targetType,
      detail.target.targetPath,
    );
    final relativePath = portableBasePath == null
        ? null
        : PathMatcher.relativeWithin(coverPath, portableBasePath);
    final portablePath = _normalizeRelativeCoverPath(relativePath);
    if (portablePath != null) {
      backup[_cardCoverRelativePathKey] = portablePath;
      return backup;
    }

    if (PathMatcher.isContentUri(coverPath) ||
        PathMatcher.isRemoteUri(coverPath)) {
      return backup;
    }
    final coverFile = File(coverPath);
    if (!await coverFile.exists()) return backup;
    final byteLength = await coverFile.length();
    if (byteLength <= 0 || byteLength > maxCoverFileBytes) return backup;
    final embedded = await _encodeCoverBackupInIsolate(coverPath);
    if (embedded != null) backup[_cardCoverEmbeddedKey] = embedded;
    return backup;
  }

  Future<AudioDetail> _detailFromBackup(
    AudioDetailTarget target,
    Map<String, dynamic> backup,
  ) async {
    final detail = AudioDetail.fromBackupJson(target, backup);
    final relativePath = _normalizeRelativeCoverPath(
      backup[_cardCoverRelativePathKey],
    );
    if (relativePath != null) {
      final restoredRelativeCover = _restoreRelativeCoverPath(
        target,
        backup,
        relativePath,
      );
      if (restoredRelativeCover != null) {
        return detail.copyWith(
          cardCoverPath: restoredRelativeCover,
          cardCoverSelected: true,
        );
      }
    }

    final embeddedCoverPath = await _restoreEmbeddedCoverPath(
      backup[_cardCoverEmbeddedKey],
    );
    return embeddedCoverPath == null
        ? detail
        : detail.copyWith(
            cardCoverPath: embeddedCoverPath,
            cardCoverSelected: true,
          );
  }

  String? _restoreRelativeCoverPath(
    AudioDetailTarget target,
    Map<String, dynamic> backup,
    String relativePath,
  ) {
    final previousTargetPath = backup['targetPath'] as String?;
    final previousCoverPath = backup['cardCoverPath'] as String?;
    final currentBasePath = _portableBasePath(
      target.targetType,
      target.targetPath,
    );
    if (currentBasePath == null) return null;

    if (previousTargetPath != null && previousCoverPath != null) {
      final previousBasePath = _portableBasePath(
        target.targetType,
        previousTargetPath,
      );
      if (previousBasePath != null) {
        final previousRelativePath = _normalizeRelativeCoverPath(
          PathMatcher.relativeWithin(previousCoverPath, previousBasePath),
        );
        if (previousRelativePath == relativePath) {
          final migratedPath = PathMatcher.replaceWithinOrEqual(
            previousCoverPath,
            previousBasePath,
            currentBasePath,
          );
          final migratedRelativePath = _normalizeRelativeCoverPath(
            PathMatcher.relativeWithin(migratedPath, currentBasePath),
          );
          if (migratedRelativePath == relativePath) return migratedPath;
        }
      }
    }

    if (!PathMatcher.isContentUri(currentBasePath)) {
      final restoredPath = PathMatcher.join(currentBasePath, relativePath);
      final restoredRelativePath = _normalizeRelativeCoverPath(
        PathMatcher.relativeWithin(restoredPath, currentBasePath),
      );
      if (restoredRelativePath == relativePath) return restoredPath;
    }
    return null;
  }

  Future<String?> _restoreEmbeddedCoverPath(Object? value) async {
    if (value is! Map) return null;
    final embedded = value.cast<Object?, Object?>();
    if (embedded['encoding'] != 'base64') return null;
    final mimeType = embedded['mimeType'] as String?;
    final expectedDigest = embedded['sha256'] as String?;
    final encoded = embedded['data'] as String?;
    final expectedLength = (embedded['byteLength'] as num?)?.toInt();
    if (mimeType == null ||
        !mimeType.toLowerCase().startsWith('image/') ||
        expectedDigest == null ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(expectedDigest) ||
        expectedLength == null ||
        expectedLength <= 0 ||
        expectedLength > maxCoverFileBytes ||
        encoded == null ||
        encoded.length > ((maxCoverFileBytes + 2) ~/ 3) * 4) {
      return null;
    }

    late final Uint8List bytes;
    try {
      bytes = base64Decode(encoded);
    } on FormatException {
      return null;
    }
    if (bytes.length != expectedLength ||
        sha256.convert(bytes).toString() != expectedDigest ||
        detectCoverMimeType('', bytes) != mimeType.toLowerCase()) {
      return null;
    }

    return _writePortableCover(bytes, mimeType, expectedDigest);
  }

  Future<({AudioDetail detail, bool portabilitySkipped})> _persistDerivedCover(
    AudioDetail detail,
  ) async {
    final coverPath = detail.cardCoverPath;
    if (coverPath == null ||
        PathMatcher.isContentUri(coverPath) ||
        PathMatcher.isRemoteUri(coverPath)) {
      return (detail: detail, portabilitySkipped: false);
    }
    final portableBasePath = _portableBasePath(
      detail.target.targetType,
      detail.target.targetPath,
    );
    if (portableBasePath != null &&
        _normalizeRelativeCoverPath(
              PathMatcher.relativeWithin(coverPath, portableBasePath),
            ) !=
            null) {
      return (detail: detail, portabilitySkipped: false);
    }

    final source = File(coverPath);
    if (!await source.exists()) {
      return (detail: detail, portabilitySkipped: false);
    }
    final byteLength = await source.length();
    if (byteLength <= 0) {
      return (detail: detail, portabilitySkipped: false);
    }
    if (byteLength > maxCoverFileBytes) {
      return (detail: detail, portabilitySkipped: true);
    }
    final coverData = await _readCoverDataInIsolate(coverPath);
    if (coverData == null) {
      return (detail: detail, portabilitySkipped: false);
    }
    final bytes = coverData['bytes']! as Uint8List;
    final mimeType = coverData['mimeType']! as String;
    final digest = coverData['sha256']! as String;
    _ensureCanCommit();
    final storedPath = await _writePortableCover(bytes, mimeType, digest);
    return (
      detail: detail.copyWith(cardCoverPath: storedPath),
      portabilitySkipped: false,
    );
  }

  Future<String> _writePortableCover(
    Uint8List bytes,
    String mimeType,
    String digest,
  ) async {
    final directory = await _portableCoverDirectory();
    await directory.create(recursive: true);
    final extension = extensionForCoverMimeType(mimeType);
    final output = File(path.join(directory.path, '$digest.$extension'));
    if (await output.exists()) {
      final existingLength = await output.length();
      final existingDigest = existingLength == bytes.length
          ? await _hashFileInIsolate(output.path)
          : null;
      if (existingDigest == digest) {
        return output.path;
      }
    }

    final partial = File('${output.path}.part');
    try {
      await partial.writeAsBytes(bytes, flush: true);
      if (await output.exists()) await output.delete();
      await partial.rename(output.path);
      return output.path;
    } finally {
      if (await partial.exists()) await partial.delete();
    }
  }

  String? _portableBasePath(
    AudioDetailTargetType targetType,
    String targetPath,
  ) {
    if (targetType == AudioDetailTargetType.libraryRootFolder) {
      return targetPath;
    }
    if (PathMatcher.isContentUri(targetPath)) return null;
    return path.dirname(targetPath);
  }

  String? _normalizeRelativeCoverPath(Object? value) {
    if (value is! String) return null;
    final normalized = value.trim().replaceAll('\\', '/');
    if (normalized.isEmpty || normalized.startsWith('/')) return null;
    final segments = normalized.split('/');
    if (segments.any(
      (segment) => segment.isEmpty || segment == '.' || segment == '..',
    )) {
      return null;
    }
    return segments.join('/');
  }

  Future<bool> _needsBackupCoverRestore(AudioDetail detail) async {
    final coverPath = detail.cardCoverPath;
    return coverPath != null &&
        !PathMatcher.isContentUri(coverPath) &&
        !PathMatcher.isRemoteUri(coverPath) &&
        !await File(coverPath).exists();
  }

  Future<AudioDetail> _restoreMissingDatabaseCoverFromBackup(
    AudioDetail detail,
    AudioDetail? backupDetail,
  ) async {
    if (!await _needsBackupCoverRestore(detail)) {
      final backupCoverPath = backupDetail?.cardCoverPath;
      if (!detail.cardCoverSelected &&
          backupDetail?.cardCoverSelected == true &&
          backupCoverPath != null &&
          detail.cardCoverPath != null &&
          PathMatcher.equalsNormalized(
            backupCoverPath,
            detail.cardCoverPath!,
          )) {
        return detail.copyWith(cardCoverSelected: true);
      }
      return detail;
    }
    final coverPath = detail.cardCoverPath;
    final restoredCoverPath = backupDetail?.cardCoverPath;
    if (restoredCoverPath == null || restoredCoverPath == coverPath) {
      return detail;
    }
    if (!PathMatcher.isContentUri(restoredCoverPath) &&
        !PathMatcher.isRemoteUri(restoredCoverPath) &&
        !await File(restoredCoverPath).exists()) {
      return detail;
    }

    return detail.copyWith(
      cardCoverPath: restoredCoverPath,
      cardCoverSelected: backupDetail?.cardCoverSelected ?? false,
    );
  }

  bool _shouldPreferBackup(AudioDetail database, AudioDetail backup) {
    if (database.isEmpty && !backup.isEmpty) return true;
    if (_isBackupNewer(database, backup)) return true;
    if (database.updatedAt != null || backup.updatedAt != null) return false;
    return _metadataScore(backup) > _metadataScore(database);
  }

  bool _isBackupNewer(AudioDetail detail, AudioDetail backup) {
    final backupUpdatedAt = backup.updatedAt;
    if (backupUpdatedAt == null) return false;
    final detailUpdatedAt = detail.updatedAt;
    return detailUpdatedAt == null || backupUpdatedAt.isAfter(detailUpdatedAt);
  }

  int _metadataScore(AudioDetail detail) {
    var score = 0;
    if (detail.rjCode.trim().isNotEmpty) score++;
    if (detail.workTitle.trim().isNotEmpty) score++;
    if (detail.circleName.trim().isNotEmpty) score++;
    if (detail.voiceActors.isNotEmpty) score++;
    if (detail.tags.isNotEmpty) score++;
    if (detail.cardCoverPath != null) score++;
    if (detail.releaseDate != null) score++;
    if (detail.duration != null) score++;
    if (detail.salesCount != null) score++;
    if (detail.rating != null) score++;
    return score;
  }

  Future<AudioDetail> _mergePreferredDetail(
    AudioDetail preferred,
    AudioDetail fallback,
  ) async {
    final preferredCover = preferred.cardCoverPath;
    final usablePreferredCover =
        preferredCover != null &&
        (PathMatcher.isContentUri(preferredCover) ||
            PathMatcher.isRemoteUri(preferredCover) ||
            await File(preferredCover).exists());
    return AudioDetail(
      target: fallback.target,
      rjCode: preferred.rjCode.trim().isNotEmpty
          ? preferred.rjCode
          : fallback.rjCode,
      workTitle: preferred.workTitle.trim().isNotEmpty
          ? preferred.workTitle
          : fallback.workTitle,
      circleName: preferred.circleName.trim().isNotEmpty
          ? preferred.circleName
          : fallback.circleName,
      voiceActors: preferred.voiceActors.isNotEmpty
          ? preferred.voiceActors
          : fallback.voiceActors,
      tags: preferred.tags.isNotEmpty ? preferred.tags : fallback.tags,
      cardCoverPath: usablePreferredCover
          ? preferredCover
          : fallback.cardCoverPath,
      cardCoverSelected: usablePreferredCover
          ? preferred.cardCoverSelected
          : fallback.cardCoverSelected,
      releaseDate: preferred.releaseDate ?? fallback.releaseDate,
      duration: preferred.duration ?? fallback.duration,
      salesCount: preferred.salesCount ?? fallback.salesCount,
      rating: preferred.rating ?? fallback.rating,
      createdAt: preferred.createdAt ?? fallback.createdAt,
      updatedAt: preferred.updatedAt ?? fallback.updatedAt,
    );
  }

  AudioDetailTarget _normalizeTarget(AudioDetailTarget target) {
    return AudioDetailTarget(
      targetType: target.targetType,
      targetPath: PathMatcher.normalize(target.targetPath),
    );
  }

  String _detailKeyForTarget(AudioDetailTarget target) {
    return '${target.targetType.dbValue}|${PathMatcher.normalize(target.targetPath)}';
  }

  int _singleFileBackupEntryIndex(
    AudioDetailTarget target,
    List<Map<String, dynamic>> entries,
  ) {
    var bestIndex = -1;
    var bestScore = 0;
    var hasTie = false;
    for (var i = 0; i < entries.length; i++) {
      final entryPath = entries[i]['targetPath'] as String?;
      if (entryPath == null) continue;
      final score = _singleFileEntryMatchScore(target, entryPath);
      if (score <= 0) continue;
      if (score > bestScore) {
        bestIndex = i;
        bestScore = score;
        hasTie = false;
      } else if (score == bestScore) {
        hasTie = true;
      }
    }
    return hasTie ? -1 : bestIndex;
  }

  int _singleFileEntryMatchScore(AudioDetailTarget target, String entryPath) {
    if (PathMatcher.equalsNormalized(entryPath, target.targetPath)) {
      return 3;
    }
    final entryName = PathDisplay.fileName(entryPath).trim();
    final targetName = PathDisplay.fileName(target.targetPath).trim();
    if (entryName.isEmpty || targetName.isEmpty) return 0;
    if (entryName == targetName) return 2;
    return _singleFileCopyKey(entryName) == _singleFileCopyKey(targetName)
        ? 1
        : 0;
  }

  String _singleFileCopyKey(String fileName) {
    return _singleFileCopyKeyValue(fileName);
  }

  List<Map<String, dynamic>> _stringKeyedMapList(List<dynamic> values) {
    final entries = <Map<String, dynamic>>[];
    for (final value in values) {
      final entry = _stringKeyedMap(value);
      if (entry != null) entries.add(entry);
    }
    return entries;
  }

  Map<String, dynamic>? _stringKeyedMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is! Map) return null;
    return value.map((key, value) => MapEntry(key.toString(), value));
  }

  File _folderBackupFile(String folderPath) {
    return File(path.join(folderPath, backupFileName));
  }
}

final class _SingleFileBackupIndex {
  _SingleFileBackupIndex(Iterable<Map<String, dynamic>> entries) {
    for (final entry in entries) {
      final entryPath = entry['targetPath'] as String?;
      if (entryPath == null) continue;
      _add(_byPath, PathMatcher.equivalenceKey(entryPath), entry);
      final fileName = PathDisplay.fileName(entryPath).trim();
      if (fileName.isEmpty) continue;
      _add(_byFileName, fileName, entry);
      _add(_byCopyKey, _singleFileCopyKeyValue(fileName), entry);
    }
  }

  final Map<String, List<Map<String, dynamic>>> _byPath = {};
  final Map<String, List<Map<String, dynamic>>> _byFileName = {};
  final Map<String, List<Map<String, dynamic>>> _byCopyKey = {};

  Map<String, dynamic>? match(AudioDetailTarget target) {
    final exactMatches = _byPath[PathMatcher.equivalenceKey(target.targetPath)];
    if (exactMatches != null) return _unique(exactMatches);
    final fileName = PathDisplay.fileName(target.targetPath).trim();
    if (fileName.isEmpty) return null;
    final fileNameMatches = _byFileName[fileName];
    if (fileNameMatches != null) return _unique(fileNameMatches);
    final copyMatches = _byCopyKey[_singleFileCopyKeyValue(fileName)];
    return copyMatches == null ? null : _unique(copyMatches);
  }

  static void _add(
    Map<String, List<Map<String, dynamic>>> index,
    String key,
    Map<String, dynamic> entry,
  ) {
    index.putIfAbsent(key, () => []).add(entry);
  }

  static Map<String, dynamic>? _unique(List<Map<String, dynamic>> matches) {
    return matches.length == 1 ? matches.single : null;
  }
}

String _singleFileCopyKeyValue(String fileName) {
  final extension = path.extension(fileName);
  final stem = extension.isEmpty
      ? fileName
      : fileName.substring(0, fileName.length - extension.length);
  final stableStem = stem.replaceFirst(RegExp(r'\s+\(\d+\)$'), '');
  return '${stableStem.toLowerCase()}${extension.toLowerCase()}';
}

Future<Map<String, Object>?> _encodeCoverBackupInIsolate(String filePath) {
  return Isolate.run(() async {
    final file = File(filePath);
    if (!await file.exists()) return null;
    final length = await file.length();
    if (length <= 0 || length > maxCoverFileBytes) return null;
    final bytes = await file.readAsBytes();
    final mimeType = detectCoverMimeType(filePath, bytes);
    if (mimeType == null) return null;
    return <String, Object>{
      'encoding': 'base64',
      'mimeType': mimeType,
      'byteLength': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
      'data': base64Encode(bytes),
    };
  });
}

Future<Map<String, Object>?> _readCoverDataInIsolate(String filePath) {
  return Isolate.run(() async {
    final file = File(filePath);
    if (!await file.exists()) return null;
    final length = await file.length();
    if (length <= 0 || length > maxCoverFileBytes) return null;
    final bytes = await file.readAsBytes();
    final mimeType = detectCoverMimeType(filePath, bytes);
    if (mimeType == null) return null;
    return <String, Object>{
      'bytes': bytes,
      'mimeType': mimeType,
      'sha256': sha256.convert(bytes).toString(),
    };
  });
}

Future<String?> _hashFileInIsolate(String filePath) {
  return Isolate.run(() async {
    final file = File(filePath);
    if (!await file.exists()) return null;
    return sha256.convert(await file.readAsBytes()).toString();
  });
}
