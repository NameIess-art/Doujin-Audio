part of 'audio_provider.dart';

extension AudioProviderNotificationSync on AudioProvider {
  Future<void> _clearUnifiedPlaybackNotificationsOnPlatform() async {
    _unifiedNotificationSyncKey = null;
    await _notificationService.clearUnifiedNotifications();
  }

  Future<void> _stopPlaybackKeepAliveOnPlatform() async {
    try {
      await AudioProvider._powerChannel.invokeMethod<void>(
        'stopPlaybackKeepAlive',
      );
    } on MissingPluginException {
      // The Android power channel is not available on this platform.
    } catch (e) {
      debugPrint('AudioProvider._stopPlaybackKeepAliveOnPlatform error: $e');
    }
  }

  void _syncNotificationState({bool immediateUnifiedSync = false}) {
    if (!_notificationsEnabled) {
      _unifiedNotificationSyncTimer?.cancel();
      _unifiedNotificationSyncTimer = null;
      _notificationProgressRefreshTimer?.cancel();
      _notificationProgressRefreshTimer = null;
      _queuedNotificationRefreshSessionId = null;
      _notificationService.updateSnapshot(null);
      _clearUnifiedPlaybackNotificationsOnPlatform();
      return;
    }

    if (_notificationsDismissedWhilePaused && !_hasPlaybackToKeepAlive) {
      _unifiedNotificationSyncTimer?.cancel();
      _unifiedNotificationSyncTimer = null;
      _notificationProgressRefreshTimer?.cancel();
      _notificationProgressRefreshTimer = null;
      _queuedNotificationRefreshSessionId = null;
      _notificationService.updateSnapshot(null);
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
      AudioProvider._unifiedNotificationDebounceInterval,
      () {
        _unifiedNotificationSyncTimer = null;
        _requestUnifiedPlaybackNotificationFlush();
      },
    );
  }

  void _requestUnifiedPlaybackNotificationFlush() {
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

    _queuedNotificationRefreshSessionId = sessionId;
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
          final track = trackByPath(session.currentTrackPath);
          final artPath = coverPathForTrack(track);
          return <String, dynamic>{
            'id': session.id,
            'title': title,
            if (subtitle != null && subtitle.isNotEmpty) 'subtitle': subtitle,
            if (artPath != null && artPath.isNotEmpty) 'artPath': artPath,
            'playing': session.state.playing,
            'hasPrevious': _hasAdjacentPathFor(session, forward: false),
            'hasNext': _hasAdjacentPathFor(session, forward: true),
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
    _notifyListeners();
  }

  Future<void> selectNotificationSessionFromQueue(int index) async {
    final sessions = _notificationQueueSessions;
    if (index < 0 || index >= sessions.length) return;
    _notificationFocusSessionId = sessions[index].id;
    _syncNotificationState();
    _notifyListeners();
  }
}
