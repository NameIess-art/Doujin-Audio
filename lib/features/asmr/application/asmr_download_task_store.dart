part of 'asmr_download_manager.dart';

extension AsmrDownloadTaskStore on AsmrDownloadManager {
  void _notifyTaskChanged({
    bool deferPersistence = false,
    bool forcePersistedUriReferenceRevision = false,
    Set<int>? changedWorkIds,
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
    _pendingProgressWorkIds.clear();
    final publishedLiveWorkIds = _publishLiveProgress();
    final previousTaskIds = _taskIdsSnapshot;
    _refreshTaskIdsSnapshot();
    if (!identical(previousTaskIds, _taskIdsSnapshot)) {
      _taskIdsController.add(_taskIdsSnapshot);
    }
    final changedIds = changedWorkIds == null
        ? _allChangedTaskIds()
        : <int>{...changedWorkIds, ...publishedLiveWorkIds};
    _publishChangedTasks(changedIds);
    _markProgressNotified();
    _scheduleTaskPersistence(deferred: deferPersistence);
  }

  Set<int> _allChangedTaskIds() {
    final taskIds = <int>{..._publishedTasks.keys, ..._tasks.keys};
    taskIds.removeWhere(
      (workId) => identical(_publishedTasks[workId], _tasks[workId]),
    );
    return taskIds;
  }

  void _publishChangedTasks(Set<int> workIds) {
    for (final workId in workIds) {
      final previous = _publishedTasks[workId];
      final next = _tasks[workId];
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
  }

  void _addAggregate(AsmrDownloadTaskSnapshot? task) {
    if (!_contributesToAggregate(task)) return;
    _aggregateTotalBytes += task!.totalBytes;
    _aggregateDownloadedBytes += task.downloadedBytes;
  }

  bool _contributesToAggregate(AsmrDownloadTaskSnapshot? task) =>
      task != null &&
      (task.isActive || task.status == AsmrDownloadTaskStatus.completed);

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

  void _notifyProgressChanged(int workId) {
    if (_disposed) return;
    _pendingProgressWorkIds.add(workId);
    final now = DateTime.now();
    final elapsed = _lastProgressNotifyAt == null
        ? AsmrDownloadManager._progressNotifyMinInterval
        : now.difference(_lastProgressNotifyAt!);

    if (elapsed >= AsmrDownloadManager._progressNotifyMinInterval) {
      final changedWorkIds = Set<int>.of(_pendingProgressWorkIds);
      _pendingProgressWorkIds.clear();
      _notifyTaskChanged(
        deferPersistence: true,
        changedWorkIds: changedWorkIds,
      );
      return;
    }

    _deferredProgressNotifyTimer ??= Timer(
      AsmrDownloadManager._progressNotifyMinInterval - elapsed,
      () {
        _deferredProgressNotifyTimer = null;
        final changedWorkIds = Set<int>.of(_pendingProgressWorkIds);
        _pendingProgressWorkIds.clear();
        _notifyTaskChanged(
          deferPersistence: true,
          changedWorkIds: changedWorkIds,
        );
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
    _notifyProgressChanged(workId);
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

  Set<int> _publishLiveProgress() {
    final changedWorkIds = <int>{};
    for (final entry in _liveDownloadedBytes.entries) {
      final task = _tasks[entry.key];
      if (task == null) continue;
      final fileDownloadedBytes = Map<String, int>.unmodifiable(
        _liveFileDownloadedBytes[entry.key] ?? task.fileDownloadedBytes,
      );
      if (task.downloadedBytes == entry.value &&
          mapEquals(task.fileDownloadedBytes, fileDownloadedBytes)) {
        continue;
      }
      _tasks[entry.key] = task.copyWith(
        downloadedBytes: entry.value,
        fileDownloadedBytes: fileDownloadedBytes,
      );
      changedWorkIds.add(entry.key);
    }
    return changedWorkIds;
  }
}
