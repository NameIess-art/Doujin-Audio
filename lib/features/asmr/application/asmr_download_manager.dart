import 'dart:async';
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
import '../../../core/immutable_collections.dart';
import '../domain/asmr_download.dart';
import '../domain/asmr_models.dart';
import 'asmr_api_service.dart';
import '../../settings/application/app_cache_service.dart';
import '../../settings/application/app_preferences.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/platform/file_cache_platform_gateway.dart';
import '../../../core/media/path_display.dart';
import '../../../core/media/path_matcher.dart';
import '../../library/data/audio_detail_json_codec.dart';

part 'asmr_download_io.dart';
part 'asmr_download_models.dart';
part 'asmr_download_planner.dart';
part 'asmr_download_transfer_service.dart';
part 'asmr_download_task_store.dart';
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
       _persistTasks = persistTasks;

  static const Duration _progressNotifyMinInterval = Duration(
    milliseconds: 120,
  );
  static const int _maxCoverBytes = 5 * 1024 * 1024;
  final FileCachePlatformGateway _fileCacheGateway;
  final JsonDocumentStore _jsonDocumentStore;
  static const AudioDetailJsonCodec _audioDetailJsonCodec =
      AudioDetailJsonCodec();
  final Future<Directory> Function() _stagingDirectoryProvider;
  final Duration _automaticFileRetryDelay;
  final bool _persistTasks;

  final Map<int, AsmrDownloadTaskSnapshot> _tasks = {};
  List<int> _taskIdsSnapshot = const <int>[];
  final List<int> _queue = [];
  final Set<int> _startingTasks = {};
  final Set<int> _activeTasks = {};
  final Set<int> _resumingTasks = {};
  final Map<int, List<_PlannedDownloadFile>> _plannedFilesMap = {};

  final Map<int, bool> _cancelRequested = {};
  final Map<int, bool> _deleteDownloadedOnCancel = {};
  final Map<int, bool> _pauseRequested = {};
  final Map<int, Completer<void>> _downloadCompletions = {};
  final Map<int, HttpClient> _activeHttpClients = {};
  final Map<int, Set<String>> _createdOutputPaths = {};
  final Map<int, Map<String, _CreatedJsonDocument>> _createdJsonDocuments = {};
  final Map<int, int> _liveDownloadedBytes = {};
  final Map<int, Map<String, int>> _liveFileDownloadedBytes = {};
  final StreamController<int> _persistedUriReferenceRevisionController =
      StreamController<int>.broadcast(sync: true);
  final StreamController<List<int>> _taskIdsController =
      StreamController<List<int>>.broadcast(sync: true);
  final StreamController<({int workId, AsmrDownloadTaskSnapshot? task})>
  _taskChangesController =
      StreamController<
        ({int workId, AsmrDownloadTaskSnapshot? task})
      >.broadcast(sync: true);
  final StreamController<AsmrDownloadButtonViewState>
  _buttonViewStateController =
      StreamController<AsmrDownloadButtonViewState>.broadcast(sync: true);
  final Map<int, AsmrDownloadTaskSnapshot> _publishedTasks =
      <int, AsmrDownloadTaskSnapshot>{};
  int _aggregateTotalBytes = 0;
  int _aggregateDownloadedBytes = 0;
  AsmrDownloadButtonViewState _publishedButtonViewState =
      const AsmrDownloadButtonViewState(visible: false, progress: null);

  static const int _maxConcurrentFilesPerTask = 3;
  int _maxConcurrentDownloads;

  bool _disposed = false;
  bool _initialized = false;
  int _persistedUriReferenceRevision = 0;
  Set<String> _persistedContentUris = const <String>{};
  Future<void>? _initializationFuture;
  Future<void> _persistenceTail = Future<void>.value();
  Timer? _deferredPersistenceTimer;
  Timer? _deferredProgressNotifyTimer;
  DateTime? _lastProgressNotifyAt;
  final Set<int> _pendingProgressWorkIds = <int>{};

  List<AsmrDownloadTaskSnapshot> get tasks => _tasks.values.toList();
  List<int> get taskIds => _taskIdsSnapshot;
  AsmrDownloadTaskSnapshot? getTask(int workId) => _tasks[workId];
  Stream<List<int>> get taskIdsStream => Stream<List<int>>.multi((events) {
    events.addSync(taskIds);
    final subscription = _taskIdsController.stream.listen(
      events.addSync,
      onError: events.addErrorSync,
      onDone: events.closeSync,
    );
    events.onCancel = subscription.cancel;
  }, isBroadcast: true);

  Stream<AsmrDownloadTaskSnapshot?> taskStream(int workId) =>
      Stream<AsmrDownloadTaskSnapshot?>.multi((events) {
        events.addSync(getTask(workId));
        final subscription = _taskChangesController.stream
            .where((change) => change.workId == workId)
            .map((change) => change.task)
            .listen(
              events.addSync,
              onError: events.addErrorSync,
              onDone: events.closeSync,
            );
        events.onCancel = subscription.cancel;
      }, isBroadcast: true);

  Stream<AsmrDownloadButtonViewState> get buttonViewStateStream =>
      Stream<AsmrDownloadButtonViewState>.multi((events) {
        events.addSync(buttonViewState);
        final subscription = _buttonViewStateController.stream.listen(
          events.addSync,
          onError: events.addErrorSync,
          onDone: events.closeSync,
        );
        events.onCancel = subscription.cancel;
      }, isBroadcast: true);

  void setMaxConcurrentDownloads(int count) {
    final normalized = normalizeAsmrDownloadThreadCount(count);
    if (_maxConcurrentDownloads == normalized) return;
    _maxConcurrentDownloads = normalized;
    _processQueue();
  }

  bool get hasLiveTask => _activeTasks.isNotEmpty || _queue.isNotEmpty;
  bool get persistedUriReferencesReady => _initialized;
  int get persistedUriReferenceRevision => _persistedUriReferenceRevision;
  Stream<int> get persistedUriReferenceRevisions =>
      _persistedUriReferenceRevisionController.stream;
  Set<String> get persistedContentUris => _persistedContentUris;

  AsmrDownloadButtonViewState get buttonViewState {
    if (_taskIdsSnapshot.isEmpty) {
      return const AsmrDownloadButtonViewState(visible: false, progress: null);
    }
    double? progress;
    if (_aggregateTotalBytes > 0) {
      progress = (_aggregateDownloadedBytes / _aggregateTotalBytes).clamp(
        0.0,
        1.0,
      );
    }
    return AsmrDownloadButtonViewState(visible: true, progress: progress);
  }

  AsmrDownloadTaskShellViewState get taskShellViewState =>
      AsmrDownloadTaskShellViewState(
        hasTask: _taskIdsSnapshot.isNotEmpty,
        isActive: hasLiveTask,
      );

  @visibleForTesting
  void debugSetCurrentTaskForTesting(
    AsmrDownloadTaskSnapshot? task, {
    bool progressOnly = false,
  }) {
    if (task != null) {
      _tasks[task.work.id] = task;
      if (task.status == AsmrDownloadTaskStatus.completed) {
        _retainOnlyLatestCompletedTask(task.work.id);
      }
    }
    if (progressOnly && task != null) {
      _notifyProgressChanged(task.work.id);
    } else {
      _notifyTaskChanged();
    }
  }

  @visibleForTesting
  void debugRecordDownloadChunkForTesting(
    int workId,
    String relativePath,
    int chunkLength,
    int fileDownloadedBytes,
  ) {
    _recordDownloadChunk(
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
              _tasks[task.work.id] = task.copyWith(
                status: AsmrDownloadTaskStatus.paused,
                fileRetryAttempts: const <String, int>{},
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
    _notifyTaskChanged(forcePersistedUriReferenceRevision: true);
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
    final task = _tasks[workId];
    if (task == null) {
      return;
    }

    if (_queue.contains(workId)) {
      _queue.remove(workId);
      _resumingTasks.remove(workId);
      _createdOutputPaths.remove(workId);
      _createdJsonDocuments.remove(workId);
      _tasks.remove(workId);
      _notifyTaskChanged();
      await _persistenceTail;
      return;
    }

    if (_activeTasks.contains(workId)) {
      _pauseRequested.remove(workId);
      _cancelRequested[workId] = true;
      _deleteDownloadedOnCancel[workId] = deleteDownloaded;
      _tasks[workId] = task.copyWith(message: 'canceling');
      _notifyTaskChanged();
      final completion = _downloadCompletions[workId]?.future;
      _activeHttpClients[workId]?.close(force: true);
      if (completion != null) {
        await completion;
      }
      _tasks.remove(workId);
      _notifyTaskChanged();
      await _persistenceTail;
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
    _tasks.remove(workId);
    _notifyTaskChanged();
    await _persistenceTail;
  }

  Future<void> deleteTask(int workId) async {
    final task = _tasks[workId];
    if (task == null) return;
    final workRootPath = task.workRootPath;
    final coverOutputPath = task.coverOutputPath;
    if (_activeTasks.contains(workId) || _queue.contains(workId)) {
      await cancelTask(workId);
    } else {
      _tasks.remove(workId);
      _notifyTaskChanged();
      await _persistenceTail;
    }
    await _deleteDownloadRoot(workRootPath);
    if (coverOutputPath != null) {
      await _deleteOutputPath(coverOutputPath);
    }
    _createdOutputPaths.remove(workId);
    _createdJsonDocuments.remove(workId);
    _resumingTasks.remove(workId);
  }

  Future<void> pauseTask(int workId) async {
    final task = _tasks[workId];
    if (task == null) return;

    if (_activeTasks.contains(workId)) {
      _pauseRequested[workId] = true;
      final completion = _downloadCompletions[workId]?.future;
      _activeHttpClients[workId]?.close(force: true);
      if (completion != null) await completion;
      await _persistenceTail;
    } else if (_queue.contains(workId)) {
      _queue.remove(workId);
      _tasks[workId] = task.copyWith(
        status: AsmrDownloadTaskStatus.paused,
        fileRetryAttempts: const <String, int>{},
        message: 'paused',
      );
      _notifyTaskChanged();
      await _persistenceTail;
    }
  }

  Future<void> pauseAllTasks() async {
    if (_disposed) return;
    await initialize();
    if (_disposed) return;

    final queuedWorkIds = List<int>.of(_queue);
    _queue.clear();
    for (final workId in queuedWorkIds) {
      final task = _tasks[workId];
      if (task == null) continue;
      _tasks[workId] = task.copyWith(
        status: AsmrDownloadTaskStatus.paused,
        fileRetryAttempts: const <String, int>{},
        message: 'paused',
      );
    }

    final activeWorkIds = List<int>.of(_activeTasks);
    for (final workId in activeWorkIds) {
      _pauseRequested[workId] = true;
      _activeHttpClients[workId]?.close(force: true);
    }
    if (queuedWorkIds.isNotEmpty || activeWorkIds.isNotEmpty) {
      _notifyTaskChanged();
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
    final task = _tasks[workId];
    if (task == null ||
        (task.status != AsmrDownloadTaskStatus.paused &&
            task.status != AsmrDownloadTaskStatus.failed)) {
      return;
    }
    _enqueueExistingTask(task);
  }

  void _enqueueExistingTask(AsmrDownloadTaskSnapshot task) {
    final workId = task.work.id;
    _resumingTasks.add(workId);
    _tasks[workId] = task.copyWith(
      status: AsmrDownloadTaskStatus.idle,
      message: 'queued',
    );
    if (!_queue.contains(workId)) {
      _queue.add(workId);
    }
    _notifyTaskChanged();
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
      final existingTask = _tasks[workId];
      if (existingTask != null) {
        if (existingTask.isActive ||
            _queue.contains(workId) ||
            _activeTasks.contains(workId)) {
          return; // Already downloading or queued
        }
        if (existingTask.status == AsmrDownloadTaskStatus.paused ||
            existingTask.status == AsmrDownloadTaskStatus.failed) {
          _enqueueExistingTask(existingTask);
          await _persistenceTail;
          return;
        }
        _tasks.remove(workId);
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

      _tasks[workId] = AsmrDownloadTaskSnapshot(
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
      _notifyTaskChanged();
      await _persistenceTail;
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
    final taskSnapshot = _tasks[workId];
    if (taskSnapshot == null) {
      _activeTasks.remove(workId);
      _processQueue();
      return;
    }

    _downloadCompletions[workId] = Completer<void>();
    _cancelRequested[workId] = false;

    _tasks[workId] = taskSnapshot.copyWith(
      status: AsmrDownloadTaskStatus.preparing,
      message: 'preparing',
    );
    _notifyTaskChanged();

    final work = taskSnapshot.work;
    final normalizedDestination = taskSnapshot.destinationRoot;
    final workFolderName = taskSnapshot.workFolderName;
    final workRootPath = taskSnapshot.workRootPath;
    final conflictPolicy = taskSnapshot.conflictPolicy;

    final saveMetadata = taskSnapshot.saveMetadata;
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

      final resumedTask = _tasks[workId]!;
      var completed = resumedTask.completedFiles;
      var skipped = resumedTask.skippedFiles;
      var failed = 0;
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

      _tasks[workId] = resumedTask.copyWith(
        status: AsmrDownloadTaskStatus.downloading,
        completedFiles: completed,
        failedFiles: 0,
        downloadedBytes: downloadedBytes,
        message: saveMetadata ? 'downloading_work_detail' : 'downloading',
      );
      _notifyTaskChanged();
      _liveDownloadedBytes[workId] = downloadedBytes;
      _liveFileDownloadedBytes[workId] = fileDownloadedBytes;
      final fileTotalBytes = _tasks[workId]!.fileTotalBytes;

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
        plannedFiles = _collectPlannedFiles(_tasks[workId]!.selectedRoots);
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
        var nextFileIndex = 0;
        var stopWorkers = false;

        Future<void> downloadNextFiles() async {
          try {
            while (!stopWorkers) {
              _throwIfCancelled(workId);
              final fileIndex = nextFileIndex;
              if (fileIndex >= plannedFiles!.length) return;
              nextFileIndex++;
              final item = plannedFiles[fileIndex];
              final previousFileBytes =
                  fileDownloadedBytes[item.relativePath] ?? 0;
              final wasAlreadyAccounted = completedFilePaths.contains(
                item.relativePath,
              );
              _tasks[workId] = _tasks[workId]!.copyWith(
                currentItemPath: item.relativePath,
                message: item.relativePath,
              );
              _notifyProgressChanged(workId);

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

              if (result.saved && !wasAlreadyAccounted) {
                completed++;
              } else if (result.skipped && !wasAlreadyAccounted) {
                skipped++;
              } else {
                if (!result.saved && !result.skipped) failed++;
              }
              // Chunks are accounted for eagerly in `_liveDownloadedBytes`.
              // A completed/skipped file may not have emitted chunks (for
              // example when resuming an already complete staging file), so
              // only apply the difference that is not already represented by
              // the live per-file counter. Never replace the aggregate with
              // the local value: another worker may still be downloading.
              final liveFileProgress = _liveFileDownloadedBytes.putIfAbsent(
                workId,
                () => Map<String, int>.from(fileDownloadedBytes),
              );
              final liveFileBytes =
                  liveFileProgress[item.relativePath] ?? previousFileBytes;
              final unaccountedBytes = result.bytesDownloaded - liveFileBytes;
              if (unaccountedBytes != 0) {
                final liveBytes =
                    _liveDownloadedBytes[workId] ?? downloadedBytes;
                _liveDownloadedBytes[workId] = liveBytes + unaccountedBytes;
              }
              downloadedBytes = _liveDownloadedBytes[workId] ?? downloadedBytes;
              liveFileProgress[item.relativePath] = result.bytesDownloaded;
              fileDownloadedBytes[item.relativePath] = result.bytesDownloaded;
              if (result.saved || result.skipped) {
                completedFilePaths.add(item.relativePath);
              }

              _tasks[workId] = _tasks[workId]!.copyWith(
                completedFiles: completed,
                skippedFiles: skipped,
                failedFiles: failed,
                downloadedBytes:
                    _liveDownloadedBytes[workId] ?? downloadedBytes,
                fileDownloadedBytes: fileDownloadedBytes,
                completedFilePaths: completedFilePaths,
              );
              _notifyProgressChanged(workId);
            }
          } catch (_) {
            stopWorkers = true;
            client.close(force: true);
            rethrow;
          }
        }

        try {
          final workerCount = plannedFiles.length.clamp(
            1,
            _maxConcurrentFilesPerTask,
          );
          await Future.wait<void>(
            List<Future<void>>.generate(
              workerCount,
              (_) => downloadNextFiles(),
            ),
          );
        } finally {
          if (identical(_activeHttpClients[workId], client)) {
            _activeHttpClients.remove(workId);
          }
          client.close(force: true);
        }
      }

      _throwIfCancelled(workId);
      final finalDownloadedBytes = failed > 0
          ? downloadedBytes
          : _tasks[workId]!.totalBytes;
      _liveDownloadedBytes[workId] = finalDownloadedBytes;
      _liveFileDownloadedBytes[workId] = fileDownloadedBytes;
      _tasks[workId] = _tasks[workId]!.copyWith(
        status: failed > 0
            ? AsmrDownloadTaskStatus.failed
            : AsmrDownloadTaskStatus.completed,
        completedFiles: completed,
        skippedFiles: skipped,
        failedFiles: failed,
        downloadedBytes: finalDownloadedBytes,
        fileDownloadedBytes: fileDownloadedBytes,
        fileRetryAttempts: const <String, int>{},
        message: failed > 0 ? 'completed_with_failures' : 'completed',
      );
      if (failed == 0) {
        _retainOnlyLatestCompletedTask(workId);
      }
      _notifyTaskChanged();
    } on _DownloadCancelled {
      final currentTask = _tasks[workId];
      if (!_disposed && currentTask != null) {
        if (_pauseRequested[workId] == true) {
          _tasks[workId] = currentTask.copyWith(
            status: AsmrDownloadTaskStatus.paused,
            fileRetryAttempts: const <String, int>{},
            message: 'paused',
          );
        } else {
          _tasks[workId] = currentTask.copyWith(
            status: AsmrDownloadTaskStatus.failed,
            fileRetryAttempts: const <String, int>{},
            message: 'cancelled',
          );
        }
        _notifyTaskChanged();
      }
    } catch (error, stackTrace) {
      final currentTask = _tasks[workId];
      if (!_disposed) {
        AppLogService.error(
          'asmr_download_failed',
          error: error,
          stackTrace: stackTrace,
        );
      }
      if (!_disposed && currentTask != null) {
        _tasks[workId] = currentTask.copyWith(
          status: AsmrDownloadTaskStatus.failed,
          fileRetryAttempts: const <String, int>{},
          error: error.toString(),
          message: 'failed',
        );
        _notifyTaskChanged();
      }
    } finally {
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
      _liveDownloadedBytes.remove(workId);
      _liveFileDownloadedBytes.remove(workId);
      if (_tasks[workId]?.status == AsmrDownloadTaskStatus.completed) {
        _createdOutputPaths.remove(workId);
        _createdJsonDocuments.remove(workId);
      }
      if (!_disposed) {
        AppCacheService.scheduleEnforce();
        _processQueue();
      }
    }
  }

  void dispose() {
    if (_disposed) return;
    _deferredPersistenceTimer?.cancel();
    _deferredPersistenceTimer = null;
    _publishLiveProgress();
    for (final workId in <int>{..._queue, ..._activeTasks}) {
      final task = _tasks[workId];
      if (task != null) {
        _tasks[workId] = task.copyWith(
          status: AsmrDownloadTaskStatus.paused,
          fileRetryAttempts: const <String, int>{},
          message: 'paused',
        );
      }
    }
    _persistCurrentTasks();
    _disposed = true;
    _deferredProgressNotifyTimer?.cancel();
    _deferredProgressNotifyTimer = null;
    _pendingProgressWorkIds.clear();
    _queue.clear();
    _resumingTasks.clear();
    for (final workId in _activeTasks) {
      _cancelRequested[workId] = true;
    }
    for (final client in _activeHttpClients.values) {
      client.close(force: true);
    }
    _activeHttpClients.clear();
    _liveDownloadedBytes.clear();
    _liveFileDownloadedBytes.clear();
    unawaited(_persistedUriReferenceRevisionController.close());
    unawaited(_taskIdsController.close());
    unawaited(_taskChangesController.close());
    unawaited(_buttonViewStateController.close());
  }
}
