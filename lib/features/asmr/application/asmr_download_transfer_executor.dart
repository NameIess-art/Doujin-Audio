import 'dart:async';
import 'dart:collection';
import 'dart:io';

import '../domain/asmr_download.dart';
import 'asmr_download_models.dart';
import 'asmr_download_internal_models.dart';
import 'asmr_download_task_store.dart';
import 'asmr_download_transfer_service.dart';
import 'asmr_download_cleanup.dart';

/// Owns active transfers and their interruption/waiting lifetime.
class AsmrDownloadTransferExecutor {
  AsmrDownloadTransferExecutor({
    required AsmrDownloadTaskStore store,
    required AsmrDownloadOutputStore outputs,
    required Duration automaticFileRetryDelay,
  }) : _store = store,
       _outputs = outputs {
    _service = AsmrDownloadTransferService(
      store: store,
      outputs: outputs,
      automaticFileRetryDelay: automaticFileRetryDelay,
      isDisposed: () => _disposed,
      isPaused: isPaused,
      throwIfCancelled: throwIfCancelled,
    );
  }
  static const int _maxConcurrentFilesPerTask = 3;
  final AsmrDownloadTaskStore _store;
  final AsmrDownloadOutputStore _outputs;
  late final AsmrDownloadTransferService _service;
  final Map<String, HttpClient> _activeHttpClients = {};
  final Map<String, void Function(PlannedDownloadFile)>
  _activeFileRetryDispatchers = {};
  final Map<String, Completer<void>> _completions = {};
  final Set<String> _cancelled = {};
  final Set<String> _paused = {};
  bool _disposed = false;

  void begin(String workId) {
    _completions[workId] = Completer<void>();
    _cancelled.remove(workId);
  }

  bool isCancelled(String workId) => _cancelled.contains(workId);
  bool isPaused(String workId) => _paused.contains(workId);
  void throwIfCancelled(String workId) {
    if (_disposed || isCancelled(workId) || isPaused(workId)) {
      throw const DownloadCancelled();
    }
  }

  Future<T> waitForExternal<T>(
    String workId,
    Future<T> Function() operation,
  ) async {
    throwIfCancelled(workId);
    final interrupted = Completer<T>();
    // Shared clients outlive this task; interrupt its wait without closing them.
    final timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      try {
        throwIfCancelled(workId);
      } on DownloadCancelled catch (error, stackTrace) {
        if (!interrupted.isCompleted) {
          interrupted.completeError(error, stackTrace);
        }
      }
    });
    try {
      final result = await Future.any([operation(), interrupted.future]);
      throwIfCancelled(workId);
      return result;
    } finally {
      timer.cancel();
    }
  }

  void pause(String workId) {
    _paused.add(workId);
    _activeHttpClients[workId]?.close(force: true);
  }

  void cancel(String workId) {
    _paused.remove(workId);
    _cancelled.add(workId);
    _activeHttpClients[workId]?.close(force: true);
  }

  Future<void> waitFor(String workId) =>
      _completions[workId]?.future ?? Future<void>.value();
  Future<void> get pendingTasks =>
      Future.wait<void>(_completions.values.map((value) => value.future));
  bool canRetry(String workId) =>
      _activeFileRetryDispatchers.containsKey(workId);
  void retry(String workId, PlannedDownloadFile item) =>
      _activeFileRetryDispatchers[workId]!(item);
  void finish(String workId) {
    _activeFileRetryDispatchers.remove(workId);
    _cancelled.remove(workId);
    _paused.remove(workId);
    final completion = _completions.remove(workId);
    if (completion != null && !completion.isCompleted) completion.complete();
  }

  void shutdown() {
    _disposed = true;
    _activeFileRetryDispatchers.clear();
    // Exit preserves resumable work; an earlier cancel must still clean output.
    _paused.addAll(_completions.keys.where((workId) => !isCancelled(workId)));
    for (final client in _activeHttpClients.values) {
      client.close(force: true);
    }
    _activeHttpClients.clear();
  }

  Future<void> downloadFiles({
    required AsmrDownloadTaskSnapshot taskSnapshot,
    required List<PlannedDownloadFile> plannedFiles,
    required AsmrDownloadFileProgress progress,
  }) async {
    final workId = taskSnapshot.work.workKey;
    final workRootPath = taskSnapshot.workRootPath;
    final conflictPolicy = taskSnapshot.conflictPolicy;

    final client = HttpClient()
      ..autoUncompress = false
      ..maxConnectionsPerHost = _maxConcurrentFilesPerTask
      ..connectionTimeout = const Duration(seconds: 15);
    _activeHttpClients[workId] = client;
    try {
      final pendingFiles = ListQueue<PlannedDownloadFile>();
      for (final item in plannedFiles) {
        if (progress.completedFilePaths.contains(item.relativePath)) {
          final exists = await _outputs.targetFileExists(
            workRootPath,
            item,
            coverOutputPath: taskSnapshot.coverOutputPath,
            actualOutputPath: taskSnapshot.actualOutputPaths[item.relativePath],
          );
          if (exists) {
            continue;
          }
          progress.completedFilePaths.remove(item.relativePath);
          progress.fileDownloadedBytes.remove(item.relativePath);
          if (progress.completed > 0) progress.completed--;
        }
        pendingFiles.add(item);
      }
      final activeTransfers = <Future<void>>{};
      final transfersDone = Completer<void>();
      var transfersStopped = false;
      Object? firstError;
      StackTrace? firstErrorStack;

      Future<void> downloadOneFile(PlannedDownloadFile item) async {
        throwIfCancelled(workId);
        final previousFileBytes =
            progress.fileDownloadedBytes[item.relativePath] ?? 0;
        final wasAlreadyAccounted = progress.completedFilePaths.contains(
          item.relativePath,
        );
        final wasFailed = progress.failedFilePaths.contains(item.relativePath);
        final wasManualRetry = progress.manuallyRetryingFilePaths.contains(
          item.relativePath,
        );
        _store[workId] = _store[workId]!.copyWith(
          currentItemPath: item.relativePath,
          message: item.relativePath,
        );
        _store.notifyProgressChanged(workId);

        final result = await _service.downloadItem(
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
              progress.completed++;
            } else {
              progress.skipped++;
            }
          }
          progress.completedFilePaths.add(item.relativePath);
          if (wasFailed && progress.failedFilePaths.remove(item.relativePath)) {
            if (progress.failed > 0) progress.failed--;
          }
        } else if (!wasFailed &&
            progress.failedFilePaths.add(item.relativePath)) {
          progress.failed++;
        }
        if (wasManualRetry) {
          progress.manuallyRetryingFilePaths.remove(item.relativePath);
        }

        // Chunks are accounted for eagerly in the task store. Apply only
        // the difference not already represented by the live counter.
        final liveFileProgress = _store.liveFileDownloadedBytes(
          workId,
          fallback: progress.fileDownloadedBytes,
        );
        final liveFileBytes =
            liveFileProgress[item.relativePath] ?? previousFileBytes;
        final unaccountedBytes = result.bytesDownloaded - liveFileBytes;
        if (unaccountedBytes != 0) {
          final liveBytes =
              _store.liveDownloadedBytes(workId) ?? progress.downloadedBytes;
          _store.setLiveDownloadedBytes(workId, liveBytes + unaccountedBytes);
        }
        progress.downloadedBytes =
            _store.liveDownloadedBytes(workId) ?? progress.downloadedBytes;
        liveFileProgress[item.relativePath] = result.bytesDownloaded;
        progress.fileDownloadedBytes[item.relativePath] =
            result.bytesDownloaded;

        _store[workId] = _store[workId]!.copyWith(
          completedFiles: progress.completed,
          skippedFiles: progress.skipped,
          failedFiles: progress.failed,
          downloadedBytes:
              _store.liveDownloadedBytes(workId) ?? progress.downloadedBytes,
          fileDownloadedBytes: progress.fileDownloadedBytes,
          completedFilePaths: progress.completedFilePaths,
          failedFilePaths: progress.failedFilePaths,
          manuallyRetryingFilePaths: progress.manuallyRetryingFilePaths,
        );
        _store.notifyProgressChanged(workId);
      }

      late void Function() pumpTransfers;
      void enqueueManualRetry(PlannedDownloadFile item) {
        if (transfersStopped || transfersDone.isCompleted) return;
        progress.manuallyRetryingFilePaths.add(item.relativePath);
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
                if (!transfersStopped) {
                  firstError = error;
                  firstErrorStack = stackTrace;
                  transfersStopped = true;
                  pendingFiles.clear();
                  client.close(force: true);
                }
                pumpTransfers();
              },
            ),
          );
        }
        if (pendingFiles.isEmpty &&
            activeTransfers.isEmpty &&
            !transfersDone.isCompleted) {
          if (firstError case final error?) {
            transfersDone.completeError(error, firstErrorStack);
          } else {
            transfersDone.complete();
          }
        }
      };

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
}

/// Local accounting for one execution; durable snapshots remain in TaskStore.
class AsmrDownloadFileProgress {
  AsmrDownloadFileProgress({
    required this.completed,
    required this.skipped,
    required this.failed,
    required this.downloadedBytes,
    required this.fileDownloadedBytes,
    required this.completedFilePaths,
    required this.failedFilePaths,
    required this.manuallyRetryingFilePaths,
  });
  int completed;
  int skipped;
  int failed;
  int downloadedBytes;
  final Map<String, int> fileDownloadedBytes;
  final Set<String> completedFilePaths;
  final Set<String> failedFilePaths;
  final Set<String> manuallyRetryingFilePaths;
}
