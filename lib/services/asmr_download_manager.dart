import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';

import '../models/audio_detail.dart';
import '../models/asmr_models.dart';
import 'app_cache_service.dart';
import 'app_preferences.dart';
import 'path_display.dart';
import 'path_matcher.dart';
import 'platform_channels.dart';

enum AsmrDownloadConflictPolicy { skip, overwrite }

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
    );
  }
}

class AsmrDownloadManager extends ChangeNotifier {
  AsmrDownloadManager();

  static const String _defaultDestinationKey =
      'asmr_download_default_destination_v1';
  static const MethodChannel _fileCacheChannel = MethodChannel(
    FileCacheChannel.name,
  );

  AsmrDownloadTaskSnapshot? _currentTask;
  String? _defaultDestinationRoot;
  bool _initialized = false;
  bool _running = false;
  bool _cancelRequested = false;
  Completer<void>? _downloadCompletion;

  AsmrDownloadTaskSnapshot? get currentTask => _currentTask;
  bool get hasLiveTask => _currentTask?.isActive ?? false;
  String? get defaultDestinationRoot => _defaultDestinationRoot;

  Future<void> initialize() async {
    if (_initialized) return;
    _defaultDestinationRoot = (await AppPreferences.getString(
      _defaultDestinationKey,
    ))?.trim();
    if (_defaultDestinationRoot?.isEmpty ?? true) {
      _defaultDestinationRoot = null;
    }
    _initialized = true;
    notifyListeners();
  }

  Future<String?> pickDestinationFolder({String? dialogTitle}) async {
    try {
      if (Platform.isAndroid) {
        final raw = await _fileCacheChannel.invokeMapMethod<String, Object?>(
          FileCacheMethod.pickAudioFolder,
        );
        final pathValue = raw?['path']?.toString().trim();
        if (pathValue != null && pathValue.isNotEmpty) {
          return pathValue;
        }
      }
    } on PlatformException {
      // Fall through to the file picker.
    } catch (_) {}

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

  Future<void> saveDefaultDestination(String folderPath) async {
    final normalized = folderPath.trim();
    if (normalized.isEmpty) return;
    _defaultDestinationRoot = normalized;
    await AppPreferences.setString(_defaultDestinationKey, normalized);
    notifyListeners();
  }

  Future<void> clearDefaultDestination() async {
    _defaultDestinationRoot = null;
    await AppPreferences.remove(_defaultDestinationKey);
    notifyListeners();
  }

  Future<bool> destinationExists(String folderPath) async {
    final normalized = folderPath.trim();
    if (normalized.isEmpty) return false;
    if (PathMatcher.isContentUri(normalized)) {
      try {
        return await _fileCacheChannel.invokeMethod<bool>(
              FileCacheMethod.documentPathExists,
              {'path': normalized},
            ) ??
            false;
      } catch (_) {
        return false;
      }
    }
    return Directory(normalized).exists();
  }

  Future<void> cancelCurrentDownload() async {
    final task = _currentTask;
    if (task == null) {
      return;
    }

    _cancelRequested = true;
    if (task.isActive) {
      _currentTask = task.copyWith(message: 'canceling');
      notifyListeners();
    }

    final completion = _downloadCompletion;
    if (completion != null && !completion.isCompleted) {
      await completion.future;
    }

    await _deleteDownloadRoot(task.workRootPath);
    _currentTask = null;
    notifyListeners();
  }

  Future<void> startDownload({
    required AsmrWork work,
    required List<AsmrTrackFile> selectedRoots,
    required String destinationRoot,
    required AsmrDownloadConflictPolicy conflictPolicy,
  }) async {
    if (_running) {
      throw StateError('A download is already in progress.');
    }
    final normalizedDestination = destinationRoot.trim();
    if (normalizedDestination.isEmpty) {
      throw ArgumentError.value(destinationRoot, 'destinationRoot');
    }
    if (selectedRoots.isEmpty) {
      throw ArgumentError.value(selectedRoots, 'selectedRoots');
    }

    await initialize();
    _running = true;
    _cancelRequested = false;
    _downloadCompletion = Completer<void>();

    final workFolderName = _buildWorkFolderName(work);
    final workRootPath = _joinFolderPath(normalizedDestination, workFolderName);
    final backup = _buildBackupDetail(work, workRootPath);
    final backupJson = const JsonEncoder.withIndent(
      '  ',
    ).convert(backup.toBackupJson());
    final backupBytes = utf8.encode(backupJson).length;
    final plannedFiles = _collectPlannedFiles(selectedRoots);
    final plannedFolders = _collectPlannedFolders(selectedRoots);
    final totalFiles = plannedFiles.length + 1;
    final totalBytes = plannedFiles.fold<int>(backupBytes, (sum, item) {
      return sum + item.size;
    });

    _currentTask = AsmrDownloadTaskSnapshot(
      work: work,
      destinationRoot: normalizedDestination,
      workFolderName: workFolderName,
      conflictPolicy: conflictPolicy,
      status: AsmrDownloadTaskStatus.preparing,
      totalFiles: totalFiles,
      completedFiles: 0,
      skippedFiles: 0,
      failedFiles: 0,
      totalBytes: totalBytes,
      downloadedBytes: 0,
      startedAt: DateTime.now(),
      message: 'preparing',
    );
    notifyListeners();

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
      _throwIfCancelled();

      _currentTask = _currentTask!.copyWith(
        status: AsmrDownloadTaskStatus.downloading,
        completedFiles: 1,
        downloadedBytes: backupBytes,
        message: 'downloading_work_detail',
      );
      notifyListeners();

      var completed = 1;
      var skipped = 0;
      var failed = 0;
      var downloadedBytes = backupBytes;

      for (final folder in plannedFolders) {
        _throwIfCancelled();
        final ensured = await _ensureFolderPath(
          basePath: workRootPath,
          relativePath: folder.relativePath,
          overwrite: conflictPolicy == AsmrDownloadConflictPolicy.overwrite,
        );
        if (ensured) {
          continue;
        }
        if (conflictPolicy == AsmrDownloadConflictPolicy.skip) {
          skipped++;
        } else {
          failed++;
        }
      }

      for (final item in plannedFiles) {
        _throwIfCancelled();
        _currentTask = _currentTask!.copyWith(
          currentItemPath: item.relativePath,
          message: item.relativePath,
        );
        notifyListeners();

        final result = await _downloadItem(
          item,
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

        _currentTask = _currentTask!.copyWith(
          completedFiles: completed,
          skippedFiles: skipped,
          failedFiles: failed,
          downloadedBytes: downloadedBytes,
        );
        notifyListeners();
      }

      _currentTask = _currentTask!.copyWith(
        status: failed > 0
            ? AsmrDownloadTaskStatus.failed
            : AsmrDownloadTaskStatus.completed,
        completedFiles: completed,
        skippedFiles: skipped,
        failedFiles: failed,
        downloadedBytes: totalBytes,
        message: failed > 0 ? 'completed_with_failures' : 'completed',
      );
      notifyListeners();
    } on _DownloadCancelled {
      _currentTask = _currentTask?.copyWith(
        status: AsmrDownloadTaskStatus.failed,
        message: 'cancelled',
      );
      notifyListeners();
    } catch (error) {
      _currentTask = _currentTask?.copyWith(
        status: AsmrDownloadTaskStatus.failed,
        error: error.toString(),
        message: 'failed',
      );
      notifyListeners();
    } finally {
      _running = false;
      final completion = _downloadCompletion;
      _downloadCompletion = null;
      if (completion != null && !completion.isCompleted) {
        completion.complete();
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

  List<_PlannedFolder> _collectPlannedFolders(List<AsmrTrackFile> roots) {
    final result = <_PlannedFolder>[];
    for (final root in roots) {
      _collectPlannedFoldersRecursively(root, result);
    }
    return result;
  }

  void _collectPlannedFoldersRecursively(
    AsmrTrackFile node,
    List<_PlannedFolder> result,
  ) {
    if (!node.isFolder) {
      return;
    }
    if (node.children.isEmpty) {
      result.add(_PlannedFolder(relativePath: node.relativePath));
      return;
    }
    for (final child in node.children) {
      _collectPlannedFoldersRecursively(child, result);
    }
  }

  Future<_WriteResult> _downloadItem(
    _PlannedDownloadFile item, {
    required String workRootPath,
    required AsmrDownloadConflictPolicy conflictPolicy,
  }) async {
    _throwIfCancelled();
    final tempResult = await _downloadToTemporaryFile(item);
    if (tempResult == null) {
      return const _WriteResult.failure(bytesDownloaded: 0);
    }

    try {
      _throwIfCancelled();
      if (PathMatcher.isContentUri(workRootPath)) {
        final saved =
            await _fileCacheChannel
                .invokeMethod<bool>(FileCacheMethod.copyFileToFolder, {
                  'sourcePath': tempResult.file.path,
                  'folder': workRootPath,
                  'relativePath': item.relativePath,
                  'overwrite':
                      conflictPolicy == AsmrDownloadConflictPolicy.overwrite,
                }) ??
            false;
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
      } catch (_) {}
    }
  }

  Future<_TemporaryDownloadResult?> _downloadToTemporaryFile(
    _PlannedDownloadFile item,
  ) async {
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
    var received = 0;
    try {
      _throwIfCancelled();
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
          _throwIfCancelled();
          received += chunk.length;
          sink.add(chunk);
          if (_currentTask != null) {
            _currentTask = _currentTask!.copyWith(
              downloadedBytes: _currentTask!.downloadedBytes + chunk.length,
            );
            notifyListeners();
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
    } catch (_) {
      return _TemporaryDownloadResult(
        file: tempFile,
        bytesDownloaded: received,
      );
    } finally {
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
      final saved =
          await _fileCacheChannel.invokeMethod<bool>(
            FileCacheMethod.writeAudioDetailBackup,
            {'folder': workRootPath, 'json': payload},
          ) ??
          false;
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
      return await _fileCacheChannel.invokeMethod<bool>(
            FileCacheMethod.ensureFolderPath,
            {
              'folder': basePath,
              'relativePath': normalized,
              'overwrite': overwrite,
            },
          ) ??
          false;
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

  void _throwIfCancelled() {
    if (_cancelRequested) {
      throw const _DownloadCancelled();
    }
  }

  Future<void> _deleteDownloadRoot(String workRootPath) async {
    try {
      if (PathMatcher.isContentUri(workRootPath)) {
        await _fileCacheChannel.invokeMethod<bool>(
          FileCacheMethod.deleteDocumentPath,
          {'path': workRootPath},
        );
        return;
      }
      final directory = Directory(workRootPath);
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } catch (_) {}
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

class _PlannedFolder {
  const _PlannedFolder({required this.relativePath});

  final String relativePath;
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
