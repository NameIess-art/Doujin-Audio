part of 'audio_provider.dart';

extension AudioProviderNotifications on AudioProvider {
  void _bindNotificationHandler() {
    _notificationService.bindCallbacks(
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
    );
    _syncNotificationState();
  }

  Future<void> playPrimarySessionFromNotification() {
    return _guardNotificationAction(() async {
      final session = _resolveNotificationSession();
      if (session == null) return;
      await _resumeNotificationSession(session);
    });
  }

  Future<void> playNotificationSessionById(String mediaId) {
    return _guardNotificationAction(() async {
      final session = _resolveNotificationSession(mediaId);
      if (session == null) return;
      await _resumeNotificationSession(session);
    });
  }

  Future<void> pausePrimarySessionFromNotification() {
    return _guardNotificationAction(() async {
      final session = _notificationActionSession;
      if (session == null || !session.state.playing) return;
      _notificationFocusSessionId = session.id;
      await NativePlaybackBridge.instance.pause(session.id);
      session.setOptimisticState(playing: false);
    });
  }

  Future<void> togglePrimarySessionPlayPauseFromNotification() {
    return _guardNotificationAction(() async {
      final session = _resolveNotificationSession();
      if (session == null || session.isLoading) return;
      if (session.state.playing) {
        await NativePlaybackBridge.instance.pause(session.id);
        session.setOptimisticState(playing: false);
        return;
      }
      await _resumeNotificationSession(session);
    });
  }

  Future<void> stopPrimarySessionFromNotification() {
    return _guardNotificationAction(() async {
      final session = _notificationActionSession;
      if (session == null) return;
      _notificationFocusSessionId = session.id;
      await NativePlaybackBridge.instance.pause(session.id);
      session.setOptimisticState(playing: false);
    });
  }

  Future<void> skipPrimarySessionToNextFromNotification() {
    return _guardNotificationAction(() async {
      final session = _notificationActionSession;
      if (session == null) return;
      _notificationFocusSessionId = session.id;
      await seekSessionToNext(session.id);
    });
  }

  Future<void> skipPrimarySessionToPreviousFromNotification() {
    return _guardNotificationAction(() async {
      final session = _notificationActionSession;
      if (session == null) return;
      _notificationFocusSessionId = session.id;
      await seekSessionToPrev(session.id);
    });
  }

  Future<void> toggleSessionPlaybackFromNotification(String sessionId) {
    return _guardNotificationAction(() async {
      final session = _sessions[sessionId];
      if (session == null) return;
      if (!_multiThreadPlaybackEnabled) {
        _notificationFocusSessionId = session.id;
      }
      await toggleSessionPlayPause(session.id);
    });
  }

  Future<void> skipNotificationSessionToPreviousById(String sessionId) {
    return _guardNotificationAction(() async {
      final session = _sessions[sessionId];
      if (session == null) return;
      if (!_multiThreadPlaybackEnabled) {
        _notificationFocusSessionId = session.id;
      }
      await seekSessionToPrev(session.id);
    });
  }

  Future<void> skipNotificationSessionToNextById(String sessionId) {
    return _guardNotificationAction(() async {
      final session = _sessions[sessionId];
      if (session == null) return;
      if (!_multiThreadPlaybackEnabled) {
        _notificationFocusSessionId = session.id;
      }
      await seekSessionToNext(session.id);
    });
  }

  Future<void> seekPrimarySessionFromNotification(Duration position) {
    return _guardNotificationAction(() async {
      final session = _notificationActionSession;
      if (session == null) return;
      _notificationFocusSessionId = session.id;
      await seekSession(session.id, position);
    });
  }

  Future<void> dismissNotificationsAfterPauseAll() async {
    _notificationsDismissedWhilePaused = true;
    await NativePlaybackBridge.instance.dismissNotifications();
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
    await NativePlaybackBridge.instance.undismissNotifications();
    _syncNotificationState(immediateUnifiedSync: true);
    _notifyListeners();
  }

  void resyncNotificationsAfterResume() {
    if (!_notificationsDismissedWhilePaused) return;
    _notificationsDismissedWhilePaused = false;
    _unifiedNotificationSyncKey = null;
    unawaited(NativePlaybackBridge.instance.undismissNotifications());
    _syncNotificationState(immediateUnifiedSync: true);
    _notifyListeners();
  }

  List<PlaybackSession> get _singleThreadNotificationSessions {
    return activeSessions
        .where(
          (session) =>
              session.state.playing ||
              session.isPlaybackStarting ||
              session.state.processingState == ProcessingState.idle ||
              session.state.processingState == ProcessingState.ready ||
              session.state.processingState == ProcessingState.completed,
        )
        .toList(growable: false);
  }

  List<PlaybackSession> get _notificationQueueSessions {
    return _multiThreadPlaybackEnabled
        ? activeSessions
        : _singleThreadNotificationSessions;
  }

  PlaybackSession? _focusedSessionFrom(Iterable<PlaybackSession> sessions) {
    final focusedId = _notificationFocusSessionId;
    if (focusedId != null) {
      for (final session in sessions) {
        if (session.id == focusedId) return session;
      }
    }
    final fallback = sessions.isNotEmpty ? sessions.first : null;
    _notificationFocusSessionId = fallback?.id;
    return fallback;
  }

  PlaybackSession? get _notificationFocusedSession {
    return _focusedSessionFrom(_notificationQueueSessions);
  }

  PlaybackSession? get _notificationActionSession {
    final focused = _focusedSessionFrom(activeSessions);
    if (focused != null) {
      return focused;
    }
    return _focusedSessionFrom(_notificationQueueSessions);
  }

  PlaybackSession? _resolveNotificationSession([String? sessionId]) {
    if (sessionId != null) {
      final matchedSession = _sessions[sessionId];
      if (matchedSession != null) {
        _notificationFocusSessionId = matchedSession.id;
        return matchedSession;
      }
    }
    final focusedSession = _notificationActionSession;
    if (focusedSession != null) {
      _notificationFocusSessionId = focusedSession.id;
    }
    return focusedSession;
  }

  // Must be called synchronously at the *start* of every notification
  // button callback, before any state changes or platform calls that
  // could trigger intermediate NotificationManager.notify() while
  // Android's SystemUI is still processing the PendingIntent.
  void _beginNotificationAction() {
    _unifiedNotificationSyncKey = null;
    _unifiedNotificationSyncTimer?.cancel();
    _unifiedNotificationSyncTimer = null;
    _notificationActionRefreshTimer?.cancel();
    _notificationActionRefreshTimer = null;
    _notificationActionRefreshPending = true;

    // Safety timeout: force-clear the guard if _scheduleNotificationActionRefresh
    // is never called (e.g., due to an uncaught exception between begin/schedule).
    _notificationActionGuardTimeout?.cancel();
    _notificationActionGuardTimeout = Timer(const Duration(seconds: 5), () {
      _notificationActionGuardTimeout = null;
      if (_notificationActionRefreshPending) {
        debugPrint(
          'AudioProvider: notification action guard timed out, force-clearing',
        );
        _notificationActionRefreshPending = false;
        if (_keepAliveSyncDeferred) {
          _keepAliveSyncDeferred = false;
          _syncKeepCpuAwake();
        }
        _syncNotificationState(immediateUnifiedSync: true);
        _notifyListeners();
      }
    });
  }

  Future<void> _guardNotificationAction(Future<void> Function() action) async {
    _beginNotificationAction();
    try {
      await action();
    } finally {
      _scheduleNotificationActionRefresh();
    }
  }

  void _scheduleNotificationActionRefresh() {
    // The guard was already set by _beginNotificationAction; reset the
    // timer so we extend the window from the last state mutation, then
    // schedule the real sync once SystemUI has finished processing the
    // PendingIntent.
    _notificationActionGuardTimeout?.cancel();
    _notificationActionGuardTimeout = null;
    _notificationActionRefreshTimer?.cancel();
    _notificationActionRefreshTimer = Timer(
      const Duration(milliseconds: 250),
      () {
        _notificationActionRefreshTimer = null;
        _notificationActionRefreshPending = false;
        // Flush any keep-alive sync that was deferred while the action
        // guard was active, so the foreground service state is updated
        // BEFORE the notification is re-posted.
        if (_keepAliveSyncDeferred) {
          _keepAliveSyncDeferred = false;
          _syncKeepCpuAwake();
        }
        _syncNotificationState(immediateUnifiedSync: true);
        _notifyListeners();
      },
    );

    _notifyListeners();
  }
}
