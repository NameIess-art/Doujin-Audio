part of 'playback_facade.dart';

extension PlaybackQueuePathCoordinator on PlaybackFacade {
  void _replacePlaybackQueueEntries(
    PlaybackSession session,
    List<PlaybackQueueEntry> entries, {
    int? Function(PlaybackQueueEntry, int)? mapOffset,
  }) {
    final queue = session.playbackQueue!;
    var oldIndex = session.currentQueueIndex;
    if (session.hasDetachedQueueTrack) {
      if (oldIndex == 0) {
        session.playbackQueue = queue.copyWith(entries: entries);
        return;
      }
      oldIndex -= 1;
    }
    final current = queue.locationAt(oldIndex);
    var nextIndex = 0;
    var found = false;
    for (final entry in entries) {
      if (current != null && entry.id == current.entry.id) {
        final offset = mapOffset == null
            ? current.offset
            : mapOffset(current.entry, current.offset);
        if (offset != null && offset < entry.tracks.length) {
          nextIndex += offset;
          found = true;
          break;
        }
      }
      nextIndex += entry.tracks.length;
    }
    final updated = queue.copyWith(entries: entries);
    if (!found && current != null && session.loadedPath != null) {
      // The current occurrence can have distinct metadata from another entry
      // with the same path. Keep that occurrence until native playback advances.
      session.customQueueTracks = [
        current.entry.tracks[current.offset],
        ...updated.expandedTracks,
      ];
      session.hasDetachedQueueTrack = true;
      session.currentQueueIndex = 0;
    } else {
      session.currentQueueIndex = found
          ? nextIndex + (session.hasDetachedQueueTrack ? 1 : 0)
          : -1;
    }
    session.playbackQueue = updated;
  }

  Future<void> addTrackToPlaybackQueue(String sessionId, MusicTrack track) {
    return _addPlaybackQueueEntry(
      sessionId,
      PlaybackQueueEntry(
        id: _nextQueueEntryId(),
        kind: PlaybackQueueEntryKind.track,
        title: track.displayName,
        tracks: <MusicTrack>[track],
      ),
    );
  }

  Future<void> addWorkToPlaybackQueue(
    String sessionId, {
    required String title,
    required List<MusicTrack> tracks,
    String? workRootPath,
  }) {
    if (tracks.isEmpty) return Future<void>.value();
    return _addPlaybackQueueEntry(
      sessionId,
      PlaybackQueueEntry(
        id: _nextQueueEntryId(),
        kind: PlaybackQueueEntryKind.work,
        title: title,
        tracks: List<MusicTrack>.unmodifiable(tracks),
        workRootPath: workRootPath,
      ),
    );
  }

  Future<void> _addPlaybackQueueEntry(
    String sessionId,
    PlaybackQueueEntry entry,
  ) => _appendPlaybackQueueEntries(sessionId, [entry]);

  Future<void> addPlaybackQueueEntries(
    String sessionId,
    List<PlaybackQueueEntry> entries,
  ) => _appendPlaybackQueueEntries(sessionId, [
    for (final entry in entries)
      PlaybackQueueEntry(
        id: _nextQueueEntryId(),
        kind: entry.kind,
        title: entry.title,
        tracks: entry.tracks,
        workRootPath: entry.workRootPath,
      ),
  ]);

  Future<void> _appendPlaybackQueueEntries(
    String sessionId,
    List<PlaybackQueueEntry> entries,
  ) async {
    final session = _service.sessions[sessionId];
    if (session == null || entries.isEmpty) return;
    if (session.queueLoadingRequired &&
        !await ensureSessionQueueLoaded(sessionId)) {
      return;
    }
    final queue = session.playbackQueue;
    if (queue == null) return;
    final shouldSelectFirst =
        queue.trackCount == 0 && !session.hasDetachedQueueTrack;
    _replacePlaybackQueueEntries(session, <PlaybackQueueEntry>[
      ...queue.entries,
      ...entries,
    ]);
    _publishQueueReferencesChanged();
    _notifySessionStateChanged(session);
    scheduleSessionStatePersistence(sessionId: session.id);
    await _synchronizePlaybackQueueSession?.call(
      session,
      selectFirst: shouldSelectFirst,
    );
    _notifySessionStateChanged(session);
    publishSessionActivated(session.id);
  }

  Future<void> removePlaybackQueueEntry(
    String sessionId,
    String entryId, {
    List<MusicTrack>? tracks,
  }) async {
    final session = _service.sessions[sessionId];
    if (session == null) return;
    if (session.queueLoadingRequired &&
        !await ensureSessionQueueLoaded(sessionId)) {
      return;
    }
    final queue = session.playbackQueue;
    if (queue == null) return;
    final index = queue.entries.indexWhere((entry) => entry.id == entryId);
    if (index < 0) return;
    final entries = queue.entries.toList();
    final entry = entries[index];
    final removedTracks = tracks == null
        ? null
        : (Set<MusicTrack>.identity()..addAll(tracks));
    int? Function(PlaybackQueueEntry, int)? mapOffset;
    if (removedTracks == null) {
      entries.removeAt(index);
    } else {
      // Metadata refreshes can replace track snapshots while undo is offered.
      final currentTracks = Set<MusicTrack>.identity()..addAll(entry.tracks);
      final refreshed = removedTracks
          .where((track) => !currentTracks.contains(track))
          .toList();
      if (refreshed.isNotEmpty) {
        removedTracks.addAll(
          entry.tracks.where(
            (track) => refreshed.any((previous) => _sameTrack(previous, track)),
          ),
        );
      }
      final remaining = entry.tracks
          .where((track) => !removedTracks.contains(track))
          .toList();
      if (remaining.length == entry.tracks.length) return;
      if (remaining.isEmpty) {
        entries.removeAt(index);
      } else {
        entries[index] = PlaybackQueueEntry(
          id: entry.id,
          kind: entry.kind,
          title: entry.title,
          tracks: remaining,
          workRootPath: entry.workRootPath,
        );
        mapOffset = (currentEntry, offset) {
          if (currentEntry.id != entryId) return offset;
          if (removedTracks.contains(currentEntry.tracks[offset])) return null;
          return currentEntry.tracks
              .take(offset)
              .where((track) => !removedTracks.contains(track))
              .length;
        };
      }
    }
    _replacePlaybackQueueEntries(session, entries, mapOffset: mapOffset);
    _publishQueueReferencesChanged();
    await _synchronizePlaybackQueueSession?.call(session, selectFirst: false);
    _notifySessionStateChanged(session);
    scheduleSessionStatePersistence(sessionId: session.id);
  }

  Future<void> reorderPlaybackQueueEntry(
    String sessionId,
    int oldIndex,
    int newIndex,
  ) async {
    final session = _service.sessions[sessionId];
    if (session == null) return;
    if (session.queueLoadingRequired &&
        !await ensureSessionQueueLoaded(sessionId)) {
      return;
    }
    final queue = session.playbackQueue;
    if (queue == null) return;
    if (oldIndex < newIndex) newIndex -= 1;
    final entries = queue.entries.toList();
    if (oldIndex < 0 ||
        oldIndex >= entries.length ||
        newIndex < 0 ||
        newIndex > entries.length) {
      return;
    }
    final item = entries.removeAt(oldIndex);
    entries.insert(newIndex, item);
    if (oldIndex == newIndex) return;
    _replacePlaybackQueueEntries(session, entries);
    _notifySessionStateChanged(session);
    await _synchronizePlaybackQueueSession?.call(session, selectFirst: false);
    scheduleSessionStatePersistence(sessionId: session.id);
  }

  String _nextQueueEntryId() =>
      'queue_entry_${DateTime.now().microsecondsSinceEpoch}_${_random.nextInt(1 << 20)}';

  bool renamePlaybackQueue(String sessionId, String name) {
    final session = _service.sessions[sessionId];
    final queue = session?.playbackQueue;
    final trimmed = name.trim();
    if (session == null || queue == null || trimmed.isEmpty) return false;
    if (queue.name == trimmed) return true;
    session.playbackQueue = queue.copyWith(name: trimmed);
    scheduleSessionStatePersistence(sessionId: session.id);
    publishSessionState(session.id);
    return true;
  }

  bool setPlaybackQueueColorValue(String sessionId, int? colorValue) {
    final session = _service.sessions[sessionId];
    final queue = session?.playbackQueue;
    if (session == null || queue == null) return false;
    if (queue.colorValue == colorValue) return true;
    session.playbackQueue = queue.copyWith(
      colorValue: colorValue,
      clearColor: colorValue == null,
    );
    scheduleSessionStatePersistence(sessionId: session.id);
    publishSessionState(session.id);
    return true;
  }

  void _publishQueueReferencesChanged() {
    _service.markSessionStateDirty();
    _emitPersistedUriReferenceRevision();
  }

  bool replaceSessionTrackSnapshots(MusicTrack updatedTrack) {
    var changed = false;
    for (final session in _service.sessions.values) {
      var sessionChanged = false;
      final customQueueTracks = session.customQueueTracks;
      if (customQueueTracks != null) {
        List<MusicTrack>? nextCustomTracks;
        for (var i = 0; i < customQueueTracks.length; i++) {
          if (!PathMatcher.equalsNormalized(
            customQueueTracks[i].path,
            updatedTrack.path,
          )) {
            continue;
          }
          nextCustomTracks ??= List<MusicTrack>.of(customQueueTracks);
          nextCustomTracks[i] = updatedTrack;
        }
        if (nextCustomTracks != null) {
          session.customQueueTracks = List<MusicTrack>.unmodifiable(
            nextCustomTracks,
          );
          changed = true;
          sessionChanged = true;
        }
      }
      final queue = session.playbackQueue;
      if (queue == null) {
        if (sessionChanged) {
          _notifySessionStateChanged(session);
          scheduleSessionStatePersistence(sessionId: session.id);
        }
        continue;
      }
      List<PlaybackQueueEntry>? nextEntries;
      for (var entryIndex = 0; entryIndex < queue.entries.length; entryIndex++) {
        final entry = queue.entries[entryIndex];
        List<MusicTrack>? nextEntryTracks;
        for (
          var trackIndex = 0;
          trackIndex < entry.tracks.length;
          trackIndex++
        ) {
          if (!PathMatcher.equalsNormalized(
            entry.tracks[trackIndex].path,
            updatedTrack.path,
          )) {
            continue;
          }
          nextEntryTracks ??= List<MusicTrack>.of(entry.tracks);
          nextEntryTracks[trackIndex] = updatedTrack;
        }
        if (nextEntryTracks == null) continue;
        nextEntries ??= List<PlaybackQueueEntry>.of(queue.entries);
        nextEntries[entryIndex] = PlaybackQueueEntry(
          id: entry.id,
          kind: entry.kind,
          title: entry.kind == PlaybackQueueEntryKind.track
              ? updatedTrack.displayName
              : entry.title,
          tracks: List<MusicTrack>.unmodifiable(nextEntryTracks),
          workRootPath: entry.workRootPath,
        );
      }
      if (nextEntries != null) {
        session.playbackQueue = queue.copyWith(
          entries: List<PlaybackQueueEntry>.unmodifiable(nextEntries),
        );
        sessionChanged = true;
        changed = true;
      }
      if (sessionChanged) {
        _notifySessionStateChanged(session);
        scheduleSessionStatePersistence(sessionId: session.id);
      }
    }
    return changed;
  }

  void _rebuildRetargetedPathIndexes() {
    _retargetedForwardIndex.clear();
    _retargetedReverseIndex.clear();
    var hasNonRemoteSources = false;
    for (final entry in _retargetedPathAliases.entries) {
      final source = entry.key;
      final target = entry.value;
      final pair = (source: source, target: target);
      _retargetedForwardIndex[PathMatcher.equivalenceKey(source)] = pair;
      if (!PathMatcher.equalsNormalized(source, target)) {
        if (!PathMatcher.isRemoteUri(source)) {
          hasNonRemoteSources = true;
        }
        _retargetedReverseIndex.putIfAbsent(
          PathMatcher.equivalenceKey(target),
          () => pair,
        );
      }
    }
    _hasNonRemoteRetargetSources = hasNonRemoteSources;
  }

  void rememberRetargetedPath(String oldPath, String newPath) {
    final normalizedOldPath = PathMatcher.normalize(oldPath);
    final normalizedNewPath = PathMatcher.normalize(newPath);
    if (PathMatcher.equalsNormalized(normalizedOldPath, normalizedNewPath)) {
      return;
    }
    final oldKey = PathMatcher.equivalenceKey(normalizedOldPath);
    final newKey = PathMatcher.equivalenceKey(normalizedNewPath);
    if (PathMatcher.isRemoteUri(normalizedOldPath) &&
        !_hasNonRemoteRetargetSources &&
        !_retargetedForwardIndex.containsKey(oldKey) &&
        !_retargetedReverseIndex.containsKey(oldKey) &&
        !_retargetedForwardIndex.containsKey(newKey) &&
        !_retargetedReverseIndex.containsKey(newKey)) {
      // Disjoint remote-to-local playback cache aliases cannot intersect any
      // existing alias prefix, so update the forward and reverse indexes in O(1).
      _retargetedPathAliases[normalizedOldPath] = normalizedNewPath;
      _retargetedPathAliases[normalizedNewPath] = normalizedNewPath;
      final pair = (source: normalizedOldPath, target: normalizedNewPath);
      _retargetedForwardIndex[oldKey] = pair;
      _retargetedForwardIndex[newKey] = (
        source: normalizedNewPath,
        target: normalizedNewPath,
      );
      _retargetedReverseIndex[newKey] = pair;
      _retargetRevision++;
      return;
    }
    final aliases = <String, String>{};
    for (final entry in _retargetedPathAliases.entries) {
      aliases[entry.key] = PathMatcher.replaceWithinOrEqual(
        entry.value,
        normalizedOldPath,
        normalizedNewPath,
      );
      // A directory alias also owns historical paths of children renamed later.
      if (PathMatcher.isWithinOrEqual(normalizedOldPath, entry.value)) {
        final historicalPath = PathMatcher.replaceWithinOrEqual(
          normalizedOldPath,
          entry.value,
          entry.key,
        );
        aliases[historicalPath] = normalizedNewPath;
      }
    }
    aliases.removeWhere(
      (source, _) => PathMatcher.isWithinOrEqual(source, normalizedNewPath),
    );
    aliases[normalizedOldPath] = normalizedNewPath;
    // A reused destination must shadow aliases of its former parent directory.
    aliases[normalizedNewPath] = normalizedNewPath;
    _retargetedPathAliases
      ..clear()
      ..addAll(aliases);
    _rebuildRetargetedPathIndexes();
    _retargetRevision++;
  }

  String resolveRetargetedPath(String value) {
    if (value.isEmpty || _retargetedPathAliases.isEmpty) {
      return PathMatcher.normalize(value);
    }
    final current = PathMatcher.normalize(value);
    final exact = _retargetedForwardIndex[PathMatcher.equivalenceKey(current)];
    if (exact != null) return exact.target;
    if (PathMatcher.isRemoteUri(current) || !_hasNonRemoteRetargetSources) {
      return current;
    }
    if (!PathMatcher.isContentUri(current)) {
      var ancestor = PathMatcher.parentPath(current);
      while (ancestor != null) {
        final match =
            _retargetedForwardIndex[PathMatcher.equivalenceKey(ancestor)];
        if (match != null) {
          return PathMatcher.normalize(
            PathMatcher.replaceWithinOrEqual(
              current,
              match.source,
              match.target,
            ),
          );
        }
        ancestor = PathMatcher.parentPath(ancestor);
      }
      return current;
    }
    String? bestMatch;
    String? nextValue;
    for (final entry in _retargetedPathAliases.entries) {
      if (!PathMatcher.isWithinOrEqualNormalized(current, entry.key)) continue;
      if (bestMatch == null || entry.key.length > bestMatch.length) {
        bestMatch = entry.key;
        nextValue = entry.value;
      }
    }
    if (bestMatch == null || nextValue == null) return current;
    return PathMatcher.normalize(
      PathMatcher.replaceWithinOrEqual(current, bestMatch, nextValue),
    );
  }

  String? originalPathForRetargeted(String value) {
    if (value.isEmpty || _retargetedPathAliases.isEmpty) return null;
    final current = PathMatcher.normalize(value);
    final exact = _retargetedReverseIndex[PathMatcher.equivalenceKey(current)];
    if (exact != null) return exact.source;
    if (PathMatcher.isRemoteUri(current) || !_hasNonRemoteRetargetSources) {
      return null;
    }
    if (!PathMatcher.isContentUri(current)) {
      var ancestor = PathMatcher.parentPath(current);
      while (ancestor != null) {
        final match =
            _retargetedReverseIndex[PathMatcher.equivalenceKey(ancestor)];
        if (match != null && !PathMatcher.isRemoteUri(match.source)) {
          return PathMatcher.normalize(
            PathMatcher.replaceWithinOrEqual(
              current,
              match.target,
              match.source,
            ),
          );
        }
        ancestor = PathMatcher.parentPath(ancestor);
      }
      return null;
    }
    String? bestMatch;
    String? nextValue;
    for (final entry in _retargetedPathAliases.entries) {
      if (PathMatcher.equalsNormalized(entry.key, entry.value) ||
          !PathMatcher.isWithinOrEqualNormalized(current, entry.value)) {
        continue;
      }
      if (bestMatch == null || entry.value.length > bestMatch.length) {
        bestMatch = entry.value;
        nextValue = entry.key;
      }
    }
    if (bestMatch == null || nextValue == null) return null;
    return PathMatcher.normalize(
      PathMatcher.replaceWithinOrEqual(current, bestMatch, nextValue),
    );
  }

  Future<void> validatePlaybackCachePaths(Iterable<String> paths) async {
    if (_retargetedPathAliases.isEmpty) return;
    final sources = <String>{};
    for (final value in paths) {
      final source = PathMatcher.isRemoteUri(value)
          ? PathMatcher.normalize(value)
          : originalPathForRetargeted(value);
      if (source != null && PathMatcher.isRemoteUri(source)) {
        sources.add(source);
      }
    }
    var removedAny = false;
    for (final source in sources) {
      final cached = resolveRetargetedPath(source);
      if (cached.contains('://')) continue;
      try {
        if (await File(cached).length() > 0) continue;
      } on PathNotFoundException {
        // Temporary playback files may have been evicted since alias creation.
      }
      if (_retargetedPathAliases[source] != cached) continue;
      _retargetedPathAliases.remove(source);
      if (_retargetedPathAliases[cached] == cached &&
          !_retargetedPathAliases.entries.any(
            (entry) => entry.key != cached && entry.value == cached,
          )) {
        _retargetedPathAliases.remove(cached);
      }
      removedAny = true;
      _retargetRevision++;
    }
    if (removedAny) {
      _rebuildRetargetedPathIndexes();
    }
  }

  void clearRetargetedPaths() {
    if (_retargetedPathAliases.isEmpty) return;
    _retargetedPathAliases.clear();
    _retargetedForwardIndex.clear();
    _retargetedReverseIndex.clear();
    _hasNonRemoteRetargetSources = false;
    _retargetRevision++;
  }

  Future<void> retargetPath(String oldPath, String newPath) async {
    rememberRetargetedPath(oldPath, newPath);
    final storage = databaseRepository;
    if (storage is PlaybackQueueStorage &&
        _service.sessions.values.any(
          (session) => session.queueLoadingRequired,
        )) {
      final ids = await (storage as PlaybackQueueStorage)
          .findQueuesReferencingPath(oldPath);
      for (final id in ids) {
        await ensureSessionQueueLoaded(id);
      }
    }
    var changed = false;
    final sessionsToReload =
        <({PlaybackSession session, int generation, bool autoPlay})>[];
    final sessionsToSyncQueue = <PlaybackSession>[];
    var retargetedTracks = 0;
    MusicTrack retargetTrack(MusicTrack track) {
      if (!PathMatcher.isWithinOrEqual(track.path, oldPath)) return track;
      changed = true;
      retargetedTracks++;
      final nextPath = PathMatcher.replaceWithinOrEqual(
        track.path,
        oldPath,
        newPath,
      );
      final resolved = _persistedTrackResolver?.call(nextPath);
      if (resolved != null) return resolved;
      final groupKey = PathMatcher.replaceWithinOrEqual(
        track.groupKey,
        oldPath,
        newPath,
      );
      String? retargetNullable(String? value) => value == null
          ? null
          : PathMatcher.replaceWithinOrEqual(value, oldPath, newPath);
      return MusicTrack(
        path: nextPath,
        displayName: PathMatcher.equalsNormalized(track.path, oldPath)
            ? PathDisplay.fileName(newPath)
            : track.displayName,
        groupKey: groupKey,
        groupTitle: groupKey != track.groupKey
            ? PathDisplay.folderName(groupKey)
            : track.groupTitle,
        groupSubtitle: groupKey != track.groupKey
            ? PathDisplay.displayPathFor(groupKey)
            : track.groupSubtitle,
        isSingle: track.isSingle,
        isVideo: track.isVideo,
        scannedAt: track.scannedAt,
        fileSizeBytes: track.fileSizeBytes,
        modifiedAt: track.modifiedAt,
        lastPlayedPosition: track.lastPlayedPosition,
        lastPlayedAt: track.lastPlayedAt,
        isFavorite: track.isFavorite,
        tags: track.tags,
        coverCachePath: retargetNullable(track.coverCachePath),
        lyricsPath: retargetNullable(track.lyricsPath),
        manualCoverPath: retargetNullable(track.manualCoverPath),
        remoteCoverUrl: track.remoteCoverUrl,
        remoteMetadataKind: track.remoteMetadataKind,
        remoteMetadata: track.remoteMetadata,
        duration: track.duration,
      );
    }

    for (final session in _service.sessions.values) {
      final playbackRequested = session.playbackRequested;
      final wasPreparing =
          session.isLoading ||
          session.isPlaybackStarting ||
          session.pendingNativeTrackPath != null;
      final previousQueueVersion = session.queueVersion;
      final previousRetargetedTracks = retargetedTracks;
      final customTracks = session.customQueueTracks;
      if (customTracks != null) {
        List<MusicTrack>? nextCustomTracks;
        for (var i = 0; i < customTracks.length; i++) {
          final track = customTracks[i];
          final retargeted = retargetTrack(track);
          if (identical(retargeted, track)) continue;
          nextCustomTracks ??= List<MusicTrack>.of(customTracks);
          nextCustomTracks[i] = retargeted;
        }
        if (nextCustomTracks != null) {
          session.customQueueTracks = List<MusicTrack>.unmodifiable(
            nextCustomTracks,
          );
        }
      }
      final queue = session.playbackQueue;
      if (queue != null) {
        List<PlaybackQueueEntry>? nextEntries;
        for (
          var entryIndex = 0;
          entryIndex < queue.entries.length;
          entryIndex++
        ) {
          final entry = queue.entries[entryIndex];
          List<MusicTrack>? nextEntryTracks;
          for (
            var trackIndex = 0;
            trackIndex < entry.tracks.length;
            trackIndex++
          ) {
            final track = entry.tracks[trackIndex];
            final retargeted = retargetTrack(track);
            if (identical(retargeted, track)) continue;
            nextEntryTracks ??= List<MusicTrack>.of(entry.tracks);
            nextEntryTracks[trackIndex] = retargeted;
          }
          final oldRoot = entry.workRootPath;
          final root = oldRoot == null
              ? null
              : PathMatcher.replaceWithinOrEqual(oldRoot, oldPath, newPath);
          final rootChanged = root != oldRoot;
          if (!rootChanged && nextEntryTracks == null) continue;
          changed = true;
          final tracks = nextEntryTracks == null
              ? entry.tracks
              : List<MusicTrack>.unmodifiable(nextEntryTracks);
          nextEntries ??= List<PlaybackQueueEntry>.of(queue.entries);
          nextEntries[entryIndex] = PlaybackQueueEntry(
            id: entry.id,
            kind: entry.kind,
            title:
                entry.kind == PlaybackQueueEntryKind.track && tracks.isNotEmpty
                ? tracks.first.displayName
                : rootChanged
                ? PathDisplay.folderName(root!)
                : entry.title,
            tracks: tracks,
            workRootPath: root,
          );
        }
        if (nextEntries != null) {
          session.playbackQueue = queue.copyWith(
            entries: List<PlaybackQueueEntry>.unmodifiable(nextEntries),
          );
        }
      }
      final currentTrackRetargeted = PathMatcher.isWithinOrEqual(
        session.currentTrackPath,
        oldPath,
      );
      if (currentTrackRetargeted) {
        session.currentTrackPath = PathMatcher.replaceWithinOrEqual(
          session.currentTrackPath,
          oldPath,
          newPath,
        );
        changed = true;
      }
      final loadedPath = session.loadedPath;
      final loadedPathRetargeted =
          loadedPath != null &&
          PathMatcher.isWithinOrEqual(loadedPath, oldPath);
      if (!currentTrackRetargeted &&
          !loadedPathRetargeted &&
          session.queueVersion == previousQueueVersion) {
        continue;
      }
      session.invalidatePreparation();
      if (loadedPathRetargeted || (wasPreparing && playbackRequested)) {
        // Keep the old loaded path until the native player is prepared with
        // the new file. This makes the preparation path detect a real source
        // change instead of treating the stale ExoPlayer item as current.
        sessionsToReload.add((
          session: session,
          generation: session.loadGeneration,
          autoPlay: playbackRequested,
        ));
        changed = true;
      } else if (loadedPath != null &&
          retargetedTracks != previousRetargetedTracks) {
        sessionsToSyncQueue.add(session);
      }
    }
    if (!changed) return;
    String retargetResumePath(String path) =>
        PathMatcher.replaceWithinOrEqual(path, oldPath, newPath);
    _resumeRetryTargets.updateAll((_, path) => retargetResumePath(path));
    final retargetedBatch = _resumeBatch.map(
      (id, path) => MapEntry(id, retargetResumePath(path)),
    );
    final resumeBatchChanged = !mapEquals(_resumeBatch, retargetedBatch);
    if (resumeBatchChanged) _resumeBatch = retargetedBatch;
    _service.markActiveSessionsDirty();
    _notifySessionStateChanged();
    final current = _service.state;
    _service.syncSlice(
      activeSessions: _service.activeSessions,
      playingSessionCount: _service.playingSessionCount,
      focusedSessionId: current.focusedSessionId,
      coverGeneration: current.coverGeneration,
      isInitialized: current.isInitialized,
    );
    final commandPort = _commandPort;
    final retargetTasks = <Future<void>>[];
    if (commandPort != null) {
      for (final request in sessionsToReload) {
        final session = request.session;
        retargetTasks.add(
          _service.enqueueSessionPreparation(session.id, () async {
            if (!isRegisteredSession(session) ||
                session.loadGeneration != request.generation) {
              return;
            }
            await commandPort.prepareSession(
              session,
              nextPath: session.currentTrackPath,
              autoPlay: request.autoPlay,
              showLoading: false,
              targetQueueIndex: session.currentQueueIndex,
            );
          }),
        );
      }
    }
    for (final session in sessionsToSyncQueue) {
      if (!isRegisteredSession(session)) continue;
      final task = _synchronizeLoopMode?.call(session, session.loopMode);
      if (task != null) retargetTasks.add(task);
    }
    await Future.wait(retargetTasks);
    await savePersistedState();
    if (resumeBatchChanged && identical(_resumeBatch, retargetedBatch)) {
      await _setResumeBatch(retargetedBatch);
    }
  }

  bool _sameTrack(MusicTrack first, MusicTrack second) {
    if (first.isRemoteAsmr && second.isRemoteAsmr) {
      final workId = first.remoteMetadata?['id'];
      final stableKey = first.remoteMetadata?['trackStableKey'];
      final otherStableKey = second.remoteMetadata?['trackStableKey'];
      if (workId != null &&
          stableKey is String &&
          stableKey.isNotEmpty &&
          otherStableKey is String &&
          otherStableKey.isNotEmpty) {
        return workId == second.remoteMetadata?['id'] &&
            stableKey == otherStableKey;
      }
      final relativePath = first.remoteMetadata?['trackRelativePath'];
      if (workId != null && relativePath is String && relativePath.isNotEmpty) {
        return workId == second.remoteMetadata?['id'] &&
            relativePath == second.remoteMetadata?['trackRelativePath'];
      }
    }
    return PathMatcher.equalsNormalized(first.path, second.path);
  }

  bool _matchesCurrentTrack(PlaybackSession session, MusicTrack track) {
    if (PathMatcher.equalsNormalized(session.currentTrackPath, track.path)) {
      return true;
    }
    final current = session.customQueueTracks
        ?.where(
          (item) =>
              PathMatcher.equalsNormalized(item.path, session.currentTrackPath),
        )
        .firstOrNull;
    return current != null && _sameTrack(current, track);
  }

  Future<bool> playDirect(
    FutureOr<List<MusicTrack>> tracks, {
    int startIndex = 0,
    SessionLoopMode loopMode = SessionLoopMode.folderSequential,
  }) async {
    final revision = ++_directPlayRevision;
    _directPlaybackSession?.invalidatePreparation();
    final List<MusicTrack> resolvedTracks;
    try {
      resolvedTracks = tracks is List<MusicTrack> ? tracks : await tracks;
    } catch (_) {
      if (revision != _directPlayRevision) return false;
      rethrow;
    }
    if (revision != _directPlayRevision || resolvedTracks.isEmpty) return false;
    final index = startIndex.clamp(0, resolvedTracks.length - 1);
    final track = resolvedTracks[index];
    final queueTracks = immutableList(resolvedTracks);
    final session =
        _service.sessions.values
            .where(
              (candidate) =>
                  candidate.isTemporary &&
                  !_removingMissingTemporarySessionIds.contains(candidate.id),
            )
            .firstOrNull ??
        createTrackSession(
          track,
          loopMode: loopMode,
          customQueueTracks: queueTracks,
          isTemporary: true,
        );
    _directPlaybackSession = session;
    session.customQueueTracks = queueTracks;
    session.loopMode = loopMode;
    session.nonSingleLoopMode = loopMode == SessionLoopMode.single
        ? SessionLoopMode.folderSequential
        : loopMode;
    session.currentQueueIndex = index;
    session.clearNativePlaybackQueueCache();
    session.lastPlayedAt = DateTime.now();
    _service.markActiveSessionsDirty();
    publishSessionActivated(session.id);
    final prepared = await _commandPort?.prepareSession(
      session,
      nextPath: track.path,
      targetQueueIndex: index,
    );
    final current = revision == _directPlayRevision && (prepared ?? true);
    if (current) scheduleSessionStatePersistence(sessionId: session.id);
    return current;
  }

  Future<bool> addTrackToPlaylist(
    MusicTrack track, {
    List<MusicTrack>? workTracks,
  }) async {
    final existing = _service.sessions.values
        .where(
          (session) =>
              !session.isTemporary &&
              !session.isPlaybackQueue &&
              _matchesCurrentTrack(session, track),
        )
        .firstOrNull;
    if (existing != null) return false;
    createTrackSession(
      track,
      customQueueTracks: workTracks == null
          ? (track.isRemoteAsmr ? [track] : null)
          : List<MusicTrack>.unmodifiable(workTracks),
    );
    return true;
  }

  Future<bool> launchQueue(
    List<MusicTrack> tracks, {
    bool? autoPlay,
    required SessionLoopMode loopMode,
  }) {
    return spawnSessionWithQueue(
      tracks,
      autoPlay: autoPlay,
      loopMode: loopMode,
    );
  }

  Future<bool> spawnSession(MusicTrack track, {bool? autoPlay}) async {
    final session = createTrackSession(track);
    final shouldAutoPlay = autoPlay ?? false;
    if (shouldAutoPlay) {
      unawaited(_enqueueSessionPreparation(session, nextPath: track.path));
    }
    publishSessionActivated(session.id);
    return true;
  }

  Future<bool> spawnSessionWithQueue(
    List<MusicTrack> tracks, {
    int startIndex = 0,
    bool? autoPlay,
    SessionLoopMode loopMode = SessionLoopMode.folderSequential,
  }) async {
    if (tracks.isEmpty) return false;
    final clampedStartIndex = startIndex.clamp(0, tracks.length - 1);
    final startTrack = tracks[clampedStartIndex];
    final session = createTrackSession(
      startTrack,
      loopMode: loopMode,
      customQueueTracks: List<MusicTrack>.unmodifiable(tracks),
    );
    final shouldAutoPlay = autoPlay ?? false;
    if (shouldAutoPlay) {
      unawaited(_enqueueSessionPreparation(session, nextPath: startTrack.path));
    }
    publishSessionActivated(session.id);
    return true;
  }

  Future<void> _enqueueSessionPreparation(
    PlaybackSession session, {
    required String nextPath,
  }) {
    session.invalidatePreparation();
    final generation = session.loadGeneration;
    return _service.enqueueSessionPreparation(session.id, () async {
      if (!isRegisteredSession(session) ||
          session.loadGeneration != generation) {
        return;
      }
      await _commandPort?.prepareSession(session, nextPath: nextPath);
    });
  }
}
