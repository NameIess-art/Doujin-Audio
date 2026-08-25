part of 'playback_facade.dart';

extension PlaybackQueuePathCoordinator on PlaybackFacade {
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
  ) async {
    final session = _service.sessions[sessionId];
    final queue = session?.playbackQueue;
    if (session == null || queue == null) return;
    final wasEmpty = queue.expandedTracks.isEmpty;
    session.playbackQueue = queue.copyWith(
      entries: List<PlaybackQueueEntry>.unmodifiable(<PlaybackQueueEntry>[
        ...queue.entries,
        entry,
      ]),
    );
    _service.markActiveSessionsDirty();
    _onSessionStateChanged?.call();
    _scheduleNewSessionPersistence();
    await _synchronizePlaybackQueueSession?.call(
      session,
      selectFirst: wasEmpty,
    );
    _service.markActiveSessionsDirty();
    _onSessionStateChanged?.call();
    publishSessionActivated(session.id);
  }

  Future<void> removePlaybackQueueEntry(
    String sessionId,
    String entryId,
  ) async {
    final session = _service.sessions[sessionId];
    final queue = session?.playbackQueue;
    if (session == null || queue == null) return;
    final entries = queue.entries
        .where((entry) => entry.id != entryId)
        .toList(growable: false);
    if (entries.length == queue.entries.length) return;
    session.playbackQueue = queue.copyWith(entries: entries);
    await _synchronizePlaybackQueueSession?.call(session, selectFirst: false);
    _service.markActiveSessionsDirty();
    _onSessionStateChanged?.call();
    _scheduleNewSessionPersistence();
  }

  Future<void> reorderPlaybackQueueEntry(
    String sessionId,
    int oldIndex,
    int newIndex,
  ) async {
    final session = _service.sessions[sessionId];
    final queue = session?.playbackQueue;
    if (session == null || queue == null) return;
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
    session.playbackQueue = queue.copyWith(entries: entries);
    await _synchronizePlaybackQueueSession?.call(session, selectFirst: false);
    _service.markActiveSessionsDirty();
    _onSessionStateChanged?.call();
    await databaseRepository.updatePlaybackQueueEntryOrder(
      session.id,
      entries.map((entry) => entry.id).toList(growable: false),
    );
  }

  String _nextQueueEntryId() =>
      'queue_entry_${DateTime.now().microsecondsSinceEpoch}_${_random.nextInt(1 << 20)}';

  bool renamePlaybackQueue(String sessionId, String name) {
    final session = _service.sessions[sessionId];
    final queue = session?.playbackQueue;
    final trimmed = name.trim();
    if (session == null || queue == null || trimmed.isEmpty) return false;
    session.playbackQueue = queue.copyWith(name: trimmed);
    _service.markActiveSessionsDirty();
    scheduleSessionStatePersistence();
    _onSessionStateChanged?.call();
    return true;
  }

  bool setPlaybackQueueColorValue(String sessionId, int? colorValue) {
    final session = _service.sessions[sessionId];
    final queue = session?.playbackQueue;
    if (session == null || queue == null) return false;
    session.playbackQueue = queue.copyWith(
      colorValue: colorValue,
      clearColor: colorValue == null,
    );
    _service.markActiveSessionsDirty();
    scheduleSessionStatePersistence();
    _onSessionStateChanged?.call();
    return true;
  }

  bool replaceSessionTrackSnapshots(MusicTrack updatedTrack) {
    var changed = false;
    for (final session in _service.sessions.values) {
      final customQueueTracks = session.customQueueTracks;
      if (customQueueTracks != null) {
        var customQueueChanged = false;
        final tracks = customQueueTracks
            .map((track) {
              if (!PathMatcher.equalsNormalized(
                track.path,
                updatedTrack.path,
              )) {
                return track;
              }
              customQueueChanged = true;
              return updatedTrack;
            })
            .toList(growable: false);
        if (customQueueChanged) {
          session.customQueueTracks = List<MusicTrack>.unmodifiable(tracks);
          changed = true;
        }
      }
      final queue = session.playbackQueue;
      if (queue == null) continue;
      var queueChanged = false;
      final entries = queue.entries
          .map((entry) {
            var entryChanged = false;
            final tracks = entry.tracks
                .map((track) {
                  if (!PathMatcher.equalsNormalized(
                    track.path,
                    updatedTrack.path,
                  )) {
                    return track;
                  }
                  entryChanged = true;
                  queueChanged = true;
                  return updatedTrack;
                })
                .toList(growable: false);
            if (!entryChanged) return entry;
            return PlaybackQueueEntry(
              id: entry.id,
              kind: entry.kind,
              title: entry.title,
              tracks: List<MusicTrack>.unmodifiable(tracks),
              workRootPath: entry.workRootPath,
            );
          })
          .toList(growable: false);
      if (!queueChanged) continue;
      session.playbackQueue = queue.copyWith(
        entries: List.unmodifiable(entries),
      );
      changed = true;
    }
    return changed;
  }

  void rememberRetargetedPath(String oldPath, String newPath) {
    final normalizedOldPath = PathMatcher.normalize(oldPath);
    final normalizedNewPath = PathMatcher.normalize(newPath);
    if (PathMatcher.equalsNormalized(normalizedOldPath, normalizedNewPath)) {
      return;
    }
    _retargetedPathAliases[normalizedOldPath] = normalizedNewPath;
  }

  String resolveRetargetedPath(String value) {
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
      if (bestMatch == null || nextValue == null) return current;
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

  void clearRetargetedPaths() => _retargetedPathAliases.clear();

  Future<void> retargetPath(String oldPath, String newPath) async {
    rememberRetargetedPath(oldPath, newPath);
    var changed = false;
    final sessionsToReload = <PlaybackSession>[];
    for (final session in _service.sessions.values) {
      if (PathMatcher.isWithinOrEqual(session.currentTrackPath, oldPath)) {
        session.currentTrackPath = PathMatcher.replaceWithinOrEqual(
          session.currentTrackPath,
          oldPath,
          newPath,
        );
        changed = true;
      }
      final loadedPath = session.loadedPath;
      if (loadedPath != null &&
          PathMatcher.isWithinOrEqual(loadedPath, oldPath)) {
        // Keep the old loaded path until the native player is prepared with
        // the new file. This makes the preparation path detect a real source
        // change instead of treating the stale ExoPlayer item as current.
        sessionsToReload.add(session);
        changed = true;
      }
    }
    if (!changed) return;
    _service.markActiveSessionsDirty();
    final current = _service.slice.state;
    _service.syncSlice(
      activeSessions: _service.activeSessions,
      playingSessionCount: _service.playingSessionCount,
      focusedSessionId: current.focusedSessionId,
      multiThreadPlaybackEnabled: current.multiThreadPlaybackEnabled,
      coverGeneration: current.coverGeneration,
      isInitialized: current.isInitialized,
    );
    final prepare = _prepareSession;
    if (prepare != null) {
      for (final session in sessionsToReload) {
        _service.enqueueSessionPreparation(() async {
          if (!isRegisteredSession(session)) return;
          await prepare(
            session,
            nextPath: session.currentTrackPath,
            autoPlay: session.effectivePlaying,
            forceStartAtZero: false,
            showLoading: false,
            targetQueueIndex: session.currentQueueIndex,
          );
        });
      }
      await _service.sessionPreparationQueue;
    }
    await savePersistedState();
  }

  Future<void> launchQueue(
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

  Future<void> spawnSession(MusicTrack track, {bool? autoPlay}) async {
    final matchingSessionIds = _matchingWorkSessionIds(track);
    if (matchingSessionIds.isNotEmpty) {
      final removed = await removeSessions(matchingSessionIds);
      if (!removed) return;
    }
    final session = createTrackSession(track);
    final shouldAutoPlay = autoPlay ?? _autoPlayAddedSessions();
    if (shouldAutoPlay) {
      unawaited(_enqueueSessionPreparation(session, nextPath: track.path));
    }
    publishSessionActivated(session.id);
  }

  Future<void> spawnSessionWithQueue(
    List<MusicTrack> tracks, {
    int startIndex = 0,
    bool? autoPlay,
    SessionLoopMode loopMode = SessionLoopMode.folderSequential,
  }) async {
    if (tracks.isEmpty) return;
    final clampedStartIndex = startIndex.clamp(0, tracks.length - 1);
    final startTrack = tracks[clampedStartIndex];
    final matchingSessionIds = _matchingWorkSessionIds(startTrack);
    if (matchingSessionIds.isNotEmpty) {
      final removed = await removeSessions(matchingSessionIds);
      if (!removed) return;
    }
    final session = createTrackSession(
      startTrack,
      loopMode: loopMode,
      customQueueTracks: List<MusicTrack>.unmodifiable(tracks),
    );
    final shouldAutoPlay = autoPlay ?? _autoPlayAddedSessions();
    if (shouldAutoPlay) {
      unawaited(_enqueueSessionPreparation(session, nextPath: startTrack.path));
    }
    publishSessionActivated(session.id);
  }

  List<String> _matchingWorkSessionIds(MusicTrack incomingTrack) {
    if (_allowDuplicateWorks()) return const <String>[];
    final incomingKey = _workKey(incomingTrack);
    return _service.sessions.values
        .where((session) {
          final representative = _representativeTrack(session);
          return representative != null &&
              _workKey(representative) == incomingKey;
        })
        .map((session) => session.id)
        .toList(growable: false);
  }

  MusicTrack? _representativeTrack(PlaybackSession session) {
    final queueTracks = session.customQueueTracks;
    if (queueTracks != null && queueTracks.isNotEmpty) {
      return queueTracks.first;
    }
    return _persistedTrackResolver?.call(session.currentTrackPath);
  }

  String _workKey(MusicTrack track) {
    if (track.isSingle || track.groupKey == '__single_files__') {
      return 'track:${PathMatcher.normalize(track.path)}';
    }
    final groupKey = PathMatcher.normalize(track.groupKey);
    return groupKey.isEmpty
        ? 'track:${PathMatcher.normalize(track.path)}'
        : 'group:$groupKey';
  }

  Future<void> _enqueueSessionPreparation(
    PlaybackSession session, {
    required String nextPath,
  }) {
    _service.enqueueSessionPreparation(() async {
      if (!_service.sessions.containsKey(session.id)) return;
      await _prepareSession?.call(session, nextPath: nextPath, autoPlay: true);
    });
    return _service.sessionPreparationQueue;
  }
}
