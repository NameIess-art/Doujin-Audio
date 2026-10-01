part of 'notification_facade.dart';

extension NotificationFacadeSync on NotificationFacade {
  List<PlaybackSession> get _notificationQueueSessions => activeSessions;

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
    _lastNotificationItems = const <Map<String, dynamic>>[];
    _lastNotificationMainSessionId = null;
    await _notificationService.clearUnifiedNotifications();
  }

  void _syncNotificationState({bool immediateUnifiedSync = false}) {
    if (!_synchronizationAttached) return;
    if (_stateService.synchronizationPaused) {
      _stateService.synchronizationPendingWhilePaused = true;
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
    if (_stateService.synchronizationPaused) {
      _unifiedNotificationSyncPending = false;
      _stateService.synchronizationPendingWhilePaused = true;
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
        if (_stateService.synchronizationPaused) {
          _unifiedNotificationSyncPending = false;
          _stateService.synchronizationPendingWhilePaused = true;
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
    if (_stateService.synchronizationPaused) {
      _stateService.synchronizationPendingWhilePaused = true;
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
      if (_stateService.synchronizationPaused) {
        _queuedNotificationRefreshSessionId = queuedSessionId;
        _stateService.synchronizationPendingWhilePaused = true;
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
    final sessionsToShow = activeSessions;
    final mainSession = _focusedSessionFrom(sessionsToShow);
    final sessionIds = sessionsToShow.map((session) => session.id).toSet();
    _notificationPresentations.removeWhere((id, _) => !sessionIds.contains(id));
    final payload = sessionsToShow
        .map(_notificationPayloadForSession)
        .toList(growable: false);
    final unchangedItems =
        payload.length == _lastNotificationItems.length &&
        Iterable<int>.generate(payload.length).every(
          (index) => identical(payload[index], _lastNotificationItems[index]),
        );
    if (_unifiedNotificationSyncKey != null &&
        _lastNotificationMainSessionId == mainSession?.id &&
        unchangedItems) {
      return;
    }
    final syncPayload = <String, dynamic>{
      'mainSessionId': mainSession?.id,
      'items': payload,
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
    _lastNotificationItems = payload;
    _lastNotificationMainSessionId = mainSession?.id;
  }

  Map<String, dynamic> _notificationPayloadForSession(PlaybackSession session) {
    final previous = _notificationPresentations[session.id];
    final trackPath = session.currentTrackPath;
    final coverGeneration = _coverArtworkCacheService.generation;
    final metadataChanged =
        previous == null ||
        !identical(previous.session, session) ||
        previous.trackPath != trackPath ||
        previous.coverGeneration != coverGeneration;
    final navigation = (
      queueVersion: session.queueVersion,
      queueIndex: session.currentQueueIndex,
      loopMode: session.loopMode,
    );
    final navigationChanged =
        metadataChanged || previous.navigation != navigation;
    final track = metadataChanged ? trackByPath(trackPath) : null;
    final artPath = metadataChanged
        ? coverPathForTrack(track, trackPath: trackPath)
        : previous.payload['artPath'] as String?;
    final subtitle = _notificationSubtitleForSession(session);
    final next = <String, dynamic>{
      'id': session.id,
      'title': metadataChanged
          ? track?.displayName ?? path.basenameWithoutExtension(trackPath)
          : previous.payload['title'],
      if (subtitle != null && subtitle.isNotEmpty) 'subtitle': subtitle,
      if (artPath != null && artPath.isNotEmpty) 'artPath': artPath,
      'playing': session.state.playing,
      'hasPrevious': navigationChanged
          ? _playbackCommands.hasAdjacent(session, forward: false)
          : previous.payload['hasPrevious'],
      'hasNext': navigationChanged
          ? _playbackCommands.hasAdjacent(session, forward: true)
          : previous.payload['hasNext'],
    };
    final previousPayload = previous?.payload;
    final payload =
        previousPayload != null &&
            previousPayload.length == next.length &&
            next.entries.every(
              (entry) => previousPayload[entry.key] == entry.value,
            )
        ? previousPayload
        : next;
    final presentation = _NotificationSessionPresentation(
      session: session,
      trackPath: trackPath,
      coverGeneration: coverGeneration,
      navigation: navigation,
      coverSearchKey: metadataChanged
          ? _notificationCoverSearchKey(track, trackPath: trackPath)
          : previous.coverSearchKey,
      payload: payload,
    );
    _notificationPresentations[session.id] = presentation;
    if (metadataChanged && artPath == null) {
      unawaited(
        _resolveNotificationCoverPathForTrack(track, trackPath: trackPath).then(
          (resolved) {
            final current = _notificationPresentations[session.id];
            if (resolved == null ||
                resolved.isEmpty ||
                current == null ||
                !identical(current.session, session) ||
                current.trackPath != trackPath ||
                !identical(_sessions[session.id], session) ||
                session.currentTrackPath != trackPath ||
                coverGeneration != _coverArtworkCacheService.generation) {
              return;
            }
            current.payload = <String, dynamic>{
              ...current.payload,
              'artPath': resolved,
            };
            _syncNotificationState();
          },
        ),
      );
    }
    return payload;
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

final class _NotificationSessionPresentation {
  _NotificationSessionPresentation({
    required this.session,
    required this.trackPath,
    required this.coverGeneration,
    required this.navigation,
    required this.coverSearchKey,
    required this.payload,
  });

  final PlaybackSession session;
  final String trackPath;
  final int coverGeneration;
  final ({int queueVersion, int queueIndex, SessionLoopMode loopMode})
  navigation;
  final String? coverSearchKey;
  Map<String, dynamic> payload;
}
