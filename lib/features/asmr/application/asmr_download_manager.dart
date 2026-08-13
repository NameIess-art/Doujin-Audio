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

const String _asmrMediaAcceptLanguage = 'zh-CN,zh;q=0.9,en;q=0.8';

@visibleForTesting
Map<String, String> asmrMediaRequestHeadersForUrl(String url) {
  return AsmrApiService.isOfficialMediaUrl(url)
      ? const <String, String>{
          HttpHeaders.acceptLanguageHeader: _asmrMediaAcceptLanguage,
        }
      : const <String, String>{};
}

@visibleForTesting
bool isValidDownloadContentRange(
  String? value, {
  required int expectedStart,
  required int responseLength,
  required int expectedTotal,
}) {
  final match = value == null
      ? null
      : RegExp(r'^bytes (\d+)-(\d+)/(\d+|\*)$').firstMatch(value);
  final start = int.tryParse(match?.group(1) ?? '');
  final end = int.tryParse(match?.group(2) ?? '');
  final total = int.tryParse(match?.group(3) ?? '');
  final rangeLength = start == null || end == null ? -1 : end - start + 1;
  return start == expectedStart &&
      rangeLength > 0 &&
      (responseLength <= 0 || responseLength == rangeLength) &&
      (expectedTotal <= 0 || total == null || total == expectedTotal);
}

@visibleForTesting
String? selectDownloadResumeValidator({String? etag, String? lastModified}) {
  final normalizedEtag = etag?.trim();
  if (normalizedEtag != null &&
      normalizedEtag.length >= 2 &&
      normalizedEtag.startsWith('"') &&
      normalizedEtag.endsWith('"')) {
    return normalizedEtag;
  }
  final normalizedLastModified = lastModified?.trim();
  return normalizedLastModified == null || normalizedLastModified.isEmpty
      ? null
      : normalizedLastModified;
}

typedef LocalFileRename =
    Future<File> Function(File source, String destination);

@visibleForTesting
Future<bool> commitLocalDownloadedFile({
  required File staging,
  required File target,
  LocalFileRename? rename,
}) async {
  final renameFile =
      rename ?? (source, destination) => source.rename(destination);
  final backup = File('${target.path}.doujin.bak');

  if (!await target.exists() && await backup.exists()) {
    await renameFile(backup, target.path);
  }
  if (await target.exists()) {
    if (await backup.exists()) {
      throw FileSystemException(
        'Cannot replace file while a previous backup is still present.',
        backup.path,
      );
    }
    await renameFile(target, backup.path);
  }

  try {
    await renameFile(staging, target.path);
  } catch (error, stackTrace) {
    try {
      if (await backup.exists()) {
        if (await target.exists()) await target.delete();
        await renameFile(backup, target.path);
      }
    } catch (rollbackError, rollbackStackTrace) {
      AppLogService.error(
        'commitLocalDownloadedFile rollback failed',
        error: rollbackError,
        stackTrace: rollbackStackTrace,
      );
    }
    Error.throwWithStackTrace(error, stackTrace);
  }

  try {
    if (await backup.exists()) await backup.delete();
  } catch (error, stackTrace) {
    AppLogService.warning(
      'commitLocalDownloadedFile backup cleanup failed',
      error: error,
      stackTrace: stackTrace,
    );
  }
  return true;
}

enum AsmrDownloadTaskStatus {
  idle,
  preparing,
  downloading,
  paused,
  completed,
  failed,
}

class AsmrDownloadTaskSnapshot {
  AsmrDownloadTaskSnapshot({
    required this.work,
    required this.destinationRoot,
    required this.workFolderName,
    required this.conflictPolicy,
    this.saveMetadata = true,
    required this.status,
    required this.totalFiles,
    required this.completedFiles,
    required this.skippedFiles,
    required this.failedFiles,
    required this.totalBytes,
    required this.downloadedBytes,
    required this.startedAt,
    this.currentItemPath,
    this.message,
    this.error,
    Map<String, int> fileDownloadedBytes = const {},
    Map<String, int> fileTotalBytes = const {},
    Map<String, int> fileRetryAttempts = const {},
    Map<String, String> fileResumeValidators = const {},
    Set<String> completedFilePaths = const {},
    List<AsmrTrackFile> selectedRoots = const [],
  }) : fileDownloadedBytes = immutableMap(fileDownloadedBytes),
       fileTotalBytes = immutableMap(fileTotalBytes),
       fileRetryAttempts = immutableMap(fileRetryAttempts),
       fileResumeValidators = immutableMap(fileResumeValidators),
       completedFilePaths = immutableSet(completedFilePaths),
       selectedRoots = immutableList(selectedRoots);

  final AsmrWork work;
  final String destinationRoot;
  final String workFolderName;
  final AsmrDownloadConflictPolicy conflictPolicy;
  final bool saveMetadata;
  final AsmrDownloadTaskStatus status;
  final int totalFiles;
  final int completedFiles;
  final int skippedFiles;
  final int failedFiles;
  final int totalBytes;
  final int downloadedBytes;
  final DateTime startedAt;
  final String? currentItemPath;
  final String? message;
  final String? error;
  final Map<String, int> fileDownloadedBytes;
  final Map<String, int> fileTotalBytes;
  final Map<String, int> fileRetryAttempts;
  final Map<String, String> fileResumeValidators;
  final Set<String> completedFilePaths;
  final List<AsmrTrackFile> selectedRoots;

  String get workRootPath {
    if (PathMatcher.isContentUri(destinationRoot)) {
      final normalizedRoot = destinationRoot.trim().replaceAll(
        RegExp(r'/+$'),
        '',
      );
      return '$normalizedRoot::$workFolderName';
    }
    return path.join(destinationRoot, workFolderName);
  }

  String get displayDestinationPath => PathDisplay.displayPathFor(workRootPath);

  bool get isActive =>
      status == AsmrDownloadTaskStatus.preparing ||
      status == AsmrDownloadTaskStatus.downloading;

  double? get progress {
    if (totalBytes > 0) {
      return (downloadedBytes / totalBytes).clamp(0.0, 1.0);
    }
    if (totalFiles > 0) {
      return (completedFiles / totalFiles).clamp(0.0, 1.0);
    }
    return null;
  }

  AsmrDownloadTaskSnapshot copyWith({
    AsmrDownloadTaskStatus? status,
    AsmrDownloadConflictPolicy? conflictPolicy,
    int? totalFiles,
    int? completedFiles,
    int? skippedFiles,
    int? failedFiles,
    int? totalBytes,
    int? downloadedBytes,
    String? currentItemPath,
    String? message,
    String? error,
    Map<String, int>? fileDownloadedBytes,
    Map<String, int>? fileTotalBytes,
    Map<String, int>? fileRetryAttempts,
    Map<String, String>? fileResumeValidators,
    Set<String>? completedFilePaths,
    List<AsmrTrackFile>? selectedRoots,
  }) {
    return AsmrDownloadTaskSnapshot(
      work: work,
      destinationRoot: destinationRoot,
      workFolderName: workFolderName,
      conflictPolicy: conflictPolicy ?? this.conflictPolicy,
      saveMetadata: saveMetadata,
      status: status ?? this.status,
      totalFiles: totalFiles ?? this.totalFiles,
      completedFiles: completedFiles ?? this.completedFiles,
      skippedFiles: skippedFiles ?? this.skippedFiles,
      failedFiles: failedFiles ?? this.failedFiles,
      totalBytes: totalBytes ?? this.totalBytes,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      startedAt: startedAt,
      currentItemPath: currentItemPath ?? this.currentItemPath,
      message: message ?? this.message,
      error: error ?? this.error,
      fileDownloadedBytes: fileDownloadedBytes ?? this.fileDownloadedBytes,
      fileTotalBytes: fileTotalBytes ?? this.fileTotalBytes,
      fileRetryAttempts: fileRetryAttempts ?? this.fileRetryAttempts,
      fileResumeValidators: fileResumeValidators ?? this.fileResumeValidators,
      completedFilePaths: completedFilePaths ?? this.completedFilePaths,
      selectedRoots: selectedRoots ?? this.selectedRoots,
    );
  }
}

class AsmrDownloadState {
  AsmrDownloadState({
    required List<int> taskIds,
    required Map<int, AsmrDownloadTaskSnapshot> tasksByWorkId,
  }) : taskIds = immutableList(taskIds),
       tasksByWorkId = immutableMap(tasksByWorkId);

  static final empty = AsmrDownloadState(
    taskIds: const <int>[],
    tasksByWorkId: const <int, AsmrDownloadTaskSnapshot>{},
  );

  factory AsmrDownloadState.fromManager(AsmrDownloadManager manager) {
    return AsmrDownloadState(
      taskIds: manager.taskIds,
      tasksByWorkId: Map<int, AsmrDownloadTaskSnapshot>.unmodifiable(
        manager._tasks,
      ),
    );
  }

  final List<int> taskIds;
  final Map<int, AsmrDownloadTaskSnapshot> tasksByWorkId;

  AsmrDownloadTaskSnapshot? taskFor(int workId) => tasksByWorkId[workId];

  @override
  bool operator ==(Object other) {
    return other is AsmrDownloadState &&
        listEquals(other.taskIds, taskIds) &&
        mapEquals(other.tasksByWorkId, tasksByWorkId);
  }

  @override
  int get hashCode => Object.hash(
    Object.hashAll(taskIds),
    Object.hashAll(tasksByWorkId.entries),
  );
}

class AsmrDownloadButtonViewState {
  const AsmrDownloadButtonViewState({
    required this.visible,
    required this.progress,
  });

  final bool visible;
  final double? progress;

  @override
  bool operator ==(Object other) {
    return other is AsmrDownloadButtonViewState &&
        visible == other.visible &&
        progress == other.progress;
  }

  @override
  int get hashCode => Object.hash(visible, progress);
}

class AsmrDownloadTaskShellViewState {
  const AsmrDownloadTaskShellViewState({
    required this.hasTask,
    required this.isActive,
  });

  final bool hasTask;
  final bool isActive;

  @override
  bool operator ==(Object other) {
    return other is AsmrDownloadTaskShellViewState &&
        hasTask == other.hasTask &&
        isActive == other.isActive;
  }

  @override
  int get hashCode => Object.hash(hasTask, isActive);
}

class AsmrDownloadTaskProgressViewState {
  const AsmrDownloadTaskProgressViewState({
    required this.progress,
    required this.status,
    required this.completedFiles,
    required this.totalFiles,
    required this.skippedFiles,
    required this.failedFiles,
    required this.downloadedBytes,
    required this.totalBytes,
  });

  final double? progress;
  final AsmrDownloadTaskStatus status;
  final int completedFiles;
  final int totalFiles;
  final int skippedFiles;
  final int failedFiles;
  final int downloadedBytes;
  final int totalBytes;

  @override
  bool operator ==(Object other) {
    return other is AsmrDownloadTaskProgressViewState &&
        progress == other.progress &&
        status == other.status &&
        completedFiles == other.completedFiles &&
        totalFiles == other.totalFiles &&
        skippedFiles == other.skippedFiles &&
        failedFiles == other.failedFiles &&
        downloadedBytes == other.downloadedBytes &&
        totalBytes == other.totalBytes;
  }

  @override
  int get hashCode => Object.hash(
    progress,
    status,
    completedFiles,
    totalFiles,
    skippedFiles,
    failedFiles,
    downloadedBytes,
    totalBytes,
  );
}

class AsmrDownloadTaskHeaderViewState {
  const AsmrDownloadTaskHeaderViewState({
    required this.title,
    required this.status,
    required this.currentItemPath,
    required this.error,
    required this.failedFiles,
    required this.completedFiles,
  });

  final String title;
  final AsmrDownloadTaskStatus status;
  final String? currentItemPath;
  final String? error;
  final int failedFiles;
  final int completedFiles;

  @override
  bool operator ==(Object other) {
    return other is AsmrDownloadTaskHeaderViewState &&
        title == other.title &&
        status == other.status &&
        currentItemPath == other.currentItemPath &&
        error == other.error &&
        failedFiles == other.failedFiles &&
        completedFiles == other.completedFiles;
  }

  @override
  int get hashCode => Object.hash(
    title,
    status,
    currentItemPath,
    error,
    failedFiles,
    completedFiles,
  );
}

class AsmrDownloadManager extends ChangeNotifier {
  AsmrDownloadManager({
    FileCachePlatformGateway? fileCacheGateway,
    JsonDocumentStore? jsonDocumentStore,
    Future<Directory> Function()? temporaryDirectoryProvider,
    Future<Directory> Function()? stagingDirectoryProvider,
    Duration automaticFileRetryDelay = const Duration(seconds: 2),
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
       _persistTasks = persistTasks;

  static const Duration _progressNotifyMinInterval = Duration(
    milliseconds: 120,
  );
  static const int maxAutomaticFileRetries = 10;
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

  static const int _maxConcurrentDownloads = 3;
  static const int _maxConcurrentFilesPerTask = 3;

  bool _disposed = false;
  bool _initialized = false;
  int _persistedUriReferenceRevision = 0;
  Set<String> _persistedContentUris = const <String>{};
  Future<void>? _initializationFuture;
  Future<void> _persistenceTail = Future<void>.value();
  Timer? _deferredPersistenceTimer;
  Timer? _deferredProgressNotifyTimer;
  DateTime? _lastProgressNotifyAt;

  List<AsmrDownloadTaskSnapshot> get tasks => _tasks.values.toList();
  List<int> get taskIds => _taskIdsSnapshot;
  AsmrDownloadTaskSnapshot? getTask(int workId) => _tasks[workId];
  AsmrDownloadState get state => AsmrDownloadState.fromManager(this);
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
    int totalBytes = 0;
    int downloadedBytes = 0;
    for (final t in _tasks.values) {
      // Keep completed bytes in the aggregate while another task is still
      // running. Completed snapshots are retained briefly, and dropping them
      // here makes the circular progress jump backwards as soon as one task
      // finishes.
      if (t.isActive || t.status == AsmrDownloadTaskStatus.completed) {
        totalBytes += t.totalBytes;
        downloadedBytes += t.downloadedBytes;
      }
    }
    double? progress;
    if (totalBytes > 0) {
      progress = (downloadedBytes / totalBytes).clamp(0.0, 1.0);
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
    if (progressOnly) {
      _notifyProgressChanged();
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
    _tasks.remove(workId);
    _notifyTaskChanged();
    await _persistenceTail;
  }

  Future<void> deleteTask(int workId) async {
    final task = _tasks[workId];
    if (task == null) return;
    final workRootPath = task.workRootPath;
    if (_activeTasks.contains(workId) || _queue.contains(workId)) {
      await cancelTask(workId);
    } else {
      _tasks.remove(workId);
      _notifyTaskChanged();
      await _persistenceTail;
    }
    await _deleteDownloadRoot(workRootPath);
    _createdOutputPaths.remove(workId);
    _createdJsonDocuments.remove(workId);
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
        message: 'paused',
      );
      _notifyTaskChanged();
      await _persistenceTail;
    }
  }

  Future<void> resumeTask(int workId) async {
    if (_disposed) return;
    final task = _tasks[workId];
    if (task == null || task.status != AsmrDownloadTaskStatus.paused) {
      return;
    }
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
        _tasks.remove(workId);
      }

      final workFolderName = buildAsmrDownloadWorkFolderName(
        work,
        folderNameFields,
      );
      final plannedFiles = _collectPlannedFiles(selectedRoots);
      for (final file in plannedFiles) {
        _validatedDownloadRelativePath(file.relativePath);
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
        fileTotalBytes[file.relativePath] = file.size;
      }
      _plannedFilesMap[workId] = plannedFiles;

      _tasks[workId] = AsmrDownloadTaskSnapshot(
        work: work,
        destinationRoot: normalizedDestination,
        workFolderName: workFolderName,
        conflictPolicy: conflictPolicy,
        saveMetadata: saveMetadata,
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
              _notifyProgressChanged();

              final result = await _downloadItem(
                item,
                workId: workId,
                workRootPath: workRootPath,
                conflictPolicy: wasAlreadyAccounted
                    ? AsmrDownloadConflictPolicy.skip
                    : conflictPolicy,
                client: client,
              );
              _setFileResumeValidator(workId, item.relativePath, null);

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
              _notifyProgressChanged();
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
            message: 'paused',
          );
        } else {
          _tasks[workId] = currentTask.copyWith(
            status: AsmrDownloadTaskStatus.failed,
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

  List<_PlannedDownloadFile> _collectPlannedFiles(List<AsmrTrackFile> roots) {
    final result = <_PlannedDownloadFile>[];
    for (final root in roots) {
      _collectPlannedFilesRecursively(root, result);
    }
    return result;
  }

  void _collectPlannedFilesRecursively(
    AsmrTrackFile node,
    List<_PlannedDownloadFile> result,
  ) {
    if (node.isFolder) {
      if (node.children.isEmpty) {
        return;
      }
      for (final child in node.children) {
        _collectPlannedFilesRecursively(child, result);
      }
      return;
    }
    final url = _downloadUrlFor(node);
    if (url == null || url.isEmpty) {
      return;
    }
    result.add(
      _PlannedDownloadFile(
        node: node,
        url: url,
        relativePath: node.relativePath,
        size: node.size,
      ),
    );
  }

  Future<_WriteResult> _downloadItem(
    _PlannedDownloadFile item, {
    required int workId,
    required String workRootPath,
    required AsmrDownloadConflictPolicy conflictPolicy,
    required HttpClient client,
  }) async {
    _throwIfCancelled(workId);
    final normalizedRelativePath = _validatedDownloadRelativePath(
      item.relativePath,
    );
    final preserveExistingJson =
        path.extension(normalizedRelativePath).toLowerCase() == '.json';
    final jsonLocation = preserveExistingJson
        ? _jsonDownloadLocation(workRootPath, normalizedRelativePath)
        : null;
    if (jsonLocation != null) {
      final existingJson = await _jsonDocumentStore.read(jsonLocation);
      if (existingJson.status == JsonDocumentReadStatus.found) {
        return _WriteResult.skipped(bytesDownloaded: item.size);
      }
    }

    File? localTargetFile;
    if (!PathMatcher.isContentUri(workRootPath)) {
      localTargetFile = File(
        _resolveLocalPathWithin(workRootPath, normalizedRelativePath),
      );
      if ((preserveExistingJson ||
              conflictPolicy == AsmrDownloadConflictPolicy.skip) &&
          await localTargetFile.exists()) {
        return _WriteResult.skipped(bytesDownloaded: item.size);
      }
      await localTargetFile.parent.create(recursive: true);
    } else {
      final docPath = _joinFolderPath(workRootPath, normalizedRelativePath);
      if (await _fileCacheGateway.documentPathExists(docPath)) {
        if (preserveExistingJson ||
            conflictPolicy == AsmrDownloadConflictPolicy.skip) {
          return _WriteResult.skipped(bytesDownloaded: item.size);
        }
      }
    }

    final stagingFile = localTargetFile == null || jsonLocation != null
        ? await _persistentStagingFile(workRootPath, normalizedRelativePath)
        : File('${localTargetFile.path}.doujin.part');
    final stagingExisted = await stagingFile.exists();
    if (!stagingExisted) _createdOutputPaths[workId]?.add(stagingFile.path);
    final tempResult = await _downloadToTemporaryFile(
      item,
      workId: workId,
      client: client,
      stagingFile: stagingFile,
    );
    if (tempResult == null) {
      return const _WriteResult.failure(bytesDownloaded: 0);
    }

    try {
      _throwIfCancelled(workId);
      if (jsonLocation != null) {
        final parentRelative = path.posix.dirname(normalizedRelativePath);
        if (parentRelative != '.' &&
            !await _ensureFolderPath(
              basePath: workRootPath,
              relativePath: parentRelative,
              overwrite: false,
            )) {
          return _WriteResult.failure(
            bytesDownloaded: tempResult.bytesDownloaded,
          );
        }
        final write = await _jsonDocumentStore.write(
          location: jsonLocation,
          bytes: await tempResult.file.readAsBytes(),
          mode: JsonDocumentWriteMode.createIfAbsent,
        );
        if (write.status == JsonDocumentWriteStatus.preserved) {
          return _WriteResult.skipped(
            bytesDownloaded: tempResult.bytesDownloaded,
          );
        }
        if (write.status != JsonDocumentWriteStatus.created) {
          return _WriteResult.failure(
            bytesDownloaded: tempResult.bytesDownloaded,
          );
        }
        _createdOutputPaths[workId]?.add(
          _joinFolderPath(workRootPath, normalizedRelativePath),
        );
        _recordCreatedJson(
          workId,
          _joinFolderPath(workRootPath, normalizedRelativePath),
          jsonLocation,
          write,
        );
        return _WriteResult.success(
          bytesDownloaded: tempResult.bytesDownloaded,
        );
      }
      if (PathMatcher.isContentUri(workRootPath)) {
        final targetPath = _joinFolderPath(
          workRootPath,
          normalizedRelativePath,
        );
        final targetExisted = await _fileCacheGateway.documentPathExists(
          targetPath,
        );
        final saved = await _fileCacheGateway.copyFileToFolder(
          sourcePath: tempResult.file.path,
          folder: workRootPath,
          relativePath: normalizedRelativePath,
          overwrite: conflictPolicy == AsmrDownloadConflictPolicy.overwrite,
        );
        if (!saved) {
          return conflictPolicy == AsmrDownloadConflictPolicy.skip
              ? _WriteResult.skipped(
                  bytesDownloaded: tempResult.bytesDownloaded,
                )
              : _WriteResult.failure(
                  bytesDownloaded: tempResult.bytesDownloaded,
                );
        }
        if (!targetExisted) {
          _createdOutputPaths[workId]?.add(targetPath);
        }
        return _WriteResult.success(
          bytesDownloaded: tempResult.bytesDownloaded,
        );
      }

      final targetFile = localTargetFile!;
      final targetExisted = await targetFile.exists();
      if (targetExisted) {
        if (conflictPolicy == AsmrDownloadConflictPolicy.skip) {
          return _WriteResult.skipped(bytesDownloaded: item.size);
        }
      }
      final committed = await commitLocalDownloadedFile(
        staging: tempResult.file,
        target: targetFile,
      );
      if (!committed) {
        return _WriteResult.skipped(
          bytesDownloaded: tempResult.bytesDownloaded,
        );
      }
      if (!targetExisted) {
        _createdOutputPaths[workId]?.add(targetFile.path);
      }
      return _WriteResult.success(bytesDownloaded: tempResult.bytesDownloaded);
    } finally {
      try {
        if (_pauseRequested[workId] != true &&
            !_disposed &&
            await tempResult.file.exists()) {
          await tempResult.file.delete();
        }
      } catch (_) {
        // Temporary download cleanup is best effort after the primary result.
      }
      tempResult.cacheLease.release();
    }
  }

  Future<_TemporaryDownloadResult?> _downloadToTemporaryFile(
    _PlannedDownloadFile item, {
    required int workId,
    required HttpClient client,
    required File stagingFile,
  }) async {
    final tempFile = stagingFile;
    await tempFile.parent.create(recursive: true);
    final cacheLease = AppCacheService.protectPaths(<String>[tempFile.path]);
    var leaseTransferred = false;
    try {
      for (var attempt = 0; ; attempt++) {
        _throwIfCancelled(workId);
        final result = await _downloadToTemporaryFileAttempt(
          item,
          workId: workId,
          client: client,
          stagingFile: stagingFile,
          allowResume: true,
        );
        if (result.bytesDownloaded case final bytesDownloaded?) {
          await tempFile.setLastModified(DateTime.now());
          leaseTransferred = true;
          return _TemporaryDownloadResult(
            file: tempFile,
            bytesDownloaded: bytesDownloaded,
            cacheLease: cacheLease,
          );
        }

        if (!result.retryable || attempt >= maxAutomaticFileRetries) {
          if (result.error case final error?) {
            AppLogService.error(
              'asmr_download_transfer_failed path=${item.relativePath}',
              error: error,
              stackTrace: result.stackTrace,
            );
          }
          return null;
        }

        final retryAttempt = attempt + 1;
        _setFileRetryAttempt(workId, item.relativePath, retryAttempt);
        AppLogService.warning(
          'asmr_download_transfer_retry path=${item.relativePath} '
          'attempt=$retryAttempt/$maxAutomaticFileRetries',
          error: result.error,
          stackTrace: result.stackTrace,
        );
        await Future<void>.delayed(_automaticFileRetryDelay);
      }
    } on _DownloadCancelled {
      rethrow;
    } finally {
      _setFileRetryAttempt(workId, item.relativePath, null);
      if (!leaseTransferred) {
        try {
          if (_pauseRequested[workId] != true &&
              !_disposed &&
              await tempFile.exists()) {
            await tempFile.delete();
          }
        } catch (_) {
          // Incomplete staging file cleanup is best effort.
        } finally {
          if (_pauseRequested[workId] != true && !_disposed) {
            _setFileResumeValidator(workId, item.relativePath, null);
          }
          cacheLease.release();
        }
      }
    }
  }

  Future<_TemporaryDownloadAttempt> _downloadToTemporaryFileAttempt(
    _PlannedDownloadFile item, {
    required int workId,
    required HttpClient client,
    required File stagingFile,
    required bool allowResume,
  }) async {
    var received = 0;
    try {
      try {
        received = await stagingFile.length();
      } on FileSystemException {
        if (await stagingFile.exists()) rethrow;
      }
      var resumeValidator =
          _tasks[workId]?.fileResumeValidators[item.relativePath];
      final completeStagingFile = item.size > 0 && received >= item.size;
      if (received > 0 &&
          (!allowResume || resumeValidator == null || completeStagingFile)) {
        _discardLivePartialProgress(workId, item.relativePath, received);
        await _deleteFileIfPresent(stagingFile);
        _setFileResumeValidator(workId, item.relativePath, null);
        received = 0;
        resumeValidator = null;
      }
      const requestTimeout = Duration(seconds: 15);
      const downloadIdleTimeout = Duration(seconds: 30);
      _throwIfCancelled(workId);
      final uri = Uri.parse(item.url);
      final request = await client.getUrl(uri).timeout(requestTimeout);
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'Doujin Audio downloader',
      );
      for (final header in asmrMediaRequestHeadersForUrl(item.url).entries) {
        request.headers.set(header.key, header.value);
      }
      if (received > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$received-');
        request.headers.set(HttpHeaders.ifRangeHeader, resumeValidator!);
      }
      final response = await request.close().timeout(requestTimeout);
      final responseValidator = selectDownloadResumeValidator(
        etag: response.headers.value(HttpHeaders.etagHeader),
        lastModified: response.headers.value(HttpHeaders.lastModifiedHeader),
      );

      Future<_TemporaryDownloadAttempt> retryWithoutRange() async {
        try {
          await response.listen((_) {}).cancel();
        } catch (_) {
          // The retry uses a new response even if cancellation already won.
        }
        _discardLivePartialProgress(workId, item.relativePath, received);
        await _deleteFileIfPresent(stagingFile);
        _setFileResumeValidator(workId, item.relativePath, null);
        return _downloadToTemporaryFileAttempt(
          item,
          workId: workId,
          client: client,
          stagingFile: stagingFile,
          allowResume: false,
        );
      }

      if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable &&
          received > 0 &&
          allowResume) {
        return retryWithoutRange();
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        try {
          await response.listen((_) {}).cancel();
        } catch (_) {
          // The status code is sufficient to classify this attempt.
        }
        final error = HttpException(
          'Download failed with HTTP ${response.statusCode}.',
          uri: uri,
        );
        return _TemporaryDownloadAttempt.failure(
          retryable: _isRetryableDownloadStatus(response.statusCode),
          error: error,
          stackTrace: StackTrace.current,
        );
      }

      var responseStart = 0;
      if (response.statusCode == HttpStatus.partialContent) {
        if (!isValidDownloadContentRange(
          response.headers.value(HttpHeaders.contentRangeHeader),
          expectedStart: received,
          responseLength: response.contentLength,
          expectedTotal: item.size,
        )) {
          if (received > 0 && allowResume) return retryWithoutRange();
          return _TemporaryDownloadAttempt.failure(
            retryable: true,
            error: HttpException(
              'Download response contained an invalid byte range.',
              uri: uri,
            ),
            stackTrace: StackTrace.current,
          );
        }
        if (received > 0 && responseValidator != resumeValidator) {
          if (allowResume) return retryWithoutRange();
          return _TemporaryDownloadAttempt.failure(
            retryable: true,
            error: HttpException(
              'Download response changed its resume validator.',
              uri: uri,
            ),
            stackTrace: StackTrace.current,
          );
        }
        responseStart = received;
      }
      if (responseStart == 0 && received > 0) {
        final discardedBytes = received;
        received = 0;
        _discardLivePartialProgress(workId, item.relativePath, discardedBytes);
      }
      _setFileResumeValidator(workId, item.relativePath, responseValidator);
      final sink = stagingFile.openWrite(
        mode: responseStart > 0 ? FileMode.append : FileMode.write,
      );
      try {
        await for (final chunk in response.timeout(downloadIdleTimeout)) {
          _throwIfCancelled(workId);
          received += chunk.length;
          sink.add(chunk);

          _recordDownloadChunk(
            workId,
            item.relativePath,
            chunk.length,
            received,
          );
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      final responseBytes = received - responseStart;
      if (item.node.isAudio &&
          item.size <= 0 &&
          response.contentLength <= 0 &&
          responseBytes == 0) {
        return _TemporaryDownloadAttempt.failure(
          retryable: true,
          error: HttpException(
            'Download response contained no media data.',
            uri: uri,
          ),
          stackTrace: StackTrace.current,
        );
      }
      if ((response.contentLength > 0 &&
              responseBytes != response.contentLength) ||
          (item.size > 0 && received != item.size)) {
        return _TemporaryDownloadAttempt.failure(
          retryable: true,
          error: HttpException(
            'Download response ended before the file was complete.',
            uri: uri,
          ),
          stackTrace: StackTrace.current,
        );
      }
      return _TemporaryDownloadAttempt.success(received);
    } on _DownloadCancelled {
      rethrow;
    } catch (error, stackTrace) {
      if (_cancelRequested[workId] == true || _pauseRequested[workId] == true) {
        throw const _DownloadCancelled();
      }
      return _TemporaryDownloadAttempt.failure(
        retryable: _isRetryableDownloadError(error),
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  bool _isRetryableDownloadStatus(int statusCode) {
    return statusCode == HttpStatus.requestTimeout ||
        statusCode == HttpStatus.tooManyRequests ||
        statusCode >= HttpStatus.internalServerError;
  }

  bool _isRetryableDownloadError(Object error) {
    return error is TimeoutException ||
        error is SocketException ||
        error is HandshakeException ||
        error is HttpException;
  }

  void _setFileRetryAttempt(int workId, String relativePath, int? attempt) {
    if (_disposed) return;
    final task = _tasks[workId];
    if (task == null) return;
    final attempts = Map<String, int>.from(task.fileRetryAttempts);
    if (attempt == null) {
      if (attempts.remove(relativePath) == null) return;
    } else {
      if (attempts[relativePath] == attempt) return;
      attempts[relativePath] = attempt;
    }
    _tasks[workId] = task.copyWith(fileRetryAttempts: attempts);
    _notifyProgressChanged();
  }

  void _setFileResumeValidator(
    int workId,
    String relativePath,
    String? validator,
  ) {
    if (_disposed) return;
    final task = _tasks[workId];
    if (task == null) return;
    final validators = Map<String, String>.from(task.fileResumeValidators);
    if (validator == null) {
      if (validators.remove(relativePath) == null) return;
    } else {
      if (validators[relativePath] == validator) return;
      validators[relativePath] = validator;
    }
    _tasks[workId] = task.copyWith(fileResumeValidators: validators);
    _notifyProgressChanged();
  }

  Future<JsonDocumentWriteResult> _writeWorkDetailBackup(
    AudioDetail detail,
    JsonDocumentLocation location,
  ) async {
    final result = await _jsonDocumentStore.write(
      location: location,
      bytes: _audioDetailJsonCodec.encodeNew(detail),
      mode: JsonDocumentWriteMode.createIfAbsent,
    );
    if (result.status == JsonDocumentWriteStatus.created ||
        result.status == JsonDocumentWriteStatus.preserved) {
      return result;
    }
    throw FileSystemException(
      'Unable to write work detail backup.',
      result.error,
    );
  }

  void _recordCreatedJson(
    int workId,
    String path,
    JsonDocumentLocation location,
    JsonDocumentWriteResult result,
  ) {
    final revision = result.revision;
    if (result.status != JsonDocumentWriteStatus.created || revision == null) {
      return;
    }
    _createdJsonDocuments.putIfAbsent(
      workId,
      () => <String, _CreatedJsonDocument>{},
    )[path] = _CreatedJsonDocument(
      location: location,
      revision: revision,
    );
  }

  Future<bool> _ensureFolderPath({
    required String basePath,
    required String relativePath,
    required bool overwrite,
  }) async {
    final normalized = _validatedDownloadRelativePath(relativePath);

    if (PathMatcher.isContentUri(basePath)) {
      return _fileCacheGateway.ensureFolderPath(
        folder: basePath,
        relativePath: normalized,
        overwrite: overwrite,
      );
    }

    final folder = Directory(_resolveLocalPathWithin(basePath, normalized));
    try {
      await folder.create(recursive: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  String _joinFolderPath(String basePath, String relativePath) {
    final normalizedRelative = _validatedDownloadRelativePath(relativePath);
    if (PathMatcher.isContentUri(basePath)) {
      return '${_trimRightSlash(basePath)}::$normalizedRelative';
    }
    return _resolveLocalPathWithin(basePath, normalizedRelative);
  }

  JsonDocumentLocation _jsonDownloadLocation(
    String workRootPath,
    String relativePath,
  ) {
    final parentRelative = path.posix.dirname(relativePath);
    final folder = parentRelative == '.'
        ? workRootPath
        : _joinFolderPath(workRootPath, parentRelative);
    return JsonDocumentLocation.folderChild(
      folder: folder,
      name: path.posix.basename(relativePath),
    );
  }

  String _validatedDownloadRelativePath(String relativePath) {
    final normalized = relativePath.trim().replaceAll('\\', '/');
    if (normalized.isEmpty ||
        path.posix.isAbsolute(normalized) ||
        path.windows.isAbsolute(normalized) ||
        normalized.startsWith('//') ||
        RegExp(r'^[A-Za-z]:').hasMatch(normalized)) {
      throw FormatException('Invalid download path: $relativePath');
    }
    final segments = normalized.split('/');
    if (segments.any(
      (segment) => segment.isEmpty || segment == '.' || segment == '..',
    )) {
      throw FormatException('Invalid download path: $relativePath');
    }
    return segments.join('/');
  }

  String _resolveLocalPathWithin(String basePath, String relativePath) {
    final normalizedRelative = _validatedDownloadRelativePath(relativePath);
    final root = path.normalize(path.absolute(basePath));
    final target = path.normalize(
      path.absolute(
        path.join(root, normalizedRelative.replaceAll('/', path.separator)),
      ),
    );
    if (!path.isWithin(root, target)) {
      throw const FormatException('Download path escapes its destination.');
    }
    return target;
  }

  AudioDetail _buildBackupDetail(AsmrWork work, String workRootPath) {
    return AudioDetail(
      target: AudioDetailTarget.libraryRootFolder(workRootPath),
      rjCode: work.rjCode,
      workTitle: work.title,
      circleName: work.circleName,
      voiceActors: work.voiceActors,
      tags: work.tags,
      releaseDate: work.releaseDate,
      duration: work.duration > Duration.zero ? work.duration : null,
      salesCount: work.dlCount > 0 ? work.dlCount : null,
      rating: work.rating > 0 ? work.rating.clamp(0, 5).toDouble() : null,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    ).normalizedForSave(DateTime.now());
  }

  String? _downloadUrlFor(AsmrTrackFile node) {
    final candidates = <String?>[
      if (<String?>[
        node.streamUrl,
        node.downloadUrl,
        node.lowQualityUrl,
      ].any(AsmrApiService.isOfficialMediaUrl))
        ...AsmrApiService.mediaDownloadUrlsForHash(node.hash),
      node.downloadUrl,
      node.streamUrl,
      node.lowQualityUrl,
    ];
    for (final candidate in candidates) {
      final value = candidate?.trim();
      if (value != null && value.isNotEmpty) {
        return value;
      }
    }
    return null;
  }

  Future<File> _persistentStagingFile(
    String workRootPath,
    String relativePath,
  ) async {
    final root = await _stagingDirectoryProvider();
    final key = sha256
        .convert(utf8.encode('$workRootPath|$relativePath'))
        .toString();
    return File(path.join(root.path, 'asmr_downloads', '$key.doujin.part'));
  }

  String _trimRightSlash(String value) {
    var result = value.trim();
    while (result.endsWith('/')) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }

  void _notifyTaskChanged({
    bool deferPersistence = false,
    bool forcePersistedUriReferenceRevision = false,
  }) {
    if (_disposed) return;
    final persistedContentUris = _tasks.values
        .where((task) => task.status != AsmrDownloadTaskStatus.completed)
        .map((task) => task.destinationRoot)
        .where(PathMatcher.isContentUri)
        .toSet();
    if (forcePersistedUriReferenceRevision ||
        !setEquals(persistedContentUris, _persistedContentUris)) {
      _persistedContentUris = Set<String>.unmodifiable(persistedContentUris);
      _persistedUriReferenceRevision += 1;
      _persistedUriReferenceRevisionController.add(
        _persistedUriReferenceRevision,
      );
    }
    _deferredProgressNotifyTimer?.cancel();
    _deferredProgressNotifyTimer = null;
    _publishLiveProgress();
    _refreshTaskIdsSnapshot();
    _markProgressNotified();
    _scheduleTaskPersistence(deferred: deferPersistence);
    notifyListeners();
  }

  void _scheduleTaskPersistence({required bool deferred}) {
    if (!_persistTasks) return;
    if (deferred) {
      _deferredPersistenceTimer ??= Timer(
        const Duration(milliseconds: 400),
        () {
          _deferredPersistenceTimer = null;
          _persistCurrentTasks();
        },
      );
      return;
    }
    _deferredPersistenceTimer?.cancel();
    _deferredPersistenceTimer = null;
    _persistCurrentTasks();
  }

  void _persistCurrentTasks() {
    if (!_persistTasks) return;
    final tasks = _tasks.values
        .where((task) => task.status != AsmrDownloadTaskStatus.completed)
        .map(
          (task) => _downloadTaskToJson(
            task,
            createdOutputPaths:
                _createdOutputPaths[task.work.id] ?? const <String>{},
            createdJsonDocuments:
                _createdJsonDocuments[task.work.id] ??
                const <String, _CreatedJsonDocument>{},
          ),
        )
        .toList(growable: false);
    final payload = tasks.isEmpty
        ? null
        : jsonEncode(<String, Object?>{'version': 1, 'tasks': tasks});
    _persistenceTail = _persistenceTail.then(
      (_) => _writePersistedTasks(payload),
    );
  }

  Future<void> _writePersistedTasks(String? payload) async {
    try {
      if (payload == null) {
        await AppPreferences.remove(AppPreferences.asmrDownloadTasksKey);
      } else {
        await AppPreferences.setString(
          AppPreferences.asmrDownloadTasksKey,
          payload,
        );
      }
    } catch (error, stackTrace) {
      AppLogService.warning(
        'asmr_download_persist_failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> flushPersistence() async {
    if (_disposed) return;
    _publishLiveProgress();
    _deferredPersistenceTimer?.cancel();
    _deferredPersistenceTimer = null;
    _persistCurrentTasks();
    await _persistenceTail;
  }

  void _refreshTaskIdsSnapshot() {
    final taskIds = _tasks.entries
        .where(
          (entry) => entry.value.status != AsmrDownloadTaskStatus.completed,
        )
        .map((entry) => entry.key)
        .toList(growable: false);
    if (listEquals(taskIds, _taskIdsSnapshot)) return;
    _taskIdsSnapshot = List<int>.unmodifiable(taskIds);
  }

  void _retainOnlyLatestCompletedTask(int workId) {
    final obsoleteTaskIds = _tasks.entries
        .where(
          (entry) =>
              entry.key != workId &&
              entry.value.status == AsmrDownloadTaskStatus.completed,
        )
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final obsoleteWorkId in obsoleteTaskIds) {
      _tasks.remove(obsoleteWorkId);
      _createdOutputPaths.remove(obsoleteWorkId);
      _createdJsonDocuments.remove(obsoleteWorkId);
    }
  }

  void _notifyProgressChanged() {
    if (_disposed) return;
    final now = DateTime.now();
    final elapsed = _lastProgressNotifyAt == null
        ? _progressNotifyMinInterval
        : now.difference(_lastProgressNotifyAt!);

    if (elapsed >= _progressNotifyMinInterval) {
      _notifyTaskChanged(deferPersistence: true);
      return;
    }

    _deferredProgressNotifyTimer ??= Timer(
      _progressNotifyMinInterval - elapsed,
      () {
        _deferredProgressNotifyTimer = null;
        _notifyTaskChanged(deferPersistence: true);
      },
    );
  }

  void _markProgressNotified() {
    _lastProgressNotifyAt = DateTime.now();
  }

  void _recordDownloadChunk(
    int workId,
    String relativePath,
    int chunkLength,
    int fileDownloadedBytes,
  ) {
    if (_disposed) return;
    final task = _tasks[workId];
    if (task == null || chunkLength <= 0) return;
    _liveDownloadedBytes.update(
      workId,
      (value) => value + chunkLength,
      ifAbsent: () => task.downloadedBytes + chunkLength,
    );
    final fileProgress = _liveFileDownloadedBytes.putIfAbsent(
      workId,
      () => Map<String, int>.from(task.fileDownloadedBytes),
    );
    fileProgress[relativePath] = fileDownloadedBytes;
    _notifyProgressChanged();
  }

  void _discardLivePartialProgress(
    int workId,
    String relativePath,
    int discardedBytes,
  ) {
    if (discardedBytes <= 0) return;
    _liveDownloadedBytes.update(
      workId,
      (value) => value > discardedBytes ? value - discardedBytes : 0,
    );
    _liveFileDownloadedBytes[workId]?[relativePath] = 0;
  }

  void _publishLiveProgress() {
    for (final entry in _liveDownloadedBytes.entries) {
      final task = _tasks[entry.key];
      if (task == null) continue;
      _tasks[entry.key] = task.copyWith(
        downloadedBytes: entry.value,
        fileDownloadedBytes: Map<String, int>.unmodifiable(
          _liveFileDownloadedBytes[entry.key] ?? task.fileDownloadedBytes,
        ),
      );
    }
  }

  @override
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
          message: 'paused',
        );
      }
    }
    _persistCurrentTasks();
    _disposed = true;
    _deferredProgressNotifyTimer?.cancel();
    _deferredProgressNotifyTimer = null;
    _queue.clear();
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
    super.dispose();
  }

  void _throwIfCancelled(int workId) {
    if (_disposed ||
        _cancelRequested[workId] == true ||
        _pauseRequested[workId] == true) {
      throw const _DownloadCancelled();
    }
  }

  Future<void> _deleteDownloadRoot(String workRootPath) async {
    if (PathMatcher.isContentUri(workRootPath)) {
      try {
        await _fileCacheGateway.deleteDocumentPath(workRootPath);
      } catch (_) {
        // Explicit task deletion is best effort.
      }
      return;
    }
    final directory = Directory(workRootPath);
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        if (!await directory.exists()) return;
        await directory.delete(recursive: true);
        return;
      } catch (_) {
        if (attempt < 2) {
          await Future<void>.delayed(const Duration(milliseconds: 40));
        }
      }
    }
  }

  Future<void> _deleteFileIfPresent(File file) async {
    try {
      await file.delete();
    } on FileSystemException {
      if (await file.exists()) rethrow;
    }
  }

  Future<void> _cleanupCancelledTask(int workId) async {
    for (final createdPath in _createdOutputPaths[workId] ?? const <String>{}) {
      try {
        final createdJson = _createdJsonDocuments[workId]?[createdPath];
        if (createdJson != null) {
          await _jsonDocumentStore.delete(
            location: createdJson.location,
            expectedRevision: createdJson.revision,
          );
          continue;
        }
        if (createdPath.toLowerCase().endsWith('.json')) {
          // A restored legacy task has no revision token. Preserve the JSON
          // instead of risking deletion of a document modified after download.
          continue;
        }
        if (PathMatcher.isContentUri(createdPath)) {
          await _fileCacheGateway.deleteDocumentPath(createdPath);
        } else {
          final file = File(createdPath);
          if (await file.exists()) {
            await file.delete();
          }
        }
      } catch (_) {
        // Cancellation cleanup is best effort and never removes pre-existing files.
      }
    }
  }
}

Map<String, Object?> _downloadTaskToJson(
  AsmrDownloadTaskSnapshot task, {
  required Set<String> createdOutputPaths,
  required Map<String, _CreatedJsonDocument> createdJsonDocuments,
}) => <String, Object?>{
  'work': task.work.toJson(),
  'destinationRoot': task.destinationRoot,
  'workFolderName': task.workFolderName,
  'conflictPolicy': task.conflictPolicy.name,
  'saveMetadata': task.saveMetadata,
  'totalFiles': task.totalFiles,
  'completedFiles': task.completedFiles,
  'skippedFiles': task.skippedFiles,
  'failedFiles': task.failedFiles,
  'totalBytes': task.totalBytes,
  'downloadedBytes': task.downloadedBytes,
  'startedAt': task.startedAt.toIso8601String(),
  'currentItemPath': task.currentItemPath,
  'message': task.message,
  'error': task.error,
  'fileDownloadedBytes': task.fileDownloadedBytes,
  'fileResumeValidators': task.fileResumeValidators,
  'fileTotalBytes': task.fileTotalBytes,
  'completedFilePaths': task.completedFilePaths.toList(growable: false),
  'selectedRoots': task.selectedRoots.map(_downloadTrackToJson).toList(),
  'createdOutputPaths': createdOutputPaths.toList(growable: false),
  'createdJsonDocuments': <String, Object?>{
    for (final entry in createdJsonDocuments.entries)
      entry.key: entry.value.toJson(),
  },
};

_PersistedDownloadTask _downloadTaskFromJson(Map<String, dynamic> json) {
  final workJson = json['work'];
  if (workJson is! Map<Object?, Object?>) {
    throw const FormatException('Missing download work.');
  }
  final work = AsmrWork.fromJson(Map<String, dynamic>.from(workJson));
  if (work.id <= 0) throw const FormatException('Invalid download work.');
  final selectedRoots = (json['selectedRoots'] as List? ?? const <Object>[])
      .whereType<Map<Object?, Object?>>()
      .map((value) => _downloadTrackFromJson(Map<String, dynamic>.from(value)))
      .toList(growable: false);
  if (selectedRoots.isEmpty) {
    throw const FormatException('Missing selected download files.');
  }
  return _PersistedDownloadTask(
    task: AsmrDownloadTaskSnapshot(
      work: work,
      destinationRoot: json['destinationRoot'] as String? ?? '',
      workFolderName: json['workFolderName'] as String? ?? '',
      conflictPolicy: _enumByName(
        AsmrDownloadConflictPolicy.values,
        json['conflictPolicy'],
        AsmrDownloadConflictPolicy.skip,
      ),
      saveMetadata: json['saveMetadata'] as bool? ?? true,
      status: AsmrDownloadTaskStatus.paused,
      totalFiles: _jsonInt(json['totalFiles']),
      completedFiles: _jsonInt(json['completedFiles']),
      skippedFiles: _jsonInt(json['skippedFiles']),
      failedFiles: _jsonInt(json['failedFiles']),
      totalBytes: _jsonInt(json['totalBytes']),
      downloadedBytes: _jsonInt(json['downloadedBytes']),
      startedAt:
          DateTime.tryParse(json['startedAt'] as String? ?? '') ??
          DateTime.now(),
      currentItemPath: json['currentItemPath'] as String?,
      message: json['message'] as String?,
      error: json['error'] as String?,
      fileDownloadedBytes: _jsonIntMap(json['fileDownloadedBytes']),
      fileResumeValidators: _jsonStringMap(json['fileResumeValidators']),
      fileTotalBytes: _jsonIntMap(json['fileTotalBytes']),
      completedFilePaths:
          (json['completedFilePaths'] as List? ?? const <Object>[])
              .whereType<String>()
              .toSet(),
      selectedRoots: selectedRoots,
    ),
    createdOutputPaths: (json['createdOutputPaths'] as List? ?? const [])
        .whereType<String>()
        .toSet(),
    createdJsonDocuments: _createdJsonDocumentsFromJson(
      json['createdJsonDocuments'],
    ),
  );
}

Map<String, _CreatedJsonDocument> _createdJsonDocumentsFromJson(Object? value) {
  if (value is! Map<Object?, Object?>) {
    return const <String, _CreatedJsonDocument>{};
  }
  final result = <String, _CreatedJsonDocument>{};
  for (final entry in value.entries) {
    if (entry.key is! String || entry.value is! Map<Object?, Object?>) continue;
    final decoded = _CreatedJsonDocument.fromJson(
      Map<String, Object?>.from(entry.value as Map<Object?, Object?>),
    );
    if (decoded != null) result[entry.key as String] = decoded;
  }
  return result;
}

Map<String, Object?> _downloadTrackToJson(AsmrTrackFile track) =>
    <String, Object?>{
      'hash': track.hash,
      'title': track.title,
      'type': track.type,
      'streamUrl': track.streamUrl,
      'downloadUrl': track.downloadUrl,
      'lowQualityUrl': track.lowQualityUrl,
      'durationMs': track.duration.inMilliseconds,
      'size': track.size,
      'workId': track.workId,
      'workTitle': track.workTitle,
      'sourceId': track.sourceId,
      'relativePath': track.relativePath,
      'children': track.children.map(_downloadTrackToJson).toList(),
    };

AsmrTrackFile _downloadTrackFromJson(Map<String, dynamic> json) =>
    AsmrTrackFile(
      hash: json['hash'] as String? ?? '',
      title: json['title'] as String? ?? '',
      type: json['type'] as String? ?? '',
      streamUrl: json['streamUrl'] as String?,
      downloadUrl: json['downloadUrl'] as String?,
      lowQualityUrl: json['lowQualityUrl'] as String?,
      duration: Duration(milliseconds: _jsonInt(json['durationMs'])),
      size: _jsonInt(json['size']),
      children: (json['children'] as List? ?? const <Object>[])
          .whereType<Map<Object?, Object?>>()
          .map(
            (value) => _downloadTrackFromJson(Map<String, dynamic>.from(value)),
          )
          .toList(growable: false),
      workId: _jsonInt(json['workId']),
      workTitle: json['workTitle'] as String? ?? '',
      sourceId: json['sourceId'] as String? ?? '',
      relativePath: json['relativePath'] as String? ?? '',
    );

Map<String, int> _jsonIntMap(Object? value) {
  if (value is! Map<Object?, Object?>) return const <String, int>{};
  return <String, int>{
    for (final entry in value.entries)
      if (entry.key is String && entry.value is num)
        entry.key as String: (entry.value as num).toInt(),
  };
}

Map<String, String> _jsonStringMap(Object? value) {
  if (value is! Map<Object?, Object?>) return const <String, String>{};
  return <String, String>{
    for (final entry in value.entries)
      if (entry.key is String && entry.value is String)
        entry.key as String: entry.value as String,
  };
}

int _jsonInt(Object? value) => (value as num?)?.toInt() ?? 0;

T _enumByName<T extends Enum>(List<T> values, Object? name, T fallback) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  return fallback;
}

class _PersistedDownloadTask {
  const _PersistedDownloadTask({
    required this.task,
    required this.createdOutputPaths,
    required this.createdJsonDocuments,
  });

  final AsmrDownloadTaskSnapshot task;
  final Set<String> createdOutputPaths;
  final Map<String, _CreatedJsonDocument> createdJsonDocuments;
}

final class _CreatedJsonDocument {
  const _CreatedJsonDocument({required this.location, required this.revision});

  final JsonDocumentLocation location;
  final String revision;

  Map<String, Object?> toJson() => <String, Object?>{
    ...location.toPlatformArguments(),
    'revision': revision,
  };

  static _CreatedJsonDocument? fromJson(Map<String, Object?> json) {
    final kind = switch (json['locationKind']) {
      'folderChild' => JsonDocumentLocationKind.folderChild,
      'fileSibling' => JsonDocumentLocationKind.fileSibling,
      _ => null,
    };
    final basePath = json['basePath'];
    final name = json['name'];
    final revision = json['revision'];
    if (kind == null ||
        basePath is! String ||
        name is! String ||
        revision is! String ||
        revision.isEmpty) {
      return null;
    }
    final location = kind == JsonDocumentLocationKind.folderChild
        ? JsonDocumentLocation.folderChild(folder: basePath, name: name)
        : JsonDocumentLocation.fileSibling(filePath: basePath, name: name);
    return _CreatedJsonDocument(location: location, revision: revision);
  }
}

class _PlannedDownloadFile {
  const _PlannedDownloadFile({
    required this.node,
    required this.url,
    required this.relativePath,
    required this.size,
  });

  final AsmrTrackFile node;
  final String url;
  final String relativePath;
  final int size;
}

class _WriteResult {
  const _WriteResult._({
    required this.saved,
    required this.skipped,
    required this.bytesDownloaded,
  });

  const _WriteResult.success({required int bytesDownloaded})
    : this._(saved: true, skipped: false, bytesDownloaded: bytesDownloaded);

  const _WriteResult.skipped({required int bytesDownloaded})
    : this._(saved: false, skipped: true, bytesDownloaded: bytesDownloaded);

  const _WriteResult.failure({required int bytesDownloaded})
    : this._(saved: false, skipped: false, bytesDownloaded: bytesDownloaded);

  final bool saved;
  final bool skipped;
  final int bytesDownloaded;
}

class _TemporaryDownloadResult {
  const _TemporaryDownloadResult({
    required this.file,
    required this.bytesDownloaded,
    required this.cacheLease,
  });

  final File file;
  final int bytesDownloaded;
  final CachePathLease cacheLease;
}

class _TemporaryDownloadAttempt {
  const _TemporaryDownloadAttempt.success(int bytesDownloaded)
    : this._(bytesDownloaded: bytesDownloaded, retryable: false);

  const _TemporaryDownloadAttempt.failure({
    required bool retryable,
    Object? error,
    StackTrace? stackTrace,
  }) : this._(
         bytesDownloaded: null,
         retryable: retryable,
         error: error,
         stackTrace: stackTrace,
       );

  const _TemporaryDownloadAttempt._({
    required this.bytesDownloaded,
    required this.retryable,
    this.error,
    this.stackTrace,
  });

  final int? bytesDownloaded;
  final bool retryable;
  final Object? error;
  final StackTrace? stackTrace;
}

class _DownloadCancelled implements Exception {
  const _DownloadCancelled();
}
