part of 'audio_provider.dart';

extension AudioProviderPlaybackEngine on AudioProvider {
  bool _isSessionCommandCurrent(
    PlaybackSession session,
    PlaybackCommandToken token,
  ) {
    return _sessions.containsKey(session.id) &&
        session.playbackCommandGeneration == token.generation &&
        token.isCurrent;
  }

  Future<bool> _startSessionPlayback(
    PlaybackSession session, {
    required bool shouldStartTriggerCountdown,
  }) async {
    if (!_sessions.containsKey(session.id)) return false;
    final generation = ++_transportCommandSequence;
    final token = _playbackCommandRunner.start(
      sessionId: session.id,
      generation: generation,
      isCurrent: () =>
          _sessions.containsKey(session.id) &&
          session.playbackCommandGeneration == generation,
    );
    _notificationsDismissedWhilePaused = false;
    unawaited(_nativePlaybackRepository.undismissNotifications());
    _notificationFocusSessionId = session.id;
    session.beginTransportCommand(commandId: generation, playing: true);
    final exclusivelyPausedSessions = !_multiThreadPlaybackEnabled
        ? _sessions.values
              .where(
                (candidate) =>
                    candidate.id != session.id && candidate.effectivePlaying,
              )
              .toList(growable: false)
        : const <PlaybackSession>[];
    for (final pausedSession in exclusivelyPausedSessions) {
      pausedSession.beginTransportCommand(
        commandId: generation,
        playing: false,
      );
    }
    _syncKeepCpuAwake();
    _notifyPlaybackChanged();

    unawaited(
      _activateAudioSessionForPlayback().then((activated) {
        if (!activated) {
          AppLogService.warning(
            'AudioProvider._startSessionPlayback: audio session activation '
            'returned false; continuing playback attempt.',
          );
        }
      }),
    );

    try {
      final playResult = await _nativePlaybackRepository.play(
        session.id,
        transportCommandId: generation,
        exclusive: !_multiThreadPlaybackEnabled,
      );
      if (!_isSessionCommandCurrent(session, token)) {
        return false;
      }
      if (!playResult.isOk) {
        session.failTransportCommand(generation);
        for (final pausedSession in exclusivelyPausedSessions) {
          pausedSession.failTransportCommand(generation);
        }
        _syncKeepCpuAwake();
        _notifyPlaybackChanged();
        return false;
      } else {
        final snapshot = playResult.valueOrNull;
        if (snapshot != null) {
          _handleNativePlaybackSnapshot(snapshot);
        }
      }
    } catch (e, stackTrace) {
      if (_isSessionCommandCurrent(session, token)) {
        session.failTransportCommand(generation);
        for (final pausedSession in exclusivelyPausedSessions) {
          pausedSession.failTransportCommand(generation);
        }
        _syncKeepCpuAwake();
        _notifyPlaybackChanged();
      }
      AppLogService.error(
        'AudioProvider._startSessionPlayback error',
        error: e,
        stackTrace: stackTrace,
      );
      return false;
    }

    if (!_isSessionCommandCurrent(session, token)) {
      return false;
    }
    _syncKeepCpuAwake();
    if (shouldStartTriggerCountdown) {
      _timerFacade.maybeStartTriggerCountdown();
    }
    return true;
  }

  Future<bool> _pauseSessionPlayback(PlaybackSession session) async {
    if (!_sessions.containsKey(session.id)) return false;
    final generation = ++_transportCommandSequence;
    final token = _playbackCommandRunner.start(
      sessionId: session.id,
      generation: generation,
      isCurrent: () =>
          _sessions.containsKey(session.id) &&
          session.playbackCommandGeneration == generation,
    );
    session.beginTransportCommand(commandId: generation, playing: false);
    _syncKeepCpuAwake();
    _notifyPlaybackChanged();
    try {
      final pauseResult = await _nativePlaybackRepository.pause(
        session.id,
        transportCommandId: generation,
      );
      if (!_isSessionCommandCurrent(session, token)) return false;
      if (!pauseResult.isOk) {
        session.failTransportCommand(generation);
        _syncKeepCpuAwake();
        _notifyPlaybackChanged();
        return false;
      }
      final snapshot = pauseResult.valueOrNull;
      if (snapshot != null) {
        _handleNativePlaybackSnapshot(snapshot);
      }
      return true;
    } catch (error, stackTrace) {
      if (_isSessionCommandCurrent(session, token)) {
        session.failTransportCommand(generation);
        _syncKeepCpuAwake();
        _notifyPlaybackChanged();
      }
      AppLogService.error(
        'AudioProvider._pauseSessionPlayback error',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  Future<void> _resetSessionsForSingleThreadMode() async {
    if (_sessions.isEmpty) {
      _notificationFocusSessionId = null;
      _syncNotificationState();
      return;
    }

    await Future.wait(
      _sessions.values.map(
        (session) => _nativePlaybackRepository.pause(session.id),
      ),
    );
    for (final session in _sessions.values) {
      session.setOptimisticState(playing: false);
    }
    _syncKeepCpuAwake();
    _notificationFocusSessionId = null;
    _syncNotificationState();
    _notifyPlaybackChanged();
  }

  Future<void> _enforceSingleThreadPlayback({
    String? preferredSessionId,
  }) async {
    final keepSessionId =
        (preferredSessionId != null &&
            _sessions.containsKey(preferredSessionId))
        ? preferredSessionId
        : _preferredSingleSessionId;
    if (keepSessionId == null) return;

    final sessionsToPause = _sessions.values
        .where(
          (session) => session.id != keepSessionId && session.state.playing,
        )
        .toList(growable: false);
    _notificationFocusSessionId = keepSessionId;
    if (sessionsToPause.isEmpty) {
      _syncNotificationState();
      return;
    }

    for (final session in sessionsToPause) {
      session.setOptimisticState(playing: false);
    }
    _syncKeepCpuAwake();
    _syncNotificationState();
    _notifyPlaybackChanged();
    await Future.wait(
      sessionsToPause.map(
        (session) => _nativePlaybackRepository.pause(session.id),
      ),
    );
    _notificationFocusSessionId = keepSessionId;
    _syncKeepCpuAwake();
    _syncNotificationState();
  }

  String? get _preferredSingleSessionId {
    for (final session in activeSessions) {
      if (session.effectivePlaying) return session.id;
    }
    final sessions = activeSessions;
    if (sessions.isEmpty) return null;
    return sessions.first.id;
  }

  void reorderSessions(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _sessionOrder.length) return;
    if (newIndex < 0 || newIndex > _sessionOrder.length) return;
    if (newIndex > oldIndex) newIndex -= 1;
    final moved = _sessionOrder.removeAt(oldIndex);
    _sessionOrder.insert(newIndex, moved);
    _markActiveSessionsDirty();
    _syncNotificationState();
    _notifyPlaybackChanged();
    _scheduleSaveSessionOrder();
  }

  bool hasSessionAdjacentTrack(String sessionId, {required bool forward}) {
    final session = _sessions[sessionId];
    if (session == null || session.isLoading) return false;
    return _hasAdjacentPathFor(session, forward: forward);
  }

  Future<void> _handleSessionCompleted(String sessionId) async {
    final session = _sessions[sessionId];
    if (session == null) return;
    final nextTarget = _nextPathFor(session, forward: true);
    if (nextTarget == null) {
      session.isAdvancingAfterCompletion = false;
      session.isLoading = false;
      _syncKeepCpuAwake();
      _syncNotificationState();
      return;
    }

    final completionGeneration = session.playbackCommandGeneration;
    session.isLoading = true;
    session.isAdvancingAfterCompletion = true;
    _syncKeepCpuAwake();
    _syncNotificationState();

    if (nextTarget.path == session.currentTrackPath &&
        (nextTarget.queueIndex == null ||
            nextTarget.queueIndex == session.currentQueueIndex)) {
      try {
        await _nativePlaybackRepository.seek(session.id, Duration.zero);
        if (!_sessions.containsKey(session.id) ||
            session.playbackCommandGeneration != completionGeneration) {
          return;
        }
        session.setOptimisticPosition(Duration.zero);
      } finally {
        if (_sessions.containsKey(session.id) &&
            session.playbackCommandGeneration == completionGeneration) {
          session.isLoading = false;
          session.isAdvancingAfterCompletion = false;
          _syncNotificationState();
          _notifyPlaybackChanged();
        }
      }
      if (_sessions.containsKey(session.id) &&
          session.playbackCommandGeneration == completionGeneration) {
        await _startSessionPlayback(
          session,
          shouldStartTriggerCountdown: false,
        );
      }
    } else {
      await _prepareAndPlay(
        session,
        nextPath: nextTarget.path,
        targetQueueIndex: nextTarget.queueIndex,
      );
      if (_sessions.containsKey(session.id)) {
        session.isAdvancingAfterCompletion = false;
      }
    }
  }

  PlaybackAdvanceResult? _nextPathFor(
    PlaybackSession session, {
    required bool forward,
  }) {
    return _playbackQueueResolver.resolveAdvance(
      scope: _playbackQueueScopeFor(
        session,
        currentPath: session.currentTrackPath,
      ),
      forward: forward,
      loopMode: session.loopMode,
      nextInt: _random.nextInt,
    );
  }

  bool _hasAdjacentPathFor(PlaybackSession session, {required bool forward}) {
    return _playbackQueueResolver.hasAdjacentInScope(
      scope: _playbackQueueScopeFor(
        session,
        currentPath: session.currentTrackPath,
      ),
      loopMode: session.loopMode,
    );
  }
}
