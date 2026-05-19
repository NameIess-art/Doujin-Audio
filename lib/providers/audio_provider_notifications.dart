part of 'audio_provider.dart';

extension AudioProviderNotifications on AudioProvider {
  void _bindNotificationHandler() {
    _notificationStateService.bindHandler(
      notificationService: _notificationService,
      onPlay: playPrimarySessionFromNotification,
      onPlayFromMediaId: playNotificationSessionById,
      onPause: pausePrimarySessionFromNotification,
      onStop: stopPrimarySessionFromNotification,
      onSkipToNext: skipPrimarySessionToNextFromNotification,
      onSkipToPrevious: skipPrimarySessionToPreviousFromNotification,
      onSeek: seekPrimarySessionFromNotification,
      onTogglePlayPause: togglePrimarySessionPlayPauseFromNotification,
      onToggleSessionPlayback: toggleSessionPlaybackFromNotification,
      onSkipToPreviousSession: skipNotificationSessionToPreviousById,
      onSkipToNextSession: skipNotificationSessionToNextById,
      onNotificationDeleted: dismissNotificationsAfterPauseAll,
      onRestoreNotifications: restoreNotificationsAfterSystemClear,
      syncNotificationState: _syncNotificationState,
    );
  }

  Future<void> playPrimarySessionFromNotification() {
    return _notificationStateService.guardNotificationAction(
      () async {
        final session = _resolveNotificationSession();
        if (session == null) return;
        await _resumeNotificationSession(session);
      },
      notify: _notifyListeners,
      flushKeepAliveSync: _syncKeepCpuAwake,
      syncNotificationState: () =>
          _syncNotificationState(immediateUnifiedSync: true),
    );
  }

  Future<void> playNotificationSessionById(String mediaId) {
    return _notificationStateService.guardNotificationAction(
      () async {
        final session = _resolveNotificationSession(mediaId);
        if (session == null) return;
        await _resumeNotificationSession(session);
      },
      notify: _notifyListeners,
      flushKeepAliveSync: _syncKeepCpuAwake,
      syncNotificationState: () =>
          _syncNotificationState(immediateUnifiedSync: true),
    );
  }

  Future<void> pausePrimarySessionFromNotification() {
    return _notificationStateService.guardNotificationAction(
      () async {
        final session = _notificationActionSession;
        if (session == null || !session.state.playing) return;
        _notificationFocusSessionId = session.id;
        await _nativePlaybackRepository.pause(session.id);
        session.setOptimisticState(playing: false);
      },
      notify: _notifyListeners,
      flushKeepAliveSync: _syncKeepCpuAwake,
      syncNotificationState: () =>
          _syncNotificationState(immediateUnifiedSync: true),
    );
  }

  Future<void> togglePrimarySessionPlayPauseFromNotification() {
    return _notificationStateService.guardNotificationAction(
      () async {
        final session = _resolveNotificationSession();
        if (session == null || session.isLoading) return;
        if (session.state.playing) {
          await _nativePlaybackRepository.pause(session.id);
          session.setOptimisticState(playing: false);
          return;
        }
        await _resumeNotificationSession(session);
      },
      notify: _notifyListeners,
      flushKeepAliveSync: _syncKeepCpuAwake,
      syncNotificationState: () =>
          _syncNotificationState(immediateUnifiedSync: true),
    );
  }

  Future<void> stopPrimarySessionFromNotification() {
    return _notificationStateService.guardNotificationAction(
      () async {
        final session = _notificationActionSession;
        if (session == null) return;
        _notificationFocusSessionId = session.id;
        await _nativePlaybackRepository.pause(session.id);
        session.setOptimisticState(playing: false);
      },
      notify: _notifyListeners,
      flushKeepAliveSync: _syncKeepCpuAwake,
      syncNotificationState: () =>
          _syncNotificationState(immediateUnifiedSync: true),
    );
  }

  Future<void> skipPrimarySessionToNextFromNotification() {
    return _notificationStateService.guardNotificationAction(
      () async {
        final session = _notificationActionSession;
        if (session == null) return;
        _notificationFocusSessionId = session.id;
        await seekSessionToNext(session.id);
      },
      notify: _notifyListeners,
      flushKeepAliveSync: _syncKeepCpuAwake,
      syncNotificationState: () =>
          _syncNotificationState(immediateUnifiedSync: true),
    );
  }

  Future<void> skipPrimarySessionToPreviousFromNotification() {
    return _notificationStateService.guardNotificationAction(
      () async {
        final session = _notificationActionSession;
        if (session == null) return;
        _notificationFocusSessionId = session.id;
        await seekSessionToPrev(session.id);
      },
      notify: _notifyListeners,
      flushKeepAliveSync: _syncKeepCpuAwake,
      syncNotificationState: () =>
          _syncNotificationState(immediateUnifiedSync: true),
    );
  }

  Future<void> toggleSessionPlaybackFromNotification(String sessionId) {
    return _notificationStateService.guardNotificationAction(
      () async {
        final session = _playbackService.sessionById(sessionId);
        if (session == null) return;
        if (!_multiThreadPlaybackEnabled) {
          _notificationFocusSessionId = session.id;
        }
        await toggleSessionPlayPause(session.id);
      },
      notify: _notifyListeners,
      flushKeepAliveSync: _syncKeepCpuAwake,
      syncNotificationState: () =>
          _syncNotificationState(immediateUnifiedSync: true),
    );
  }

  Future<void> skipNotificationSessionToPreviousById(String sessionId) {
    return _notificationStateService.guardNotificationAction(
      () async {
        final session = _playbackService.sessionById(sessionId);
        if (session == null) return;
        if (!_multiThreadPlaybackEnabled) {
          _notificationFocusSessionId = session.id;
        }
        await seekSessionToPrev(session.id);
      },
      notify: _notifyListeners,
      flushKeepAliveSync: _syncKeepCpuAwake,
      syncNotificationState: () =>
          _syncNotificationState(immediateUnifiedSync: true),
    );
  }

  Future<void> skipNotificationSessionToNextById(String sessionId) {
    return _notificationStateService.guardNotificationAction(
      () async {
        final session = _playbackService.sessionById(sessionId);
        if (session == null) return;
        if (!_multiThreadPlaybackEnabled) {
          _notificationFocusSessionId = session.id;
        }
        await seekSessionToNext(session.id);
      },
      notify: _notifyListeners,
      flushKeepAliveSync: _syncKeepCpuAwake,
      syncNotificationState: () =>
          _syncNotificationState(immediateUnifiedSync: true),
    );
  }

  Future<void> seekPrimarySessionFromNotification(Duration position) {
    return _notificationStateService.guardNotificationAction(
      () async {
        final session = _notificationActionSession;
        if (session == null) return;
        _notificationFocusSessionId = session.id;
        await seekSession(session.id, position);
      },
      notify: _notifyListeners,
      flushKeepAliveSync: _syncKeepCpuAwake,
      syncNotificationState: () =>
          _syncNotificationState(immediateUnifiedSync: true),
    );
  }

  Future<void> dismissNotificationsAfterPauseAll() async {
    _notificationsDismissedWhilePaused = true;
    await _nativePlaybackRepository.dismissNotifications();
    if (_hasPlaybackToKeepAlive) {
      await _clearUnifiedPlaybackNotificationsOnPlatform();
      _syncKeepCpuAwake();
      _notifyListeners();
      return;
    }
    // Clear unified notifications before stopping the keep-alive service
    // so that activeNotificationCount is 0, which causes the keep-alive
    // service to use STOP_FOREGROUND_REMOVE instead of DETACH.
    await _clearUnifiedPlaybackNotificationsOnPlatform();
    await _stopPlaybackKeepAliveOnPlatform();
    await pauseAllSessions();
    // Clear the handler snapshot so audio_service shows no notification,
    // but keep the handler registered so that unified notification button
    // actions (via UnifiedPlaybackActionReceiver -> AudioService.dispatchCustomAction)
    // continue to work.
    _notificationService.updateSnapshot(null);
    _notificationFocusSessionId = _preferredSingleSessionId;
    _syncKeepCpuAwake();
    _notifyListeners();
  }

  Future<void> restoreNotificationsAfterSystemClear() async {
    _notificationsDismissedWhilePaused = false;
    _unifiedNotificationSyncKey = null;
    await _nativePlaybackRepository.undismissNotifications();
    _syncNotificationState(immediateUnifiedSync: true);
    _notifyListeners();
  }

  void resyncNotificationsAfterResume() {
    if (!_notificationsDismissedWhilePaused) return;
    _notificationsDismissedWhilePaused = false;
    _unifiedNotificationSyncKey = null;
    unawaited(_nativePlaybackRepository.undismissNotifications());
    _syncNotificationState(immediateUnifiedSync: true);
    _notifyListeners();
  }

  List<PlaybackSession> get _singleThreadNotificationSessions {
    return _notificationStateService.singleThreadNotificationSessions(
      activeSessions,
    );
  }

  List<PlaybackSession> get _notificationQueueSessions {
    return _notificationStateService.notificationQueueSessions(
      activeSessions: activeSessions,
      multiThreadPlaybackEnabled: _multiThreadPlaybackEnabled,
    );
  }

  PlaybackSession? _focusedSessionFrom(Iterable<PlaybackSession> sessions) {
    return _notificationStateService.focusedSessionFrom(sessions);
  }

  PlaybackSession? get _notificationFocusedSession {
    return _focusedSessionFrom(_notificationQueueSessions);
  }

  PlaybackSession? get _notificationActionSession {
    return _notificationStateService.notificationActionSession(
      activeSessions: activeSessions,
      queueSessions: _notificationQueueSessions,
    );
  }

  PlaybackSession? _resolveNotificationSession([String? sessionId]) {
    return _notificationStateService.resolveNotificationSession(
      sessions: _sessions,
      activeSessions: activeSessions,
      queueSessions: _notificationQueueSessions,
      sessionId: sessionId,
    );
  }
}
