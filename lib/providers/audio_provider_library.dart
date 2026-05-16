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
    _notifyListeners();
  }

  List<String> childFoldersForLibrary(String libraryPath) =>
      _libraryService.childFoldersForLibrary(libraryPath);

  List<String> excludedFoldersForLibrary(String libraryPath) =>
      _libraryService.excludedFoldersForLibrary(libraryPath);

  List<String> excludedTracksForLibrary(String libraryPath) =>
      _libraryService.excludedTracksForLibrary(libraryPath);

  List<LibraryEntry> libraryEntriesForLibrary(String libraryPath) =>
      _libraryService.libraryEntriesForLibrary(libraryPath);

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
    } else {
      unawaited(
        _restoreExcludedFolder(normalizedLibraryPath, normalizedFolderPath),
      );
    }
    _notifyListeners();
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
    } else {
      unawaited(_restoreExcludedTrack(libraryPath, normalizedTrackPath));
    }
    _notifyListeners();
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
      _notifyListeners();
      return;
    }

    final restoredTracks = PathMatcher.isContentUri(folderPath)
        ? await _scanRestorableTracksViaNative(folderPath)
        : await _scanRestorableTracksFromDisk(folderPath);
    if (restoredTracks.isEmpty) {
      _notifyListeners();
      return;
    }

    final candidates = restoredTracks
        .where(
          (track) =>
              !_libraryService.isLibraryPathExcluded(libraryPath, track.path),
        )
        .toList(growable: false);
    if (candidates.isEmpty) {
      _notifyListeners();
      return;
    }

    addOrReplaceTracks(candidates, notify: false);
    _notifyListeners();
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
        } catch (_) {}

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
      final data = await AudioProvider._fileCacheChannel
          .invokeMethod<List<dynamic>>(FileCacheMethod.scanFolder, {
            'folder': folderPath,
          });
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
    _removeTracksWhere((track) {
      for (final entry in _excludedLibraryFolders.entries) {
        for (final folderPath in entry.value) {
          if (PathMatcher.isWithinOrEqual(track.path, folderPath) ||
              PathMatcher.isWithinOrEqual(track.groupKey, folderPath)) {
            return true;
          }
        }
      }
      for (final entry in _excludedLibraryTracks.entries) {
        for (final trackPath in entry.value) {
          if (PathMatcher.equalsNormalized(track.path, trackPath)) {
            return true;
          }
        }
      }
      return false;
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
    }
    // Skip the expensive rebuild when inside a batch — endLibraryBatch will
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
    _removeTracksWhere((track) {
      if (!PathMatcher.isWithinOrEqualNormalized(track.path, normalizedFolder)) {
        return false;
      }
      return !scannedPaths.contains(track.path);
    });
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
    if (tracksToPersist.isNotEmpty && !_skipDisposePersistence) {
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
      if (notify) {
        _notifyListeners();
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
      if (existing == nextTrack) continue;
      if (existing != null && existing.groupKey != nextTrack.groupKey) {
        didReplaceGroup = true;
      }
      if (existing == null) {
        _library.add(nextTrack);
      } else {
        final index = _library.indexWhere(
          (item) => item.path == nextTrack.path,
        );
        if (index >= 0) {
          _library[index] = nextTrack;
        } else {
          _library.add(nextTrack);
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
    if (notify) {
      _notifyListeners();
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
  }) {
    final entries = _buildLibraryEntries(
      libraryPath,
      tracks,
      folderPaths: folderPaths,
    );
    if (entries.isEmpty) return;
    _libraryService.replaceLibraryEntries(entries);
    if (persist && !_skipDisposePersistence) {
      unawaited(_audioDatabaseRepository.upsertLibraryEntries(entries));
    }
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
    if (persist && !_skipDisposePersistence) {
      unawaited(_audioDatabaseRepository.upsertLibraryEntries(entries));
    }
  }

  List<LibraryEntry> _buildLibraryEntries(
    String libraryPath,
    List<MusicTrack> tracks, {
    Iterable<String> folderPaths = const <String>[],
  }) {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
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
          state:
              _libraryService.isLibraryPathExcluded(
                normalizedLibraryPath,
                normalizedFolderPath,
              )
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
          state:
              _libraryService.isLibraryPathExcluded(
                normalizedLibraryPath,
                track.path,
              )
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
    _notifyListeners();
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
    _notifyListeners();
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

  String getRootFolderPath(String trackPath) {
    for (final folder in _watchedFolders) {
      if (PathMatcher.isWithinOrEqual(trackPath, folder)) {
        return folder;
      }
    }
    for (final libraryPath in _watchedLibraries) {
      if (PathMatcher.isWithinOrEqual(trackPath, libraryPath)) {
        return libraryPath;
      }
    }
    return '';
  }

  String getRootFolderName(String trackPath) {
    for (final folder in _watchedFolders) {
      if (PathMatcher.isWithinOrEqual(trackPath, folder)) {
        return PathDisplay.folderName(folder);
      }
    }
    for (final libraryPath in _watchedLibraries) {
      if (PathMatcher.isWithinOrEqual(trackPath, libraryPath)) {
        return PathDisplay.folderName(libraryPath);
      }
    }
    return '';
  }
}
