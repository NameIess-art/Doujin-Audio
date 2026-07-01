import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';

import '../models/audio_detail.dart';
import '../models/asmr_download.dart';
import '../models/asmr_models.dart';
import 'app_cache_service.dart';
import 'app_log_service.dart';
import 'file_cache_platform_gateway.dart';
import 'path_display.dart';
import 'path_matcher.dart';

enum AsmrDownloadTaskStatus { idle, preparing, downloading, completed, failed }

class AsmrDownloadTaskSnapshot {
  const AsmrDownloadTaskSnapshot({
    required this.work,
    required this.destinationRoot,
    required this.workFolderName,
    required this.conflictPolicy,
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
    this.fileDownloadedBytes = const {},
    this.fileTotalBytes = const {},
    this.selectedRoots = const [],
  });

  final AsmrWork work;
  final String destinationRoot;
  final String workFolderName;
  final AsmrDownloadConflictPolicy conflictPolicy;
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
    List<AsmrTrackFile>? selectedRoots,
  }) {
    return AsmrDownloadTaskSnapshot(
      work: work,
      destinationRoot: destinationRoot,
      workFolderName: workFolderName,
      conflictPolicy: conflictPolicy,
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
      selectedRoots: selectedRoots ?? this.selectedRoots,
    );
  }
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
  AsmrDownloadManager({FileCachePlatformGateway? fileCacheGateway})
    : _fileCacheGateway = fileCacheGateway ?? FileCachePlatformGateway.instance;

  static const Duration _progressNotifyMinInterval = Duration(
    milliseconds: 120,
  );
  static const int _progressNotifyMinByteDelta = 128 * 1024;
  final FileCachePlatformGateway _fileCacheGateway;

  final Map<int, AsmrDownloadTaskSnapshot> _tasks = {};
  List<int> _taskIdsSnapshot = const <int>[];
  final List<int> _queue = [];
  final Set<int> _activeTasks = {};
  final Map<int, List<_PlannedDownloadFile>> _plannedFilesMap = {};

  final Map<int, bool> _cancelRequested = {};
  final Map<int, Completer<void>> _downloadCompletions = {};
  final Map<int, HttpClient> _activeHttpClients = {};
  final Map<int, String> _cancelCleanupRoots = {};

  static const int _maxConcurrentDownloads = 3;

  bool _initialized = false;
  Timer? _deferredProgressNotifyTimer;
  DateTime? _lastProgressNotifyAt;
  int _lastProgressNotifyBytes = 0;

  List<AsmrDownloadTaskSnapshot> get tasks => _tasks.values.toList();
  List<int> get taskIds => _taskIdsSnapshot;
  AsmrDownloadTaskSnapshot? getTask(int workId) => _tasks[workId];
  bool get hasLiveTask => _activeTasks.isNotEmpty || _queue.isNotEmpty;

  AsmrDownloadButtonViewState get buttonViewState {
    if (_tasks.isEmpty) {
      return const AsmrDownloadButtonViewState(visible: false, progress: null);
    }
    int totalBytes = 0;
    int downloadedBytes = 0;
    for (final t in _tasks.values) {
      if (t.isActive) {
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
        hasTask: _tasks.isNotEmpty,
        isActive: hasLiveTask,
      );

  @visibleForTesting
  void debugSetCurrentTaskForTesting(
    AsmrDownloadTaskSnapshot? task, {
    bool progressOnly = false,
  }) {
    if (task != null) {
      _tasks[task.work.id] = task;
    }
    if (progressOnly) {
      _notifyProgressChanged();
    } else {
      _notifyTaskChanged();
    }
  }

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    _notifyTaskChanged();
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
      final directory = await FilePicker.platform.getDirectoryPath(
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

  Future<void> cancelTask(int workId) async {
    final task = _tasks[workId];
    if (task == null) {
      return;
    }

    if (_queue.contains(workId)) {
      _queue.remove(workId);
      _tasks.remove(workId);
      _notifyTaskChanged();
      return;
    }

    if (_activeTasks.contains(workId)) {
      _cancelRequested[workId] = true;
      _cancelCleanupRoots[workId] = task.workRootPath;
      _activeHttpClients[workId]?.close(force: true);
      await _deleteDownloadRoot(task.workRootPath);
      _tasks.remove(workId);
      _notifyTaskChanged();
      return;
    }

    await _deleteDownloadRoot(task.workRootPath);
    _tasks.remove(workId);
    _notifyTaskChanged();
  }

  Future<void> deleteTask(int workId) async {
    await cancelTask(workId);
  }

  Future<void> startDownload({
    required AsmrWork work,
    required List<AsmrTrackFile> selectedRoots,
    required String destinationRoot,
    required AsmrDownloadConflictPolicy conflictPolicy,
  }) async {
    final normalizedDestination = destinationRoot.trim();
    if (normalizedDestination.isEmpty) {
      throw ArgumentError.value(destinationRoot, 'destinationRoot');
    }
    if (selectedRoots.isEmpty) {
      throw ArgumentError.value(selectedRoots, 'selectedRoots');
    }

    await initialize();

    final workId = work.id;
    final existingTask = _tasks[workId];
    if (existingTask != null) {
      if (existingTask.isActive || _queue.contains(workId)) {
        return; // Already downloading or queued
      }
      _tasks.remove(workId);
    }

    final workFolderName = _buildWorkFolderName(work);
    final workRootPath = _joinFolderPath(normalizedDestination, workFolderName);
    final backup = _buildBackupDetail(work, workRootPath);
    final backupJson = const JsonEncoder.withIndent(
      '  ',
    ).convert(backup.toBackupJson());
    final backupBytes = utf8.encode(backupJson).length;
    final plannedFiles = _collectPlannedFiles(selectedRoots);
    final totalFiles = plannedFiles.length + 1;
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

    _queue.add(workId);
    _notifyTaskChanged();
    _processQueue();
  }

  void _processQueue() {
    while (_activeTasks.length < _maxConcurrentDownloads && _queue.isNotEmpty) {
      final workId = _queue.removeAt(0);
      _activeTasks.add(workId);
      _runTask(workId);
    }
  }

  Future<void> _runTask(int workId) async {
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

    final backup = _buildBackupDetail(work, workRootPath);
    final backupJson = const JsonEncoder.withIndent(
      '  ',
    ).convert(backup.toBackupJson());
    final backupBytes = utf8.encode(backupJson).length;

    try {
      final rootReady = await _ensureFolderPath(
        basePath: normalizedDestination,
        relativePath: workFolderName,
        overwrite: conflictPolicy == AsmrDownloadConflictPolicy.overwrite,
      );
      if (!rootReady) {
        throw const FileSystemException('Unable to create download folder.');
      }

      await _writeWorkDetailBackup(backup, workRootPath);
      _throwIfCancelled(workId);

      _tasks[workId] = _tasks[workId]!.copyWith(
        status: AsmrDownloadTaskStatus.downloading,
        completedFiles: 1,
        downloadedBytes: backupBytes,
        message: 'downloading_work_detail',
      );
      _notifyTaskChanged();

      var completed = 1;
      var skipped = 0;
      var failed = 0;
      var downloadedBytes = backupBytes;

      final fileDownloadedBytes = Map<String, int>.from(
        _tasks[workId]!.fileDownloadedBytes,
      );
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

      final plannedFiles = _plannedFilesMap[workId] ?? [];
      for (final item in plannedFiles) {
        _throwIfCancelled(workId);
        _tasks[workId] = _tasks[workId]!.copyWith(
          currentItemPath: item.relativePath,
          message: item.relativePath,
        );
        _notifyProgressChanged();

        final result = await _downloadItem(
          item,
          workId: workId,
          workRootPath: workRootPath,
          conflictPolicy: conflictPolicy,
        );

        if (result.saved) {
          completed++;
        } else if (result.skipped) {
          skipped++;
        } else {
          failed++;
        }
        downloadedBytes += result.bytesDownloaded;
        fileDownloadedBytes[item.relativePath] = result.bytesDownloaded;

        _tasks[workId] = _tasks[workId]!.copyWith(
          completedFiles: completed,
          skippedFiles: skipped,
          failedFiles: failed,
          downloadedBytes: downloadedBytes,
          fileDownloadedBytes: fileDownloadedBytes,
        );
        _notifyProgressChanged();
      }

      _tasks[workId] = _tasks[workId]!.copyWith(
        status: failed > 0
            ? AsmrDownloadTaskStatus.failed
            : AsmrDownloadTaskStatus.completed,
        completedFiles: completed,
        skippedFiles: skipped,
        failedFiles: failed,
        downloadedBytes:
            backupBytes +
            plannedFiles.fold<int>(0, (sum, item) => sum + item.size),
        message: failed > 0 ? 'completed_with_failures' : 'completed',
      );
      _notifyTaskChanged();
    } on _DownloadCancelled {
      final currentTask = _tasks[workId];
      if (currentTask != null) {
        _tasks[workId] = currentTask.copyWith(
          status: AsmrDownloadTaskStatus.failed,
          message: 'cancelled',
        );
        _notifyTaskChanged();
      }
    } catch (error, stackTrace) {
      AppLogService.error(
        'asmr_download_failed',
        error: error,
        stackTrace: stackTrace,
      );
      final currentTask = _tasks[workId];
      if (currentTask != null) {
        _tasks[workId] = currentTask.copyWith(
          status: AsmrDownloadTaskStatus.failed,
          error: error.toString(),
          message: 'failed',
        );
        _notifyTaskChanged();
      }
    } finally {
      _plannedFilesMap.remove(workId);
      final cleanupRoot = _cancelCleanupRoots.remove(workId);
      if (cleanupRoot != null) {
        await _deleteDownloadRoot(cleanupRoot);
      }
      _cancelRequested.remove(workId);
      final completion = _downloadCompletions.remove(workId);
      if (completion != null && !completion.isCompleted) {
        completion.complete();
      }
      _activeTasks.remove(workId);
      _processQueue();
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
  }) async {
    _throwIfCancelled(workId);
    final tempResult = await _downloadToTemporaryFile(item, workId: workId);
    if (tempResult == null) {
      return const _WriteResult.failure(bytesDownloaded: 0);
    }

    try {
      _throwIfCancelled(workId);
      if (PathMatcher.isContentUri(workRootPath)) {
        final saved = await _fileCacheGateway.copyFileToFolder(
          sourcePath: tempResult.file.path,
          folder: workRootPath,
          relativePath: item.relativePath,
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
        return _WriteResult.success(
          bytesDownloaded: tempResult.bytesDownloaded,
        );
      }

      final targetFile = File(
        path.join(
          workRootPath,
          item.relativePath.replaceAll('/', path.separator),
        ),
      );
      await targetFile.parent.create(recursive: true);
      if (await targetFile.exists()) {
        if (conflictPolicy == AsmrDownloadConflictPolicy.skip) {
          return _WriteResult.skipped(
            bytesDownloaded: tempResult.bytesDownloaded,
          );
        }
        await targetFile.delete();
      }
      await tempResult.file.copy(targetFile.path);
      return _WriteResult.success(bytesDownloaded: tempResult.bytesDownloaded);
    } finally {
      try {
        if (await tempResult.file.exists()) {
          await tempResult.file.delete();
        }
      } catch (_) {
        // Temporary download cleanup is best effort after the primary result.
      }
    }
  }

  Future<_TemporaryDownloadResult?> _downloadToTemporaryFile(
    _PlannedDownloadFile item, {
    required int workId,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final downloadDir = Directory(path.join(tempDir.path, 'asmr_downloads'));
    if (!await downloadDir.exists()) {
      await downloadDir.create(recursive: true);
    }
    final tempFile = File(
      path.join(
        downloadDir.path,
        '${DateTime.now().microsecondsSinceEpoch}_${_safeFileName(item.node.title)}',
      ),
    );
    if (await tempFile.exists()) {
      await tempFile.delete();
    }

    final client = HttpClient();
    _activeHttpClients[workId] = client;
    var received = 0;
    try {
      _throwIfCancelled(workId);
      final request = await client.getUrl(Uri.parse(item.url));
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'Nameless Audio downloader',
      );
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }

      final sink = tempFile.openWrite();
      try {
        await for (final chunk in response) {
          _throwIfCancelled(workId);
          received += chunk.length;
          sink.add(chunk);

          final task = _tasks[workId];
          if (task != null) {
            final updatedFileDownloadedBytes = Map<String, int>.from(
              task.fileDownloadedBytes,
            );
            updatedFileDownloadedBytes[item.relativePath] = received;
            _tasks[workId] = task.copyWith(
              downloadedBytes: task.downloadedBytes + chunk.length,
              fileDownloadedBytes: updatedFileDownloadedBytes,
            );
            _notifyProgressChanged();
          }
        }
        await sink.flush();
      } finally {
        await sink.close();
      }

      await tempFile.setLastModified(DateTime.now());
      await AppCacheService.enforceLimit();
      return _TemporaryDownloadResult(
        file: tempFile,
        bytesDownloaded: received,
      );
    } on _DownloadCancelled {
      rethrow;
    } catch (error, stackTrace) {
      AppLogService.error(
        'asmr_download_transfer_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return _TemporaryDownloadResult(
        file: tempFile,
        bytesDownloaded: received,
      );
    } finally {
      if (identical(_activeHttpClients[workId], client)) {
        _activeHttpClients.remove(workId);
      }
      client.close(force: true);
    }
  }

  Future<void> _writeWorkDetailBackup(
    AudioDetail detail,
    String workRootPath,
  ) async {
    final payload = const JsonEncoder.withIndent(
      '  ',
    ).convert(detail.toBackupJson());
    if (PathMatcher.isContentUri(workRootPath)) {
      final saved = await _fileCacheGateway.writeAudioDetailBackup(
        folder: workRootPath,
        json: payload,
      );
      if (!saved) {
        throw const FileSystemException('Unable to write work detail backup.');
      }
      return;
    }

    final backupFile = File(path.join(workRootPath, 'nameless-audio.json'));
    await backupFile.writeAsString(payload, flush: true);
  }

  Future<bool> _ensureFolderPath({
    required String basePath,
    required String relativePath,
    required bool overwrite,
  }) async {
    final normalized = relativePath.trim().replaceAll('\\', '/');
    if (normalized.isEmpty) {
      return true;
    }

    if (PathMatcher.isContentUri(basePath)) {
      return _fileCacheGateway.ensureFolderPath(
        folder: basePath,
        relativePath: normalized,
        overwrite: overwrite,
      );
    }

    final folder = Directory(_joinFolderPath(basePath, normalized));
    try {
      await folder.create(recursive: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  String _joinFolderPath(String basePath, String relativePath) {
    if (PathMatcher.isContentUri(basePath)) {
      final normalizedRelative = relativePath.trim().replaceAll('\\', '/');
      if (normalizedRelative.isEmpty) {
        return _trimRightSlash(basePath);
      }
      return '${_trimRightSlash(basePath)}::$normalizedRelative';
    }
    return path.join(basePath, relativePath);
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
      salesCount: work.dlCount > 0 ? work.dlCount : null,
      rating: work.rating > 0 ? work.rating.clamp(0, 5).toDouble() : null,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    ).normalizedForSave(DateTime.now());
  }

  String _buildWorkFolderName(AsmrWork work) {
    final raw = [
      if (work.rjCode.trim().isNotEmpty) work.rjCode.trim(),
      work.title.trim(),
    ].where((item) => item.isNotEmpty).join(' - ');
    return PathDisplay.safeFileName(
      raw,
      replacement: '_',
      collapseWhitespace: false,
      fallback: 'ASMR_ONE',
    );
  }

  String? _downloadUrlFor(AsmrTrackFile node) {
    final candidates = <String?>[
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

  String _safeFileName(String value) {
    return PathDisplay.safeFileName(
      value,
      replacement: '_',
      collapseWhitespace: false,
      fallback: 'file',
    );
  }

  String _trimRightSlash(String value) {
    var result = value.trim();
    while (result.endsWith('/')) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }

  void _notifyTaskChanged() {
    _deferredProgressNotifyTimer?.cancel();
    _deferredProgressNotifyTimer = null;
    _refreshTaskIdsSnapshot();
    _markProgressNotified();
    notifyListeners();
  }

  void _refreshTaskIdsSnapshot() {
    final taskIds = _tasks.keys.toList(growable: false);
    if (listEquals(taskIds, _taskIdsSnapshot)) return;
    _taskIdsSnapshot = List<int>.unmodifiable(taskIds);
  }

  void _notifyProgressChanged() {
    final now = DateTime.now();
    final elapsed = _lastProgressNotifyAt == null
        ? _progressNotifyMinInterval
        : now.difference(_lastProgressNotifyAt!);

    int totalDownloadedBytes = 0;
    for (final task in _tasks.values) {
      if (task.status == AsmrDownloadTaskStatus.downloading) {
        totalDownloadedBytes += task.downloadedBytes;
      }
    }

    final byteDelta = (totalDownloadedBytes - _lastProgressNotifyBytes).abs();
    if (byteDelta >= _progressNotifyMinByteDelta ||
        elapsed >= _progressNotifyMinInterval) {
      _notifyTaskChanged();
      return;
    }

    _deferredProgressNotifyTimer ??= Timer(
      _progressNotifyMinInterval - elapsed,
      () {
        _deferredProgressNotifyTimer = null;
        _notifyTaskChanged();
      },
    );
  }

  void _markProgressNotified() {
    _lastProgressNotifyAt = DateTime.now();
    int totalDownloadedBytes = 0;
    for (final task in _tasks.values) {
      if (task.status == AsmrDownloadTaskStatus.downloading) {
        totalDownloadedBytes += task.downloadedBytes;
      }
    }
    _lastProgressNotifyBytes = totalDownloadedBytes;
  }

  @override
  void dispose() {
    _deferredProgressNotifyTimer?.cancel();
    for (final client in _activeHttpClients.values) {
      client.close(force: true);
    }
    _activeHttpClients.clear();
    _cancelCleanupRoots.clear();
    super.dispose();
  }

  void _throwIfCancelled(int workId) {
    if (_cancelRequested[workId] == true) {
      throw const _DownloadCancelled();
    }
  }

  Future<void> _deleteDownloadRoot(String workRootPath) async {
    try {
      if (PathMatcher.isContentUri(workRootPath)) {
        await _fileCacheGateway.deleteDocumentPath(workRootPath);
        return;
      }
      final directory = Directory(workRootPath);
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } catch (_) {
      // Temporary task directory cleanup is best effort.
    }
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
  });

  final File file;
  final int bytesDownloaded;
}

class _DownloadCancelled implements Exception {
  const _DownloadCancelled();
}
