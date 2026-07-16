part of 'notification_facade.dart';

extension NotificationFacadeSubtitles on NotificationFacade {
  Future<SubtitleTrack?> _subtitleTrackForPath(String trackPath) {
    return _subtitleService.load(trackPath);
  }

  void _handleSubtitleTrackLoaded(String trackPath, SubtitleTrack? track) {
    var shouldRefreshNotification = false;
    for (final session in _sessions.values) {
      if (session.currentTrackPath != trackPath) continue;
      final changed = _refreshNotificationSubtitleForSession(
        session,
        syncNotification: false,
      );
      if (changed && _notificationFocusedSession?.id == session.id) {
        shouldRefreshNotification = true;
      }
    }
    if (shouldRefreshNotification) {
      _syncNotificationState();
      _notifyNotificationChanged();
    } else if (track != null) {
      _notifyNotificationChanged();
    }
  }

  String? _subtitleTextForTrackAt(
    String trackPath,
    Duration position, {
    SubtitleTrack? subtitleTrack,
  }) {
    return _subtitleService.textAt(
      trackPath,
      position,
      subtitleTrack: subtitleTrack,
    );
  }

  String? _notificationSubtitleForSession(PlaybackSession session) {
    _ensureSubtitleTrackLoaded(session.currentTrackPath);
    if (_notificationSubtitleTrackPaths[session.id] !=
            session.currentTrackPath ||
        !_notificationSubtitleTexts.containsKey(session.id)) {
      _refreshNotificationSubtitleForSession(session, syncNotification: false);
    }
    return _notificationSubtitleTexts[session.id];
  }

  bool get _shouldUseUnifiedPlaybackNotifications =>
      _multiThreadPlaybackEnabled;

  Duration get _notificationRefreshInterval =>
      _shouldUseUnifiedPlaybackNotifications
      ? NotificationFacade._multiSessionNotificationRefreshInterval
      : NotificationFacade._notificationProgressRefreshInterval;

  void _ensureSubtitleTrackLoaded(String trackPath) {
    if (_subtitleService.hasResult(trackPath) ||
        _subtitleService.isLoading(trackPath)) {
      return;
    }
    unawaited(_subtitleTrackForPath(trackPath));
  }

  bool _refreshNotificationSubtitleForSession(
    PlaybackSession session, {
    Duration? position,
    bool syncNotification = true,
  }) {
    final trackPath = session.currentTrackPath;
    _ensureSubtitleTrackLoaded(trackPath);
    final nextText = _subtitleTextForTrackAt(
      trackPath,
      position ?? session.position,
      subtitleTrack: _subtitleService.trackSync(trackPath),
    );
    final previousText = _notificationSubtitleTexts[session.id];
    final previousTrackPath = _notificationSubtitleTrackPaths[session.id];
    if (previousTrackPath == trackPath && previousText == nextText) {
      return false;
    }

    _notificationSubtitleTexts[session.id] = nextText;
    _notificationSubtitleTrackPaths[session.id] = trackPath;

    if (syncNotification && _notificationFocusedSession?.id == session.id) {
      _syncNotificationState();
    }
    return true;
  }

  void _clearNotificationSubtitleForSession(String sessionId) {
    _notificationSubtitleTexts.remove(sessionId);
    _notificationSubtitleTrackPaths.remove(sessionId);
  }
}
