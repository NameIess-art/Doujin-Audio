part of 'audio_provider.dart';

const PlaybackQueueResolver _playbackQueueResolver = PlaybackQueueResolver();
const TimerRuntimeCalculator _timerRuntimeCalculator = TimerRuntimeCalculator();

extension AudioProviderPlayback on AudioProvider {
  bool get _hasArmedTimerRuntime {
    return _timerRuntimeCalculator.hasArmedRuntime(
      mode: _timerMode,
      duration: _timerDuration,
      waitingForPlayback: _timerWaitingForPlayback,
      active: _timerActive,
      endsAt: _timerEndsAt,
      autoResumeAt: _autoResumeAt,
      hasPausedByTimerPaths: _pausedByTimerPaths.isNotEmpty,
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
      _pausedByTimerPaths.clear();
    }
    unawaited(_syncNativeTimerAlarms());
  }

  Future<void> toggleSessionPlayPause(String sessionId) async {
    final session = _playbackService.sessionById(sessionId);
    if (session == null || session.isLoading) return;

    if (session.state.playing) {
      session.isPlaybackStarting = false;
      await _nativePlaybackRepository.pause(session.id);
      session.setOptimisticState(playing: false);
    } else if (session.state.processingState == ProcessingState.completed ||
        session.state.processingState == ProcessingState.idle) {
      await _prepareAndPlay(session, nextPath: session.currentTrackPath);
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
      _clearNotificationSubtitleForSession(session.id);
      if (_notificationFocusSessionId == session.id) {
        _notificationFocusSessionId = null;
      }
    }
    await Future.wait(
      removedSessions.map((session) async {
        await _nativePlaybackRepository.removeSession(session.id);
        session.dispose();
      }),
    );
    _syncKeepCpuAwake();
    _syncNotificationState();
    if (notify) {
      _notifyListeners();
    }
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
    await _nativePlaybackRepository.setRepeatOne(
      session.id,
      mode == SessionLoopMode.single,
    );
    _syncNotificationState();
    _notifyListeners();
    _scheduleSaveSessionState();
  }

  Future<void> setSessionChannelSwap(String sessionId, bool enabled) async {
    final session = _sessions[sessionId];
    if (session == null) return;
    if (session.channelSwapEnabled == enabled) return;
    session.channelSwapEnabled = enabled;
    final response = await _nativePlaybackRepository.setChannelSwap(
      session.id,
      enabled,
    );
    final value = response.valueOrNull;
    if (value != null) {
      session.applyNativeSnapshot(value);
    }
    _notifyListeners();
    _scheduleSaveSessionState();
  }

  bool _isShuffleMode(SessionLoopMode mode) {
    return mode == SessionLoopMode.crossRandom ||
        mode == SessionLoopMode.folderRandom;
  }

  bool _isCrossFolderMode(SessionLoopMode mode) {
    return mode == SessionLoopMode.crossRandom ||
        mode == SessionLoopMode.crossSequential;
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
    final nextVolume = volume.clamp(0.0, 1.0);
    if ((session.volume - nextVolume).abs() < 0.001) {
      if (persist) {
        _scheduleSaveSessionState();
      }
      return;
    }
    session.volume = nextVolume;
    await _nativePlaybackRepository.setVolume(session.id, session.volume);
    if (notify) {
      _notifyListeners();
    }
    if (persist) {
      _scheduleSaveSessionState();
    }
  }

  Future<void> seekSession(String sessionId, Duration position) async {
    final session = _sessions[sessionId];
    if (session != null) {
      await _nativePlaybackRepository.seek(session.id, position);
      session.setOptimisticPosition(position);
      session.lastPersistedPositionBucket = position.inSeconds ~/ 5;
      _refreshNotificationSubtitleForSession(
        session,
        position: position,
        syncNotification: false,
      );
      _scheduleFocusedNotificationRefresh(session.id, immediate: true);
    }
  }

  Future<void> switchSessionTrack(String sessionId, String newPath) async {
    final session = _sessions[sessionId];
    if (session == null || session.isLoading) return;
    await _prepareAndPlay(session, nextPath: newPath);
    _scheduleSaveSessionState();
  }

  Future<void> seekSessionToNext(String sessionId) async {
    final session = _sessions[sessionId];
    if (session == null || session.isLoading) return;
    final nextPath = _nextPathFor(session, forward: true);
    if (nextPath != null) {
      await _prepareAndPlay(session, nextPath: nextPath);
    }
  }

  Future<void> seekSessionToPrev(String sessionId) async {
    final session = _sessions[sessionId];
    if (session == null || session.isLoading) return;
    if (session.position.inSeconds > 3) {
      await _nativePlaybackRepository.seek(session.id, Duration.zero);
      session.setOptimisticPosition(Duration.zero);
      session.lastPersistedPositionBucket = 0;
      _refreshNotificationSubtitleForSession(
        session,
        position: Duration.zero,
        syncNotification: false,
      );
      _scheduleFocusedNotificationRefresh(session.id, immediate: true);
      return;
    }
    final prevPath = _nextPathFor(session, forward: false);
    if (prevPath != null) {
      await _prepareAndPlay(session, nextPath: prevPath);
    }
  }

  Future<void> pauseAllSessions() async {
    await _nativePlaybackRepository.pauseAll();
    for (final session in _sessions.values) {
      session.setOptimisticState(playing: false);
      session.isLoading = false;
      session.isPlaybackStarting = false;
    }
    _syncKeepCpuAwake();
    _scheduleSaveSessionState();
  }

  Future<void> clearAllSessions() async {
    await _removeSessions(_sessions.keys.toList());
  }
}
