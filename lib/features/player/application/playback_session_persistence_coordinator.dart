part of 'playback_facade.dart';

extension PlaybackSessionPersistenceCoordinator on PlaybackFacade {
  void attachPersistenceRuntime({
    required MusicTrack? Function(String trackPath) trackByPath,
    required bool Function() recordPlaybackProgress,
    required RestoredPlaybackRuntime restoreRuntime,
    required PlaybackHistoryUpdater updatePlaybackHistory,
    required void Function(String? sessionId) onFocusChanged,
  }) {
    _persistedTrackResolver ??= trackByPath;
    _recordPlaybackProgress ??= recordPlaybackProgress;
    _restoreRuntime ??= restoreRuntime;
    _updatePlaybackHistory ??= updatePlaybackHistory;
    _onPersistenceFocusChanged ??= onFocusChanged;
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
      MusicTrack? track;
      if (customQueueTracks != null && customQueueTracks.isNotEmpty) {
        track = customQueueTracks.firstWhere(
          (candidate) =>
              PathMatcher.equalsNormalized(candidate.path, item.trackPath),
          orElse: () => customQueueTracks.first,
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
        state: PlayerState(false, ProcessingState.idle),
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
    _service.sessions.clear();
    _service.sessionOrder.clear();
    _service.markActiveSessionsDirty();
    for (final session in removedSessions) {
      session.isPlaybackStarting = false;
    }
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
    List<MusicTrack>? tracksToUpdate,
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
    if (tracksToUpdate != null &&
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
      if (updated != null) tracksToUpdate.add(updated);
    }
    return PersistedPlaybackSession(
      id: session.id,
      trackPath: session.currentTrackPath,
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
    _savePlaybackStateTimer?.cancel();
    _savePlaybackStateTimer = null;
    _pendingPlaybackStateSessionIds.clear();
    return _enqueueSessionPersistence(_savePersistedStateNow);
  }

  Future<void> _savePersistedStateNow() async {
    if (!_persistenceEnabled) return;
    final ordered = _service.sessionOrder
        .map((id) => _service.sessions[id])
        .whereType<PlaybackSession>()
        .toList(growable: false);
    final tracksToUpdate = <MusicTrack>[];
    final now = DateTime.now();
    final payload = ordered
        .asMap()
        .entries
        .map((entry) {
          return _persistedSessionSnapshot(
            entry.value,
            sortOrder: entry.key,
            now: now,
            tracksToUpdate: tracksToUpdate,
          );
        })
        .toList(growable: false);
    if (tracksToUpdate.isNotEmpty) {
      await databaseRepository.upsertTracks(tracksToUpdate);
    }
    await databaseRepository.saveAllSessions(payload);
  }

  Future<void> _savePendingPlaybackStates() async {
    if (!_persistenceEnabled || _pendingPlaybackStateSessionIds.isEmpty) {
      return;
    }
    final sessionIds = Set<String>.of(_pendingPlaybackStateSessionIds);
    _pendingPlaybackStateSessionIds.removeAll(sessionIds);
    final now = DateTime.now();
    final tracksToUpdate = <MusicTrack>[];
    final orderedIds = _service.sessionOrder;
    for (final sessionId in sessionIds) {
      final session = _service.sessions[sessionId];
      if (session == null) continue;
      final sortOrder = orderedIds.indexOf(sessionId);
      await databaseRepository.upsertSessionPlaybackState(
        _persistedSessionSnapshot(
          session,
          sortOrder: sortOrder < 0 ? orderedIds.length : sortOrder,
          now: now,
          tracksToUpdate: tracksToUpdate,
        ),
      );
    }
    if (tracksToUpdate.isNotEmpty) {
      await databaseRepository.upsertTracks(tracksToUpdate);
    }
  }

  Future<void> saveSessionOrder() async {
    if (!_persistenceEnabled) return;
    await databaseRepository.updateSessionOrder(
      _service.sessionOrder.toList(growable: false),
    );
    await AppPreferences.remove('session_order_v1');
  }

  void scheduleSessionStatePersistence({
    Duration delay = const Duration(milliseconds: 220),
  }) {
    if (!_persistenceEnabled) return;
    _savePlaybackStateTimer?.cancel();
    _savePlaybackStateTimer = null;
    _pendingPlaybackStateSessionIds.clear();
    _service.saveSessionStateTimer?.cancel();
    _service.saveSessionStateTimer = Timer(delay, () {
      _service.saveSessionStateTimer = null;
      unawaited(savePersistedState());
    });
  }

  void _scheduleSessionPlaybackStatePersistence(
    String sessionId, {
    Duration delay = const Duration(milliseconds: 800),
  }) {
    if (!_persistenceEnabled || _service.saveSessionStateTimer != null) return;
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
    _service.saveSessionOrderTimer?.cancel();
    _service.saveSessionOrderTimer = Timer(delay, () {
      _service.saveSessionOrderTimer = null;
      unawaited(saveSessionOrder());
    });
  }

  Future<void> flushSessionStatePersistence() async {
    _service.saveSessionStateTimer?.cancel();
    _service.saveSessionStateTimer = null;
    await savePersistedState();
  }

  void cancelScheduledPersistence() {
    _savePlaybackStateTimer?.cancel();
    _savePlaybackStateTimer = null;
    _pendingPlaybackStateSessionIds.clear();
    _service.saveSessionStateTimer?.cancel();
    _service.saveSessionStateTimer = null;
    _service.saveSessionOrderTimer?.cancel();
    _service.saveSessionOrderTimer = null;
  }
}
