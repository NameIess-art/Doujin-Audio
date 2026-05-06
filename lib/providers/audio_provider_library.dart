part of 'audio_provider.dart';

extension AudioProviderLibrary on AudioProvider {
  static const LibraryOrganizer _libraryOrganizer = LibraryOrganizer();

  List<String> _currentLibraryTopLevelNodeIds() {
    return _libraryOrganizer.topLevelNodeIds(_library, _watchedFolders);
  }

  void _syncLibraryNodeOrder({bool persist = true}) {
    final validNodeIds = _currentLibraryTopLevelNodeIds();
    final validNodeIdSet = validNodeIds.toSet();
    var changed = false;
    final previousLength = _libraryNodeOrder.length;
    _libraryNodeOrder.removeWhere((id) => !validNodeIdSet.contains(id));
    if (_libraryNodeOrder.length != previousLength) {
      changed = true;
    }

    for (final nodeId in validNodeIds) {
      if (_libraryNodeOrder.contains(nodeId)) continue;
      _libraryNodeOrder.add(nodeId);
      changed = true;
    }

    if (changed && persist) {
      unawaited(_saveLibraryNodeOrder());
    }
  }

  void reorderLibraryNodes(int oldIndex, int newIndex) {
    final currentIds = buildLibraryTree().map((node) => node.path).toList();
    if (oldIndex < 0 || oldIndex >= currentIds.length) return;
    if (newIndex < 0 || newIndex > currentIds.length) return;
    if (newIndex > oldIndex) newIndex -= 1;
    final movedId = currentIds.removeAt(oldIndex);
    currentIds.insert(newIndex, movedId);
    _libraryNodeOrder
      ..clear()
      ..addAll(currentIds);
    _markLibraryStructureDirty();
    _notifyListeners();
    unawaited(_saveLibraryNodeOrder());
  }

  void addWatchedFolder(String folderPath, {bool notify = true}) {
    if (!_watchedFolders.contains(folderPath)) {
      _watchedFolders.add(folderPath);
      _syncLibraryNodeOrder();
      _markLibraryStructureDirty();
      if (notify) _notifyListeners();
      unawaited(_saveWatchedFolders());
    }
  }

  void addWatchedLibrary(String folderPath, {bool notify = true}) {
    if (!_watchedLibraries.contains(folderPath)) {
      _watchedLibraries.add(folderPath);
      if (notify) _notifyListeners();
      unawaited(_saveWatchedLibraries());
    }
  }

  void removeWatchedFolder(String folderPath, {bool notify = true}) {
    if (_watchedFolders.remove(folderPath)) {
      _syncLibraryNodeOrder();
      _markLibraryStructureDirty();
      if (notify) _notifyListeners();
      unawaited(_saveWatchedFolders());
    }
  }

  void removeWatchedLibrary(String folderPath, {bool notify = true}) {
    if (_watchedLibraries.remove(folderPath)) {
      if (notify) _notifyListeners();
      unawaited(_saveWatchedLibraries());
    }
  }

  void setScanning(bool scanning) {
    if (_isScanning == scanning) return;
    _isScanning = scanning;
    if (scanning) {
      _scanProgressNotifyTimer?.cancel();
      _scanProgressNotifyTimer = null;
      _scanCurrentFolder = '';
      _scanFoundCount = 0;
      _scanDuplicateCount = 0;
      _scanFailureCount = 0;
    } else {
      _scanProgressNotifyTimer?.cancel();
      _scanProgressNotifyTimer = null;
    }
    _notifyListeners();
  }

  void beginLibraryBatch() {
    _libraryBatchDepth++;
  }

  Future<void> endLibraryBatch({bool notify = true}) async {
    if (_libraryBatchDepth <= 0) return;
    _libraryBatchDepth--;
    if (_libraryBatchDepth > 0 || !_libraryBatchChanged) return;

    final tracksToPersist = List<MusicTrack>.from(_libraryBatchPersistTracks);
    final didChangeGroupOrder = _libraryBatchChangedGroupOrder;
    _libraryBatchChanged = false;
    _libraryBatchChangedGroupOrder = false;
    _libraryBatchPersistTracks.clear();

    _clearResolvedCoverPaths();
    _rebuildLibraryIndexes();
    _syncLibraryNodeOrder(persist: false);
    if (notify) {
      _notifyListeners();
    }
    if (tracksToPersist.isNotEmpty) {
      await AppDatabase.instance.insertTracks(tracksToPersist);
    }
    if (didChangeGroupOrder) {
      await _saveGroupOrder();
    }
    await _saveLibraryNodeOrder();
  }

  void addTracks(
    List<MusicTrack> newTracks, {
    bool notify = true,
    bool persist = true,
  }) {
    if (newTracks.isEmpty) return;

    final toAdd = <MusicTrack>[];
    var didChangeGroupOrder = false;
    for (final track in newTracks) {
      if (_libraryByPath.containsKey(track.path)) {
        continue;
      }
      _library.add(track);
      _libraryByPath[track.path] = track;
      toAdd.add(track);
      if (_groupOrderSet.add(track.groupKey)) {
        _groupOrder.add(track.groupKey);
        didChangeGroupOrder = true;
      }
    }

    if (toAdd.isNotEmpty) {
      if (_libraryBatchDepth > 0) {
        _libraryBatchChanged = true;
        if (persist) {
          _libraryBatchPersistTracks.addAll(toAdd);
        }
        if (didChangeGroupOrder) {
          _libraryBatchChangedGroupOrder = true;
        }
        return;
      }
      _clearResolvedCoverPaths();
      _rebuildLibraryIndexes();
      _syncLibraryNodeOrder(persist: false);
      if (notify) {
        _notifyListeners();
      }
      if (persist) {
        unawaited(AppDatabase.instance.insertTracks(toAdd));
        if (didChangeGroupOrder) {
          _saveGroupOrder();
        }
        _saveLibraryNodeOrder();
      }
    }
  }

  Future<void> removeTrackFromLibrary(String trackPath) async {
    final removedTrack = _libraryByPath.remove(trackPath);
    if (removedTrack == null) return;

    _library.removeWhere((track) => track.path == trackPath);
    _clearResolvedCoverPaths();

    final sessionsToRemove = _sessions.values
        .where((s) => s.currentTrackPath == trackPath)
        .map((s) => s.id)
        .toList();
    if (sessionsToRemove.isNotEmpty) {
      await _removeSessions(sessionsToRemove, persist: false, notify: false);
    }

    if (!_library.any((track) => track.groupKey == removedTrack.groupKey)) {
      _groupOrder.remove(removedTrack.groupKey);
      _groupOrderSet.remove(removedTrack.groupKey);
    }

    _rebuildLibraryIndexes();
    _syncLibraryNodeOrder(persist: false);
    _notifyListeners();
    unawaited(AppDatabase.instance.deleteTracks([trackPath]));
    unawaited(_saveGroupOrder());
    unawaited(_saveLibraryNodeOrder());
  }

  Future<void> removeFolderFromLibrary(String folderPath) async {
    _clearResolvedCoverPaths();
    final trackPaths = _library
        .where((track) => track.path.startsWith(folderPath))
        .map((track) => track.path)
        .toSet();
    if (trackPaths.isEmpty && !_watchedFolders.contains(folderPath)) {
      return;
    }

    final sessionsToRemove = _sessions.values
        .where((s) => trackPaths.contains(s.currentTrackPath))
        .map((s) => s.id)
        .toList();
    if (sessionsToRemove.isNotEmpty) {
      await _removeSessions(sessionsToRemove, persist: false, notify: false);
    }

    _library.removeWhere((track) => track.path.startsWith(folderPath));
    for (final trackPath in trackPaths) {
      _libraryByPath.remove(trackPath);
    }
    _groupOrder.removeWhere((key) => key.startsWith(folderPath));
    _groupOrderSet
      ..clear()
      ..addAll(_groupOrder);

    if (_watchedFolders.contains(folderPath)) {
      _watchedFolders.remove(folderPath);
      unawaited(_saveWatchedFolders());
    }

    _rebuildLibraryIndexes();
    _syncLibraryNodeOrder(persist: false);
    _notifyListeners();
    unawaited(AppDatabase.instance.deleteTracks(trackPaths.toList()));
    unawaited(_saveGroupOrder());
    unawaited(_saveLibraryNodeOrder());
  }

  int getTrackComparator(MusicTrack a, MusicTrack b) {
    return _libraryOrganizer.compareTracks(a, b);
  }

  List<LibraryNode> buildLibraryTree() => libraryTree;

  LibraryTreeSnapshot _buildLibraryTreeSnapshot() {
    return _libraryOrganizer.buildTree(
      tracks: _library,
      watchedFolders: _watchedFolders,
      nodeOrder: _libraryNodeOrder,
    );
  }

  MusicTrack? trackByPath(String trackPath) => _libraryByPath[trackPath];

  PlaybackSession? sessionById(String sessionId) => _sessions[sessionId];

  String? sessionTrackPath(String sessionId) =>
      _sessions[sessionId]?.currentTrackPath;

  bool isTrackActive(String trackPath) =>
      _sessions.values.any((session) => session.currentTrackPath == trackPath);

  List<MusicTrack> tracksInSameGroup(String trackPath) {
    final track = trackByPath(trackPath);
    if (track == null) return [];
    return _tracksByGroup[track.groupKey] ?? const <MusicTrack>[];
  }
}
