part of 'playback_facade.dart';

extension PlaybackSessionPersistenceCoordinator on PlaybackFacade {
  int get positionBucketSeconds => _backgroundMode
      ? PlaybackFacade.backgroundPositionBucketSeconds
      : PlaybackFacade.foregroundPositionBucketSeconds;

  void setBackgroundMode(bool value) {
    if (_backgroundMode == value) return;
    if (value) {
      _savePlaybackStateTimer?.cancel();
      _savePlaybackStateTimer = null;
      if (_pendingPlaybackStateSessionIds.isNotEmpty) {
        unawaited(_enqueueSessionPersistence(_savePendingPlaybackStates));
      }
    }
    _backgroundMode = value;
    for (final session in _service.sessions.values) {
      session.lastPersistedPositionBucket =
          session.lastKnownPosition.inSeconds ~/ positionBucketSeconds;
    }
  }

  void _scheduleNewSessionPersistence({
    String? sessionId,
    bool respectConfiguration = true,
  }) {
    if (respectConfiguration && !_persistenceEnabled) return;
    scheduleSessionStatePersistence(sessionId: sessionId);
    scheduleSessionOrderPersistence();
  }

  void attachPersistenceRuntime({
    required MusicTrack? Function(String trackPath) trackByPath,
    required bool Function() recordPlaybackProgress,
    required RestoredPlaybackRuntime restoreRuntime,
    required PlaybackHistoryUpdater updatePlaybackHistory,
    required void Function(String? sessionId) onFocusChanged,
    Future<void> Function(PlaybackSession session)? synchronizePausedRecovery,
  }) {
    _persistedTrackResolver ??= trackByPath;
    _service.libraryTrackByPath ??= trackByPath;
    _recordPlaybackProgress ??= recordPlaybackProgress;
    _restoreRuntime ??= restoreRuntime;
    _updatePlaybackHistory ??= updatePlaybackHistory;
    _onPersistenceFocusChanged ??= onFocusChanged;
    _synchronizePausedRecovery ??= synchronizePausedRecovery;
  }

  void configurePersistence({required bool enabled}) {
    _persistenceEnabled = enabled;
    if (!enabled) cancelScheduledPersistence();
  }

  Future<void> loadPersistedState() async {
    final persistedSessions = await databaseRepository.loadAllSessions();
    if (persistedSessions.isEmpty) return;
    final legacyOrder = await AppPreferences.readJson<List<String>>(
      'session_order_v1',
      (value) => (value as List<dynamic>).cast<String>(),
    );
    final restoredSessions = <PlaybackSession>[];
    final recordProgress = _recordPlaybackProgress?.call() ?? true;

    for (final item in persistedSessions) {
      final customQueueTracks = item.customQueueTracks == null
          ? null
          : List<MusicTrack>.unmodifiable(item.customQueueTracks!);
      final queueTracks =
          customQueueTracks ?? item.playbackQueue?.expandedTracks;
      MusicTrack? track;
      if (queueTracks != null && queueTracks.isNotEmpty) {
        track = queueTracks.firstWhere(
          (candidate) =>
              PathMatcher.equalsNormalized(candidate.path, item.trackPath),
          orElse: () => queueTracks.first,
        );
      }
      track ??= _persistedTrackResolver?.call(item.trackPath);
      if (track == null && item.playbackQueue == null) continue;

      final loopMode =
          SessionLoopMode.values[item.loopModeIndex.clamp(
            0,
            SessionLoopMode.values.length - 1,
          )];
      final restoredPosition = Duration(
        milliseconds: max(0, recordProgress ? item.positionMs : 0),
      );
      final session = PlaybackSession(
        id: item.id,
        currentTrackPath: track?.path ?? '',
        isTemporary: item.isTemporary,
        loopMode: loopMode,
        nonSingleLoopMode: loopMode == SessionLoopMode.single
            ? (item.playbackQueue != null
                  ? SessionLoopMode.crossSequential
                  : SessionLoopMode.folderSequential)
            : loopMode,
        volume: item.volume.clamp(0.0, PlaybackFacade.maxSessionVolume),
        createdAt: item.createdAtMs == null
            ? DateTime.now()
            : DateTime.fromMillisecondsSinceEpoch(item.createdAtMs!),
        lastPlayedAt: item.lastPlayedAtMs == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(item.lastPlayedAtMs!),
        state: const PlayerState(false, ProcessingState.idle),
        customQueueTracks: customQueueTracks,
        playbackQueue: item.playbackQueue,
        currentQueueIndex: recordProgress ? item.currentQueueIndex : 0,
      );
      session
        ..lastKnownPosition = restoredPosition
        ..setOptimisticDuration(Duration(milliseconds: item.durationMs))
        ..lastPersistedPositionBucket =
            restoredPosition.inSeconds ~/ positionBucketSeconds
        ..channelSwapEnabled = item.channelSwapEnabled
        ..speed = nearestPlaybackSpeed(item.speed)
        ..audioEffects = item.audioEffects;
      _service.sessions[session.id] = session;
      _persistedSessions[session.id] = item;
      _persistedQueueVersions[session.id] = session.queueVersion;
      observeSession(session);
      restoredSessions.add(session);
    }

    final restoredIds = restoredSessions.map((session) => session.id).toSet();
    final orderedIds = (legacyOrder ?? const <String>[])
        .where(restoredIds.contains)
        .toList(growable: true);
    for (final session in restoredSessions) {
      if (!orderedIds.contains(session.id)) orderedIds.add(session.id);
    }
    _service.sessionOrder
      ..clear()
      ..addAll(orderedIds);
    _service.markActiveSessionsDirty();
    publishSessionState();
    final focusedSessionId = orderedIds.firstOrNull;
    _onPersistenceFocusChanged?.call(focusedSessionId);
    await _restoreRuntime?.call(
      restoredSessions,
      focusedSessionId: focusedSessionId,
    );
  }

  Future<void> resetPersistedState() async {
    cancelScheduledPersistence();
    final removedSessions = _service.sessions.values.toList(growable: false);
    _service.removeSessions(removedSessions.map((session) => session.id));
    _persistedSessions.clear();
    _persistedQueueVersions.clear();
    await Future.wait(removedSessions.map((session) => session.shutdown()));
    try {
      final response = await nativeRepository.clearAll();
      if (response.isOk) _clearNativeRetainedContentUris();
    } catch (error, stackTrace) {
      AppLogService.error(
        'playback_persisted_state_reset_clear_failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
    clearDeferredVolumeReloads();
    clearRetargetedPaths();
    _onPersistenceFocusChanged?.call(null);
  }

  PersistedPlaybackSession _persistedSessionSnapshot(
    PlaybackSession session, {
    required int sortOrder,
    required DateTime now,
    bool updateHistory = false,
  }) {
    final positionMs = max(
      0,
      max(
        session.position.inMilliseconds,
        session.lastKnownPosition.inMilliseconds,
      ),
    );
    final position = Duration(milliseconds: positionMs);
    final track = _persistedTrackResolver?.call(session.currentTrackPath);
    if (updateHistory &&
        track != null &&
        (track.lastPlayedPosition.inSeconds ~/ positionBucketSeconds !=
                position.inSeconds ~/ positionBucketSeconds ||
            session.state.playing)) {
      final updated = _updatePlaybackHistory?.call(
        trackPath: track.path,
        position: position,
        now: now,
        updatePlayedAt: session.state.playing,
      );
      if (updated != null) {
        _pendingPlaybackHistoryTracks[updated.path] = updated;
      }
    }
    return PersistedPlaybackSession(
      id: session.id,
      trackPath: session.currentTrackPath,
      isTemporary: session.isTemporary,
      loopModeIndex: session.loopMode.index,
      volume: session.volume,
      speed: session.speed,
      positionMs: positionMs,
      durationMs: session.duration?.inMilliseconds ?? 0,
      customQueueTracks: session.customQueueTracks,
      playbackQueue: session.playbackQueue,
      currentQueueIndex: session.currentQueueIndex,
      channelSwapEnabled: session.channelSwapEnabled,
      audioEffects: session.audioEffects,
      createdAtMs: session.createdAt.millisecondsSinceEpoch,
      updatedAtMs: now.millisecondsSinceEpoch,
      lastPlayedAtMs: session.lastPlayedAt?.millisecondsSinceEpoch,
      sortOrder: sortOrder,
    );
  }

  Future<void> _enqueueSessionPersistence(Future<void> Function() persist) {
    final previous = _sessionPersistenceTail;
    final result = previous == null
        ? Future<void>.sync(persist)
        : previous.then((_) => persist());
    _sessionPersistenceTail = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        AppLogService.error(
          'playback_session_persistence_failed',
          error: error,
          stackTrace: stackTrace,
        );
      },
    );
    return result;
  }

  Future<void> savePersistedState() {
    if (!_persistenceEnabled) return Future<void>.value();
    _pendingSessionDefinitionIds.addAll(_service.sessions.keys);
    _service.saveSessionStateTimer?.cancel();
    _service.saveSessionStateTimer = null;
    _savePlaybackStateTimer?.cancel();
    _savePlaybackStateTimer = null;
    _pendingPlaybackStateSessionIds.clear();
    return _enqueueSessionPersistence(_savePendingSessionDefinitions);
  }

  bool _sameSessionDefinition(
    PersistedPlaybackSession a,
    PersistedPlaybackSession b,
  ) =>
      (
        a.trackPath,
        a.isTemporary,
        a.loopModeIndex,
        a.volume,
        a.speed,
        a.positionMs,
        a.durationMs,
        a.currentQueueIndex,
        a.channelSwapEnabled,
        a.createdAtMs,
        a.lastPlayedAtMs,
      ) ==
      (
        b.trackPath,
        b.isTemporary,
        b.loopModeIndex,
        b.volume,
        b.speed,
        b.positionMs,
        b.durationMs,
        b.currentQueueIndex,
        b.channelSwapEnabled,
        b.createdAtMs,
        b.lastPlayedAtMs,
      );

  Future<void> _savePendingSessionDefinitions({
    String? ensurePausedRecoverySessionId,
  }) async {
    if (!_persistenceEnabled) return;
    final deletedIds = Set<String>.of(_pendingDeletedSessionIds);
    _pendingDeletedSessionIds.removeAll(deletedIds);
    final sessionIds = Set<String>.of(_pendingSessionDefinitionIds);
    _pendingSessionDefinitionIds.removeAll(sessionIds);
    final now = DateTime.now();
    try {
      if (deletedIds.isNotEmpty) {
        await databaseRepository.deleteSessions(deletedIds.toList());
        for (final id in deletedIds) {
          _persistedSessions.remove(id);
          _persistedQueueVersions.remove(id);
        }
      }
      for (final id in sessionIds) {
        final session = _service.sessions[id];
        if (session == null) continue;
        final queueVersion = session.queueVersion;
        final next = _persistedSessionSnapshot(
          session,
          sortOrder: _service.sessionOrder.indexOf(id),
          now: now,
        );
        final previous = _persistedSessions[id];
        final queueChanged = _persistedQueueVersions[id] != queueVersion;
        final effectsChanged = previous?.audioEffects != next.audioEffects;
        if (previous != null &&
            !queueChanged &&
            !effectsChanged &&
            _sameSessionDefinition(previous, next)) {
          if (id == ensurePausedRecoverySessionId) {
            await _savePausedRecovery(session);
          }
          continue;
        }
        await databaseRepository.upsertSession(
          next,
          includeQueue: queueChanged,
          includeEffects: effectsChanged,
        );
        await _savePausedRecovery(session);
        _persistedSessions[id] = next;
        _persistedQueueVersions[id] = queueVersion;
        _persistedSessionSnapshot(
          session,
          sortOrder: next.sortOrder,
          now: now,
          updateHistory: true,
        );
      }
    } catch (_) {
      _pendingDeletedSessionIds.addAll(deletedIds);
      _pendingSessionDefinitionIds.addAll(sessionIds);
      rethrow;
    }
    await _savePendingPlaybackHistory();
  }

  Future<void> _savePendingPlaybackStates() async {
    if (!_persistenceEnabled || _pendingPlaybackStateSessionIds.isEmpty) {
      return;
    }
    final sessionIds = Set<String>.of(_pendingPlaybackStateSessionIds);
    _pendingPlaybackStateSessionIds.removeAll(sessionIds);
    final now = DateTime.now();
    final orderedIds = _service.sessionOrder;
    try {
      for (final sessionId in sessionIds) {
        final session = _service.sessions[sessionId];
        if (session == null) continue;
        if (_pendingSessionDefinitionIds.contains(sessionId)) continue;
        final sortOrder = orderedIds.indexOf(sessionId);
        final next = _persistedSessionSnapshot(
          session,
          sortOrder: sortOrder < 0 ? orderedIds.length : sortOrder,
          now: now,
          updateHistory: true,
        );
        final previous = _persistedSessions[sessionId];
        if (previous == null ||
            _persistedQueueVersions[sessionId] != session.queueVersion ||
            previous.audioEffects != next.audioEffects ||
            (
                  previous.trackPath,
                  previous.isTemporary,
                  previous.loopModeIndex,
                  previous.createdAtMs,
                  previous.lastPlayedAtMs,
                ) !=
                (
                  next.trackPath,
                  next.isTemporary,
                  next.loopModeIndex,
                  next.createdAtMs,
                  next.lastPlayedAtMs,
                )) {
          _pendingSessionDefinitionIds.add(sessionId);
          continue;
        }
        if (_sameSessionDefinition(previous, next)) continue;
        await databaseRepository.upsertSessionPlaybackState(next);
        await _savePausedRecovery(session);
        _persistedSessions[sessionId] = next;
      }
      if (_pendingSessionDefinitionIds.isNotEmpty) {
        await _savePendingSessionDefinitions();
      }
      await _savePendingPlaybackHistory();
    } catch (_) {
      _pendingPlaybackStateSessionIds.addAll(sessionIds);
      rethrow;
    }
  }

  Future<void> _savePausedRecovery(PlaybackSession session) async {
    final synchronize = _synchronizePausedRecovery;
    if (synchronize == null) return;
    if (session.loadedPath == null &&
        !session.playbackRequested &&
        !session.effectivePlaying &&
        !session.isLoading) {
      // Keep the comparison cache unchanged until both stores commit, so an
      // existing pending ID also retries a failed native recovery write.
      await synchronize(session);
    }
  }

  Future<void> _savePendingPlaybackHistory() async {
    if (_pendingPlaybackHistoryTracks.isEmpty) return;
    final pending = Map<String, MusicTrack>.of(_pendingPlaybackHistoryTracks);
    final resolver = _persistedTrackResolver;
    final tracks = <MusicTrack>[
      for (final entry in pending.entries)
        if (resolver == null)
          entry.value
        else if (resolver(entry.key) case final track?)
          track.copyWith(
            lastPlayedPosition: entry.value.lastPlayedPosition,
            lastPlayedAt: entry.value.lastPlayedAt,
          ),
    ];
    if (tracks.isNotEmpty) {
      await databaseRepository.updateTrackPlaybackHistory(tracks);
    }
    for (final entry in pending.entries) {
      if (identical(_pendingPlaybackHistoryTracks[entry.key], entry.value)) {
        _pendingPlaybackHistoryTracks.remove(entry.key);
      }
    }
  }

  Future<void> saveSessionOrder() {
    if (!_persistenceEnabled) return Future<void>.value();
    _pendingSessionOrder = true;
    _service.saveSessionOrderTimer?.cancel();
    _service.saveSessionOrderTimer = null;
    return _enqueueSessionPersistence(_savePendingSessionOrder);
  }

  Future<void> _savePendingSessionOrder() async {
    if (!_persistenceEnabled || !_pendingSessionOrder) return;
    _pendingSessionOrder = false;
    try {
      await databaseRepository.updateSessionOrder(
        List<String>.of(_service.sessionOrder),
      );
      await AppPreferences.remove('session_order_v1');
    } catch (_) {
      _pendingSessionOrder = true;
      rethrow;
    }
  }

  void scheduleSessionStatePersistence({
    String? sessionId,
    Duration delay = const Duration(milliseconds: 220),
  }) {
    if (!_persistenceEnabled) return;
    if (sessionId == null) {
      _pendingSessionDefinitionIds.addAll(_service.sessions.keys);
    } else {
      _pendingSessionDefinitionIds.add(sessionId);
    }
    _service.saveSessionStateTimer?.cancel();
    _service.saveSessionStateTimer = Timer(delay, () {
      _service.saveSessionStateTimer = null;
      unawaited(_enqueueSessionPersistence(_savePendingSessionDefinitions));
    });
  }

  void _scheduleSessionPlaybackStatePersistence(
    String sessionId, {
    Duration delay = const Duration(milliseconds: 800),
  }) {
    if (!_persistenceEnabled ||
        _pendingSessionDefinitionIds.contains(sessionId) ||
        !_service.sessions.containsKey(sessionId)) {
      return;
    }
    _pendingPlaybackStateSessionIds.add(sessionId);
    _savePlaybackStateTimer?.cancel();
    _savePlaybackStateTimer = Timer(delay, () {
      _savePlaybackStateTimer = null;
      unawaited(_enqueueSessionPersistence(_savePendingPlaybackStates));
    });
  }

  void scheduleSessionOrderPersistence({
    Duration delay = const Duration(milliseconds: 180),
  }) {
    if (!_persistenceEnabled) return;
    _pendingSessionOrder = true;
    _service.saveSessionOrderTimer?.cancel();
    _service.saveSessionOrderTimer = Timer(delay, () {
      _service.saveSessionOrderTimer = null;
      unawaited(saveSessionOrder());
    });
  }

  Future<void> flushSessionStatePersistence({String? sessionId}) async {
    if (!_persistenceEnabled) return;
    _service.saveSessionStateTimer?.cancel();
    _service.saveSessionStateTimer = null;
    _service.saveSessionOrderTimer?.cancel();
    _service.saveSessionOrderTimer = null;
    if (sessionId == null) {
      _pendingSessionDefinitionIds.addAll(_service.sessions.keys);
    } else {
      _pendingSessionDefinitionIds.add(sessionId);
    }
    await _enqueueSessionPersistence(() async {
      await _savePendingSessionDefinitions(
        ensurePausedRecoverySessionId: sessionId,
      );
      await _savePendingPlaybackStates();
      await _savePendingSessionOrder();
    });
  }

  void cancelScheduledPersistence() {
    _savePlaybackStateTimer?.cancel();
    _savePlaybackStateTimer = null;
    _pendingPlaybackStateSessionIds.clear();
    _pendingSessionDefinitionIds.clear();
    _pendingDeletedSessionIds.clear();
    _pendingPlaybackHistoryTracks.clear();
    _pendingSessionOrder = false;
    _service.saveSessionStateTimer?.cancel();
    _service.saveSessionStateTimer = null;
    _service.saveSessionOrderTimer?.cancel();
    _service.saveSessionOrderTimer = null;
  }
}
