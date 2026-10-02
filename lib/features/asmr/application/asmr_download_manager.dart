import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';

import '../../../core/persistence/json_document_store.dart';
import '../domain/asmr_download.dart';
import '../domain/asmr_models.dart';
import '../../../core/cache/app_cache_service.dart';
import '../../../core/persistence/app_preferences.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/platform/file_cache_platform_gateway.dart';
import '../../../core/media/path_matcher.dart';
import '../../library/data/audio_detail_json_codec.dart';
import 'asmr_download_models.dart';
import 'asmr_download_task_store.dart';

import 'asmr_download_planner.dart';
import 'asmr_download_transfer_executor.dart';
import 'asmr_download_cleanup.dart';
import 'asmr_download_serialization.dart';
import 'asmr_download_internal_models.dart';

export 'asmr_download_models.dart';
export 'asmr_download_task_store.dart' show AsmrDownloadStoreOperation;

export 'asmr_download_io.dart'
    show
        asmrMediaRequestHeadersForUrl,
        isValidDownloadContentRange,
        commitLocalDownloadedFile,
        LocalFileRename;

class AsmrDownloadManager {
  AsmrDownloadManager({
    FileCachePlatformGateway? fileCacheGateway,
    JsonDocumentStore? jsonDocumentStore,
    Future<Directory> Function()? temporaryDirectoryProvider,
    Future<Directory> Function()? stagingDirectoryProvider,
    Duration automaticFileRetryDelay = const Duration(seconds: 2),
    int maxConcurrentDownloads = kDefaultAsmrDownloadThreadCount,
    bool persistTasks = true,
    @visibleForTesting
    Future<void> Function(String? payload)? persistenceWriter,
    @visibleForTesting
    void Function(AsmrDownloadStoreOperation operation)? storeOperationObserver,
  }) : _fileCacheGateway =
           fileCacheGateway ?? FileCachePlatformGateway.instance,
       _maxConcurrentDownloads = normalizeAsmrDownloadThreadCount(
         maxConcurrentDownloads,
       ),
       _persistTasks = persistTasks {
    _outputs = AsmrDownloadOutputStore(
      fileCacheGateway: _fileCacheGateway,
      jsonDocumentStore:
          jsonDocumentStore ??
          DefaultJsonDocumentStore(platformGateway: _fileCacheGateway),
      stagingDirectoryProvider:
          stagingDirectoryProvider ??
          temporaryDirectoryProvider ??
          getApplicationSupportDirectory,
    );
    _store = AsmrDownloadTaskStore(
      persistTasks: persistTasks,
      persistenceWriter: persistenceWriter,
      persistedTaskEncoder: _persistedTaskToJson,
      operationObserver: storeOperationObserver,
    );
    _transfers = AsmrDownloadTransferExecutor(
      store: _store,
      outputs: _outputs,
      automaticFileRetryDelay: automaticFileRetryDelay,
    );
  }

  final FileCachePlatformGateway _fileCacheGateway;
  static const AudioDetailJsonCodec _audioDetailJsonCodec =
      AudioDetailJsonCodec();
  final bool _persistTasks;
  late final AsmrDownloadTaskStore _store;
  final List<int> _queue = [];
  final Set<int> _startingTasks = {};
  final Set<int> _activeTasks = {};
  final Map<int, List<PlannedDownloadFile>> _plannedFilesMap = {};
  final Map<int, Set<String>> _manualRetryOnlyPaths = {};

  final Map<int, bool> _deleteDownloadedOnCancel = {};
  late final AsmrDownloadOutputStore _outputs;
  static const _planner = AsmrDownloadPlanner();

  late final AsmrDownloadTransferExecutor _transfers;
  int _maxConcurrentDownloads;

  bool _disposed = false;
  bool _initialized = false;
  Future<void>? _initializationFuture;
  Future<void>? _shutdownFuture;

  List<AsmrDownloadTaskSnapshot> get tasks => _store.tasks;
  List<int> get taskIds => _store.taskIds;
  AsmrDownloadTaskSnapshot? getTask(int workId) => _store[workId];
  Stream<List<int>> get taskIdsStream => _store.taskIdsStream;
  Stream<AsmrDownloadTaskSnapshot?> taskStream(int workId) =>
      _store.taskStream(workId);
  Stream<AsmrDownloadButtonViewState> get buttonViewStateStream =>
      _store.buttonViewStateStream;

  void setMaxConcurrentDownloads(int count) {
    final normalized = normalizeAsmrDownloadThreadCount(count);
    if (_maxConcurrentDownloads == normalized) return;
    _maxConcurrentDownloads = normalized;
    _processQueue();
  }

  bool get hasLiveTask => _activeTasks.isNotEmpty || _queue.isNotEmpty;
  bool get persistedUriReferencesReady => _initialized;
  int get persistedUriReferenceRevision => _store.persistedUriReferenceRevision;
  Stream<int> get persistedUriReferenceRevisions =>
      _store.persistedUriReferenceRevisions;
  Set<String> get persistedContentUris => _store.persistedContentUris;
  AsmrDownloadButtonViewState get buttonViewState => _store.buttonViewState;

  AsmrDownloadTaskShellViewState get taskShellViewState =>
      AsmrDownloadTaskShellViewState(
        hasTask: _store.taskIds.isNotEmpty,
        isActive: hasLiveTask,
      );

  @visibleForTesting
  void debugSetCurrentTaskForTesting(
    AsmrDownloadTaskSnapshot? task, {
    bool progressOnly = false,
    bool queued = false,
  }) {
    if (task != null) {
      _store[task.work.id] = task;
      if (queued && !_queue.contains(task.work.id)) {
        _queue.add(task.work.id);
      }
      if (task.status == AsmrDownloadTaskStatus.completed) {
        _retainOnlyLatestCompletedTask(task.work.id);
      }
    }
    if (progressOnly && task != null) {
      _store.notifyProgressChanged(task.work.id);
    } else {
      _store.notifyTaskChanged(
        changedWorkIds:
            task == null || task.status == AsmrDownloadTaskStatus.completed
            ? null
            : {task.work.id},
      );
    }
  }

  @visibleForTesting
  void debugRecordDownloadChunkForTesting(
    int workId,
    String relativePath,
    int chunkLength,
    int fileDownloadedBytes,
  ) {
    _store.recordDownloadChunk(
      workId,
      relativePath,
      chunkLength,
      fileDownloadedBytes,
    );
  }

  @visibleForTesting
  void debugRecordCreatedOutputPathForTesting(int workId, String outputPath) {
    _outputs.createdOutputPaths
        .putIfAbsent(workId, () => <String>{})
        .add(outputPath);
  }

  Future<void> initialize() {
    if (_disposed) return Future<void>.value();
    return _initializationFuture ??= _initializeOnce();
  }

  Future<void> _initializeOnce() async {
    if (_persistTasks) {
      await _restorePersistedTasksFromPreferences();
    }
    if (_disposed) return;
    _initialized = true;
    _store.notifyTaskChanged(forcePersistedUriReferenceRevision: true);
  }

  Future<String?> pickDestinationFolder({String? dialogTitle}) async {
    try {
      if (Platform.isAndroid) {
        final pathValue = await _fileCacheGateway.pickAudioFolder();
        if (pathValue != null && pathValue.isNotEmpty) {
          return pathValue;
        }
      }
    } on PlatformException {
      // Fall through to the file picker.
    } catch (_) {
      // Native folder selection is optional; fall through to the file picker.
    }

    if (!Platform.isAndroid || kIsWeb) {
      final directory = await FilePicker.getDirectoryPath(
        dialogTitle: dialogTitle ?? 'Choose download folder',
      );
      if (directory != null && directory.trim().isNotEmpty) {
        return directory.trim();
      }
    }
    return null;
  }

  Future<bool> destinationExists(String folderPath) async {
    final normalized = folderPath.trim();
    if (normalized.isEmpty) return false;
    if (PathMatcher.isContentUri(normalized)) {
      try {
        return await _fileCacheGateway.documentPathExists(normalized);
      } catch (_) {
        return false;
      }
    }
    return Directory(normalized).exists();
  }

  Future<void> cancelTask(int workId, {bool deleteDownloaded = true}) async {
    final task = _store[workId];
    if (task == null) {
      return;
    }

    if (_queue.contains(workId)) {
      _queue.remove(workId);

      _manualRetryOnlyPaths.remove(workId);
      _plannedFilesMap.remove(workId);
      _outputs.createdOutputPaths.remove(workId);
      _outputs.createdJsonDocuments.remove(workId);
      _store.remove(workId);
      _store.notifyTaskChanged();
      await flushPersistence();
      return;
    }

    if (_activeTasks.contains(workId)) {
      _transfers.cancel(workId);
      _deleteDownloadedOnCancel[workId] = deleteDownloaded;
      _store[workId] = task.copyWith(message: 'canceling');
      _store.notifyTaskChanged();
      await _transfers.waitFor(workId);
      _store.remove(workId);
      _store.notifyTaskChanged();
      await flushPersistence();
      return;
    }

    if (task.status == AsmrDownloadTaskStatus.failed ||
        task.status == AsmrDownloadTaskStatus.paused) {
      if (deleteDownloaded) {
        await _outputs.cleanupCancelledTask(workId);
      }
    }
    _outputs.createdOutputPaths.remove(workId);
    _outputs.createdJsonDocuments.remove(workId);

    _manualRetryOnlyPaths.remove(workId);
    _plannedFilesMap.remove(workId);
    _store.remove(workId);
    _store.notifyTaskChanged();
    await flushPersistence();
  }

  Future<void> deleteTask(int workId) async {
    final task = _store[workId];
    if (task == null) return;
    final createdPaths = Set<String>.from(
      _outputs.createdOutputPaths[workId] ?? const <String>{},
    );
    final createdJsons = Map<String, CreatedDownloadJsonDocument>.from(
      _outputs.createdJsonDocuments[workId] ?? const {},
    );
    if (_activeTasks.contains(workId) || _queue.contains(workId)) {
      await cancelTask(workId, deleteDownloaded: false);
    } else {
      _store.remove(workId);
      _store.notifyTaskChanged();
      await flushPersistence();
    }
    _outputs.createdOutputPaths.remove(workId);
    _outputs.createdJsonDocuments.remove(workId);

    _manualRetryOnlyPaths.remove(workId);
    _plannedFilesMap.remove(workId);

    await _outputs.deleteTaskDownloadedFiles(
      task,
      extraCreatedPaths: createdPaths,
      createdJsonDocs: createdJsons,
    );
  }

  Future<void> pauseTask(int workId) async {
    final task = _store[workId];
    if (task == null) return;

    if (_activeTasks.contains(workId)) {
      _transfers.pause(workId);
      await _transfers.waitFor(workId);
      await flushPersistence();
    } else if (_queue.contains(workId)) {
      _queue.remove(workId);
      _store[workId] = task.copyWith(
        status: AsmrDownloadTaskStatus.paused,
        fileRetryAttempts: const <String, int>{},
        manuallyRetryingFilePaths: const <String>{},
        message: 'paused',
      );
      _store.notifyTaskChanged();
      await flushPersistence();
    }
  }

  Future<void> pauseAllTasks() async {
    if (_disposed) return;
    await initialize();
    if (_disposed) return;

    final queuedWorkIds = List<int>.of(_queue);
    _queue.clear();
    for (final workId in queuedWorkIds) {
      final task = _store[workId];
      if (task == null) continue;
      _store[workId] = task.copyWith(
        status: AsmrDownloadTaskStatus.paused,
        fileRetryAttempts: const <String, int>{},
        manuallyRetryingFilePaths: const <String>{},
        message: 'paused',
      );
    }

    final activeWorkIds = List<int>.of(_activeTasks);
    for (final workId in activeWorkIds) {
      _transfers.pause(workId);
    }
    if (queuedWorkIds.isNotEmpty || activeWorkIds.isNotEmpty) {
      _store.notifyTaskChanged();
    }

    await Future.wait<void>(
      activeWorkIds.map((workId) => _transfers.waitFor(workId)),
    );
    await flushPersistence();
  }

  Future<void> resumeTask(int workId) => _resumeTask(workId);

  Future<bool> retryFailedFile(int workId, String relativePath) =>
      _retryFailedFile(workId, relativePath);

  Future<void> startDownload({
    required AsmrWork work,
    required List<AsmrTrackFile> selectedRoots,
    required String destinationRoot,
    required AsmrDownloadConflictPolicy conflictPolicy,
    bool saveMetadata = true,
    bool saveCover = true,
    int automaticFileRetryCount = kDefaultAsmrDownloadRetryCount,
    Iterable<AsmrDownloadFolderNameField> folderNameFields =
        kDefaultAsmrDownloadFolderNameFields,
    String? customWorkFolderName,
  }) async {
    if (_disposed) return;
    if (work.id <= 0) {
      throw ArgumentError.value(work.id, 'work.id');
    }
    final normalizedDestination = destinationRoot.trim();
    if (normalizedDestination.isEmpty) {
      throw ArgumentError.value(destinationRoot, 'destinationRoot');
    }
    if (selectedRoots.isEmpty) {
      throw ArgumentError.value(selectedRoots, 'selectedRoots');
    }
    final normalizedRetryCount = normalizeAsmrDownloadRetryCount(
      automaticFileRetryCount,
    );

    await initialize();
    if (_disposed) return;

    final workId = work.id;
    if (!_startingTasks.add(workId)) return;
    try {
      final existingTask = _store[workId];
      if (existingTask != null) {
        if (existingTask.isActive ||
            _queue.contains(workId) ||
            _activeTasks.contains(workId)) {
          return; // Already downloading or queued
        }
        if (existingTask.status == AsmrDownloadTaskStatus.paused ||
            existingTask.status == AsmrDownloadTaskStatus.failed) {
          _enqueueExistingTask(existingTask);
          await _store.pendingPersistenceWrites;
          return;
        }
        _store.remove(workId);
        _outputs.createdOutputPaths.remove(workId);
        _outputs.createdJsonDocuments.remove(workId);
      }

      final workFolderName =
          customWorkFolderName != null && customWorkFolderName.trim().isNotEmpty
          ? customWorkFolderName.trim()
          : buildAsmrDownloadWorkFolderName(work, folderNameFields);
      final plannedFiles = _planner.collectPlannedFiles(selectedRoots);
      final coverFile = saveCover ? _planner.plannedCoverFile(work) : null;
      if (coverFile != null) plannedFiles.add(coverFile);
      for (final file in plannedFiles) {
        if (!file.isCover) {
          _planner.validatedDownloadRelativePath(file.relativePath);
        }
      }
      final workRootPath = _planner.joinFolderPath(
        normalizedDestination,
        workFolderName,
      );
      if (_disposed) {
        return;
      }
      final backupBytes = saveMetadata
          ? _audioDetailJsonCodec
                .encodeNew(_planner.buildBackupDetail(work, workRootPath))
                .length
          : 0;
      final totalFiles = plannedFiles.length + (saveMetadata ? 1 : 0);
      final totalBytes = plannedFiles.fold<int>(backupBytes, (sum, item) {
        return sum + item.size;
      });

      final fileTotalBytes = <String, int>{};
      for (final file in plannedFiles) {
        if (!file.isCover) fileTotalBytes[file.relativePath] = file.size;
      }
      _plannedFilesMap[workId] = plannedFiles;

      _store[workId] = AsmrDownloadTaskSnapshot(
        work: work,
        destinationRoot: normalizedDestination,
        workFolderName: workFolderName,
        conflictPolicy: conflictPolicy,
        saveMetadata: saveMetadata,
        saveCover: coverFile != null,
        automaticFileRetryCount: normalizedRetryCount,
        status: AsmrDownloadTaskStatus.idle,
        totalFiles: totalFiles,
        completedFiles: 0,
        skippedFiles: 0,
        failedFiles: 0,
        totalBytes: totalBytes,
        downloadedBytes: 0,
        startedAt: DateTime.now(),
        message: 'queued',
        fileTotalBytes: fileTotalBytes,
        fileDownloadedBytes: {},
        selectedRoots: selectedRoots,
      );

      if (!_queue.contains(workId) && !_activeTasks.contains(workId)) {
        _queue.add(workId);
      }
      _store.notifyTaskChanged();
      await _store.pendingPersistenceWrites;
      _processQueue();
    } finally {
      _startingTasks.remove(workId);
    }
  }

  void _processQueue() {
    if (_disposed) return;
    while (_activeTasks.length < _maxConcurrentDownloads && _queue.isNotEmpty) {
      final workId = _queue.removeAt(0);
      if (!_activeTasks.add(workId)) continue;
      unawaited(_runTask(workId));
    }
  }

  Future<void> _runTask(int workId) async {
    if (_disposed) {
      _activeTasks.remove(workId);
      return;
    }
    final taskSnapshot = _store[workId];
    if (taskSnapshot == null) {
      _activeTasks.remove(workId);
      _processQueue();
      return;
    }
    final manualRetryPaths = _manualRetryOnlyPaths.remove(workId);
    final isManualRetryRun = manualRetryPaths?.isNotEmpty ?? false;

    _transfers.begin(workId);

    _store[workId] = taskSnapshot.copyWith(
      status: AsmrDownloadTaskStatus.preparing,
      message: 'preparing',
    );
    _store.notifyTaskChanged();

    final work = taskSnapshot.work;
    final workRootPath = taskSnapshot.workRootPath;
    final conflictPolicy = taskSnapshot.conflictPolicy;

    final backup = taskSnapshot.saveMetadata
        ? _planner.buildBackupDetail(work, workRootPath)
        : null;
    final backupBytes = backup == null
        ? 0
        : _audioDetailJsonCodec.encodeNew(backup).length;
    // Restored tasks may already include metadata in their aggregate counters.
    final metadataAccounted =
        taskSnapshot.completedFiles + taskSnapshot.skippedFiles >
        taskSnapshot.completedFilePaths.length;

    try {
      await _outputs.prepareTask(taskSnapshot);
      _transfers.throwIfCancelled(workId);

      final resumedTask = _store[workId]!;
      var completed = resumedTask.completedFiles;
      var skipped = resumedTask.skippedFiles;
      var failed = isManualRetryRun ? resumedTask.failedFiles : 0;
      var downloadedBytes = resumedTask.downloadedBytes;
      final fileDownloadedBytes = Map<String, int>.from(
        resumedTask.fileDownloadedBytes,
      );
      if (resumedTask.totalBytes > 0 &&
          downloadedBytes > resumedTask.totalBytes) {
        final calculated = fileDownloadedBytes.values.fold<int>(
          backup != null && metadataAccounted ? backupBytes : 0,
          (sum, b) => sum + b,
        );
        downloadedBytes = calculated.clamp(0, resumedTask.totalBytes);
      }
      final completedFilePaths = Set<String>.from(
        resumedTask.completedFilePaths,
      );
      final failedFilePaths = isManualRetryRun
          ? Set<String>.from(resumedTask.failedFilePaths)
          : <String>{};
      final manuallyRetryingFilePaths = isManualRetryRun
          ? Set<String>.from(resumedTask.manuallyRetryingFilePaths)
          : <String>{};

      _store[workId] = resumedTask.copyWith(
        status: AsmrDownloadTaskStatus.downloading,
        completedFiles: completed,
        failedFiles: failed,
        downloadedBytes: downloadedBytes,
        failedFilePaths: failedFilePaths,
        manuallyRetryingFilePaths: manuallyRetryingFilePaths,
        message: 'downloading',
      );
      _store.notifyTaskChanged();
      _store.setLiveDownloadedBytes(workId, downloadedBytes);
      _store.setLiveFileDownloadedBytes(workId, fileDownloadedBytes);
      final fileTotalBytes = _store[workId]!.fileTotalBytes;

      // Ensure folders
      for (final relativePath
          in fileTotalBytes.keys.map((p) => path.dirname(p)).toSet()) {
        if (relativePath == '.') continue;
        _transfers.throwIfCancelled(workId);
        await _outputs.ensureFolderPath(
          basePath: workRootPath,
          relativePath: relativePath,
          overwrite: conflictPolicy == AsmrDownloadConflictPolicy.overwrite,
        );
      }

      var plannedFiles = _plannedFilesMap[workId];
      if (plannedFiles == null) {
        plannedFiles = _planner.collectPlannedFiles(
          _store[workId]!.selectedRoots,
        );
        if (taskSnapshot.saveCover) {
          final coverFile = _planner.plannedCoverFile(work);
          if (coverFile != null) plannedFiles.add(coverFile);
        }
        _plannedFilesMap[workId] = plannedFiles;
      }
      if (plannedFiles.isNotEmpty) {
        final progress = AsmrDownloadFileProgress(
          completed: completed,
          skipped: skipped,
          failed: failed,
          downloadedBytes: downloadedBytes,
          fileDownloadedBytes: fileDownloadedBytes,
          completedFilePaths: completedFilePaths,
          failedFilePaths: failedFilePaths,
          manuallyRetryingFilePaths: manuallyRetryingFilePaths,
        );
        await _transfers.downloadFiles(
          taskSnapshot: taskSnapshot,
          plannedFiles: plannedFiles,
          progress: progress,
        );
        completed = progress.completed;
        skipped = progress.skipped;
        failed = progress.failed;
        downloadedBytes = progress.downloadedBytes;
      }

      _transfers.throwIfCancelled(workId);
      if (backup != null) {
        _store[workId] = _store[workId]!.copyWith(
          currentItemPath: 'doujin-audio.json',
          message: 'downloading_work_detail',
        );
        _store.notifyTaskChanged();
        final metadataCreated = await _outputs.saveTaskMetadata(
          taskSnapshot,
          backup,
        );
        _transfers.throwIfCancelled(workId);
        if (!metadataAccounted) {
          if (metadataCreated) {
            completed++;
            downloadedBytes += backupBytes;
          } else {
            skipped++;
          }
        }
      }
      final finalDownloadedBytes = failed > 0
          ? downloadedBytes
          : _store[workId]!.totalBytes;
      _store.setLiveDownloadedBytes(workId, finalDownloadedBytes);
      _store.setLiveFileDownloadedBytes(workId, fileDownloadedBytes);
      _store[workId] = _store[workId]!.copyWith(
        status: failed > 0
            ? AsmrDownloadTaskStatus.failed
            : AsmrDownloadTaskStatus.completed,
        completedFiles: completed,
        skippedFiles: skipped,
        failedFiles: failed,
        downloadedBytes: finalDownloadedBytes,
        fileDownloadedBytes: fileDownloadedBytes,
        fileRetryAttempts: const <String, int>{},
        failedFilePaths: failedFilePaths,
        manuallyRetryingFilePaths: const <String>{},
        message: failed > 0 ? 'completed_with_failures' : 'completed',
      );
      if (failed == 0) {
        _retainOnlyLatestCompletedTask(workId);
      }
      _store.notifyTaskChanged();
      await flushPersistence();
    } on DownloadCancelled {
      final currentTask = _store[workId];
      if (!_disposed && currentTask != null) {
        if (_transfers.isPaused(workId)) {
          _store[workId] = currentTask.copyWith(
            status: AsmrDownloadTaskStatus.paused,
            fileRetryAttempts: const <String, int>{},
            manuallyRetryingFilePaths: const <String>{},
            message: 'paused',
          );
        } else {
          _store[workId] = currentTask.copyWith(
            status: AsmrDownloadTaskStatus.failed,
            fileRetryAttempts: const <String, int>{},
            manuallyRetryingFilePaths: const <String>{},
            message: 'cancelled',
          );
        }
        _store.notifyTaskChanged();
      }
    } catch (error, stackTrace) {
      final currentTask = _store[workId];
      if (!_disposed) {
        AppLogService.error(
          'asmr_download_failed',
          error: error,
          stackTrace: stackTrace,
        );
      }
      if (!_disposed && currentTask != null) {
        _store[workId] = currentTask.copyWith(
          status: AsmrDownloadTaskStatus.failed,
          fileRetryAttempts: const <String, int>{},
          manuallyRetryingFilePaths: const <String>{},
          error: error.toString(),
          message: 'failed',
        );
        _store.notifyTaskChanged();
      }
    } finally {
      _manualRetryOnlyPaths.remove(workId);
      _plannedFilesMap.remove(workId);
      if (!_disposed &&
          _transfers.isCancelled(workId) &&
          !_transfers.isPaused(workId) &&
          _deleteDownloadedOnCancel[workId] == true) {
        await _outputs.cleanupCancelledTask(workId);
      }
      if (_transfers.isCancelled(workId)) {
        _outputs.createdOutputPaths.remove(workId);
        _outputs.createdJsonDocuments.remove(workId);
      }
      _deleteDownloadedOnCancel.remove(workId);
      _transfers.finish(workId);
      _activeTasks.remove(workId);

      _store.removeLiveProgress(workId);
      if (!_disposed) {
        AppCacheService.scheduleEnforce();
        _processQueue();
      }
    }
  }

  Future<void> flushPersistence() => _store.flushPersistence();

  @visibleForTesting
  void debugRemoveTaskForTesting(int workId) {
    _store.remove(workId);
    _queue.remove(workId);
    _manualRetryOnlyPaths.remove(workId);
    _plannedFilesMap.remove(workId);
    _store.notifyTaskChanged(changedWorkIds: <int>{workId});
  }

  @visibleForTesting
  void debugFlushProgressNotificationsForTesting() {
    _store.flushPendingProgressNotifications();
  }

  @visibleForTesting
  Future<void> debugRunStructuralPersistenceForTesting() =>
      _store.runStructuralPersistenceForTesting();

  @visibleForTesting
  Future<void> debugRunProgressCheckpointForTesting() =>
      _store.runProgressCheckpointForTesting();

  Future<void> shutdown() => _shutdownFuture ??= _shutdownOnce();

  Future<void> _shutdownOnce() async {
    if (_disposed) return;
    final runningWorkIds = <int>{..._queue, ..._activeTasks};
    final activeCompletions = _transfers.pendingTasks;
    _disposed = true;
    _queue.clear();

    _manualRetryOnlyPaths.clear();
    _transfers.shutdown();
    await _store.shutdown(pauseWorkIds: runningWorkIds);
    await activeCompletions;
  }

  void dispose() {
    unawaited(shutdown());
  }

  Future<void> _resumeTask(int workId) async {
    if (_disposed) return;
    final task = _store[workId];
    if (task == null ||
        (task.status != AsmrDownloadTaskStatus.paused &&
            task.status != AsmrDownloadTaskStatus.failed)) {
      return;
    }
    _enqueueExistingTask(task);
  }

  Future<bool> _retryFailedFile(int workId, String relativePath) async {
    if (_disposed) return false;
    await initialize();
    if (_disposed) return false;
    final task = _store[workId];
    final normalizedPath = relativePath.trim();
    if (task == null ||
        normalizedPath.isEmpty ||
        !task.failedFilePaths.contains(normalizedPath) ||
        task.manuallyRetryingFilePaths.contains(normalizedPath)) {
      return false;
    }
    final plannedFile = _planner.findPlannedFile(task, normalizedPath);
    if (plannedFile == null) return false;

    final canRetryActiveTask = _transfers.canRetry(workId);
    final canStartFailedTask =
        task.status == AsmrDownloadTaskStatus.failed &&
        !_activeTasks.contains(workId) &&
        !_queue.contains(workId);
    if (!canRetryActiveTask && !canStartFailedTask) return false;

    final retryAttempts = Map<String, int>.from(task.fileRetryAttempts)
      ..remove(normalizedPath);
    final retryingPaths = Set<String>.from(task.manuallyRetryingFilePaths)
      ..add(normalizedPath);
    final retryingTask = task.copyWith(
      fileRetryAttempts: retryAttempts,
      manuallyRetryingFilePaths: retryingPaths,
    );
    _store[workId] = retryingTask;
    _store.notifyTaskChanged(changedWorkIds: <int>{workId});

    if (canRetryActiveTask) {
      _transfers.retry(workId, plannedFile);
    } else {
      _manualRetryOnlyPaths[workId] = <String>{normalizedPath};
      _plannedFilesMap[workId] = <PlannedDownloadFile>[plannedFile];
      _enqueueExistingTask(retryingTask);
    }
    return true;
  }

  void _enqueueExistingTask(AsmrDownloadTaskSnapshot task) {
    final workId = task.work.id;

    _store[workId] = task.copyWith(
      status: AsmrDownloadTaskStatus.idle,
      message: 'queued',
    );
    if (!_queue.contains(workId)) {
      _queue.add(workId);
    }
    _store.notifyTaskChanged();
    _processQueue();
  }

  Map<String, Object?> _persistedTaskToJson(AsmrDownloadTaskSnapshot task) =>
      downloadTaskToJson(
        task,
        createdOutputPaths:
            _outputs.createdOutputPaths[task.work.id] ?? const <String>{},
        createdJsonDocuments:
            _outputs.createdJsonDocuments[task.work.id] ??
            const <String, CreatedDownloadJsonDocument>{},
      );

  Future<void> _restorePersistedTasksFromPreferences() async {
    final raw = await AppPreferences.getString(
      AppPreferences.asmrDownloadTasksKey,
    );
    if (_disposed || raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map && decoded['tasks'] is List) {
        for (final value in decoded['tasks'] as List) {
          if (value is! Map) continue;
          final restored = downloadTaskFromJson(
            Map<String, dynamic>.from(value),
          );
          final task = restored.task;
          _store[task.work.id] = task.copyWith(
            status: AsmrDownloadTaskStatus.paused,
            fileRetryAttempts: const <String, int>{},
            manuallyRetryingFilePaths: const <String>{},
            message: 'paused',
          );
          _outputs.createdOutputPaths[task.work.id] =
              restored.createdOutputPaths;
          _outputs.createdJsonDocuments[task.work.id] =
              restored.createdJsonDocuments;
        }
      }
    } catch (error, stackTrace) {
      AppLogService.warning(
        'asmr_download_restore_failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void _retainOnlyLatestCompletedTask(int workId) {
    for (final obsoleteWorkId in _store.retainOnlyLatestCompletedTask(workId)) {
      _outputs.createdOutputPaths.remove(obsoleteWorkId);
      _outputs.createdJsonDocuments.remove(obsoleteWorkId);
    }
  }
}
