part of 'audio_provider.dart';

extension AudioProviderLibrary on AudioProvider {
  static const LibraryOrganizer _libraryOrganizer = LibraryOrganizer();

  void _syncLibraryNodeOrder({bool persist = true}) {
    _libraryService.syncLibraryNodeOrder(
      persist: persist,
      onPersist: () => unawaited(_saveLibraryNodeOrder()),
    );
  }

  void reorderLibraryNodes(int oldIndex, int newIndex) {
    _libraryService.reorderLibraryNodes(
      oldIndex,
      newIndex,
      currentTree: buildLibraryTree(),
      onPersist: () => unawaited(_saveLibraryNodeOrder()),
    );
    _notifyListeners();
  }

  void addWatchedFolder(String folderPath, {bool notify = true}) {
    final changed = _libraryService.addWatchedFolder(
      folderPath,
      onPersist: () => unawaited(_saveWatchedFolders()),
    );
    if (changed && notify) _notifyListeners();
  }

  void addWatchedLibrary(String folderPath, {bool notify = true}) {
    final changed = _libraryService.addWatchedLibrary(
      folderPath,
      onPersist: () => unawaited(_saveWatchedLibraries()),
    );
    if (changed && notify) _notifyListeners();
  }

  void removeWatchedFolder(String folderPath, {bool notify = true}) {
    final changed = _libraryService.removeWatchedFolder(
      folderPath,
      onPersist: () => unawaited(_saveWatchedFolders()),
    );
    if (changed && notify) _notifyListeners();
  }

  void removeWatchedLibrary(String folderPath, {bool notify = true}) {
    final changed = _libraryService.removeWatchedLibrary(
      folderPath,
      onPersist: () => unawaited(_saveWatchedLibraries()),
    );
    if (changed && notify) _notifyListeners();
  }

  Future<void> removeLibrary(String libraryPath) async {
    await _libraryService.removeLibrary(
      libraryPath,
      removeFolder: removeFolderFromLibrary,
      onSaveWatchedLibraries: () => unawaited(_saveWatchedLibraries()),
      onSaveLibraryExclusions: () => unawaited(_saveLibraryExclusions()),
    );
    _notifyListeners();
  }

  List<String> childFoldersForLibrary(String libraryPath) =>
      _libraryService.childFoldersForLibrary(libraryPath);

  List<String> excludedFoldersForLibrary(String libraryPath) =>
      _libraryService.excludedFoldersForLibrary(libraryPath);

  List<String> excludedTracksForLibrary(String libraryPath) =>
      _libraryService.excludedTracksForLibrary(libraryPath);

  bool isLibraryPathExcluded(String libraryPath, String entityPath) =>
      _libraryService.isLibraryPathExcluded(libraryPath, entityPath);

  bool isLibraryFolderExplicitlyExcluded(
    String libraryPath,
    String folderPath,
  ) {
    return _libraryService.isLibraryFolderExplicitlyExcluded(
      libraryPath,
      folderPath,
    );
  }

  bool isLibraryTrackExplicitlyExcluded(String libraryPath, String trackPath) {
    return _libraryService.isLibraryTrackExplicitlyExcluded(
      libraryPath,
      trackPath,
    );
  }

  void setLibraryFolderExcluded(
    String libraryPath,
    String folderPath,
    bool excluded,
  ) {
    final normalizedFolderPath = path.normalize(folderPath);
    final changed = _libraryService.setLibraryFolderExcluded(
      libraryPath,
      folderPath,
      excluded,
      onPersist: () => unawaited(_saveLibraryExclusions()),
    );
    if (!changed) return;
    if (excluded) {
      _removeTracksWhere(
        (track) => _isPathWithinOrEqual(track.path, normalizedFolderPath),
      );
    }
    _notifyListeners();
  }

  void setLibraryTrackExcluded(
    String libraryPath,
    String trackPath,
    bool excluded,
  ) {
    final normalizedTrackPath = path.normalize(trackPath);
    final changed = _libraryService.setLibraryTrackExcluded(
      libraryPath,
      trackPath,
      excluded,
      onPersist: () => unawaited(_saveLibraryExclusions()),
    );
    if (!changed) return;
    if (excluded) {
      _removeTracksWhere(
        (track) => path.equals(track.path, normalizedTrackPath),
      );
    } else {
      _restoreExcludedTrack(normalizedTrackPath);
    }
    _notifyListeners();
  }

  void _restoreExcludedTrack(String trackPath) {
    if (_libraryByPath.containsKey(trackPath)) return;
    final isContentUri = trackPath.startsWith('content://');
    FileStat? fileStat;
    if (!isContentUri) {
      try {
        final file = File(trackPath);
        if (!file.existsSync()) return;
        fileStat = file.statSync();
      } catch (_) {
        return;
      }
    }

    final parentFolder = path.dirname(trackPath);
    final folderName = path.basename(parentFolder);
    addTracks([
      MusicTrack(
        path: trackPath,
        displayName: path.basenameWithoutExtension(trackPath),
        groupKey: parentFolder,
        groupTitle: folderName.isEmpty ? parentFolder : folderName,
        groupSubtitle: parentFolder,
        isSingle: false,
        scannedAt: DateTime.now(),
        fileSizeBytes: fileStat?.size,
        modifiedAt: fileStat?.modified,
      ),
    ], notify: false);
  }

  void _removeTracksWhere(bool Function(MusicTrack track) test) {
    final removedPaths = _library
        .where(test)
        .map((track) => track.path)
        .toList(growable: false);
    if (removedPaths.isEmpty) return;
    final removedSet = removedPaths.toSet();
    final sessionsToRemove = _sessions.values
        .where((session) => removedSet.contains(session.currentTrackPath))
        .map((session) => session.id)
        .toList(growable: false);
    _library.removeWhere((track) => removedSet.contains(track.path));
    for (final trackPath in removedPaths) {
      _libraryByPath.remove(trackPath);
    }
    _rebuildLibraryIndexes();
    _syncLibraryNodeOrder(persist: false);
    if (sessionsToRemove.isNotEmpty) {
      unawaited(
        _removeSessions(sessionsToRemove, persist: false, notify: false),
      );
    }
    unawaited(_audioDatabaseRepository.deleteTracks(removedPaths));
    unawaited(_saveLibraryNodeOrder());
  }

  void setScanning(bool scanning, {bool background = false}) {
    if (_isScanning == scanning && _isBackgroundScanning == background) return;
    _isScanning = scanning;
    _isBackgroundScanning = background;
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
    _syncGroupOrderFromLibrary();
    _syncLibraryNodeOrder(persist: false);
    if (notify) {
      _notifyListeners();
    }
    if (tracksToPersist.isNotEmpty) {
      await _audioDatabaseRepository.upsertTracks(tracksToPersist);
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
        unawaited(_audioDatabaseRepository.upsertTracks(toAdd));
        if (didChangeGroupOrder) {
          _saveGroupOrder();
        }
        _saveLibraryNodeOrder();
      }
    }
  }

  void addOrReplaceTracks(
    List<MusicTrack> tracks, {
    bool notify = true,
    bool persist = true,
  }) {
    if (tracks.isEmpty) return;

    var changed = false;
    var didChangeGroupOrder = false;
    var didReplaceGroup = false;
    final tracksToPersist = <MusicTrack>[];

    for (final track in tracks) {
      final existing = _libraryByPath[track.path];
      if (existing == track) continue;
      if (existing != null && existing.groupKey != track.groupKey) {
        didReplaceGroup = true;
      }
      if (existing == null) {
        _library.add(track);
      } else {
        final index = _library.indexWhere((item) => item.path == track.path);
        if (index >= 0) {
          _library[index] = track;
        } else {
          _library.add(track);
        }
      }
      _libraryByPath[track.path] = track;
      tracksToPersist.add(track);
      changed = true;
      if (_groupOrderSet.add(track.groupKey)) {
        _groupOrder.add(track.groupKey);
        didChangeGroupOrder = true;
      }
    }

    if (!changed) return;
    if (_libraryBatchDepth > 0) {
      _libraryBatchChanged = true;
      if (persist) {
        _libraryBatchPersistTracks.addAll(tracksToPersist);
      }
      if (didChangeGroupOrder || didReplaceGroup) {
        _libraryBatchChangedGroupOrder = true;
      }
      return;
    }

    _clearResolvedCoverPaths();
    _rebuildLibraryIndexes();
    _syncGroupOrderFromLibrary();
    _syncLibraryNodeOrder(persist: false);
    if (notify) {
      _notifyListeners();
    }
    if (persist) {
      unawaited(_audioDatabaseRepository.upsertTracks(tracksToPersist));
      if (didChangeGroupOrder || didReplaceGroup) {
        _saveGroupOrder();
      }
      _saveLibraryNodeOrder();
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
    unawaited(_audioDatabaseRepository.deleteTracks([trackPath]));
    unawaited(_saveGroupOrder());
    unawaited(_saveLibraryNodeOrder());
  }

  Future<void> removeFolderFromLibrary(String folderPath) async {
    _clearResolvedCoverPaths();
    final normalizedFolderPath = PathMatcher.normalize(folderPath);
    final trackPaths = _library
        .where(
          (track) =>
              PathMatcher.isWithinOrEqual(track.path, normalizedFolderPath),
        )
        .map((track) => track.path)
        .toSet();
    if (trackPaths.isEmpty &&
        !_watchedFolders.any(
          (watchedFolder) =>
              PathMatcher.equalsNormalized(watchedFolder, normalizedFolderPath),
        )) {
      return;
    }

    final sessionsToRemove = _sessions.values
        .where((s) => trackPaths.contains(s.currentTrackPath))
        .map((s) => s.id)
        .toList();
    if (sessionsToRemove.isNotEmpty) {
      await _removeSessions(sessionsToRemove, persist: false, notify: false);
    }

    _library.removeWhere(
      (track) => PathMatcher.isWithinOrEqual(track.path, normalizedFolderPath),
    );
    for (final trackPath in trackPaths) {
      _libraryByPath.remove(trackPath);
    }
    _groupOrder.removeWhere(
      (key) => PathMatcher.isWithinOrEqual(key, normalizedFolderPath),
    );
    _groupOrderSet
      ..clear()
      ..addAll(_groupOrder);

    final watchedFoldersBeforeRemoval = _watchedFolders.length;
    _watchedFolders.removeWhere(
      (watchedFolder) =>
          PathMatcher.equalsNormalized(watchedFolder, normalizedFolderPath),
    );
    if (_watchedFolders.length != watchedFoldersBeforeRemoval) {
      unawaited(_saveWatchedFolders());
    }

    _rebuildLibraryIndexes();
    _syncLibraryNodeOrder(persist: false);
    _notifyListeners();
    unawaited(_audioDatabaseRepository.deleteTracks(trackPaths.toList()));
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

  MusicTrack? trackByPath(String trackPath) =>
      _libraryService.trackByPath(trackPath);

  PlaybackSession? sessionById(String sessionId) =>
      _playbackService.sessionById(sessionId);

  String? sessionTrackPath(String sessionId) =>
      _playbackService.sessionById(sessionId)?.currentTrackPath;

  bool isTrackActive(String trackPath) =>
      _playbackService.isTrackActive(trackPath);

  List<MusicTrack> tracksInSameGroup(String trackPath) {
    final track = trackByPath(trackPath);
    if (track == null) return [];
    return _tracksByGroup[track.groupKey] ?? const <MusicTrack>[];
  }

  String getRootFolderName(String trackPath) {
    for (final folder in _watchedFolders) {
      if (PathMatcher.isWithinOrEqual(trackPath, folder)) {
        final name = path.basename(folder);
        return name.isEmpty ? folder : name;
      }
    }
    for (final libraryPath in _watchedLibraries) {
      if (PathMatcher.isWithinOrEqual(trackPath, libraryPath)) {
        final name = path.basename(libraryPath);
        return name.isEmpty ? libraryPath : name;
      }
    }
    return '';
  }
}
