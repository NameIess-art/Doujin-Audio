part of 'audio_provider.dart';

extension AudioProviderPlaybackEngine on AudioProvider {
  Future<void> _startSessionPlayback(
    PlaybackSession session, {
    required bool shouldStartTriggerCountdown,
  }) async {
    if (!_sessions.containsKey(session.id)) return;
    final generation = ++session.playbackCommandGeneration;
    _notificationsDismissedWhilePaused = false;
    unawaited(NativePlaybackBridge.instance.undismissNotifications());
    if (!_multiThreadPlaybackEnabled) {
      await _enforceSingleThreadPlayback(preferredSessionId: session.id);
    }
    if (!_sessions.containsKey(session.id) ||
        session.playbackCommandGeneration != generation) {
      return;
    }
    final activated = await _activateAudioSessionForPlayback();
    if (!_sessions.containsKey(session.id) ||
        session.playbackCommandGeneration != generation) {
      return;
    }
    if (!activated) {
      debugPrint(
        'AudioProvider._startSessionPlayback: audio session activation '
        'returned false; continuing playback attempt.',
      );
    }

    _notificationFocusSessionId = session.id;
    session.isPlaybackStarting = true;
    _syncKeepCpuAwake();
    session.setOptimisticState(
      playing: true,
      processingState: session.state.processingState == ProcessingState.idle
          ? ProcessingState.loading
          : null,
    );

    try {
      final playResult = await NativePlaybackBridge.instance.play(session.id);
      if (!_sessions.containsKey(session.id) ||
          session.playbackCommandGeneration != generation) {
        return;
      }
      if ((playResult['ok'] as bool?) != true) {
        session.isPlaybackStarting = false;
        session.setOptimisticState(
          playing: false,
          processingState: session.loadedPath != null
              ? ProcessingState.ready
              : ProcessingState.idle,
        );
      } else if (!session.state.playing && session.isPlaybackStarting) {
        // Stale EventChannel snapshots from prepareSession may have
        // overwritten the optimistic playing state. Re-assert it.
        session.setOptimisticState(
          playing: true,
          processingState: session.loadedPath != null
              ? ProcessingState.ready
              : ProcessingState.idle,
        );
      }
    } catch (e) {
      if (_sessions.containsKey(session.id) &&
          session.playbackCommandGeneration == generation) {
        session.isPlaybackStarting = false;
        session.setOptimisticState(
          playing: false,
          processingState: session.loadedPath != null
              ? ProcessingState.ready
              : ProcessingState.idle,
        );
      }
      debugPrint('AudioProvider._startSessionPlayback error: $e');
    }

    if (!_sessions.containsKey(session.id) ||
        session.playbackCommandGeneration != generation) {
      return;
    }
    _syncKeepCpuAwake();
    unawaited(_clearPlaybackStartingIfStillPending(session.id, generation));
    if (shouldStartTriggerCountdown) {
      _maybeStartTriggerCountdown();
    }
  }

  Future<void> _clearPlaybackStartingIfStillPending(
    String sessionId,
    int generation,
  ) async {
    await Future<void>.delayed(const Duration(seconds: 3));
    final session = _sessions[sessionId];
    if (session == null ||
        session.playbackCommandGeneration != generation ||
        !session.isPlaybackStarting ||
        session.state.playing) {
      return;
    }
    session.isPlaybackStarting = false;
    _syncKeepCpuAwake();
    _syncNotificationState();
  }

  Future<void> _resetSessionsForSingleThreadMode() async {
    if (_sessions.isEmpty) {
      _notificationFocusSessionId = null;
      _syncNotificationState();
      return;
    }

    await Future.wait(
      _sessions.values.map(
        (session) => NativePlaybackBridge.instance.pause(session.id),
      ),
    );
    for (final session in _sessions.values) {
      session.setOptimisticState(playing: false);
    }
    _syncKeepCpuAwake();
    _notificationFocusSessionId = null;
    _syncNotificationState();
    _notifyListeners();
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
      _notifyListeners();
      return;
    }

    await Future.wait(
      sessionsToPause.map((session) {
        session.setOptimisticState(playing: false);
        return NativePlaybackBridge.instance.pause(session.id);
      }),
    );
    _notificationFocusSessionId = keepSessionId;
    _syncKeepCpuAwake();
    _syncNotificationState();
    _notifyListeners();
  }

  String? get _preferredSingleSessionId {
    for (final session in activeSessions) {
      if (session.state.playing) return session.id;
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
    _notifyListeners();
    _scheduleSaveSessionOrder();
  }

  Future<void> _handleSessionCompleted(String sessionId) async {
    final session = _sessions[sessionId];
    if (session == null) return;
    if (session.loopMode == SessionLoopMode.single) {
      session.isAdvancingAfterCompletion = false;
      return;
    }

    final nextPath = _nextPathFor(session, forward: true);
    if (nextPath == null) {
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

    if (nextPath == session.currentTrackPath) {
      try {
        await NativePlaybackBridge.instance.seek(session.id, Duration.zero);
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
          _notifyListeners();
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
      await _prepareAndPlay(session, nextPath: nextPath);
      if (_sessions.containsKey(session.id)) {
        session.isAdvancingAfterCompletion = false;
      }
    }
  }

  String? _nextPathFor(PlaybackSession session, {required bool forward}) {
    final currentTrack = trackByPath(session.currentTrackPath);
    return _playbackQueueResolver.resolveNextPath(
      currentTrack: currentTrack,
      forward: forward,
      loopMode: session.loopMode,
      sortedLibraryTrackPaths: _sortedLibraryTrackPaths,
      tracksByGroup: _tracksByGroup,
      nextInt: _random.nextInt,
    );
  }

  bool _hasAdjacentPathFor(PlaybackSession session, {required bool forward}) {
    final currentTrack = trackByPath(session.currentTrackPath);
    return _playbackQueueResolver.hasAdjacentPath(
      currentTrack: currentTrack,
      forward: forward,
      loopMode: session.loopMode,
      sortedLibraryTrackPaths: _sortedLibraryTrackPaths,
      tracksByGroup: _tracksByGroup,
    );
  }
}
