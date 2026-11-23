import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../../core/logging/app_log_service.dart';
import '../../../core/persistence/app_preferences.dart';
import '../domain/asmr_download.dart';
import '../domain/asmr_models.dart';
import 'asmr_download_models.dart';
import 'asmr_download_internal_models.dart';
import 'asmr_download_io.dart';

const Duration _taskStructurePersistenceDebounce = Duration(milliseconds: 400);
const Duration _taskProgressCheckpointInterval = Duration(seconds: 5);

typedef AsmrDownloadProgressCheckpoint = ({
  int downloadedBytes,
  Map<String, int> fileDownloadedBytes,
});

typedef _ResumableFileMetadata = ({
  Map<String, String> entityTags,
  Map<String, String> outputPaths,
});

/// Composed persistence & durability coordinator for [AsmrDownloadTaskStore].
/// Handles dedicated JSON file storage, atomic temp-file writes, one-time
/// migration from [AppPreferences], and lightweight 5 s progress checkpoints.
final class AsmrDownloadTaskPersistence {
  AsmrDownloadTaskPersistence({
    required bool persistTasks,
    required bool persistenceReady,
    required Iterable<AsmrDownloadTaskSnapshot> Function() currentTasks,
    required PersistedDownloadTask Function(AsmrDownloadTaskSnapshot task)
    persistenceSnapshot,
    Future<void> Function(String? payload)? persistenceWriter,
    Future<Directory> Function()? persistenceDirectoryProvider,
    void Function()? onSnapshotCaptured,
  }) : _persistTasks = persistTasks,
       _persistenceReady = persistenceReady,
       _currentTasks = currentTasks,
       _persistenceSnapshot = persistenceSnapshot,
       _persistenceWriter = persistenceWriter,
       _persistenceDirectoryProvider = persistenceDirectoryProvider,
       _onSnapshotCaptured = onSnapshotCaptured;

  static const String tasksFileName = 'asmr_download_tasks.json';
  static const String progressFileName = 'asmr_download_progress.json';

  final bool _persistTasks;
  final Iterable<AsmrDownloadTaskSnapshot> Function() _currentTasks;
  final PersistedDownloadTask Function(AsmrDownloadTaskSnapshot task)
  _persistenceSnapshot;
  final Future<void> Function(String? payload)? _persistenceWriter;
  final Future<Directory> Function()? _persistenceDirectoryProvider;
  final void Function()? _onSnapshotCaptured;

  Future<void> _persistenceTail = Future<void>.value();
  Future<void>? _queuedPersistence;
  Map<String, _ResumableFileMetadata> _committedFileMetadata = {};
  Map<String, _ResumableFileMetadata>? _writingFileMetadata;
  Timer? _deferredPersistenceTimer;
  Timer? _progressCheckpointTimer;
  bool _structuralDirty = false;
  bool _progressDirty = false;
  bool _hasWrittenFullFileSnapshot = false;
  bool _directoryChecked = false;
  Directory? _directory;
  bool _persistenceReady;

  Future<void> get pendingWrites => _persistenceTail;

  void markReady({bool restoredFromFile = false}) {
    _persistenceReady = true;
    if (restoredFromFile) _hasWrittenFullFileSnapshot = true;
  }

  void restoreTaskMetadata(AsmrDownloadTaskSnapshot task) {
    _committedFileMetadata[task.work.workKey] = _fileMetadata(task);
  }

  void removeTaskMetadata(String workId) {
    _committedFileMetadata.remove(workId);
    _writingFileMetadata?.remove(workId);
  }

  String? durableFileEntityTag(String workId, String relativePath) {
    if (!_persistTasks) return null;
    return _writingFileMetadata?[workId]?.entityTags[relativePath] ??
        _committedFileMetadata[workId]?.entityTags[relativePath];
  }

  bool isFileEntityTagDurable(String workId, String relativePath, String? tag) {
    if (!_persistTasks) return true;
    final committed = _committedFileMetadata[workId];
    final writing = _writingFileMetadata;
    return committed != null &&
        committed.entityTags[relativePath] == tag &&
        (writing == null ||
            (writing.containsKey(workId) &&
                writing[workId]!.entityTags[relativePath] == tag));
  }

  bool isFileOutputPathDurable(
    String workId,
    String relativePath,
    String outputPath,
  ) {
    if (!_persistTasks) return true;
    final committed = _committedFileMetadata[workId];
    final writing = _writingFileMetadata;
    return committed != null &&
        committed.outputPaths[relativePath] == outputPath &&
        (writing == null ||
            writing[workId]?.outputPaths[relativePath] == outputPath);
  }

  static _ResumableFileMetadata _fileMetadata(AsmrDownloadTaskSnapshot task) =>
      (entityTags: task.fileEntityTags, outputPaths: task.actualOutputPaths);

  Future<Directory?> _resolveDirectory() async {
    if (_directoryChecked) return _directory;
    final customProvider = _persistenceDirectoryProvider;
    try {
      _directory = await (customProvider ?? getApplicationSupportDirectory)();
      _directoryChecked = true;
      return _directory;
    } on MissingPluginException {
      _directoryChecked = true;
      _directory = null;
      return null;
    } on FlutterError {
      if (customProvider != null) rethrow;
      _directoryChecked = true;
      _directory = null;
      return null;
    }
  }

  Future<({List<PersistedDownloadTask> tasks, bool fromFile})>
  restorePersistedTasks({
    Future<String?> Function()? reader,
    bool Function()? isDisposed,
  }) async {
    final String? raw;
    String? progressPayload;
    var migratedFromLegacy = false;
    var fromFile = false;
    if (reader != null) {
      raw = await reader();
    } else {
      final dir = await _resolveDirectory();
      if (dir != null) {
        final tasksFile = File(path.join(dir.path, tasksFileName));
        if (await tasksFile.exists()) {
          raw = await tasksFile.readAsString();
          fromFile = true;
          final progressFile = File(path.join(dir.path, progressFileName));
          if (await progressFile.exists()) {
            try {
              progressPayload = await progressFile.readAsString();
            } catch (error, stackTrace) {
              AppLogService.warning(
                'asmr_download_progress_checkpoint_read_failed',
                error: error,
                stackTrace: stackTrace,
              );
            }
          }
        } else {
          raw = await AppPreferences.getString(
            AppPreferences.asmrDownloadTasksKey,
            throwOnError: true,
          );
          migratedFromLegacy = raw != null && raw.isNotEmpty;
        }
      } else {
        raw = await AppPreferences.getString(
          AppPreferences.asmrDownloadTasksKey,
          throwOnError: true,
        );
      }
    }
    if ((isDisposed?.call() ?? false) || raw == null || raw.isEmpty) {
      return (tasks: const <PersistedDownloadTask>[], fromFile: fromFile);
    }
    final restored = await compute(decodePersistedDownloadTasks, raw);
    if (isDisposed?.call() ?? false) {
      return (tasks: const <PersistedDownloadTask>[], fromFile: fromFile);
    }
    if (restored.error != null) {
      Error.throwWithStackTrace(restored.error!, restored.stackTrace!);
    }
    Map<String, AsmrDownloadProgressCheckpoint> progressOverlay = const {};
    if (progressPayload != null && progressPayload.isNotEmpty) {
      try {
        progressOverlay = decodePersistedDownloadProgressCheckpoints(
          progressPayload,
        );
      } catch (error, stackTrace) {
        AppLogService.warning(
          'asmr_download_progress_checkpoint_decode_failed',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    if (migratedFromLegacy) {
      final dir = await _resolveDirectory();
      if (dir != null) {
        await writeRawPersistedDownloadTasksFile(
          filePath: path.join(dir.path, tasksFileName),
          payload: raw,
        );
        _hasWrittenFullFileSnapshot = true;
        fromFile = true;
        await AppPreferences.remove(AppPreferences.asmrDownloadTasksKey);
      }
    }
    final merged = restored.tasks
        .map((snapshot) {
          final overlay = progressOverlay[snapshot.task.work.workKey];
          if (overlay == null) return snapshot;
          return PersistedDownloadTask(
            task: _applyProgressOverlay(snapshot.task, overlay),
            createdOutputPaths: snapshot.createdOutputPaths,
            createdJsonDocuments: snapshot.createdJsonDocuments,
          );
        })
        .toList(growable: false);
    return (tasks: merged, fromFile: fromFile);
  }

  static AsmrDownloadTaskSnapshot _applyProgressOverlay(
    AsmrDownloadTaskSnapshot task,
    AsmrDownloadProgressCheckpoint overlay,
  ) {
    final mergedFileBytes = Map<String, int>.from(task.fileDownloadedBytes);
    for (final entry in overlay.fileDownloadedBytes.entries) {
      final current = mergedFileBytes[entry.key] ?? 0;
      if (entry.value > current) mergedFileBytes[entry.key] = entry.value;
    }
    var mergedBytes = overlay.downloadedBytes > task.downloadedBytes
        ? overlay.downloadedBytes
        : task.downloadedBytes;
    if (task.totalBytes > 0 &&
        !task.hasUnknownFileSizes &&
        mergedBytes > task.totalBytes) {
      mergedBytes = task.totalBytes;
    }
    return task.copyWith(
      downloadedBytes: mergedBytes,
      fileDownloadedBytes: mergedFileBytes,
    );
  }

  void scheduleStructural() {
    if (!_persistTasks) return;
    _structuralDirty = true;
    _progressDirty = true;
    _progressCheckpointTimer?.cancel();
    _progressCheckpointTimer = null;
    _deferredPersistenceTimer ??= Timer(_taskStructurePersistenceDebounce, () {
      _deferredPersistenceTimer = null;
      persistNow();
    });
  }

  void scheduleProgress() {
    if (!_persistTasks) return;
    _progressDirty = true;
    if (_deferredPersistenceTimer != null) return;
    _progressCheckpointTimer ??= Timer(_taskProgressCheckpointInterval, () {
      _progressCheckpointTimer = null;
      persistNow();
    });
  }

  Future<void>? flushNow() {
    cancelTimers();
    _structuralDirty = true;
    _progressDirty = true;
    return persistNow();
  }

  Future<void> runStructuralForTesting() async {
    _deferredPersistenceTimer?.cancel();
    _deferredPersistenceTimer = null;
    if (_progressDirty) _structuralDirty = true;
    unawaited(persistNow());
    await _persistenceTail;
  }

  Future<void> runProgressCheckpointForTesting() async {
    _progressCheckpointTimer?.cancel();
    _progressCheckpointTimer = null;
    unawaited(persistNow());
    await _persistenceTail;
  }

  void cancelTimers() {
    _deferredPersistenceTimer?.cancel();
    _deferredPersistenceTimer = null;
    _progressCheckpointTimer?.cancel();
    _progressCheckpointTimer = null;
  }

  Future<void>? persistNow() {
    if (!_persistTasks ||
        !_persistenceReady ||
        (!_structuralDirty && !_progressDirty)) {
      return null;
    }
    final queued = _queuedPersistence;
    if (queued != null) return queued;
    var attemptedFullWrite = false;
    late final Future<void> write;
    write = _persistenceTail.then((_) async {
      _queuedPersistence = null;
      final dir = _persistenceWriter == null ? await _resolveDirectory() : null;
      final fullWrite =
          _structuralDirty || dir == null || !_hasWrittenFullFileSnapshot;
      attemptedFullWrite = fullWrite;
      _structuralDirty = false;
      _progressDirty = false;

      if (dir != null && !fullWrite) {
        final progress = <String, AsmrDownloadProgressCheckpoint>{
          for (final task in _currentTasks())
            if (task.status != AsmrDownloadTaskStatus.completed)
              task.work.workKey: (
                downloadedBytes: task.downloadedBytes,
                fileDownloadedBytes: Map<String, int>.of(
                  task.fileDownloadedBytes,
                ),
              ),
        };
        await writePersistedDownloadProgressFile(
          progressFilePath: path.join(dir.path, progressFileName),
          progress: progress,
        );
        return;
      }

      _onSnapshotCaptured?.call();
      final tasks = _currentTasks()
          .where((task) => task.status != AsmrDownloadTaskStatus.completed)
          .map(_persistenceSnapshot)
          .toList(growable: false);
      final fileMetadata = {
        for (final snapshot in tasks)
          snapshot.task.work.workKey: _fileMetadata(snapshot.task),
      };
      _writingFileMetadata = fileMetadata;
      try {
        if (dir != null) {
          await writePersistedDownloadTasksFile(
            filePath: path.join(dir.path, tasksFileName),
            progressFilePath: path.join(dir.path, progressFileName),
            tasks: tasks,
          );
          _hasWrittenFullFileSnapshot = true;
        } else {
          final payload = tasks.isEmpty
              ? null
              : await compute(encodePersistedDownloadTasks, tasks);
          await _writeLegacyOrInjected(payload);
        }
        _committedFileMetadata = fileMetadata;
      } finally {
        _writingFileMetadata = null;
      }
    });
    _queuedPersistence = write;
    _persistenceTail = write.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        if (attemptedFullWrite) _structuralDirty = true;
        _progressDirty = true;
        AppLogService.warning(
          'asmr_download_persist_failed',
          error: error,
          stackTrace: stackTrace,
        );
      },
    );
    return write;
  }

  Future<void> _writeLegacyOrInjected(String? payload) async {
    final writer = _persistenceWriter;
    if (writer != null) {
      await writer(payload);
      return;
    }
    final saved = payload == null
        ? await AppPreferences.remove(AppPreferences.asmrDownloadTasksKey)
        : await AppPreferences.setString(
            AppPreferences.asmrDownloadTasksKey,
            payload,
          );
    if (!saved) throw StateError('asmr_download_persist_failed');
  }
}

String encodePersistedDownloadProgressCheckpoints(
  Map<String, AsmrDownloadProgressCheckpoint> progress,
) => jsonEncode(<String, Object?>{
  'version': 1,
  'progress': <String, Object?>{
    for (final entry in progress.entries)
      entry.key: <String, Object?>{
        'downloadedBytes': entry.value.downloadedBytes,
        'fileDownloadedBytes': entry.value.fileDownloadedBytes,
      },
  },
});

Map<String, AsmrDownloadProgressCheckpoint>
decodePersistedDownloadProgressCheckpoints(String payload) {
  final decoded = jsonDecode(payload);
  if (decoded is! Map || decoded['progress'] is! Map) {
    throw const FormatException('Invalid download progress checkpoint record.');
  }
  final result = <String, AsmrDownloadProgressCheckpoint>{};
  for (final entry in (decoded['progress'] as Map).entries) {
    if (entry.key is! String || entry.value is! Map) continue;
    final map = entry.value as Map;
    result[entry.key as String] = (
      downloadedBytes: _jsonInt(map['downloadedBytes']),
      fileDownloadedBytes: _jsonIntMap(map['fileDownloadedBytes']),
    );
  }
  return result;
}

Future<void> writePersistedDownloadTasksFile({
  required String filePath,
  required String progressFilePath,
  required List<PersistedDownloadTask> tasks,
}) => Isolate.run(() {
  if (tasks.isEmpty) {
    _deleteIfExistsSync(filePath);
    _deleteIfExistsSync('$filePath.tmp');
    _deleteIfExistsSync(progressFilePath);
    _deleteIfExistsSync('$progressFilePath.tmp');
    return;
  }
  final payload = encodePersistedDownloadTasks(tasks);
  _writeFileAtomicallySync(filePath, payload);
  _deleteIfExistsSync(progressFilePath);
  _deleteIfExistsSync('$progressFilePath.tmp');
});

Future<void> writeRawPersistedDownloadTasksFile({
  required String filePath,
  required String payload,
}) => Isolate.run(() {
  _writeFileAtomicallySync(filePath, payload);
});

Future<void> writePersistedDownloadProgressFile({
  required String progressFilePath,
  required Map<String, AsmrDownloadProgressCheckpoint> progress,
}) => Isolate.run(() {
  if (progress.isEmpty) {
    _deleteIfExistsSync(progressFilePath);
    _deleteIfExistsSync('$progressFilePath.tmp');
    return;
  }
  final payload = encodePersistedDownloadProgressCheckpoints(progress);
  _writeFileAtomicallySync(progressFilePath, payload);
});

void _writeFileAtomicallySync(String filePath, String content) {
  final target = File(filePath);
  target.parent.createSync(recursive: true);
  final temp = File('$filePath.tmp');
  temp.writeAsStringSync(content, flush: true);
  temp.renameSync(filePath);
}

void _deleteIfExistsSync(String filePath) {
  final file = File(filePath);
  if (file.existsSync()) {
    file.deleteSync();
  }
}

String encodePersistedDownloadTasks(List<PersistedDownloadTask> tasks) =>
    jsonEncode(<String, Object?>{
      'version': 3,
      'tasks': tasks
          .map(
            (snapshot) => downloadTaskToJson(
              snapshot.task,
              createdOutputPaths: snapshot.createdOutputPaths,
              createdJsonDocuments: snapshot.createdJsonDocuments,
            ),
          )
          .toList(growable: false),
    });

({List<PersistedDownloadTask> tasks, Object? error, StackTrace? stackTrace})
decodePersistedDownloadTasks(String payload) {
  final tasks = <PersistedDownloadTask>[];
  try {
    final decoded = jsonDecode(payload);
    if (decoded is! Map || decoded['tasks'] is! List) {
      throw const FormatException('Invalid download task record.');
    }
    for (final value in decoded['tasks'] as List) {
      if (value is! Map) {
        throw const FormatException('Invalid download task entry.');
      }
      final taskJson = Map<String, dynamic>.from(value);
      if (!const [2, 3].contains(decoded['version'])) {
        taskJson.remove('fileEntityTags');
      }
      final restored = downloadTaskFromJson(taskJson);
      final preserveFailed =
          restored.task.status == AsmrDownloadTaskStatus.failed;
      tasks.add(
        PersistedDownloadTask(
          task: restored.task.copyWith(
            status: preserveFailed
                ? AsmrDownloadTaskStatus.failed
                : AsmrDownloadTaskStatus.paused,
            fileRetryAttempts: const {},
            manuallyRetryingFilePaths: const {},
            message: preserveFailed ? restored.task.message : 'paused',
          ),
          createdOutputPaths: restored.createdOutputPaths,
          createdJsonDocuments: restored.createdJsonDocuments,
        ),
      );
    }
    return (tasks: tasks, error: null, stackTrace: null);
  } catch (error, stackTrace) {
    // Retain the decoded prefix for diagnostics; a restore must reject the error
    // before publishing or persisting a partial record.
    return (tasks: tasks, error: error, stackTrace: stackTrace);
  }
}

Map<String, Object?> downloadTaskToJson(
  AsmrDownloadTaskSnapshot task, {
  required Set<String> createdOutputPaths,
  required Map<String, CreatedDownloadJsonDocument> createdJsonDocuments,
}) => <String, Object?>{
  'work': task.work.toJson(),
  'destinationRoot': task.destinationRoot,
  'workFolderName': task.workFolderName,
  'requestedWorkFolderName': task.requestedWorkFolderName,
  'conflictPolicy': task.conflictPolicy.name,
  'saveMetadata': task.saveMetadata,
  'saveCover': task.saveCover,
  'automaticFileRetryCount': task.automaticFileRetryCount,
  'status': task.status.name,
  'totalFiles': task.totalFiles,
  'completedFiles': task.completedFiles,
  'skippedFiles': task.skippedFiles,
  'failedFiles': task.failedFiles,
  'totalBytes': task.totalBytes,
  'downloadedBytes': task.downloadedBytes,
  'startedAt': task.startedAt.toIso8601String(),
  'currentItemPath': task.currentItemPath,
  'coverOutputPath': task.coverOutputPath,
  'message': task.message,
  'error': task.error,
  'fileDownloadedBytes': task.fileDownloadedBytes,
  'fileTotalBytes': task.fileTotalBytes,
  'fileEntityTags': task.fileEntityTags,
  'actualOutputPaths': task.actualOutputPaths,
  'completedFilePaths': task.completedFilePaths.toList(growable: false),
  'failedFilePaths': task.failedFilePaths.toList(growable: false),
  'selectedRoots': task.selectedRoots.map(_downloadTrackToJson).toList(),
  'createdOutputPaths': createdOutputPaths.toList(growable: false),
  'createdJsonDocuments': <String, Object?>{
    for (final entry in createdJsonDocuments.entries)
      entry.key: entry.value.toJson(),
  },
};

PersistedDownloadTask downloadTaskFromJson(Map<String, dynamic> json) {
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
  return PersistedDownloadTask(
    task: AsmrDownloadTaskSnapshot(
      work: work,
      destinationRoot: json['destinationRoot'] as String? ?? '',
      workFolderName: json['workFolderName'] as String? ?? '',
      requestedWorkFolderName: json['requestedWorkFolderName'] as String?,
      conflictPolicy: _enumByName(
        AsmrDownloadConflictPolicy.values,
        json['conflictPolicy'],
        AsmrDownloadConflictPolicy.skip,
      ),
      saveMetadata: json['saveMetadata'] as bool? ?? true,
      saveCover: json['saveCover'] as bool? ?? false,
      automaticFileRetryCount: normalizeAsmrDownloadRetryCount(
        (json['automaticFileRetryCount'] as num?)?.toInt() ??
            kMaxAsmrDownloadRetryCount,
      ),
      status:
          _enumByName(
                AsmrDownloadTaskStatus.values,
                json['status'],
                AsmrDownloadTaskStatus.paused,
              ) ==
              AsmrDownloadTaskStatus.failed
          ? AsmrDownloadTaskStatus.failed
          : AsmrDownloadTaskStatus.paused,
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
      coverOutputPath: json['coverOutputPath'] as String?,
      message: json['message'] as String?,
      error: json['error'] as String?,
      fileDownloadedBytes: _jsonIntMap(json['fileDownloadedBytes']),
      fileTotalBytes: _jsonIntMap(json['fileTotalBytes']),
      fileEntityTags: _jsonEntityTags(json['fileEntityTags']),
      actualOutputPaths: (json['actualOutputPaths'] as Map? ?? const {}).map(
        (key, value) => MapEntry(key as String, value as String),
      ),
      completedFilePaths:
          (json['completedFilePaths'] as List? ?? const <Object>[])
              .whereType<String>()
              .toSet(),
      failedFilePaths: (json['failedFilePaths'] as List? ?? const <Object>[])
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

Map<String, CreatedDownloadJsonDocument> _createdJsonDocumentsFromJson(
  Object? value,
) {
  if (value is! Map<Object?, Object?>) {
    return const <String, CreatedDownloadJsonDocument>{};
  }
  final result = <String, CreatedDownloadJsonDocument>{};
  for (final entry in value.entries) {
    if (entry.key is! String || entry.value is! Map<Object?, Object?>) continue;
    final decoded = CreatedDownloadJsonDocument.fromJson(
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
      'workKey': track.workKey,
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
      workKey: json['workKey'] as String?,
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

Map<String, String> _jsonEntityTags(Object? value) {
  if (value is! Map<Object?, Object?>) return const {};
  return <String, String>{
    for (final entry in value.entries)
      if (entry.key is String)
        entry.key as String: ?strongDownloadEntityTag(entry.value),
  };
}

int _jsonInt(Object? value) => (value as num?)?.toInt() ?? 0;

T _enumByName<T extends Enum>(List<T> values, Object? name, T fallback) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  return fallback;
}
