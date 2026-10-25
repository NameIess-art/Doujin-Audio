import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/logging/app_log_service.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/persistence/app_preferences.dart';
import 'asmr_download_models.dart';
import 'asmr_download_internal_models.dart';
import 'asmr_download_serialization.dart';

const Duration _taskStructurePersistenceDebounce = Duration(milliseconds: 400);
const Duration _taskProgressCheckpointInterval = Duration(seconds: 5);
const Duration _progressNotifyMinInterval = Duration(milliseconds: 120);

enum AsmrDownloadStoreOperation {
  uriReferenceVisit,
  liveProgressVisit,
  persistenceSnapshot,
}

typedef AsmrDownloadPersistenceSnapshot =
    PersistedDownloadTask Function(AsmrDownloadTaskSnapshot task);

/// Owns download task snapshots and every derived/published task state.
final class AsmrDownloadTaskStore {
  AsmrDownloadTaskStore({
    required bool persistTasks,
    required AsmrDownloadPersistenceSnapshot persistenceSnapshot,
    bool persistenceReady = true,
    Future<void> Function(String? payload)? persistenceWriter,
    void Function(AsmrDownloadStoreOperation operation)? operationObserver,
  }) : _persistTasks = persistTasks,
       _persistenceReady = persistenceReady,
       _persistenceSnapshot = persistenceSnapshot,
       _persistenceWriter = persistenceWriter,
       _operationObserver = operationObserver;

  final bool _persistTasks;
  final AsmrDownloadPersistenceSnapshot _persistenceSnapshot;
  final Future<void> Function(String? payload)? _persistenceWriter;
  final void Function(AsmrDownloadStoreOperation operation)? _operationObserver;

  final Map<String, AsmrDownloadTaskSnapshot> _tasks = {};
  final Map<String, AsmrDownloadTaskSnapshot> _publishedTasks = {};
  final Map<String, int> _liveDownloadedBytes = {};
  final Map<String, Map<String, int>> _liveFileDownloadedBytes = {};
  final Map<String, String> _persistedContentUriByWorkId = {};
  final Map<String, int> _persistedContentUriRefCounts = {};
  final Set<String> _pendingProgressWorkIds = {};

  final StreamController<int> _persistedUriReferenceRevisionController =
      StreamController<int>.broadcast(sync: true);
  final StreamController<List<String>> _taskIdsController =
      StreamController<List<String>>.broadcast(sync: true);
  final StreamController<({String workId, AsmrDownloadTaskSnapshot? task})>
  _taskChangesController =
      StreamController<
        ({String workId, AsmrDownloadTaskSnapshot? task})
      >.broadcast(sync: true);
  final StreamController<AsmrDownloadButtonViewState>
  _buttonViewStateController =
      StreamController<AsmrDownloadButtonViewState>.broadcast(sync: true);

  List<String> _taskIdsSnapshot = const [];
  Set<String> _persistedContentUris = const {};
  AsmrDownloadButtonViewState _publishedButtonViewState =
      const AsmrDownloadButtonViewState(visible: false, progress: null);
  int _aggregateTotalBytes = 0;
  int _aggregateDownloadedBytes = 0;
  int _aggregateUnknownSizeTasks = 0;
  int _aggregateTotalFiles = 0;
  double _aggregateProgressUnits = 0;
  int _persistedUriReferenceRevision = 0;
  Future<void> _persistenceTail = Future<void>.value();
  Future<void>? _shutdownFuture;
  Timer? _deferredPersistenceTimer;
  Timer? _progressCheckpointTimer;
  Timer? _deferredProgressNotifyTimer;
  DateTime? _lastProgressNotifyAt;
  bool _persistenceDirty = false;
  bool _persistenceReady;
  bool _shutdown = false;

  List<AsmrDownloadTaskSnapshot> get tasks =>
      List<AsmrDownloadTaskSnapshot>.unmodifiable(_tasks.values);
  List<String> get taskIds => _taskIdsSnapshot;
  Iterable<MapEntry<String, AsmrDownloadTaskSnapshot>> get entries =>
      _tasks.entries;
  Iterable<AsmrDownloadTaskSnapshot> get values => _tasks.values;
  bool get isShutdown => _shutdown;
  Future<void> get pendingPersistenceWrites => _persistenceTail;

  void markPersistenceReady() {
    _persistenceReady = true;
  }

  AsmrDownloadTaskSnapshot? operator [](String workId) => _tasks[workId];

  void operator []=(String workId, AsmrDownloadTaskSnapshot task) {
    if (_shutdown) return;
    _tasks[workId] = task;
  }

  AsmrDownloadTaskSnapshot? remove(String workId) {
    if (_shutdown) return null;
    _liveDownloadedBytes.remove(workId);
    _liveFileDownloadedBytes.remove(workId);
    return _tasks.remove(workId);
  }

  int get persistedUriReferenceRevision => _persistedUriReferenceRevision;
  Stream<int> get persistedUriReferenceRevisions =>
      _persistedUriReferenceRevisionController.stream;
  Set<String> get persistedContentUris => _persistedContentUris;

  Stream<List<String>> get taskIdsStream =>
      Stream<List<String>>.multi((events) {
        events.addSync(taskIds);
        final subscription = _taskIdsController.stream.listen(
          events.addSync,
          onError: events.addErrorSync,
          onDone: events.closeSync,
        );
        events.onCancel = subscription.cancel;
      }, isBroadcast: true);

  Stream<AsmrDownloadTaskSnapshot?> taskStream(String workId) =>
      Stream<AsmrDownloadTaskSnapshot?>.multi((events) {
        events.addSync(this[workId]);
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

  AsmrDownloadButtonViewState get buttonViewState {
    if (_taskIdsSnapshot.isEmpty) {
      return const AsmrDownloadButtonViewState(visible: false, progress: null);
    }
    final double? progress;
    if (_aggregateUnknownSizeTasks > 0) {
      progress = _aggregateTotalFiles > 0
          ? (_aggregateProgressUnits / _aggregateTotalFiles).clamp(0.0, 1.0)
          : null;
    } else {
      progress = _aggregateTotalBytes > 0
          ? (_aggregateDownloadedBytes / _aggregateTotalBytes).clamp(0.0, 1.0)
          : null;
    }
    return AsmrDownloadButtonViewState(visible: true, progress: progress);
  }

  void notifyTaskChanged({
    bool progressOnly = false,
    bool forcePersistedUriReferenceRevision = false,
    Set<String>? changedWorkIds,
  }) {
    if (_shutdown) return;
    _deferredProgressNotifyTimer?.cancel();
    _deferredProgressNotifyTimer = null;
    _pendingProgressWorkIds.clear();
    final publishedLiveWorkIds = _publishLiveProgress(changedWorkIds);
    final changedIds = changedWorkIds == null
        ? _allChangedTaskIds()
        : <String>{...changedWorkIds, ...publishedLiveWorkIds};
    _syncPersistedUriReferences(
      changedIds,
      forceRevision: forcePersistedUriReferenceRevision,
    );
    if (!progressOnly) {
      final previousTaskIds = _taskIdsSnapshot;
      _refreshTaskIdsSnapshot();
      if (!identical(previousTaskIds, _taskIdsSnapshot)) {
        _taskIdsController.add(_taskIdsSnapshot);
      }
    }
    _publishChangedTasks(changedIds);
    _lastProgressNotifyAt = DateTime.now();
    if (progressOnly) {
      _scheduleProgressCheckpoint();
    } else {
      _scheduleStructuralPersistence();
    }
  }

  void notifyProgressChanged(String workId) {
    if (_shutdown) return;
    _pendingProgressWorkIds.add(workId);
    final now = DateTime.now();
    final elapsed = _lastProgressNotifyAt == null
        ? _progressNotifyMinInterval
        : now.difference(_lastProgressNotifyAt!);
    if (elapsed >= _progressNotifyMinInterval) {
      flushPendingProgressNotifications();
      return;
    }
    _deferredProgressNotifyTimer ??= Timer(
      _progressNotifyMinInterval - elapsed,
      flushPendingProgressNotifications,
    );
  }

  void flushPendingProgressNotifications() {
    _deferredProgressNotifyTimer?.cancel();
    _deferredProgressNotifyTimer = null;
    if (_pendingProgressWorkIds.isEmpty) return;
    final changedWorkIds = Set<String>.of(_pendingProgressWorkIds);
    _pendingProgressWorkIds.clear();
    notifyTaskChanged(progressOnly: true, changedWorkIds: changedWorkIds);
  }

  void recordDownloadChunk(
    String workId,
    String relativePath,
    int chunkLength,
    int fileDownloadedBytes,
  ) {
    if (_shutdown) return;
    final task = this[workId];
    if (task == null || chunkLength <= 0) return;
    final maxBytes = task.totalBytes > 0 && !task.hasUnknownFileSizes
        ? task.totalBytes
        : null;
    _liveDownloadedBytes.update(
      workId,
      (value) {
        final next = value + chunkLength;
        return maxBytes != null && next > maxBytes ? maxBytes : next;
      },
      ifAbsent: () {
        final next = task.downloadedBytes + chunkLength;
        return maxBytes != null && next > maxBytes ? maxBytes : next;
      },
    );
    final fileProgress = _liveFileDownloadedBytes.putIfAbsent(
      workId,
      () => Map<String, int>.from(task.fileDownloadedBytes),
    );
    fileProgress[relativePath] = fileDownloadedBytes;
    notifyProgressChanged(workId);
  }

  void reconcileLiveFileProgress(
    String workId,
    String relativePath,
    int actualBytes,
  ) {
    final task = this[workId];
    if (_shutdown || task == null) return;
    final fileProgress = liveFileDownloadedBytes(
      workId,
      fallback: task.fileDownloadedBytes,
    );
    final previous = fileProgress[relativePath] ?? 0;
    if (previous == actualBytes) return;
    final next =
        (liveDownloadedBytes(workId) ?? task.downloadedBytes) +
        actualBytes -
        previous;
    setLiveDownloadedBytes(workId, next < 0 ? 0 : next);
    fileProgress[relativePath] = actualBytes;
    notifyProgressChanged(workId);
  }

  int? liveDownloadedBytes(String workId) => _liveDownloadedBytes[workId];

  void setLiveDownloadedBytes(String workId, int value) {
    final task = this[workId];
    final maxBytes =
        task != null && task.totalBytes > 0 && !task.hasUnknownFileSizes
        ? task.totalBytes
        : null;
    _liveDownloadedBytes[workId] = maxBytes != null && value > maxBytes
        ? maxBytes
        : value;
  }

  Map<String, int> liveFileDownloadedBytes(
    String workId, {
    Map<String, int> fallback = const {},
  }) => _liveFileDownloadedBytes.putIfAbsent(
    workId,
    () => Map<String, int>.from(fallback),
  );

  void setLiveFileDownloadedBytes(String workId, Map<String, int> value) {
    _liveFileDownloadedBytes[workId] = value;
  }

  void removeLiveProgress(String workId) {
    _liveDownloadedBytes.remove(workId);
    _liveFileDownloadedBytes.remove(workId);
  }

  List<String> retainOnlyLatestCompletedTask(String workId) {
    final obsoleteTaskIds = _tasks.entries
        .where(
          (entry) =>
              entry.key != workId &&
              entry.value.status == AsmrDownloadTaskStatus.completed,
        )
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final obsoleteWorkId in obsoleteTaskIds) {
      remove(obsoleteWorkId);
    }
    return obsoleteTaskIds;
  }

  Future<void> flushPersistence() async {
    if (_shutdown) return _persistenceTail;
    _publishLiveProgress();
    _cancelPersistenceTimers();
    _persistenceDirty = true;
    await _persistCurrentTasks();
  }

  Future<void> runStructuralPersistenceForTesting() async {
    _deferredPersistenceTimer?.cancel();
    _deferredPersistenceTimer = null;
    unawaited(_persistCurrentTasks());
    await _persistenceTail;
  }

  Future<void> runProgressCheckpointForTesting() async {
    _progressCheckpointTimer?.cancel();
    _progressCheckpointTimer = null;
    unawaited(_persistCurrentTasks());
    await _persistenceTail;
  }

  Future<void> shutdown({Iterable<String> pauseWorkIds = const []}) =>
      _shutdownFuture ??= _shutdownOnce(pauseWorkIds);

  Future<void> _shutdownOnce(Iterable<String> pauseWorkIds) async {
    if (_shutdown) return _persistenceTail;
    _cancelPersistenceTimers();
    _deferredProgressNotifyTimer?.cancel();
    _deferredProgressNotifyTimer = null;
    _pendingProgressWorkIds.clear();
    _publishLiveProgress();
    for (final workId in pauseWorkIds) {
      final task = this[workId];
      if (task != null) {
        this[workId] = task.copyWith(
          status: AsmrDownloadTaskStatus.paused,
          fileRetryAttempts: const {},
          manuallyRetryingFilePaths: const {},
          message: 'paused',
        );
      }
    }
    _persistenceDirty = true;
    final finalWrite = _persistCurrentTasks();
    _shutdown = true;
    _liveDownloadedBytes.clear();
    _liveFileDownloadedBytes.clear();
    try {
      await finalWrite;
    } finally {
      await Future.wait<void>([
        _persistedUriReferenceRevisionController.close(),
        _taskIdsController.close(),
        _taskChangesController.close(),
        _buttonViewStateController.close(),
      ]);
    }
  }

  void _syncPersistedUriReferences(
    Set<String> workIds, {
    required bool forceRevision,
  }) {
    var membershipChanged = false;
    for (final workId in workIds) {
      _operationObserver?.call(AsmrDownloadStoreOperation.uriReferenceVisit);
      final previous = _persistedContentUriByWorkId[workId];
      final task = this[workId];
      final next =
          task != null &&
              task.status != AsmrDownloadTaskStatus.completed &&
              PathMatcher.isContentUri(task.destinationRoot)
          ? task.destinationRoot
          : null;
      if (previous == next) continue;
      if (previous != null) {
        final remaining = (_persistedContentUriRefCounts[previous] ?? 1) - 1;
        if (remaining <= 0) {
          _persistedContentUriRefCounts.remove(previous);
          membershipChanged = true;
        } else {
          _persistedContentUriRefCounts[previous] = remaining;
        }
        _persistedContentUriByWorkId.remove(workId);
      }
      if (next != null) {
        final previousCount = _persistedContentUriRefCounts[next] ?? 0;
        _persistedContentUriRefCounts[next] = previousCount + 1;
        _persistedContentUriByWorkId[workId] = next;
        membershipChanged = membershipChanged || previousCount == 0;
      }
    }
    if (!membershipChanged && !forceRevision) return;
    if (membershipChanged) {
      _persistedContentUris = Set<String>.unmodifiable(
        _persistedContentUriRefCounts.keys,
      );
    }
    _persistedUriReferenceRevision += 1;
    _persistedUriReferenceRevisionController.add(
      _persistedUriReferenceRevision,
    );
  }

  Set<String> _allChangedTaskIds() {
    final taskIds = <String>{..._publishedTasks.keys, ..._tasks.keys};
    taskIds.removeWhere(
      (workId) => identical(_publishedTasks[workId], _tasks[workId]),
    );
    return taskIds;
  }

  void _publishChangedTasks(Set<String> workIds) {
    for (final workId in workIds) {
      final previous = _publishedTasks[workId];
      final next = this[workId];
      _subtractAggregate(previous);
      _addAggregate(next);
      if (next == null) {
        _publishedTasks.remove(workId);
      } else {
        _publishedTasks[workId] = next;
      }
      _taskChangesController.add((workId: workId, task: next));
    }
    final buttonState = buttonViewState;
    if (buttonState != _publishedButtonViewState) {
      _publishedButtonViewState = buttonState;
      _buttonViewStateController.add(buttonState);
    }
  }

  void _subtractAggregate(AsmrDownloadTaskSnapshot? task) {
    if (!_contributesToAggregate(task)) return;
    _aggregateTotalBytes -= task!.totalBytes;
    _aggregateDownloadedBytes -= task.downloadedBytes;
    if (task.hasUnknownFileSizes) _aggregateUnknownSizeTasks--;
    _aggregateTotalFiles -= task.totalFiles;
    _aggregateProgressUnits -= (task.progress ?? 0) * task.totalFiles;
  }

  void _addAggregate(AsmrDownloadTaskSnapshot? task) {
    if (!_contributesToAggregate(task)) return;
    _aggregateTotalBytes += task!.totalBytes;
    _aggregateDownloadedBytes += task.downloadedBytes;
    if (task.hasUnknownFileSizes) _aggregateUnknownSizeTasks++;
    _aggregateTotalFiles += task.totalFiles;
    _aggregateProgressUnits += (task.progress ?? 0) * task.totalFiles;
  }

  bool _contributesToAggregate(AsmrDownloadTaskSnapshot? task) =>
      task != null &&
      (task.isActive || task.status == AsmrDownloadTaskStatus.completed);

  void _refreshTaskIdsSnapshot() {
    final taskIds = _tasks.entries
        .where(
          (entry) => entry.value.status != AsmrDownloadTaskStatus.completed,
        )
        .map((entry) => entry.key)
        .toList(growable: false);
    if (listEquals(taskIds, _taskIdsSnapshot)) return;
    _taskIdsSnapshot = List<String>.unmodifiable(taskIds);
  }

  Set<String> _publishLiveProgress([Set<String>? workIds]) {
    final changedWorkIds = <String>{};
    for (final workId in workIds ?? _liveDownloadedBytes.keys.toSet()) {
      _operationObserver?.call(AsmrDownloadStoreOperation.liveProgressVisit);
      final downloadedBytes = _liveDownloadedBytes[workId];
      final task = this[workId];
      if (task == null || downloadedBytes == null) continue;
      final fileDownloadedBytes = Map<String, int>.unmodifiable(
        _liveFileDownloadedBytes[workId] ?? task.fileDownloadedBytes,
      );
      final effectiveDownloadedBytes =
          task.totalBytes > 0 &&
              !task.hasUnknownFileSizes &&
              downloadedBytes > task.totalBytes
          ? task.totalBytes
          : downloadedBytes;
      if (task.downloadedBytes == effectiveDownloadedBytes &&
          mapEquals(task.fileDownloadedBytes, fileDownloadedBytes)) {
        continue;
      }
      this[workId] = task.copyWith(
        downloadedBytes: effectiveDownloadedBytes,
        fileDownloadedBytes: fileDownloadedBytes,
      );
      changedWorkIds.add(workId);
    }
    return changedWorkIds;
  }

  void _scheduleStructuralPersistence() {
    if (!_persistTasks) return;
    _persistenceDirty = true;
    _progressCheckpointTimer?.cancel();
    _progressCheckpointTimer = null;
    _deferredPersistenceTimer ??= Timer(_taskStructurePersistenceDebounce, () {
      _deferredPersistenceTimer = null;
      _persistCurrentTasks();
    });
  }

  void _scheduleProgressCheckpoint() {
    if (!_persistTasks) return;
    _persistenceDirty = true;
    if (_deferredPersistenceTimer != null) return;
    _progressCheckpointTimer ??= Timer(_taskProgressCheckpointInterval, () {
      _progressCheckpointTimer = null;
      _persistCurrentTasks();
    });
  }

  Future<void>? _persistCurrentTasks() {
    if (!_persistTasks || !_persistenceReady || !_persistenceDirty) return null;
    _persistenceDirty = false;
    _operationObserver?.call(AsmrDownloadStoreOperation.persistenceSnapshot);
    final tasks = _tasks.values
        .where((task) => task.status != AsmrDownloadTaskStatus.completed)
        .map(_persistenceSnapshot)
        .toList(growable: false);
    final write = _persistenceTail.then((_) async {
      final payload = tasks.isEmpty
          ? null
          : await compute(encodePersistedDownloadTasks, tasks);
      await _writePersistedTasks(payload);
    });
    // Keep background writes and later retries usable after a failed write;
    // explicit flush callers still await the original result.
    _persistenceTail = write.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        AppLogService.warning(
          'asmr_download_persist_failed',
          error: error,
          stackTrace: stackTrace,
        );
      },
    );
    return write;
  }

  Future<void> _writePersistedTasks(String? payload) async {
    final writer = _persistenceWriter;
    if (writer != null) {
      await writer(payload);
    } else {
      final saved = payload == null
          ? await AppPreferences.remove(AppPreferences.asmrDownloadTasksKey)
          : await AppPreferences.setString(
              AppPreferences.asmrDownloadTasksKey,
              payload,
            );
      if (!saved) throw StateError('asmr_download_persist_failed');
    }
  }

  void _cancelPersistenceTimers() {
    _deferredPersistenceTimer?.cancel();
    _deferredPersistenceTimer = null;
    _progressCheckpointTimer?.cancel();
    _progressCheckpointTimer = null;
  }
}
