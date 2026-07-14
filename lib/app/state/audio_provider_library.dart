part of 'audio_provider.dart';

extension AudioProviderLibrary on AudioProvider {
  static const LibraryOrganizer _libraryOrganizer = LibraryOrganizer();

  void _rememberRetargetedPath(String oldPath, String newPath) {
    final normalizedOldPath = PathMatcher.normalize(oldPath);
    final normalizedNewPath = PathMatcher.normalize(newPath);
    if (PathMatcher.equalsNormalized(normalizedOldPath, normalizedNewPath)) {
      return;
    }
    _retargetedPathAliases[normalizedOldPath] = normalizedNewPath;
  }

  String _resolveRetargetedPath(String value) {
    if (value.isEmpty || _retargetedPathAliases.isEmpty) {
      return PathMatcher.normalize(value);
    }

    var current = PathMatcher.normalize(value);
    final seen = <String>{current};
    while (true) {
      String? bestMatch;
      String? nextValue;
      for (final entry in _retargetedPathAliases.entries) {
        if (!PathMatcher.isWithinOrEqual(current, entry.key)) continue;
        if (bestMatch == null || entry.key.length > bestMatch.length) {
          bestMatch = entry.key;
          nextValue = entry.value;
        }
      }
      if (bestMatch == null || nextValue == null) {
        return current;
      }
      final resolved = PathMatcher.normalize(
        PathMatcher.replaceWithinOrEqual(current, bestMatch, nextValue),
      );
      if (PathMatcher.equalsNormalized(resolved, current) ||
          !seen.add(resolved)) {
        return resolved;
      }
      current = resolved;
    }
  }

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
      currentTree: libraryCards,
      onPersist: () => unawaited(_saveLibraryNodeOrder()),
    );
    _librarySnapshotCacheService.applyCurrentTopLevelOrder();
    _notifyLibraryChanged();
  }

  void addWatchedFolder(String folderPath, {bool notify = true}) {
    final changed = _libraryService.addWatchedFolder(
      folderPath,
      onPersist: () => unawaited(_saveWatchedFolders()),
    );
    if (changed && notify) _notifyLibraryChanged();
  }

  void addWatchedLibrary(String folderPath, {bool notify = true}) {
    final changed = _libraryService.addWatchedLibrary(
      folderPath,
      onPersist: () => unawaited(_saveWatchedLibraries()),
    );
    if (changed && notify) _notifyLibraryChanged();
  }

  void removeWatchedFolder(String folderPath, {bool notify = true}) {
    final changed = _libraryService.removeWatchedFolder(
      folderPath,
      onPersist: () => unawaited(_saveWatchedFolders()),
    );
    if (changed && notify) _notifyLibraryChanged();
  }

  void removeWatchedLibrary(String folderPath, {bool notify = true}) {
    final changed = _libraryService.removeWatchedLibrary(
      folderPath,
      onPersist: () => unawaited(_saveWatchedLibraries()),
    );
    if (changed && notify) _notifyLibraryChanged();
  }

  Future<void> removeLibrary(String libraryPath) async {
    setScanning(false);
    await _libraryService.removeLibrary(
      libraryPath,
      removeFolder: removeFolderFromLibrary,
      onSaveWatchedLibraries: () => unawaited(_saveWatchedLibraries()),
      onSaveLibraryExclusions: () => unawaited(_saveLibraryExclusions()),
    );
    await removeFolderFromLibrary(libraryPath);
    if (!_skipDisposePersistence) {
      unawaited(
        _audioDatabaseRepository.deleteLibraryEntriesForLibrary(libraryPath),
      );
    }
    _notifyLibraryAndPlaybackChanged();
  }

  List<String> childFoldersForLibrary(String libraryPath) =>
      _libraryService.childFoldersForLibrary(libraryPath);

  String? libraryRootForPath(String entityPath) {
    final resolvedPath = _resolveRetargetedPath(entityPath);
    for (final libraryPath in _watchedLibraries) {
      if (PathMatcher.isWithinOrEqual(resolvedPath, libraryPath)) {
        return libraryPath;
      }
    }
    for (final folderPath in _watchedFolders) {
      if (PathMatcher.isWithinOrEqual(resolvedPath, folderPath)) {
        return folderPath;
      }
    }
    return null;
  }

  List<String> excludedFoldersForLibrary(String libraryPath) =>
      _libraryService.excludedFoldersForLibrary(libraryPath);

  List<String> excludedTracksForLibrary(String libraryPath) =>
      _libraryService.excludedTracksForLibrary(libraryPath);

  List<LibraryEntry> libraryEntriesForLibrary(String libraryPath) =>
      _libraryService.libraryEntriesForLibrary(libraryPath);

  LibraryEntrySnapshot libraryEntrySnapshotForLibrary(String libraryPath) =>
      _libraryService.libraryEntrySnapshotForLibrary(libraryPath);

  LibraryExclusionMatcher libraryExclusionMatcherForLibrary(
    String libraryPath,
  ) => _libraryService.libraryExclusionMatcherForLibrary(libraryPath);

  bool isLibraryPathExcluded(String libraryPath, String entityPath) =>
      _libraryService.isLibraryPathExcluded(libraryPath, entityPath);

  bool isLibraryPathInheritedExcluded(String libraryPath, String entityPath) =>
      _libraryService.isLibraryPathInheritedExcluded(libraryPath, entityPath);

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

  bool hasLibraryExclusions(String libraryPath) {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    return (_excludedLibraryFolders[normalizedLibraryPath]?.isNotEmpty ??
            false) ||
        (_excludedLibraryTracks[normalizedLibraryPath]?.isNotEmpty ?? false);
  }

  void clearLibraryExclusions(String libraryPath) {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    final removedFolders = _excludedLibraryFolders.remove(
      normalizedLibraryPath,
    );
    final removedTracks = _excludedLibraryTracks.remove(normalizedLibraryPath);
    if ((removedFolders == null || removedFolders.isEmpty) &&
        (removedTracks == null || removedTracks.isEmpty)) {
      return;
    }

    final restoredEntryPaths = _libraryService.setLibraryEntriesSubtreeState(
      normalizedLibraryPath,
      normalizedLibraryPath,
      LibraryEntryState.active,
    );
    final restoredTracks = _libraryService
        .libraryEntriesForLibrary(normalizedLibraryPath)
        .where(
          (entry) => entry.isTrack && !_libraryByPath.containsKey(entry.path),
        )
        .map((entry) => entry.toTrack())
        .toList(growable: false);
    if (restoredTracks.isNotEmpty) {
      addOrReplaceTracks(restoredTracks, notify: false);
    }
    if (restoredEntryPaths.isNotEmpty && !_skipDisposePersistence) {
      unawaited(
        _audioDatabaseRepository.setLibraryEntriesState(
          normalizedLibraryPath,
          restoredEntryPaths,
          LibraryEntryState.active,
        ),
      );
    }
    unawaited(_saveLibraryExclusions());
    _notifyLibraryChanged();
  }

  void setLibraryFolderExcluded(
    String libraryPath,
    String folderPath,
    bool excluded,
  ) {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    final normalizedFolderPath = _canonicalLibraryFolderPath(
      normalizedLibraryPath,
      folderPath,
    );
    final changed = _libraryService.setLibraryFolderExcluded(
      normalizedLibraryPath,
      normalizedFolderPath,
      excluded,
      onPersist: () => unawaited(_saveLibraryExclusions()),
    );
    if (!changed) return;
    final affectedEntryPaths = _libraryService
        .libraryEntriesForLibrary(normalizedLibraryPath)
        .where(
          (entry) =>
              PathMatcher.isWithinOrEqual(entry.path, normalizedFolderPath),
        )
        .map((entry) => entry.path)
        .toList(growable: false);
    if (affectedEntryPaths.isNotEmpty && !_skipDisposePersistence) {
      unawaited(
        _audioDatabaseRepository.setLibraryEntriesState(
          normalizedLibraryPath,
          affectedEntryPaths,
          excluded ? LibraryEntryState.excluded : LibraryEntryState.active,
        ),
      );
    }
    if (excluded) {
      _removeTracksWhere(
        (track) =>
            PathMatcher.isWithinOrEqual(track.path, normalizedFolderPath) ||
            PathMatcher.isWithinOrEqual(track.groupKey, normalizedFolderPath),
      );
      _notifyLibraryAndPlaybackChanged();
    } else {
      unawaited(
        _restoreExcludedFolder(normalizedLibraryPath, normalizedFolderPath),
      );
      _notifyLibraryChanged();
    }
  }

  void setLibraryTrackExcluded(
    String libraryPath,
    String trackPath,
    bool excluded,
  ) {
    final normalizedTrackPath = PathMatcher.normalize(trackPath);
    final changed = _libraryService.setLibraryTrackExcluded(
      libraryPath,
      trackPath,
      excluded,
      onPersist: () => unawaited(_saveLibraryExclusions()),
    );
    if (!changed) return;
    if (_libraryService
        .libraryEntriesForLibrary(libraryPath)
        .any((entry) => PathMatcher.equalsNormalized(entry.path, trackPath))) {
      if (!_skipDisposePersistence) {
        unawaited(
          _audioDatabaseRepository.setLibraryEntriesState(
            libraryPath,
            [normalizedTrackPath],
            excluded ? LibraryEntryState.excluded : LibraryEntryState.active,
          ),
        );
      }
    }
    if (excluded) {
      _removeTracksWhere(
        (track) =>
            PathMatcher.equalsNormalized(track.path, normalizedTrackPath),
      );
      _notifyLibraryAndPlaybackChanged();
    } else {
      unawaited(_restoreExcludedTrack(libraryPath, normalizedTrackPath));
      _notifyLibraryChanged();
    }
  }

  Future<void> _restoreExcludedTrack(
    String libraryPath,
    String trackPath,
  ) async {
    if (_libraryByPath.containsKey(trackPath)) return;
    final persistedEntry = _libraryService
        .libraryEntriesForLibrary(libraryPath)
        .where(
          (entry) =>
              entry.isTrack &&
              PathMatcher.equalsNormalized(entry.path, trackPath),
        )
        .firstOrNull;
    if (persistedEntry != null) {
      addTracks([persistedEntry.toTrack()], notify: false);
      return;
    }

    final isContentUri = trackPath.startsWith('content://');
    FileStat? fileStat;
    if (!isContentUri) {
      try {
        final file = File(trackPath);
        if (!await file.exists()) return;
        fileStat = await file.stat();
      } catch (_) {
        return;
      }
    }

    final parentFolder = path.dirname(trackPath);
    final folderName = path.basename(parentFolder);
    addTracks([
      MusicTrack(
        path: trackPath,
        displayName: PathDisplay.fileName(trackPath, withoutExtension: true),
        groupKey: parentFolder,
        groupTitle: folderName.isEmpty
            ? PathDisplay.folderName(parentFolder)
            : PathDisplay.normalizeDisplaySegment(folderName),
        groupSubtitle: parentFolder,
        isSingle: false,
        isVideo: isVideoMediaFile(trackPath),
        scannedAt: DateTime.now(),
        fileSizeBytes: fileStat?.size,
        modifiedAt: fileStat?.modified,
      ),
    ], notify: false);
  }

  Future<void> _restoreExcludedFolder(
    String libraryPath,
    String folderPath,
  ) async {
    final persistedTracks = _libraryService
        .libraryEntriesForLibrary(libraryPath)
        .where(
          (entry) =>
              entry.isTrack &&
              entry.isActive &&
              PathMatcher.isWithinOrEqual(entry.path, folderPath) &&
              !_libraryService.isLibraryPathExcluded(libraryPath, entry.path),
        )
        .map((entry) => entry.toTrack())
        .where((track) => !_libraryByPath.containsKey(track.path))
        .toList(growable: false);
    if (persistedTracks.isNotEmpty) {
      addOrReplaceTracks(persistedTracks, notify: false);
      _notifyLibraryChanged();
      return;
    }

    final restoredTracks = PathMatcher.isContentUri(folderPath)
        ? await _scanRestorableTracksViaNative(folderPath)
        : await _scanRestorableTracksFromDisk(folderPath);
    if (restoredTracks.isEmpty) {
      _notifyLibraryChanged();
      return;
    }

    final candidates = restoredTracks
        .where(
          (track) =>
              !_libraryService.isLibraryPathExcluded(libraryPath, track.path),
        )
        .toList(growable: false);
    if (candidates.isEmpty) {
      _notifyLibraryChanged();
      return;
    }

    addOrReplaceTracks(candidates, notify: false);
    _notifyLibraryChanged();
  }

  Future<List<MusicTrack>> _scanRestorableTracksFromDisk(
    String folderPath,
  ) async {
    final directory = Directory(folderPath);
    if (!await directory.exists()) return const <MusicTrack>[];

    final pendingDirs = <Directory>[directory];
    final restoredTracks = <MusicTrack>[];

    while (pendingDirs.isNotEmpty) {
      final currentDir = pendingDirs.removeLast();
      late final Stream<FileSystemEntity> stream;
      try {
        stream = currentDir.list(followLinks: false);
      } catch (_) {
        continue;
      }

      await for (final entity in stream.handleError((_) {})) {
        if (entity is Directory) {
          pendingDirs.add(entity);
          continue;
        }
        if (entity is! File) continue;

        final absolutePath = path.normalize(entity.path);
        if (!isSupportedMediaFile(absolutePath) ||
            _libraryByPath.containsKey(absolutePath)) {
          continue;
        }

        FileStat? fileStat;
        try {
          fileStat = await entity.stat();
        } catch (_) {
          // File timestamps are optional library metadata.
        }

        final parentFolder = path.dirname(absolutePath);
        final folderName = path.basename(parentFolder);
        restoredTracks.add(
          MusicTrack(
            path: absolutePath,
            displayName: path.basenameWithoutExtension(absolutePath),
            groupKey: parentFolder,
            groupTitle: folderName.isEmpty ? parentFolder : folderName,
            groupSubtitle: parentFolder,
            isSingle: false,
            isVideo: isVideoMediaFile(absolutePath),
            scannedAt: DateTime.now(),
            fileSizeBytes: fileStat?.size,
            modifiedAt: fileStat?.modified,
          ),
        );
      }
    }

    return restoredTracks;
  }

  Future<List<MusicTrack>> _scanRestorableTracksViaNative(
    String folderPath,
  ) async {
    try {
      final data = await AudioProvider._fileCacheGateway.scanFolderPayload(
        folderPath,
      );
      if (data == null) return const <MusicTrack>[];

      final restoredTracks = <MusicTrack>[];
      for (final item in data) {
        if (item is! Map) continue;
        final map = item.cast<Object?, Object?>();
        final rawPath = map['path']?.toString().trim();
        if (rawPath == null ||
            rawPath.isEmpty ||
            !isSupportedMediaFile(rawPath) ||
            _libraryByPath.containsKey(rawPath)) {
          continue;
        }

        final normalizedPath = rawPath.startsWith('content://')
            ? rawPath
            : path.normalize(rawPath);
        final nativeGroupKey = map['groupKey']?.toString().trim();
        final nativeGroupTitle = map['groupTitle']?.toString().trim();
        final nativeGroupSubtitle = map['groupSubtitle']?.toString().trim();
        final groupKey = (nativeGroupKey?.isNotEmpty ?? false)
            ? nativeGroupKey!
            : path.dirname(normalizedPath);
        final groupTitle = (nativeGroupTitle?.isNotEmpty ?? false)
            ? nativeGroupTitle!
            : PathDisplay.folderName(groupKey);
        final groupSubtitle = (nativeGroupSubtitle?.isNotEmpty ?? false)
            ? nativeGroupSubtitle!
            : groupKey;
        final displayName = map['title']?.toString().trim();
        final scannedAtMs = map['scannedAtMs'] as num?;
        final modifiedAtMs = map['modifiedAtMs'] as num?;

        restoredTracks.add(
          MusicTrack(
            path: normalizedPath,
            displayName: displayName?.isEmpty ?? true
                ? PathDisplay.fileName(normalizedPath, withoutExtension: true)
                : displayName!,
            groupKey: groupKey,
            groupTitle: groupTitle,
            groupSubtitle: groupSubtitle,
            isSingle: false,
            isVideo:
                map['isVideo'] as bool? ?? isVideoMediaFile(normalizedPath),
            scannedAt: scannedAtMs == null
                ? DateTime.now()
                : DateTime.fromMillisecondsSinceEpoch(scannedAtMs.toInt()),
            fileSizeBytes: (map['fileSizeBytes'] as num?)?.toInt(),
            modifiedAt: modifiedAtMs == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(modifiedAtMs.toInt()),
          ),
        );
      }
      return restoredTracks;
    } catch (_) {
      return const <MusicTrack>[];
    }
  }

  /// Removes tracks from the in-memory library that are currently marked as
  /// excluded in [_excludedLibraryFolders] or [_excludedLibraryTracks].
  /// Called once during startup after both the library and exclusion maps have
  /// been loaded, so that excluded items are not shown on the first render.
  void _applyExclusionsToLibrary() {
    final allExcludedTracks = <String>{};
    for (final paths in _excludedLibraryTracks.values) {
      allExcludedTracks.addAll(paths);
    }
    final allExcludedFolders = <String>{};
    for (final paths in _excludedLibraryFolders.values) {
      allExcludedFolders.addAll(paths);
    }
    if (allExcludedTracks.isEmpty && allExcludedFolders.isEmpty) return;
    final excludedTrackIndex = PathMembershipIndex(allExcludedTracks);
    final excludedFolderIndex = PathMembershipIndex(allExcludedFolders);
    _removeTracksWhere((track) {
      return excludedTrackIndex.containsEquivalent(track.path) ||
          excludedFolderIndex.containsAncestorOrEqual(track.path) ||
          excludedFolderIndex.containsAncestorOrEqual(track.groupKey);
    });
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
      _libraryIndexByPath.remove(trackPath);
    }
    // Skip the expensive rebuild when inside a batch 鈥?endLibraryBatch will
    // do a single consolidated rebuild when the batch closes.
    if (_libraryBatchDepth <= 0) {
      _rebuildLibraryIndexes();
      _syncLibraryNodeOrder(persist: false);
    } else {
      _libraryBatchChanged = true;
    }
    if (sessionsToRemove.isNotEmpty) {
      unawaited(
        _removeSessions(sessionsToRemove, persist: false, notify: false),
      );
    }
    if (!_skipDisposePersistence) {
      unawaited(_audioDatabaseRepository.deleteTracks(removedPaths));
    }
    if (_libraryBatchDepth <= 0) {
      unawaited(_saveLibraryNodeOrder());
    }
  }

  /// Removes tracks that belong to [folderPath] but whose paths are not in
  /// [scannedPaths].  Called after a successful rescan to prune deleted files.
  void removeTracksDeletedFromFolder(
    String folderPath,
    Set<String> scannedPaths,
  ) {
    final normalizedFolder = PathMatcher.normalize(folderPath);
    final scannedPathIndex = PathMembershipIndex(scannedPaths);
    _removeTracksWhere((track) {
      if (!PathMatcher.isWithinOrEqualNormalized(
        track.path,
        normalizedFolder,
      )) {
        return false;
      }
      return !scannedPathIndex.containsEquivalent(track.path);
    });
  }

  void removeTracksByPath(Iterable<String> trackPaths) {
    final removedPaths = trackPaths.toSet();
    if (removedPaths.isEmpty) return;
    _removeTracksWhere((track) => removedPaths.contains(track.path));
  }

  void removeLibraryEntriesDeletedFromFolder(
    String libraryPath,
    String folderPath,
    Set<String> retainedPaths,
  ) {
    final removedPaths = _libraryService
        .removeLibraryEntriesMissingFromFolderScan(
          libraryPath,
          folderPath,
          retainedPaths,
        );
    if (removedPaths.isEmpty) return;
    if (!_skipDisposePersistence) {
      unawaited(
        _audioDatabaseRepository.deleteLibraryEntries(
          libraryPath,
          removedPaths,
        ),
      );
    }
  }

  void removeLibraryEntriesByPaths(
    String libraryPath,
    Iterable<String> entryPaths,
  ) {
    final removedPaths = _libraryService.removeLibraryEntriesByPaths(
      libraryPath,
      entryPaths,
    );
    if (removedPaths.isEmpty) return;
    if (!_skipDisposePersistence) {
      unawaited(
        _audioDatabaseRepository.deleteLibraryEntries(
          libraryPath,
          removedPaths,
        ),
      );
    }
  }

  void setScanning(
    bool scanning, {
    bool background = false,
    bool notify = true,
  }) {
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
      _scanStage = FolderScanStage.preparing;
      _scanProcessed = 0;
      _scanTotal = null;
    } else {
      _scanProgressNotifyTimer?.cancel();
      _scanProgressNotifyTimer = null;
      _scanGeneration = 0;
      _scanStage = FolderScanStage.idle;
      _scanTotal = null;
    }
    if (notify) {
      _notifyLibraryChanged();
    } else {
      _syncLibraryStateSlice();
    }
  }

  void beginLibraryBatch() {
    _libraryBatchDepth++;
  }

  void beginStagedLibraryRefresh() {
    beginLibraryBatch();
  }

  int applyStagedLibraryRefreshChunk({
    required String sourceFolderPath,
    required String libraryRoot,
    List<MusicTrack> tracks = const <MusicTrack>[],
    Iterable<String> folderPaths = const <String>[],
    Iterable<String> removeWatchedFolders = const <String>[],
    Iterable<String> addWatchedFolders = const <String>[],
    Iterable<String> removeTrackPaths = const <String>[],
    Iterable<String> removeEntryPaths = const <String>[],
    bool persist = true,
  }) {
    for (final folderPath in removeWatchedFolders) {
      removeWatchedFolder(folderPath, notify: false);
    }
    if (tracks.isNotEmpty || folderPaths.isNotEmpty) {
      recordLibraryEntriesForTracks(
        libraryRoot,
        tracks,
        folderPaths: folderPaths,
        persist: persist,
      );
    }
    for (final folderPath in addWatchedFolders) {
      addWatchedFolder(folderPath, notify: false);
    }
    final beforeCount = _library.length;
    if (tracks.isNotEmpty) {
      addOrReplaceTracks(tracks, notify: false, persist: persist);
    }
    final trackPathsToRemove = removeTrackPaths.toList(growable: false);
    if (trackPathsToRemove.isNotEmpty) {
      removeTracksByPath(trackPathsToRemove);
    }
    final entryPathsToRemove = removeEntryPaths.toList(growable: false);
    if (entryPathsToRemove.isNotEmpty) {
      removeLibraryEntriesByPaths(libraryRoot, entryPathsToRemove);
    }
    return _library.length - beforeCount;
  }

  Future<bool> flushStagedLibraryRefreshChunk({
    bool waitForPersistence = false,
  }) async {
    if (UiInteractionCoordinator.instance.isInteracting) {
      final completer = Completer<void>();
      UiInteractionCoordinator.instance.scheduleCommit(
        key: 'library_refresh_chunk_flush',
        priority: 0,
        commit: () {
          unawaited(
            endLibraryBatch(
              waitForPersistence: waitForPersistence,
            ).then(completer.complete).catchError(completer.completeError),
          );
        },
      );
      await completer.future;
    } else {
      await endLibraryBatch(waitForPersistence: waitForPersistence);
    }
    await Future<void>.delayed(Duration.zero);
    if (!_isScanning) {
      return false;
    }
    beginLibraryBatch();
    return true;
  }

  Future<void> finishStagedLibraryRefresh({bool waitForPersistence = false}) {
    return endLibraryBatch(waitForPersistence: waitForPersistence);
  }

  Future<void> endLibraryBatch({
    bool notify = true,
    bool waitForPersistence = true,
  }) async {
    if (_libraryBatchDepth <= 0) return;
    _libraryBatchDepth--;
    if (_libraryBatchDepth > 0) return;

    final didChangeLibrary = _libraryBatchChanged;
    final entriesToPersist = List<LibraryEntry>.from(
      _libraryBatchPersistEntriesByKey.values,
    );
    if (!didChangeLibrary && entriesToPersist.isEmpty) return;
    final tracksToPersist = List<MusicTrack>.from(_libraryBatchPersistTracks);
    final didChangeGroupOrder = _libraryBatchChangedGroupOrder;
    _libraryBatchChanged = false;
    _libraryBatchChangedGroupOrder = false;
    _libraryBatchPersistTracks.clear();
    _libraryBatchPersistEntriesByKey.clear();

    if (didChangeLibrary) {
      _clearResolvedCoverPaths();
      _syncGroupOrderFromLibrary();
      _syncLibraryNodeOrder(persist: false);
      final derivedGeneration = ++_libraryDerivedGeneration;
      final derivedSnapshot = await AppLogService.measureAsync(
        'library_derived_snapshot_build',
        () => compute(
          buildLibraryDerivedSnapshot,
          LibraryDerivedSnapshotPayload(
            tracks: List<MusicTrack>.unmodifiable(_library),
            watchedFolders: List<String>.unmodifiable(_watchedFolders),
            nodeOrder: List<String>.unmodifiable(_libraryNodeOrder),
          ),
        ),
        details: <String, Object?>{'tracks': _library.length},
      );
      if (derivedGeneration == _libraryDerivedGeneration) {
        _libraryService
          ..library = derivedSnapshot.library
          ..libraryByPath = derivedSnapshot.libraryByPath
          ..libraryIndexByPath = derivedSnapshot.libraryIndexByPath
          ..tracksByGroup = derivedSnapshot.tracksByGroup
          ..sortedLibraryTracks = derivedSnapshot.sortedLibraryTracks
          ..sortedLibraryTrackPaths = derivedSnapshot.sortedLibraryTrackPaths;
        _markLibraryStructureDirty();
        _librarySnapshotCacheService.adoptCardSnapshot(
          derivedSnapshot.cardSnapshot,
        );
        if (notify) {
          _notifyLibraryAndPlaybackChanged();
        }
      }
    }
    final persistenceTasks = <Future<void>>[];
    if (tracksToPersist.isNotEmpty && !_skipDisposePersistence) {
      persistenceTasks.add(
        _audioDatabaseRepository.upsertTracks(tracksToPersist),
      );
    }
    if (entriesToPersist.isNotEmpty && !_skipDisposePersistence) {
      persistenceTasks.add(
        _audioDatabaseRepository.upsertLibraryEntries(entriesToPersist),
      );
    }
    if (didChangeLibrary && didChangeGroupOrder) {
      persistenceTasks.add(_saveGroupOrder());
    }
    if (didChangeLibrary) {
      persistenceTasks.add(_saveLibraryNodeOrder());
    }
    if (waitForPersistence) {
      await Future.wait(persistenceTasks);
    } else {
      for (final task in persistenceTasks) {
        unawaited(task);
      }
    }
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
      _recordLibraryEntriesForTracks(toAdd, persist: persist);
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
      if (!notify) {
        unawaited(_ensureLibraryCardSnapshot(notifyOnCommit: false));
      }
      if (notify) {
        _notifyLibraryAndPlaybackChanged();
      }
      if (persist && !_skipDisposePersistence) {
        unawaited(_audioDatabaseRepository.upsertTracks(toAdd));
      }
      if (persist) {
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
      final nextTrack = existing == null
          ? track
          : _mergeExistingTrackState(existing, track);
      if (existing != null && !_mergedTrackHasChanges(existing, track)) {
        continue;
      }
      if (existing != null && existing.groupKey != nextTrack.groupKey) {
        didReplaceGroup = true;
      }
      if (existing == null) {
        _library.add(nextTrack);
      } else {
        // Use the O(1) path index instead of an O(n) indexWhere scan.
        final index = _libraryIndexByPath[nextTrack.path];
        if (index != null &&
            index < _library.length &&
            _library[index].path == nextTrack.path) {
          _library[index] = nextTrack;
        } else {
          // Index is stale 鈥?fall back to a linear scan and repair the index.
          final fallbackIndex = _library.indexWhere(
            (item) => item.path == nextTrack.path,
          );
          if (fallbackIndex >= 0) {
            _library[fallbackIndex] = nextTrack;
          } else {
            _library.add(nextTrack);
          }
        }
      }
      _libraryByPath[nextTrack.path] = nextTrack;
      tracksToPersist.add(nextTrack);
      changed = true;
      if (_groupOrderSet.add(nextTrack.groupKey)) {
        _groupOrder.add(nextTrack.groupKey);
        didChangeGroupOrder = true;
      }
    }

    if (!changed) return;
    _recordLibraryEntriesForTracks(tracksToPersist, persist: persist);
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
    if (!notify) {
      unawaited(_ensureLibraryCardSnapshot(notifyOnCommit: false));
    }
    if (notify) {
      _notifyLibraryAndPlaybackChanged();
    }
    if (persist && !_skipDisposePersistence) {
      unawaited(_audioDatabaseRepository.upsertTracks(tracksToPersist));
    }
    if (persist) {
      if (didChangeGroupOrder || didReplaceGroup) {
        _saveGroupOrder();
      }
      _saveLibraryNodeOrder();
    }
  }

  bool libraryTrackNeedsRefresh(MusicTrack nextTrack) {
    final existing = _libraryByPath[nextTrack.path];
    return existing == null || _mergedTrackHasChanges(existing, nextTrack);
  }

  bool _mergedTrackHasChanges(MusicTrack existing, MusicTrack scanned) {
    return existing.displayName != scanned.displayName ||
        existing.groupKey != scanned.groupKey ||
        existing.groupTitle != scanned.groupTitle ||
        existing.groupSubtitle != scanned.groupSubtitle ||
        existing.isSingle != scanned.isSingle ||
        existing.isVideo != scanned.isVideo ||
        existing.fileSizeBytes != scanned.fileSizeBytes ||
        !_sameScanTimestamp(existing.modifiedAt, scanned.modifiedAt) ||
        existing.coverCachePath == null && scanned.coverCachePath != null ||
        existing.lyricsPath == null && scanned.lyricsPath != null ||
        existing.manualCoverPath == null && scanned.manualCoverPath != null ||
        existing.remoteCoverUrl == null && scanned.remoteCoverUrl != null ||
        existing.remoteMetadataKind == null &&
            scanned.remoteMetadataKind != null ||
        existing.remoteMetadata == null && scanned.remoteMetadata != null ||
        existing.duration == Duration.zero && scanned.duration != Duration.zero;
  }

  bool _sameScanTimestamp(DateTime? first, DateTime? second) {
    return first?.millisecondsSinceEpoch == second?.millisecondsSinceEpoch;
  }

  MusicTrack _mergeExistingTrackState(MusicTrack existing, MusicTrack scanned) {
    return MusicTrack(
      path: scanned.path,
      displayName: scanned.displayName,
      groupKey: scanned.groupKey,
      groupTitle: scanned.groupTitle,
      groupSubtitle: scanned.groupSubtitle,
      isSingle: scanned.isSingle,
      isVideo: scanned.isVideo,
      scannedAt: scanned.scannedAt,
      fileSizeBytes: scanned.fileSizeBytes,
      modifiedAt: scanned.modifiedAt,
      lastPlayedPosition: existing.lastPlayedPosition,
      lastPlayedAt: existing.lastPlayedAt,
      isFavorite: existing.isFavorite,
      tags: existing.tags,
      coverCachePath: existing.coverCachePath ?? scanned.coverCachePath,
      lyricsPath: existing.lyricsPath ?? scanned.lyricsPath,
      manualCoverPath: existing.manualCoverPath ?? scanned.manualCoverPath,
      remoteCoverUrl: existing.remoteCoverUrl ?? scanned.remoteCoverUrl,
      remoteMetadataKind:
          existing.remoteMetadataKind ?? scanned.remoteMetadataKind,
      remoteMetadata: existing.remoteMetadata ?? scanned.remoteMetadata,
      duration: existing.duration == Duration.zero
          ? scanned.duration
          : existing.duration,
    );
  }

  void recordLibraryEntriesForTracks(
    String libraryPath,
    List<MusicTrack> tracks, {
    Iterable<String> folderPaths = const <String>[],
    bool persist = true,
    LibraryExclusionMatcher? exclusionMatcher,
    LibraryEntrySnapshot? entrySnapshot,
  }) {
    final entries = _filterFreshLibraryEntries(
      _buildLibraryEntries(
        libraryPath,
        tracks,
        folderPaths: folderPaths,
        exclusionMatcher: exclusionMatcher,
      ),
      entrySnapshot,
    );
    if (entries.isEmpty) return;
    _libraryService.replaceLibraryEntries(entries);
    entrySnapshot?.remember(entries);
    _queueOrPersistLibraryEntries(entries, persist: persist);
  }

  List<LibraryEntry> _filterFreshLibraryEntries(
    List<LibraryEntry> entries,
    LibraryEntrySnapshot? entrySnapshot,
  ) {
    if (entries.isEmpty || entrySnapshot == null) return entries;
    return entries
        .where(entrySnapshot.entryNeedsRefresh)
        .toList(growable: false);
  }

  void _recordLibraryEntriesForTracks(
    List<MusicTrack> tracks, {
    bool persist = true,
  }) {
    final entries = <LibraryEntry>[];
    final tracksByLibrary = <String, List<MusicTrack>>{};
    for (final track in tracks) {
      final libraryPath = _libraryPathForTrack(track);
      if (libraryPath == null || libraryPath.isEmpty) continue;
      tracksByLibrary.putIfAbsent(libraryPath, () => <MusicTrack>[]).add(track);
    }
    for (final entry in tracksByLibrary.entries) {
      entries.addAll(_buildLibraryEntries(entry.key, entry.value));
    }
    if (entries.isEmpty) return;
    _libraryService.replaceLibraryEntries(entries);
    _queueOrPersistLibraryEntries(entries, persist: persist);
  }

  void _queueOrPersistLibraryEntries(
    List<LibraryEntry> entries, {
    required bool persist,
  }) {
    if (entries.isEmpty || !persist || _skipDisposePersistence) return;
    if (_libraryBatchDepth > 0) {
      for (final entry in entries) {
        _libraryBatchPersistEntriesByKey[_libraryEntryBatchKey(entry)] = entry;
      }
      return;
    }
    unawaited(_audioDatabaseRepository.upsertLibraryEntries(entries));
  }

  String _libraryEntryBatchKey(LibraryEntry entry) {
    return [
      PathMatcher.normalize(entry.libraryPath),
      PathMatcher.normalize(entry.path),
      entry.kind.dbValue,
    ].join('\x1F');
  }

  List<LibraryEntry> _buildLibraryEntries(
    String libraryPath,
    List<MusicTrack> tracks, {
    Iterable<String> folderPaths = const <String>[],
    LibraryExclusionMatcher? exclusionMatcher,
  }) {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    final matcher =
        exclusionMatcher ??
        _libraryService.libraryExclusionMatcherForLibrary(
          normalizedLibraryPath,
        );
    final entriesByKey = <String, LibraryEntry>{};

    void putEntry(LibraryEntry entry) {
      entriesByKey['${entry.kind.dbValue}:${entry.path}'] = entry;
    }

    void ensureFolder(String folderPath) {
      final normalizedFolderPath = _canonicalLibraryFolderPath(
        normalizedLibraryPath,
        folderPath,
      );
      if (PathMatcher.equalsNormalized(
            normalizedFolderPath,
            normalizedLibraryPath,
          ) ||
          !PathMatcher.isWithinOrEqual(
            normalizedFolderPath,
            normalizedLibraryPath,
          )) {
        return;
      }
      final parentPath = _parentLibraryFolderPath(
        normalizedFolderPath,
        normalizedLibraryPath,
      );
      if (parentPath != null) {
        ensureFolder(parentPath);
      }
      putEntry(
        LibraryEntry.folder(
          libraryPath: normalizedLibraryPath,
          path: normalizedFolderPath,
          parentPath: parentPath,
          state: matcher.isExcluded(normalizedFolderPath)
              ? LibraryEntryState.excluded
              : LibraryEntryState.active,
          displayName: PathDisplay.folderName(normalizedFolderPath),
        ),
      );
    }

    for (final folderPath in folderPaths) {
      ensureFolder(folderPath);
    }

    for (final track in tracks) {
      if (!PathMatcher.isWithinOrEqual(track.path, normalizedLibraryPath)) {
        continue;
      }
      final parentPath = _folderPathForLibraryTrack(
        normalizedLibraryPath,
        track,
      );
      if (parentPath != null) {
        ensureFolder(parentPath);
      }
      putEntry(
        LibraryEntry.track(
          libraryPath: normalizedLibraryPath,
          track: track,
          parentPath: parentPath,
          state: matcher.isExcluded(track.path)
              ? LibraryEntryState.excluded
              : LibraryEntryState.active,
        ),
      );
    }

    return entriesByKey.values.toList(growable: false);
  }

  String? _libraryPathForTrack(MusicTrack track) {
    for (final libraryPath in _watchedLibraries) {
      if (PathMatcher.isWithinOrEqual(track.path, libraryPath) ||
          PathMatcher.isWithinOrEqual(track.groupKey, libraryPath)) {
        return libraryPath;
      }
    }
    for (final folderPath in _watchedFolders) {
      if (PathMatcher.isWithinOrEqual(track.path, folderPath) ||
          PathMatcher.isWithinOrEqual(track.groupKey, folderPath)) {
        return folderPath;
      }
    }
    return null;
  }

  String? _folderPathForLibraryTrack(String libraryPath, MusicTrack track) {
    if (!track.isSingle &&
        track.groupKey.isNotEmpty &&
        track.groupKey != '__single_files__' &&
        PathMatcher.isWithinOrEqual(track.groupKey, libraryPath) &&
        !PathMatcher.equalsNormalized(track.groupKey, libraryPath)) {
      return _canonicalLibraryFolderPath(libraryPath, track.groupKey);
    }
    final relative = PathMatcher.relativeWithin(track.path, libraryPath);
    if (relative == null || relative.isEmpty) return null;
    final normalizedRelative = relative.replaceAll('\\', '/');
    final relativeFolder = path.posix.dirname(normalizedRelative);
    if (relativeFolder == '.' || relativeFolder.isEmpty) return null;
    if (PathMatcher.isContentUri(libraryPath)) {
      return '$libraryPath::$relativeFolder';
    }
    return path.normalize(path.join(libraryPath, relativeFolder));
  }

  String _canonicalLibraryFolderPath(String libraryPath, String folderPath) {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    final normalizedFolderPath = PathMatcher.normalize(folderPath);
    if (!PathMatcher.isContentUri(normalizedLibraryPath) ||
        normalizedFolderPath.contains('::')) {
      return normalizedFolderPath;
    }
    final relativeFolderPath = PathMatcher.relativeWithin(
      normalizedFolderPath,
      normalizedLibraryPath,
    );
    if (relativeFolderPath == null || relativeFolderPath.isEmpty) {
      return normalizedFolderPath;
    }
    return '$normalizedLibraryPath::${relativeFolderPath.replaceAll('\\', '/')}';
  }

  String? _parentLibraryFolderPath(String folderPath, String rootPath) {
    final normalizedFolderPath = PathMatcher.normalize(folderPath);
    if (PathMatcher.equalsNormalized(normalizedFolderPath, rootPath)) {
      return null;
    }
    if (PathMatcher.isContentUri(normalizedFolderPath)) {
      final markerIndex = normalizedFolderPath.indexOf('::');
      if (markerIndex >= 0) {
        final base = normalizedFolderPath.substring(0, markerIndex);
        final relative = normalizedFolderPath
            .substring(markerIndex + 2)
            .replaceAll('\\', '/')
            .replaceFirst(RegExp(r'^/+'), '')
            .replaceFirst(RegExp(r'/+$'), '');
        final parentRelative = path.posix.dirname(relative);
        if (parentRelative == '.' || parentRelative.isEmpty) {
          return base;
        }
        return '$base::$parentRelative';
      }
    }
    final parentPath = path.dirname(normalizedFolderPath);
    return PathMatcher.equalsNormalized(parentPath, rootPath)
        ? rootPath
        : parentPath;
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
    _notifyLibraryAndPlaybackChanged();
    if (!_skipDisposePersistence) {
      unawaited(_audioDatabaseRepository.deleteTracks([trackPath]));
    }
    unawaited(_saveGroupOrder());
    unawaited(_saveLibraryNodeOrder());
  }

  Future<void> removeFolderFromLibrary(String folderPath) async {
    _clearResolvedCoverPaths();
    unawaited(
      deleteAudioDetail(AudioDetailTarget.libraryRootFolder(folderPath)),
    );
    final normalizedFolderPath = PathMatcher.normalize(folderPath);
    final trackPaths = _library
        .where(
          (track) =>
              PathMatcher.isWithinOrEqual(track.path, normalizedFolderPath) ||
              PathMatcher.isWithinOrEqual(track.groupKey, normalizedFolderPath),
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
      (track) =>
          PathMatcher.isWithinOrEqual(track.path, normalizedFolderPath) ||
          PathMatcher.isWithinOrEqual(track.groupKey, normalizedFolderPath),
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
    _libraryService.libraryEntriesByLibrary.remove(normalizedFolderPath);

    _rebuildLibraryIndexes();
    _syncLibraryNodeOrder(persist: false);
    _notifyLibraryAndPlaybackChanged();
    if (!_skipDisposePersistence) {
      unawaited(_audioDatabaseRepository.deleteTracks(trackPaths.toList()));
      unawaited(
        _audioDatabaseRepository.deleteLibraryEntriesForLibrary(folderPath),
      );
    }
    unawaited(_saveGroupOrder());
    unawaited(_saveLibraryNodeOrder());
  }

  int getTrackComparator(MusicTrack a, MusicTrack b) {
    return _libraryOrganizer.compareTracks(a, b);
  }

  MusicTrack? trackByPath(String trackPath) {
    final resolvedPath = _resolveRetargetedPath(trackPath);
    final libraryTrack = _libraryService.trackByPath(resolvedPath);
    if (libraryTrack != null) {
      return libraryTrack;
    }
    for (final session in _sessions.values) {
      for (final track in session.customQueueTracks ?? const <MusicTrack>[]) {
        if (PathMatcher.equalsNormalized(track.path, trackPath) ||
            PathMatcher.equalsNormalized(track.path, resolvedPath) ||
            PathMatcher.equalsNormalized(
              _resolveRetargetedPath(track.path),
              resolvedPath,
            )) {
          return track;
        }
      }
    }
    return null;
  }

  PlaybackSession? sessionById(String sessionId) =>
      _playbackService.sessionById(sessionId);

  String? sessionTrackPath(String sessionId) =>
      _playbackService.sessionById(sessionId)?.currentTrackPath == null
      ? null
      : _resolveRetargetedPath(
          _playbackService.sessionById(sessionId)!.currentTrackPath,
        );

  bool isTrackActive(String trackPath) =>
      _playbackService.isTrackActive(trackPath);

  List<MusicTrack> tracksInSameGroup(String trackPath) {
    final track = trackByPath(trackPath);
    if (track == null) return [];
    final libraryGroupTracks = _tracksByGroup[track.groupKey];
    if (libraryGroupTracks != null && libraryGroupTracks.isNotEmpty) {
      return libraryGroupTracks;
    }
    final resolvedPath = _resolveRetargetedPath(trackPath);
    for (final session in _sessions.values) {
      final customQueueTracks = session.customQueueTracks;
      if (customQueueTracks == null || customQueueTracks.isEmpty) continue;
      if (customQueueTracks.any(
        (candidate) =>
            PathMatcher.equalsNormalized(candidate.path, trackPath) ||
            PathMatcher.equalsNormalized(candidate.path, resolvedPath) ||
            PathMatcher.equalsNormalized(
              _resolveRetargetedPath(candidate.path),
              resolvedPath,
            ),
      )) {
        return customQueueTracks
            .where((candidate) => candidate.groupKey == track.groupKey)
            .toList(growable: false);
      }
    }
    return const <MusicTrack>[];
  }

  List<MusicTrack> tracksInSameWork(String trackPath) {
    final track = trackByPath(trackPath);
    if (track == null) return const <MusicTrack>[];
    if (track.isSingle) return <MusicTrack>[track];
    if (track.remoteMetadataKind == 'asmr.one' ||
        PathMatcher.isRemoteUri(track.path)) {
      return tracksInSameGroup(trackPath);
    }

    final workRoot = workRootForTrack(trackPath);
    if (workRoot == null) {
      return tracksInSameGroup(trackPath);
    }

    final tracks =
        _library
            .where(
              (candidate) =>
                  PathMatcher.isWithinOrEqual(candidate.path, workRoot) ||
                  PathMatcher.isWithinOrEqual(candidate.groupKey, workRoot),
            )
            .toList(growable: false)
          ..sort(getTrackComparator);
    return tracks;
  }

  List<MusicTrack> tracksForSessionSwitcher(String sessionId) {
    final session = _sessions[sessionId];
    if (session == null) return const <MusicTrack>[];
    final sessionTracks = session.customQueueTracks;
    if (sessionTracks != null && sessionTracks.isNotEmpty) {
      return sessionTracks;
    }
    return tracksInSameWork(session.currentTrackPath);
  }

  String? workRootForTrack(String trackPath) {
    final track = trackByPath(trackPath);
    if (track == null || PathMatcher.isRemoteUri(track.path)) return null;
    return _resolveCoverScopeFolderPath(track, trackPath: trackPath);
  }

  String getRootFolderPath(String trackPath) {
    final resolvedPath = _resolveRetargetedPath(trackPath);
    for (final folder in _watchedFolders) {
      if (PathMatcher.isWithinOrEqual(resolvedPath, folder)) {
        return folder;
      }
    }
    for (final libraryPath in _watchedLibraries) {
      if (PathMatcher.isWithinOrEqual(resolvedPath, libraryPath)) {
        return libraryPath;
      }
    }
    return '';
  }

  String getRootFolderName(String trackPath) {
    final resolvedPath = _resolveRetargetedPath(trackPath);
    for (final folder in _watchedFolders) {
      if (PathMatcher.isWithinOrEqual(resolvedPath, folder)) {
        return PathDisplay.folderName(folder);
      }
    }
    for (final libraryPath in _watchedLibraries) {
      if (PathMatcher.isWithinOrEqual(resolvedPath, libraryPath)) {
        return PathDisplay.folderName(libraryPath);
      }
    }
    return '';
  }

  Future<Duration?> calculateMissingLibraryDuration(
    String targetPath, {
    @visibleForTesting Future<Duration?> Function(String path)? durationReader,
  }) async {
    final singleTracks = _library
        .where(
          (track) =>
              track.isSingle &&
              PathMatcher.equalsNormalized(track.path, targetPath),
        )
        .toList(growable: false);
    final targetTracks = singleTracks.isNotEmpty
        ? singleTracks
        : _library
              .where(
                (track) =>
                    !track.isSingle &&
                    (PathMatcher.isWithinOrEqual(track.groupKey, targetPath) ||
                        PathMatcher.isWithinOrEqual(track.path, targetPath)),
              )
              .toList(growable: false);
    if (targetTracks.isEmpty) return null;

    final tracksToUpdate = <MusicTrack>[];
    var totalDuration = Duration.zero;
    var hasUnknownDuration = false;
    final missingTracks = <MusicTrack>[];
    for (final track in targetTracks) {
      if (track.duration > Duration.zero) {
        totalDuration += track.duration;
      } else {
        missingTracks.add(track);
      }
    }

    Future<Duration?> resolveDuration(MusicTrack track) async {
      try {
        if (durationReader != null) return durationReader(track.path);
        final nativeDuration = await AudioProvider._fileCacheGateway
            .resolveMediaDuration(track.path);
        if (nativeDuration != null && nativeDuration > Duration.zero) {
          return nativeDuration;
        }
        final player = AudioPlayer();
        try {
          return await _readLocalMediaDuration(player, track.path);
        } finally {
          await player.dispose();
        }
      } catch (error, stackTrace) {
        AppLogService.warning(
          'library_duration_probe_failed path=${track.path}',
          error: error,
          stackTrace: stackTrace,
        );
        return null;
      }
    }

    const concurrency = 2;
    for (var start = 0; start < missingTracks.length; start += concurrency) {
      final end = (start + concurrency).clamp(0, missingTracks.length);
      final chunk = missingTracks.sublist(start, end);
      final durations = await Future.wait(chunk.map(resolveDuration));
      for (var index = 0; index < chunk.length; index++) {
        final track = chunk[index];
        final duration = durations[index] ?? Duration.zero;
        if (duration > Duration.zero) {
          totalDuration += duration;
          tracksToUpdate.add(track.copyWith(duration: duration));
        } else {
          hasUnknownDuration = true;
          AppLogService.warning(
            'library_duration_unresolved path=${track.path} video=${track.isVideo}',
          );
        }
      }
    }

    if (tracksToUpdate.isNotEmpty) {
      for (final track in tracksToUpdate) {
        final index = _libraryIndexByPath[track.path];
        if (index != null) _library[index] = track;
        _libraryByPath[track.path] = track;
      }
      await _audioDatabaseRepository.upsertTracks(tracksToUpdate);
      _rebuildLibraryIndexes();
      _notifyListeners();
    }

    return !hasUnknownDuration && totalDuration > Duration.zero
        ? totalDuration
        : null;
  }
}

Future<Duration?> _readLocalMediaDuration(
  AudioPlayer player,
  String mediaPath,
) {
  if (PathMatcher.isContentUri(mediaPath)) {
    return player
        .setAudioSource(AudioSource.uri(Uri.parse(mediaPath)))
        .timeout(const Duration(seconds: 8));
  }
  return player.setFilePath(mediaPath).timeout(const Duration(seconds: 8));
}
