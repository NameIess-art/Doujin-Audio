part of 'notification_facade.dart';

extension NotificationFacadeSync on NotificationFacade {
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

  Future<void> _clearUnifiedPlaybackNotificationsOnPlatform() async {
    _unifiedNotificationSyncKey = null;
    await _notificationService.clearUnifiedNotifications();
  }

  void _syncNotificationState({bool immediateUnifiedSync = false}) {
    if (!_synchronizationAttached) return;
    if (stateService.synchronizationPaused) {
      stateService.synchronizationPendingWhilePaused = true;
      return;
    }

    if (!_notificationsEnabled) {
      _unifiedNotificationSyncTimer?.cancel();
      _unifiedNotificationSyncTimer = null;
      _notificationProgressRefreshTimer?.cancel();
      _notificationProgressRefreshTimer = null;
      _queuedNotificationRefreshSessionId = null;
      _clearUnifiedPlaybackNotificationsOnPlatform();
      return;
    }

    if (_notificationsDismissedWhilePaused && !_hasPlaybackToKeepAlive) {
      _unifiedNotificationSyncTimer?.cancel();
      _unifiedNotificationSyncTimer = null;
      _notificationProgressRefreshTimer?.cancel();
      _notificationProgressRefreshTimer = null;
      _queuedNotificationRefreshSessionId = null;
      _requestUnifiedPlaybackNotificationFlush();
      return;
    }

    if (immediateUnifiedSync) {
      _unifiedNotificationSyncTimer?.cancel();
      _unifiedNotificationSyncTimer = null;
      _requestUnifiedPlaybackNotificationFlush();
    } else {
      _scheduleUnifiedPlaybackNotificationSync();
    }
  }

  void _scheduleUnifiedPlaybackNotificationSync() {
    if (_unifiedNotificationSyncTimer != null) {
      return;
    }
    if (_notificationActionRefreshPending) {
      return;
    }
    _unifiedNotificationSyncTimer = Timer(
      NotificationFacade._unifiedNotificationDebounceInterval,
      () {
        _unifiedNotificationSyncTimer = null;
        _requestUnifiedPlaybackNotificationFlush();
      },
    );
  }

  void _requestUnifiedPlaybackNotificationFlush() {
    if (stateService.synchronizationPaused) {
      _unifiedNotificationSyncPending = false;
      stateService.synchronizationPendingWhilePaused = true;
      return;
    }
    _unifiedNotificationSyncPending = true;
    if (_unifiedNotificationSyncInFlight) {
      return;
    }
    _unifiedNotificationSyncInFlight = true;
    unawaited(_flushUnifiedPlaybackNotificationState());
  }

  Future<void> _flushUnifiedPlaybackNotificationState() async {
    try {
      while (_unifiedNotificationSyncPending) {
        if (stateService.synchronizationPaused) {
          _unifiedNotificationSyncPending = false;
          stateService.synchronizationPendingWhilePaused = true;
          break;
        }
        _unifiedNotificationSyncPending = false;
        final shouldShowUnifiedNotifications =
            _notificationsEnabled && !_notificationsDismissedWhilePaused;
        if (!shouldShowUnifiedNotifications) {
          await _clearUnifiedPlaybackNotificationsOnPlatform();
          continue;
        }
        await _syncUnifiedPlaybackNotifications();
      }
    } finally {
      _unifiedNotificationSyncInFlight = false;
      if (_unifiedNotificationSyncPending) {
        _requestUnifiedPlaybackNotificationFlush();
      }
    }
  }

  void _scheduleFocusedNotificationRefresh(
    String sessionId, {
    bool immediate = false,
  }) {
    if (stateService.synchronizationPaused) {
      stateService.synchronizationPendingWhilePaused = true;
      return;
    }
    if (!_notificationsEnabled ||
        (_notificationsDismissedWhilePaused && !_hasPlaybackToKeepAlive)) {
      _notificationProgressRefreshTimer?.cancel();
      _notificationProgressRefreshTimer = null;
      _queuedNotificationRefreshSessionId = null;
      return;
    }

    if (!_isNotificationFocusedSessionId(sessionId)) {
      return;
    }

    if (_shouldUseUnifiedPlaybackNotifications) {
      immediate = false;
    }

    if (immediate) {
      _notificationProgressRefreshTimer?.cancel();
      _notificationProgressRefreshTimer = null;
      _queuedNotificationRefreshSessionId = null;
      _syncNotificationState();
      return;
    }

    if (_queuedNotificationRefreshSessionId != sessionId) {
      _queuedNotificationRefreshSessionId = sessionId;
    }
    if (_notificationProgressRefreshTimer != null) {
      return;
    }

    _notificationProgressRefreshTimer = Timer(_notificationRefreshInterval, () {
      _notificationProgressRefreshTimer = null;
      final queuedSessionId = _queuedNotificationRefreshSessionId;
      _queuedNotificationRefreshSessionId = null;
      if (queuedSessionId == null ||
          _notificationFocusedSession?.id != queuedSessionId) {
        return;
      }
      if (!_notificationsEnabled ||
          (_notificationsDismissedWhilePaused && !_hasPlaybackToKeepAlive)) {
        return;
      }
      if (stateService.synchronizationPaused) {
        _queuedNotificationRefreshSessionId = queuedSessionId;
        stateService.synchronizationPendingWhilePaused = true;
        return;
      }
      _syncNotificationState();
    });
  }

  bool _isNotificationFocusedSessionId(String sessionId) {
    final focusedId = _notificationFocusSessionId;
    if (focusedId != null && focusedId != sessionId) {
      return false;
    }
    return _notificationFocusedSession?.id == sessionId;
  }

  Future<void> _syncUnifiedPlaybackNotifications() async {
    final isMultiMode = _multiThreadPlaybackEnabled;
    final mainSession = _focusedSessionFrom(
      isMultiMode ? activeSessions : _singleThreadNotificationSessions,
    );
    final sessionsToShow = isMultiMode
        ? activeSessions
        : (mainSession == null
              ? const <PlaybackSession>[]
              : <PlaybackSession>[mainSession]);
    final showUnifiedSummary = sessionsToShow.isNotEmpty;
    final summaryText = showUnifiedSummary
        ? _notificationSummaryText(sessionsToShow)
        : null;
    final summaryLines = showUnifiedSummary && isMultiMode
        ? sessionsToShow
              .map(_notificationTitleForSession)
              .toList(growable: false)
        : const <String>[];

    final payload = sessionsToShow
        .map((session) {
          final title = _notificationTitleForSession(session);
          final subtitle = _notificationSubtitleForSession(session);
          final trackPath = session.currentTrackPath;
          final track = trackByPath(trackPath);
          final artPath = coverPathForTrack(track, trackPath: trackPath);
          if (artPath == null) {
            unawaited(
              _resolveNotificationCoverPathForTrack(
                track,
                trackPath: trackPath,
              ),
            );
          }
          return <String, dynamic>{
            'id': session.id,
            'title': title,
            if (subtitle != null && subtitle.isNotEmpty) 'subtitle': subtitle,
            if (artPath != null && artPath.isNotEmpty) 'artPath': artPath,
            'playing': session.state.playing,
            'hasPrevious': _playbackCommands.hasAdjacent(
              session,
              forward: false,
            ),
            'hasNext': _playbackCommands.hasAdjacent(session, forward: true),
          };
        })
        .toList(growable: false);

    final styleVariant = isMultiMode ? 'multi_thread' : 'single_thread';
    final syncPayload = <String, dynamic>{
      'mode': isMultiMode ? 'multi' : 'single',
      'styleVariant': styleVariant,
      'mainSessionId': mainSession?.id,
      'items': payload,
      'showSummary': showUnifiedSummary,
      'summaryText': summaryText,
      'summaryLines': summaryLines,
    };
    final nextSyncKey = json.encode(syncPayload);
    if (_unifiedNotificationSyncKey == nextSyncKey) {
      return;
    }

    if (payload.isEmpty) {
      await _clearUnifiedPlaybackNotificationsOnPlatform();
    } else {
      await _notificationService.syncUnifiedNotifications(syncPayload);
    }
    _unifiedNotificationSyncKey = nextSyncKey;
  }

  void refreshNotificationState() {
    _syncNotificationState();
    _notifyNotificationChanged();
  }

  Future<void> selectNotificationSessionFromQueue(int index) async {
    final sessions = _notificationQueueSessions;
    if (index < 0 || index >= sessions.length) return;
    _notificationFocusSessionId = sessions[index].id;
    _syncNotificationState();
    _notifyNotificationChanged();
  }
}
