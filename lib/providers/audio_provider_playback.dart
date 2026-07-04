part of 'audio_provider.dart';

const PlaybackQueueResolver _playbackQueueResolver = PlaybackQueueResolver();
const TimerRuntimeCalculator _timerRuntimeCalculator = TimerRuntimeCalculator();
const double _maxSessionVolume = 2.0;

double _nearestPlaybackSpeed(double speed) {
  const options = AudioProvider.playbackSpeedOptions;
  return options.reduce((best, candidate) {
    final bestDistance = (best - speed).abs();
    final candidateDistance = (candidate - speed).abs();
    return candidateDistance < bestDistance ? candidate : best;
  });
}

String _folderKeyForTrack(MusicTrack track) {
  if (track.remoteMetadataKind == 'asmr.one' ||
      PathMatcher.isRemoteUri(track.path)) {
    final remotePath = track.remoteMetadata?['trackDirectoryPath']?.toString();
    if (remotePath != null && remotePath.isNotEmpty && remotePath != '.') {
      return '${track.groupKey}::$remotePath';
    }
  }
  return track.groupKey;
}

extension AudioProviderPlayback on AudioProvider {
  bool get _hasArmedTimerRuntime {
    return _timerRuntimeCalculator.hasArmedRuntime(
      mode: _timerMode,
      duration: _timerDuration,
      waitingForPlayback: _timerWaitingForPlayback,
      active: _timerActive,
      endsAt: _timerEndsAt,
      autoResumeAt: _autoResumeAt,
      hasPausedByTimerSessionIds: _pausedByTimerSessionIds.isNotEmpty,
    );
  }

  void _resetTimerRuntimeState({bool clearPausedSessions = true}) {
    _timerGeneration++;
    _countdownTimer?.cancel();
    _countdownTimer = null;
    _timerMode = null;
    _timerDuration = null;
    _timerActive = false;
    _timerRemaining = null;
    _timerEndsAt = null;
    _timerWaitingForPlayback = false;
    _autoResumeTimer?.cancel();
    _autoResumeTimer = null;
    _autoResumeAt = null;
    if (clearPausedSessions) {
      _pausedByTimerSessionIds.clear();
    }
    _applyFadeMultiplierToAllPlaying(1.0);
    unawaited(_syncNativeTimerAlarms());
  }

  Future<void> toggleSessionPlayPause(String sessionId) async {
    final session = _playbackService.sessionById(sessionId);
    if (session == null) return;
    if (session.currentTrackPath.isEmpty) return;

    if (session.playbackError != null || session.isLoading) {
      await _prepareAndPlay(
        session,
        nextPath: session.currentTrackPath,
      );
      return;
    }

    if (session.effectivePlaying) {
      await _pauseSessionPlayback(session);
    } else if (session.state.processingState == ProcessingState.completed ||
        session.state.processingState == ProcessingState.idle) {
      final isCompleted =
          session.state.processingState == ProcessingState.completed;
      await _prepareAndPlay(
        session,
        nextPath: session.currentTrackPath,
        forceStartAtZero: isCompleted,
      );
    } else {
      await _startSessionPlayback(session, shouldStartTriggerCountdown: true);
    }
  }

  Future<void> removeSession(String sessionId) async {
    await _removeSessions([sessionId]);
  }

  Future<void> _removeSessions(
    Iterable<String> sessionIds, {
    bool persist = true,
    bool notify = true,
  }) async {
    final removedSessions = _playbackService.removeSessions(sessionIds);
    if (removedSessions.isEmpty) return;

    for (final session in removedSessions) {
      session.isPlaybackStarting = false;
      _deferredVolumeReloadSessionIds.remove(session.id);
      _forgetTimeSegmentLoopSession(session.id);
      _clearNotificationSubtitleForSession(session.id);
      if (_notificationFocusSessionId == session.id) {
        _notificationFocusSessionId = null;
      }
    }
    if (notify) {
      _notifyPlaybackChanged();
    }

    await Future.wait(
      removedSessions.map((session) async {
        await _nativePlaybackRepository.removeSession(session.id);
        session.dispose();
      }),
    );
    _syncKeepCpuAwake();
    _syncNotificationState();
    if (persist) {
      _scheduleSaveSessionState();
      _scheduleSaveSessionOrder();
    }
  }

  Future<void> setSessionLoopMode(
    String sessionId,
    SessionLoopMode mode,
  ) async {
    final session = _sessions[sessionId];
    if (session == null) return;
    session.loopMode = mode;
    if (mode != SessionLoopMode.single) {
      session.nonSingleLoopMode = mode;
    }
    _markActiveSessionsDirty();
    _notifyPlaybackChanged();
    _syncNotificationState();
    unawaited(
      _nativePlaybackRepository.setRepeatOne(
        session.id,
        mode == SessionLoopMode.single,
        queue: _nativePlaybackQueueFor(
          session,
          currentPath: session.currentTrackPath,
        ),
        queueStartIndex: _nativePlaybackQueueStartIndexFor(
          session,
          currentPath: session.currentTrackPath,
        ),
        repeatAll: mode != SessionLoopMode.single,
        shuffle: _isShuffleMode(mode),
      ),
    );
    _scheduleSaveSessionState();
  }

  Future<void> setSessionChannelSwap(String sessionId, bool enabled) async {
    final session = _sessions[sessionId];
    if (session == null) return;
    if (session.channelSwapEnabled == enabled) {
      await _persistSessionConsoleSettings(session);
      return;
    }
    session.channelSwapEnabled = enabled;
    _markActiveSessionsDirty();
    _notifyPlaybackChanged(); // Optimistic update

    final response = await _syncSessionAudioEffects(session);

    if (response.isFailure) {
      AppLogService.warning(
        'AudioProvider.setSessionChannelSwap error: '
        '${response.errorOrNull}',
      );
      await _persistSessionConsoleSettings(session);
      return;
    }
    _applyAudioEffectsSnapshot(
      session,
      response,
      fallbackAudioEffects: session.audioEffects,
    );
    await _persistSessionConsoleSettings(session);
  }

  Future<void> setSessionSkipSilence(String sessionId, bool enabled) async {
    await _updateSessionAudioEffects(
      sessionId,
      (state) => state.copyWith(skipSilenceEnabled: enabled),
      errorLabel: 'setSessionSkipSilence',
    );
  }

  Future<void> setSessionNoiseReduction(String sessionId, bool enabled) async {
    await _updateSessionAudioEffects(
      sessionId,
      (state) => state.copyWith(noiseReductionEnabled: enabled),
      errorLabel: 'setSessionNoiseReduction',
    );
  }

  Future<void> setSessionVolumeNormalization(
    String sessionId,
    bool enabled,
  ) async {
    await _updateSessionAudioEffects(
      sessionId,
      (state) => state.copyWith(volumeNormalizationEnabled: enabled),
      errorLabel: 'setSessionVolumeNormalization',
    );
  }

  Future<void> setSessionPanning(String sessionId, double panning) async {
    await _updateSessionAudioEffects(
      sessionId,
      (state) => state.copyWith(panning: panning),
      errorLabel: 'setSessionPanning',
    );
  }

  Future<void> setSessionEqEnabled(String sessionId, bool enabled) async {
    await _updateSessionAudioEffects(
      sessionId,
      (state) => state.copyWith(eqEnabled: enabled),
      errorLabel: 'setSessionEqEnabled',
    );
  }

  Future<void> setSessionEqBandLevel(
    String sessionId,
    int frequencyHz,
    double gainDb,
  ) async {
    await _updateSessionAudioEffects(sessionId, (state) {
      final levels = Map<int, double>.of(state.eqBandLevels);
      levels[frequencyHz] = _clampEqGainForSession(sessionId, gainDb);
      return state.copyWith(
        eqEnabled: true,
        eqPresetId: null,
        eqBandLevels: levels,
      );
    }, errorLabel: 'setSessionEqBandLevel');
  }

  Future<void> applySessionEqPreset(String sessionId, EqPreset preset) async {
    await _updateSessionAudioEffects(sessionId, (state) {
      final isFlatPreset = preset.bandLevels.isEmpty;
      return state.copyWith(
        eqEnabled: isFlatPreset ? state.eqEnabled : true,
        eqPresetId: preset.id,
        eqBandLevels: _mapPresetToSessionBands(sessionId, preset),
      );
    }, errorLabel: 'applySessionEqPreset');
  }

  Future<NativeResult<NativePlaybackSnapshot>> _syncSessionAudioEffects(
    PlaybackSession session,
  ) async {
    final shouldKeepPlaying = session.effectivePlaying;
    final loadedPath = session.loadedPath;
    final needsPrepare =
        loadedPath == null ||
        !PathMatcher.equalsNormalized(loadedPath, session.currentTrackPath);
    if (needsPrepare) {
      await _prepareAndPlay(
        session,
        nextPath: session.currentTrackPath,
        autoPlay: shouldKeepPlaying,
      );
      if (!_sessions.containsKey(session.id)) {
        return const NativeFailure(
          'Session removed before audio effects sync.',
        );
      }
      if (session.loadedPath == null) {
        return const NativeFailure(
          'Failed to prepare session before audio effects sync.',
        );
      }
    }
    var response = await _nativePlaybackRepository.setAudioEffects(
      session.id,
      NativeAudioEffects(
        state: session.audioEffects,
        channelSwapEnabled: session.channelSwapEnabled,
      ),
    );
    if (response.isOk || needsPrepare || !_sessions.containsKey(session.id)) {
      return response;
    }

    session.loadedPath = null;
    await _prepareAndPlay(
      session,
      nextPath: session.currentTrackPath,
      autoPlay: shouldKeepPlaying,
      showLoading: false,
    );
    if (session.loadedPath == null || !_sessions.containsKey(session.id)) {
      return response;
    }
    response = await _nativePlaybackRepository.setAudioEffects(
      session.id,
      NativeAudioEffects(
        state: session.audioEffects,
        channelSwapEnabled: session.channelSwapEnabled,
      ),
    );
    return response;
  }

  Future<void> _updateSessionAudioEffects(
    String sessionId,
    AudioEffectsState Function(AudioEffectsState state) update, {
    required String errorLabel,
  }) async {
    final session = _sessions[sessionId];
    if (session == null) return;
    final previous = session.audioEffects;
    final next = update(previous);
    session.audioEffects = next;
    _markActiveSessionsDirty();
    _notifyPlaybackChanged();

    final response = await _syncSessionAudioEffects(session);
    if (response.isFailure) {
      AppLogService.warning(
        'AudioProvider.$errorLabel error: ${response.errorOrNull}',
      );
      await _persistSessionConsoleSettings(session);
      return;
    }
    _applyAudioEffectsSnapshot(session, response, fallbackAudioEffects: next);
    await _persistSessionConsoleSettings(session);
  }

  Future<void> _persistSessionConsoleSettings(PlaybackSession session) async {
    _saveSessionStateTimer?.cancel();
    _saveSessionStateTimer = null;
    await _saveSessionState();
  }

  void _applyAudioEffectsSnapshot(
    PlaybackSession session,
    NativeResult<NativePlaybackSnapshot> response, {
    AudioEffectsState? fallbackAudioEffects,
  }) {
    final snapshot = response.valueOrNull;
    if (snapshot == null) return;
    if (snapshot.hasAudioEffectsPayload) {
      final shouldKeepFallback =
          fallbackAudioEffects != null &&
          fallbackAudioEffects != AudioEffectsState.flat &&
          snapshot.audioEffects == AudioEffectsState.flat;
      session.audioEffects = shouldKeepFallback
          ? fallbackAudioEffects
          : snapshot.audioEffects;
    } else if (fallbackAudioEffects != null) {
      session.audioEffects = fallbackAudioEffects;
    }
    session.eqCapabilities = snapshot.eqCapabilities;
    if (snapshot.hasChannelSwapPayload) {
      session.channelSwapEnabled = snapshot.channelSwapEnabled;
    }
    _markActiveSessionsDirty();
    _notifyPlaybackChanged();
  }

  Map<int, double> _mapPresetToSessionBands(String sessionId, EqPreset preset) {
    final session = _sessions[sessionId];
    final bands = session?.eqCapabilities.bands ?? const <EqBandInfo>[];
    if (bands.isEmpty) {
      return Map<int, double>.unmodifiable(preset.bandLevels);
    }
    final mapped = <int, double>{};
    for (final presetEntry in preset.bandLevels.entries) {
      final targetBand = bands.reduce((best, candidate) {
        final bestDistance = (best.frequencyHz - presetEntry.key).abs();
        final candidateDistance = (candidate.frequencyHz - presetEntry.key)
            .abs();
        return candidateDistance < bestDistance ? candidate : best;
      });
      mapped[targetBand.frequencyHz] = _clampEqGainForSession(
        sessionId,
        (mapped[targetBand.frequencyHz] ?? 0) + presetEntry.value,
      );
    }
    return Map<int, double>.unmodifiable(mapped);
  }

  double _clampEqGainForSession(String sessionId, double gainDb) {
    final capabilities = _sessions[sessionId]?.eqCapabilities;
    if (capabilities == null || !capabilities.supported) {
      return gainDb.clamp(-12.0, 12.0);
    }
    return gainDb.clamp(capabilities.minGainDb, capabilities.maxGainDb);
  }

  bool _isShuffleMode(SessionLoopMode mode) {
    return mode == SessionLoopMode.crossRandom ||
        mode == SessionLoopMode.folderRandom;
  }

  bool _isCrossFolderMode(SessionLoopMode mode) {
    return mode == SessionLoopMode.crossRandom ||
        mode == SessionLoopMode.crossSequential;
  }

  List<String> _crossFolderTrackPathsFor(MusicTrack? currentTrack) {
    if (currentTrack == null) return const <String>[];
    return tracksInSameWork(currentTrack.path)
        .map((track) => _resolveRetargetedPath(track.path))
        .toList(growable: false);
  }

  Future<void> toggleSessionSingleLoop(String sessionId) async {
    final session = _sessions[sessionId];
    if (session == null) return;
    if (session.loopMode == SessionLoopMode.single) {
      await setSessionLoopMode(sessionId, session.nonSingleLoopMode);
      return;
    }
    session.nonSingleLoopMode = session.loopMode;
    await setSessionLoopMode(sessionId, SessionLoopMode.single);
  }

  Future<void> toggleSessionShuffle(String sessionId) async {
    final session = _sessions[sessionId];
    if (session == null || session.loopMode == SessionLoopMode.single) return;
    final isCrossFolder = _isCrossFolderMode(session.loopMode);
    final isShuffle = _isShuffleMode(session.loopMode);
    final nextMode = isShuffle
        ? (isCrossFolder
              ? SessionLoopMode.crossSequential
              : SessionLoopMode.folderSequential)
        : (isCrossFolder
              ? SessionLoopMode.crossRandom
              : SessionLoopMode.folderRandom);
    await setSessionLoopMode(sessionId, nextMode);
  }

  Future<void> toggleSessionCrossFolder(String sessionId) async {
    final session = _sessions[sessionId];
    if (session == null || session.loopMode == SessionLoopMode.single) return;
    final isCrossFolder = _isCrossFolderMode(session.loopMode);
    final isShuffle = _isShuffleMode(session.loopMode);
    final nextMode = isCrossFolder
        ? (isShuffle
              ? SessionLoopMode.folderRandom
              : SessionLoopMode.folderSequential)
        : (isShuffle
              ? SessionLoopMode.crossRandom
              : SessionLoopMode.crossSequential);
    await setSessionLoopMode(sessionId, nextMode);
  }

  Future<void> setSessionVolume(
    String sessionId,
    double volume, {
    bool persist = true,
    bool notify = true,
  }) async {
    final session = _sessions[sessionId];
    if (session == null) return;
    final nextVolume = volume.clamp(0.0, _maxSessionVolume);
    final hasDeferredReload = _deferredVolumeReloadSessionIds.contains(
      session.id,
    );
    if ((session.volume - nextVolume).abs() < 0.001) {
      if (persist && hasDeferredReload) {
        await _nativePlaybackRepository.setVolume(session.id, session.volume);
        _deferredVolumeReloadSessionIds.remove(session.id);
      }
      if (persist) {
        await _persistSessionConsoleSettings(session);
      }
      return;
    }
    session.volume = nextVolume;
    if (persist) {
      _deferredVolumeReloadSessionIds.remove(session.id);
    } else {
      _deferredVolumeReloadSessionIds.add(session.id);
    }
    if (notify) {
      _markActiveSessionsDirty();
      _notifyPlaybackChanged();
    }
    await _nativePlaybackRepository.setVolume(
      session.id,
      session.volume,
      reloadSource: persist,
    );
    if (persist) {
      await _persistSessionConsoleSettings(session);
    }
  }

  Future<void> setSessionSpeed(
    String sessionId,
    double speed, {
    bool persist = true,
    bool notify = true,
  }) async {
    final session = _sessions[sessionId];
    if (session == null) return;
    final nextSpeed = _nearestPlaybackSpeed(speed);
    if ((session.speed - nextSpeed).abs() < 0.001) {
      if (persist) {
        await _persistSessionConsoleSettings(session);
      }
      return;
    }
    final previous = session.speed;
    session.speed = nextSpeed;
    _markActiveSessionsDirty();
    if (notify) {
      _notifyPlaybackChanged();
      _syncNotificationState();
    }

    final response = await _nativePlaybackRepository.setSpeed(
      session.id,
      nextSpeed,
    );

    if (response.isFailure) {
      session.speed = previous;
      _markActiveSessionsDirty();
      AppLogService.warning(
        'AudioProvider.setSessionSpeed error: ${response.errorOrNull}',
      );
      if (notify) {
        _notifyPlaybackChanged();
        _syncNotificationState();
      }
      return;
    }
    if (persist) {
      await _persistSessionConsoleSettings(session);
    }
  }

  Future<void> seekSession(String sessionId, Duration position) async {
    final session = _sessions[sessionId];
    if (session != null) {
      session.setOptimisticPosition(position);
      session.lastPersistedPositionBucket = position.inSeconds ~/ 5;
      _refreshNotificationSubtitleForSession(
        session,
        position: position,
        syncNotification: false,
      );
      _scheduleFocusedNotificationRefresh(session.id, immediate: true);
      await _nativePlaybackRepository.seek(session.id, position);
    }
  }

  Future<void> switchSessionTrack(String sessionId, String newPath) async {
    final session = _sessions[sessionId];
    if (session == null) return;
    await _prepareAndPlay(
      session,
      nextPath: newPath,
      forceStartAtZero: true,
      showLoading: false,
    );
    _scheduleSaveSessionState();
  }

  Future<void> switchSessionQueueTrack(String sessionId, int queueIndex) async {
    final session = _sessions[sessionId];
    final tracks = session?.customQueueTracks;
    if (session == null || tracks == null || tracks.isEmpty) {
      return;
    }
    final index = queueIndex.clamp(0, tracks.length - 1);
    session.currentQueueIndex = index;
    await _prepareAndPlay(
      session,
      nextPath: tracks[index].path,
      forceStartAtZero: true,
      showLoading: false,
    );
    _scheduleSaveSessionState();
  }

  Future<void> seekSessionToNext(String sessionId) async {
    final session = _sessions[sessionId];
    if (session == null) return;
    final nextPath = _nextPathFor(session, forward: true);
    if (nextPath != null) {
      await _prepareAndPlay(
        session,
        nextPath: nextPath,
        forceStartAtZero: true,
        showLoading: false,
      );
    }
  }

  Future<void> seekSessionToPrev(String sessionId) async {
    final session = _sessions[sessionId];
    if (session == null) return;
    if (session.position.inSeconds > 3) {
      session.setOptimisticPosition(Duration.zero);
      session.lastPersistedPositionBucket = 0;
      _refreshNotificationSubtitleForSession(
        session,
        position: Duration.zero,
        syncNotification: false,
      );
      _scheduleFocusedNotificationRefresh(session.id, immediate: true);
      await _nativePlaybackRepository.seek(session.id, Duration.zero);
      return;
    }
    final prevPath = _nextPathFor(session, forward: false);
    if (prevPath != null) {
      await _prepareAndPlay(
        session,
        nextPath: prevPath,
        forceStartAtZero: true,
        showLoading: false,
      );
    }
  }

  Future<void> pauseAllSessions() async {
    for (final session in _sessions.values) {
      session.setOptimisticState(playing: false);
      session.isLoading = false;
      session.isPlaybackStarting = false;
    }
    _syncKeepCpuAwake();
    _notifyPlaybackChanged();
    await _nativePlaybackRepository.pauseAll();
    _scheduleSaveSessionState();
  }

  Future<void> clearAllSessions() async {
    final sessionIds = _sessions.keys.toList();
    if (sessionIds.isEmpty) return;

    final removedSessions = _playbackService.removeSessions(sessionIds);
    for (final session in removedSessions) {
      session.isPlaybackStarting = false;
      _deferredVolumeReloadSessionIds.remove(session.id);
      _forgetTimeSegmentLoopSession(session.id);
      _clearNotificationSubtitleForSession(session.id);
    }
    _notificationFocusSessionId = null;

    _notifyPlaybackChanged();

    await _nativePlaybackRepository.clearAll();
    for (final session in removedSessions) {
      session.dispose();
    }

    _syncKeepCpuAwake();
    _syncNotificationState();
    _scheduleSaveSessionState();
    _scheduleSaveSessionOrder();
  }
}
