import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';

import '../../../core/media/audio_detail.dart';
import '../../../core/persistence/json_document_store.dart';
import '../domain/asmr_download.dart';
import '../domain/asmr_models.dart';
import 'asmr_api_service.dart';
import '../../settings/application/app_cache_service.dart';
import '../../settings/application/app_preferences.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/platform/file_cache_platform_gateway.dart';
import '../../../core/media/path_matcher.dart';
import '../../library/data/audio_detail_json_codec.dart';
import 'asmr_download_models.dart';
import 'asmr_download_task_store.dart';

export 'asmr_download_models.dart';
export 'asmr_download_task_store.dart' show AsmrDownloadStoreOperation;

part 'asmr_download_io.dart';
part 'asmr_download_planner.dart';
part 'asmr_download_transfer_service.dart';
part 'asmr_download_cleanup.dart';
part 'asmr_download_serialization.dart';
part 'asmr_download_internal_models.dart';

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
       _jsonDocumentStore =
           jsonDocumentStore ??
           DefaultJsonDocumentStore(
             platformGateway:
                 fileCacheGateway ?? FileCachePlatformGateway.instance,
           ),
       _stagingDirectoryProvider =
           stagingDirectoryProvider ??
           temporaryDirectoryProvider ??
           getApplicationSupportDirectory,
       _automaticFileRetryDelay = automaticFileRetryDelay,
       _maxConcurrentDownloads = normalizeAsmrDownloadThreadCount(
         maxConcurrentDownloads,
       ),
       _persistTasks = persistTasks {
    _store = AsmrDownloadTaskStore(
      persistTasks: persistTasks,
      persistenceWriter: persistenceWriter,
      persistedTaskEncoder: _persistedTaskToJson,
      operationObserver: storeOperationObserver,
    );
  }

  static const int _maxCoverBytes = 5 * 1024 * 1024;
  final FileCachePlatformGateway _fileCacheGateway;
  final JsonDocumentStore _jsonDocumentStore;
  static const AudioDetailJsonCodec _audioDetailJsonCodec =
      AudioDetailJsonCodec();
  final Future<Directory> Function() _stagingDirectoryProvider;
  final Duration _automaticFileRetryDelay;
  final bool _persistTasks;
  late final AsmrDownloadTaskStore _store;
  final List<int> _queue = [];
  final Set<int> _startingTasks = {};
  final Set<int> _activeTasks = {};
  final Set<int> _resumingTasks = {};
  final Map<int, List<_PlannedDownloadFile>> _plannedFilesMap = {};
  final Map<int, Set<String>> _manualRetryOnlyPaths = {};
  final Map<int, void Function(_PlannedDownloadFile)>
  _activeFileRetryDispatchers = {};

  final Map<int, bool> _cancelRequested = {};
  final Map<int, bool> _deleteDownloadedOnCancel = {};
  final Map<int, bool> _pauseRequested = {};
  final Map<int, Completer<void>> _downloadCompletions = {};
  final Map<int, HttpClient> _activeHttpClients = {};
  final Map<int, Set<String>> _createdOutputPaths = {};
  final Map<int, Map<String, _CreatedJsonDocument>> _createdJsonDocuments = {};

  static const int _maxConcurrentFilesPerTask = 3;
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

  Future<void> initialize() {
    if (_disposed) return Future<void>.value();
    return _initializationFuture ??= _initializeOnce();
  }

  Future<void> _initializeOnce() async {
    if (_persistTasks) {
      final raw = await AppPreferences.getString(
        AppPreferences.asmrDownloadTasksKey,
      );
      if (!_disposed && raw != null && raw.isNotEmpty) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map && decoded['tasks'] is List) {
            for (final value in decoded['tasks'] as List) {
              if (value is! Map) continue;
              final restored = _downloadTaskFromJson(
                Map<String, dynamic>.from(value),
              );
              final task = restored.task;
              _store[task.work.id] = task.copyWith(
                status: AsmrDownloadTaskStatus.paused,
                fileRetryAttempts: const <String, int>{},
                manuallyRetryingFilePaths: const <String>{},
                message: 'paused',
              );
              _createdOutputPaths[task.work.id] = restored.createdOutputPaths;
              _createdJsonDocuments[task.work.id] =
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
      _resumingTasks.remove(workId);
      _manualRetryOnlyPaths.remove(workId);
      _plannedFilesMap.remove(workId);
      _createdOutputPaths.remove(workId);
      _createdJsonDocuments.remove(workId);
      _store.remove(workId);
      _store.notifyTaskChanged();
      await flushPersistence();
      return;
    }

    if (_activeTasks.contains(workId)) {
      _pauseRequested.remove(workId);
      _cancelRequested[workId] = true;
      _deleteDownloadedOnCancel[workId] = deleteDownloaded;
      _store[workId] = task.copyWith(message: 'canceling');
      _store.notifyTaskChanged();
      final completion = _downloadCompletions[workId]?.future;
      _activeHttpClients[workId]?.close(force: true);
      if (completion != null) {
        await completion;
      }
      _store.remove(workId);
      _store.notifyTaskChanged();
      await flushPersistence();
      return;
    }

    if (task.status == AsmrDownloadTaskStatus.failed ||
        task.status == AsmrDownloadTaskStatus.paused) {
      if (deleteDownloaded) {
        await _cleanupCancelledTask(workId);
      }
    }
    _createdOutputPaths.remove(workId);
    _createdJsonDocuments.remove(workId);
    _resumingTasks.remove(workId);
    _manualRetryOnlyPaths.remove(workId);
    _plannedFilesMap.remove(workId);
    _store.remove(workId);
    _store.notifyTaskChanged();
    await flushPersistence();
  }

  Future<void> deleteTask(int workId) async {
    final task = _store[workId];
    if (task == null) return;
    final workRootPath = task.workRootPath;
    final coverOutputPath = task.coverOutputPath;
    if (_activeTasks.contains(workId) || _queue.contains(workId)) {
      await cancelTask(workId);
    } else {
      _store.remove(workId);
      _store.notifyTaskChanged();
      await flushPersistence();
    }
    await _deleteDownloadRoot(workRootPath);
    if (coverOutputPath != null) {
      await _deleteOutputPath(coverOutputPath);
    }
    _createdOutputPaths.remove(workId);
    _createdJsonDocuments.remove(workId);
    _resumingTasks.remove(workId);
    _manualRetryOnlyPaths.remove(workId);
    _plannedFilesMap.remove(workId);
  }

  Future<void> pauseTask(int workId) async {
    final task = _store[workId];
    if (task == null) return;

    if (_activeTasks.contains(workId)) {
      _pauseRequested[workId] = true;
      final completion = _downloadCompletions[workId]?.future;
      _activeHttpClients[workId]?.close(force: true);
      if (completion != null) await completion;
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
      _pauseRequested[workId] = true;
      _activeHttpClients[workId]?.close(force: true);
    }
    if (queuedWorkIds.isNotEmpty || activeWorkIds.isNotEmpty) {
      _store.notifyTaskChanged();
    }

    await Future.wait<void>(
      activeWorkIds.map(
        (workId) =>
            _downloadCompletions[workId]?.future ?? Future<void>.value(),
      ),
    );
    await flushPersistence();
  }

  Future<void> resumeTask(int workId) async {
    if (_disposed) return;
    final task = _store[workId];
    if (task == null ||
        (task.status != AsmrDownloadTaskStatus.paused &&
            task.status != AsmrDownloadTaskStatus.failed)) {
      return;
    }
    _enqueueExistingTask(task);
  }

  Future<bool> retryFailedFile(int workId, String relativePath) async {
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
    final plannedFile = _findPlannedFile(task, normalizedPath);
    if (plannedFile == null) return false;

    final activeDispatcher = _activeFileRetryDispatchers[workId];
    final canStartFailedTask =
        task.status == AsmrDownloadTaskStatus.failed &&
        !_activeTasks.contains(workId) &&
        !_queue.contains(workId);
    if (activeDispatcher == null && !canStartFailedTask) return false;

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

    if (activeDispatcher != null) {
      activeDispatcher(plannedFile);
    } else {
      _manualRetryOnlyPaths[workId] = <String>{normalizedPath};
      _plannedFilesMap[workId] = <_PlannedDownloadFile>[plannedFile];
      _enqueueExistingTask(retryingTask);
    }
    return true;
  }

  void _enqueueExistingTask(AsmrDownloadTaskSnapshot task) {
    final workId = task.work.id;
    _resumingTasks.add(workId);
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
      }
      _resumingTasks.remove(workId);

      final workFolderName = buildAsmrDownloadWorkFolderName(
        work,
        folderNameFields,
      );
      final plannedFiles = _collectPlannedFiles(selectedRoots);
      final coverFile = saveCover ? _plannedCoverFile(work) : null;
      if (coverFile != null) plannedFiles.add(coverFile);
      for (final file in plannedFiles) {
        if (!file.isCover) {
          _validatedDownloadRelativePath(file.relativePath);
        }
      }
      final workRootPath = _joinFolderPath(
        normalizedDestination,
        workFolderName,
      );
      if (_disposed) {
        return;
      }
      final backupBytes = saveMetadata
          ? _audioDetailJsonCodec
                .encodeNew(_buildBackupDetail(work, workRootPath))
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

    _downloadCompletions[workId] = Completer<void>();
    _cancelRequested[workId] = false;

    _store[workId] = taskSnapshot.copyWith(
      status: AsmrDownloadTaskStatus.preparing,
      message: 'preparing',
    );
    _store.notifyTaskChanged();

    final work = taskSnapshot.work;
    final normalizedDestination = taskSnapshot.destinationRoot;
    final workFolderName = taskSnapshot.workFolderName;
    final workRootPath = taskSnapshot.workRootPath;
    final conflictPolicy = taskSnapshot.conflictPolicy;

    final saveMetadata = taskSnapshot.saveMetadata && !isManualRetryRun;
    final backup = saveMetadata ? _buildBackupDetail(work, workRootPath) : null;
    final backupBytes = backup == null
        ? 0
        : _audioDetailJsonCodec.encodeNew(backup).length;
    var metadataCreated = false;

    try {
      _createdOutputPaths.putIfAbsent(workId, () => <String>{});
      _createdJsonDocuments.putIfAbsent(
        workId,
        () => <String, _CreatedJsonDocument>{},
      );
      final rootReady = await _ensureFolderPath(
        basePath: normalizedDestination,
        relativePath: workFolderName,
        overwrite: conflictPolicy == AsmrDownloadConflictPolicy.overwrite,
      );
      if (!rootReady) {
        throw const FileSystemException('Unable to create download folder.');
      }

      if (backup != null) {
        final backupPath = _joinFolderPath(workRootPath, 'doujin-audio.json');
        final location = JsonDocumentLocation.folderChild(
          folder: workRootPath,
          name: 'doujin-audio.json',
        );
        final write = await _writeWorkDetailBackup(backup, location);
        metadataCreated = write.status == JsonDocumentWriteStatus.created;
        if (metadataCreated) {
          _createdOutputPaths[workId]?.add(backupPath);
          _recordCreatedJson(workId, backupPath, location, write);
        }
      }
      _throwIfCancelled(workId);

      final resumedTask = _store[workId]!;
      var completed = resumedTask.completedFiles;
      var skipped = resumedTask.skippedFiles;
      var failed = isManualRetryRun ? resumedTask.failedFiles : 0;
      var downloadedBytes = resumedTask.downloadedBytes;
      if (saveMetadata && completed == 0) {
        if (metadataCreated) {
          completed = 1;
          downloadedBytes += backupBytes;
        } else {
          skipped++;
        }
      }
      final fileDownloadedBytes = Map<String, int>.from(
        resumedTask.fileDownloadedBytes,
      );
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
        message: saveMetadata ? 'downloading_work_detail' : 'downloading',
      );
      _store.notifyTaskChanged();
      _store.setLiveDownloadedBytes(workId, downloadedBytes);
      _store.setLiveFileDownloadedBytes(workId, fileDownloadedBytes);
      final fileTotalBytes = _store[workId]!.fileTotalBytes;

      // Ensure folders
      for (final relativePath
          in fileTotalBytes.keys.map((p) => path.dirname(p)).toSet()) {
        if (relativePath == '.') continue;
        _throwIfCancelled(workId);
        await _ensureFolderPath(
          basePath: workRootPath,
          relativePath: relativePath,
          overwrite: conflictPolicy == AsmrDownloadConflictPolicy.overwrite,
        );
      }

      var plannedFiles = _plannedFilesMap[workId];
      if (plannedFiles == null) {
        plannedFiles = _collectPlannedFiles(_store[workId]!.selectedRoots);
        if (taskSnapshot.saveCover) {
          final coverFile = _plannedCoverFile(work);
          if (coverFile != null) plannedFiles.add(coverFile);
        }
        _plannedFilesMap[workId] = plannedFiles;
      }
      if (plannedFiles.isNotEmpty) {
        final client = HttpClient()
          ..maxConnectionsPerHost = _maxConcurrentFilesPerTask
          ..connectionTimeout = const Duration(seconds: 15);
        _activeHttpClients[workId] = client;
        final pendingFiles = ListQueue<_PlannedDownloadFile>.of(plannedFiles);
        final activeTransfers = <Future<void>>{};
        final transfersDone = Completer<void>();
        var transfersStopped = false;

        Future<void> downloadOneFile(_PlannedDownloadFile item) async {
          _throwIfCancelled(workId);
          final previousFileBytes = fileDownloadedBytes[item.relativePath] ?? 0;
          final wasAlreadyAccounted = completedFilePaths.contains(
            item.relativePath,
          );
          final wasFailed = failedFilePaths.contains(item.relativePath);
          final wasManualRetry = manuallyRetryingFilePaths.contains(
            item.relativePath,
          );
          _store[workId] = _store[workId]!.copyWith(
            currentItemPath: item.relativePath,
            message: item.relativePath,
          );
          _store.notifyProgressChanged(workId);

          final result = await _downloadItem(
            item,
            workId: workId,
            task: taskSnapshot,
            workRootPath: workRootPath,
            conflictPolicy: wasAlreadyAccounted
                ? AsmrDownloadConflictPolicy.skip
                : conflictPolicy,
            client: client,
          );

          if (result.saved || result.skipped) {
            if (!wasAlreadyAccounted) {
              if (result.saved) {
                completed++;
              } else {
                skipped++;
              }
            }
            completedFilePaths.add(item.relativePath);
            if (wasFailed && failedFilePaths.remove(item.relativePath)) {
              if (failed > 0) failed--;
            }
          } else if (!wasFailed && failedFilePaths.add(item.relativePath)) {
            failed++;
          }
          if (wasManualRetry) {
            manuallyRetryingFilePaths.remove(item.relativePath);
          }

          // Chunks are accounted for eagerly in the task store. Apply only
          // the difference not already represented by the live counter.
          final liveFileProgress = _store.liveFileDownloadedBytes(
            workId,
            fallback: fileDownloadedBytes,
          );
          final liveFileBytes =
              liveFileProgress[item.relativePath] ?? previousFileBytes;
          final unaccountedBytes = result.bytesDownloaded - liveFileBytes;
          if (unaccountedBytes != 0) {
            final liveBytes =
                _store.liveDownloadedBytes(workId) ?? downloadedBytes;
            _store.setLiveDownloadedBytes(workId, liveBytes + unaccountedBytes);
          }
          downloadedBytes =
              _store.liveDownloadedBytes(workId) ?? downloadedBytes;
          liveFileProgress[item.relativePath] = result.bytesDownloaded;
          fileDownloadedBytes[item.relativePath] = result.bytesDownloaded;

          _store[workId] = _store[workId]!.copyWith(
            completedFiles: completed,
            skippedFiles: skipped,
            failedFiles: failed,
            downloadedBytes:
                _store.liveDownloadedBytes(workId) ?? downloadedBytes,
            fileDownloadedBytes: fileDownloadedBytes,
            completedFilePaths: completedFilePaths,
            failedFilePaths: failedFilePaths,
            manuallyRetryingFilePaths: manuallyRetryingFilePaths,
          );
          _store.notifyProgressChanged(workId);
        }

        late void Function() pumpTransfers;
        void enqueueManualRetry(_PlannedDownloadFile item) {
          if (transfersStopped || transfersDone.isCompleted) return;
          manuallyRetryingFilePaths.add(item.relativePath);
          pendingFiles.add(item);
          pumpTransfers();
        }

        pumpTransfers = () {
          while (!transfersStopped &&
              pendingFiles.isNotEmpty &&
              activeTransfers.length < _maxConcurrentFilesPerTask) {
            final item = pendingFiles.removeFirst();
            late final Future<void> transfer;
            transfer = downloadOneFile(item);
            activeTransfers.add(transfer);
            unawaited(
              transfer.then<void>(
                (_) {
                  activeTransfers.remove(transfer);
                  pumpTransfers();
                },
                onError: (Object error, StackTrace stackTrace) {
                  activeTransfers.remove(transfer);
                  transfersStopped = true;
                  pendingFiles.clear();
                  client.close(force: true);
                  if (!transfersDone.isCompleted) {
                    transfersDone.completeError(error, stackTrace);
                  }
                },
              ),
            );
          }
          if (!transfersStopped &&
              pendingFiles.isEmpty &&
              activeTransfers.isEmpty &&
              !transfersDone.isCompleted) {
            transfersDone.complete();
          }
        };

        try {
          _activeFileRetryDispatchers[workId] = enqueueManualRetry;
          pumpTransfers();
          await transfersDone.future;
        } finally {
          _activeFileRetryDispatchers.remove(workId);
          if (identical(_activeHttpClients[workId], client)) {
            _activeHttpClients.remove(workId);
          }
          client.close(force: true);
        }
      }

      _throwIfCancelled(workId);
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
    } on _DownloadCancelled {
      final currentTask = _store[workId];
      if (!_disposed && currentTask != null) {
        if (_pauseRequested[workId] == true) {
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
      _activeFileRetryDispatchers.remove(workId);
      _manualRetryOnlyPaths.remove(workId);
      _plannedFilesMap.remove(workId);
      if (!_disposed &&
          _cancelRequested[workId] == true &&
          _pauseRequested[workId] != true &&
          _deleteDownloadedOnCancel[workId] == true) {
        await _cleanupCancelledTask(workId);
      }
      if (_cancelRequested[workId] == true) {
        _createdOutputPaths.remove(workId);
        _createdJsonDocuments.remove(workId);
      }
      _cancelRequested.remove(workId);
      _deleteDownloadedOnCancel.remove(workId);
      _pauseRequested.remove(workId);
      final completion = _downloadCompletions.remove(workId);
      if (completion != null && !completion.isCompleted) {
        completion.complete();
      }
      _activeTasks.remove(workId);
      _resumingTasks.remove(workId);
      _store.removeLiveProgress(workId);
      if (_store[workId]?.status == AsmrDownloadTaskStatus.completed) {
        _createdOutputPaths.remove(workId);
        _createdJsonDocuments.remove(workId);
      }
      if (!_disposed) {
        AppCacheService.scheduleEnforce();
        _processQueue();
      }
    }
  }

  Map<String, Object?> _persistedTaskToJson(AsmrDownloadTaskSnapshot task) =>
      _downloadTaskToJson(
        task,
        createdOutputPaths:
            _createdOutputPaths[task.work.id] ?? const <String>{},
        createdJsonDocuments:
            _createdJsonDocuments[task.work.id] ??
            const <String, _CreatedJsonDocument>{},
      );

  void _retainOnlyLatestCompletedTask(int workId) {
    for (final obsoleteWorkId in _store.retainOnlyLatestCompletedTask(workId)) {
      _createdOutputPaths.remove(obsoleteWorkId);
      _createdJsonDocuments.remove(obsoleteWorkId);
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
    final activeCompletions = _activeTasks
        .map((workId) => _downloadCompletions[workId]?.future)
        .whereType<Future<void>>()
        .toList(growable: false);
    _disposed = true;
    _queue.clear();
    _resumingTasks.clear();
    _manualRetryOnlyPaths.clear();
    _activeFileRetryDispatchers.clear();
    for (final workId in _activeTasks) {
      _cancelRequested[workId] = true;
    }
    for (final client in _activeHttpClients.values) {
      client.close(force: true);
    }
    _activeHttpClients.clear();
    await _store.shutdown(pauseWorkIds: runningWorkIds);
    await Future.wait<void>(activeCompletions);
  }

  void dispose() {
    unawaited(shutdown());
  }
}
