part of 'audio_provider.dart';

extension AudioProviderLibrary on AudioProvider {
  void _syncLibraryNodeOrder({bool persist = true}) {
    _libraryService.syncLibraryNodeOrder(
      persist: persist,
      onPersist: () => unawaited(_saveLibraryNodeOrder()),
    );
  }

  void reorderLibraryNodes(int oldIndex, int newIndex) {
    _libraryFacade.reorderLibraryNodes(oldIndex, newIndex);
    _notifyLibraryChanged();
  }

  void addWatchedFolder(String folderPath, {bool notify = true}) {
    final previousCount = _watchedFolders.length;
    _libraryFacade.addWatchedFolder(folderPath, notify: false);
    if (notify && _watchedFolders.length != previousCount) {
      _notifyLibraryChanged();
    }
  }

  void addWatchedLibrary(String folderPath, {bool notify = true}) {
    final previousCount = _watchedLibraries.length;
    _libraryFacade.addWatchedLibrary(folderPath, notify: false);
    if (notify && _watchedLibraries.length != previousCount) {
      _notifyLibraryChanged();
    }
  }

  void removeWatchedFolder(String folderPath, {bool notify = true}) {
    final previousCount = _watchedFolders.length;
    _libraryFacade.removeWatchedFolder(folderPath, notify: false);
    if (notify && _watchedFolders.length != previousCount) {
      _notifyLibraryChanged();
    }
  }

  void removeWatchedLibrary(String folderPath, {bool notify = true}) {
    final previousCount = _watchedLibraries.length;
    _libraryFacade.removeWatchedLibrary(folderPath, notify: false);
    if (notify && _watchedLibraries.length != previousCount) {
      _notifyLibraryChanged();
    }
  }

  Future<void> removeLibrary(String libraryPath) async {
    await _libraryFacade.removeLibrary(libraryPath);
    _notifyLibraryAndPlaybackChanged();
  }

  List<String> childFoldersForLibrary(String libraryPath) =>
      _libraryService.childFoldersForLibrary(libraryPath);

  String? libraryRootForPath(String entityPath) {
    final resolvedPath = _playbackFacade.resolveRetargetedPath(entityPath);
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
    _libraryFacade.clearLibraryExclusions(libraryPath);
    _notifyLibraryChanged();
  }

  void setLibraryFolderExcluded(
    String libraryPath,
    String folderPath,
    bool excluded,
  ) {
    _libraryFacade.setLibraryFolderExcluded(libraryPath, folderPath, excluded);
    if (excluded) {
      _notifyLibraryAndPlaybackChanged();
    } else {
      _notifyLibraryChanged();
    }
  }

  void setLibraryTrackExcluded(
    String libraryPath,
    String trackPath,
    bool excluded,
  ) {
    _libraryFacade.setLibraryTrackExcluded(libraryPath, trackPath, excluded);
    if (excluded) {
      _notifyLibraryAndPlaybackChanged();
    } else {
      _notifyLibraryChanged();
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
    _libraryFacade.removeTracksMatching(test);
  }

  void _handleLibraryTracksRemoved(List<String> removedPaths) {
    final removedSet = removedPaths.toSet();
    final sessionsToRemove = _sessions.values
        .where((session) => removedSet.contains(session.currentTrackPath))
        .map((session) => session.id)
        .toList(growable: false);
    if (sessionsToRemove.isNotEmpty) {
      unawaited(
        _playbackFacade.removeSessions(
          sessionsToRemove,
          persist: false,
          notify: false,
        ),
      );
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
    _libraryFacade.removeLibraryEntriesDeletedFromFolder(
      libraryPath,
      folderPath,
      retainedPaths,
    );
  }

  void removeLibraryEntriesByPaths(
    String libraryPath,
    Iterable<String> entryPaths,
  ) {
    _libraryFacade.removeLibraryEntriesByPaths(libraryPath, entryPaths);
  }

  void beginLibraryBatch() {
    _libraryFacade.beginLibraryBatch();
  }

  void beginStagedLibraryRefresh() {
    _libraryFacade.beginStagedLibraryRefresh();
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
  }) => _libraryFacade.applyStagedLibraryRefreshChunk(
    sourceFolderPath: sourceFolderPath,
    libraryRoot: libraryRoot,
    tracks: tracks,
    folderPaths: folderPaths,
    removeWatchedFolders: removeWatchedFolders,
    addWatchedFolders: addWatchedFolders,
    removeTrackPaths: removeTrackPaths,
    removeEntryPaths: removeEntryPaths,
    persist: persist,
  );

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
    return _libraryFacade.finishStagedLibraryRefresh(
      waitForPersistence: waitForPersistence,
    );
  }

  Future<void> endLibraryBatch({
    bool notify = true,
    bool waitForPersistence = true,
  }) async {
    final previousRevision = _libraryService.structureRevision;
    await _libraryFacade.endLibraryBatch(
      notify: notify,
      waitForPersistence: waitForPersistence,
    );
    if (notify && _libraryService.structureRevision != previousRevision) {
      _notifyLibraryAndPlaybackChanged();
    }
  }

  void addTracks(
    List<MusicTrack> newTracks, {
    bool notify = true,
    bool persist = true,
  }) {
    final previousRevision = _libraryService.structureRevision;
    _libraryFacade.addTracks(newTracks, notify: notify, persist: persist);
    if (notify && _libraryService.structureRevision != previousRevision) {
      _notifyLibraryAndPlaybackChanged();
    }
  }

  void addOrReplaceTracks(
    List<MusicTrack> tracks, {
    bool notify = true,
    bool persist = true,
  }) {
    final previousRevision = _libraryService.structureRevision;
    _libraryFacade.addOrReplaceTracks(tracks, notify: notify, persist: persist);
    if (notify && _libraryService.structureRevision != previousRevision) {
      _notifyLibraryAndPlaybackChanged();
    }
  }

  bool libraryTrackNeedsRefresh(MusicTrack nextTrack) {
    return _libraryService.trackNeedsRefresh(nextTrack);
  }

  void recordLibraryEntriesForTracks(
    String libraryPath,
    List<MusicTrack> tracks, {
    Iterable<String> folderPaths = const <String>[],
    bool persist = true,
    LibraryExclusionMatcher? exclusionMatcher,
    LibraryEntrySnapshot? entrySnapshot,
  }) {
    _libraryFacade.recordLibraryEntriesForTracks(
      libraryPath,
      tracks,
      folderPaths: folderPaths,
      persist: persist,
      exclusionMatcher: exclusionMatcher,
      entrySnapshot: entrySnapshot,
    );
  }

  Future<void> removeTrackFromLibrary(String trackPath) async {
    await _libraryFacade.removeTrackFromLibrary(trackPath);
    _notifyLibraryAndPlaybackChanged();
  }

  Future<void> removeFolderFromLibrary(String folderPath) async {
    await _libraryFacade.removeFolderFromLibrary(folderPath);
    _notifyLibraryAndPlaybackChanged();
  }

  int getTrackComparator(MusicTrack a, MusicTrack b) {
    return _libraryService.compareTracks(a, b);
  }

  MusicTrack? trackByPath(String trackPath) {
    final resolvedPath = _playbackFacade.resolveRetargetedPath(trackPath);
    final libraryTrack = _libraryService.trackByPath(resolvedPath);
    if (libraryTrack != null) {
      return libraryTrack;
    }
    for (final session in _sessions.values) {
      for (final track in session.customQueueTracks ?? const <MusicTrack>[]) {
        if (PathMatcher.equalsNormalized(track.path, trackPath) ||
            PathMatcher.equalsNormalized(track.path, resolvedPath) ||
            PathMatcher.equalsNormalized(
              _playbackFacade.resolveRetargetedPath(track.path),
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
      : _playbackFacade.resolveRetargetedPath(
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
    final resolvedPath = _playbackFacade.resolveRetargetedPath(trackPath);
    for (final session in _sessions.values) {
      final customQueueTracks = session.customQueueTracks;
      if (customQueueTracks == null || customQueueTracks.isEmpty) continue;
      if (customQueueTracks.any(
        (candidate) =>
            PathMatcher.equalsNormalized(candidate.path, trackPath) ||
            PathMatcher.equalsNormalized(candidate.path, resolvedPath) ||
            PathMatcher.equalsNormalized(
              _playbackFacade.resolveRetargetedPath(candidate.path),
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
    final resolvedPath = _playbackFacade.resolveRetargetedPath(trackPath);
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
    final resolvedPath = _playbackFacade.resolveRetargetedPath(trackPath);
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
}
