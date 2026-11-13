part of 'notification_facade.dart';

extension NotificationFacadeSubtitles on NotificationFacade {
  void _handleSubtitleTrackLoaded(String trackPath, SubtitleTrack? track) {
    if (!_notificationsEnabled) return;
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

  String? _notificationSubtitleForSession(PlaybackSession session) {
    if (_notificationSubtitleTrackPaths[session.id] !=
            session.currentTrackPath ||
        !_notificationSubtitleTexts.containsKey(session.id)) {
      _refreshNotificationSubtitleForSession(session, syncNotification: false);
    } else if (_notificationsEnabled) {
      // Periodic notifications can observe source changes while paused.
      final (:loading, text: _) = _subtitleService.readPlaybackSubtitle(
        session.currentTrackPath,
        session.position,
      );
      unawaited(loading);
    }
    return _notificationSubtitleTexts[session.id];
  }

  bool get _shouldUseUnifiedPlaybackNotifications => true;

  Duration get _notificationRefreshInterval =>
      _shouldUseUnifiedPlaybackNotifications
      ? NotificationFacade._multiSessionNotificationRefreshInterval
      : NotificationFacade._notificationProgressRefreshInterval;

  bool _refreshNotificationSubtitleForSession(
    PlaybackSession session, {
    Duration? position,
    bool syncNotification = true,
  }) {
    if (!_notificationsEnabled) return false;
    final trackPath = session.currentTrackPath;
    final (text: nextText, :loading) = _subtitleService.readPlaybackSubtitle(
      trackPath,
      position ?? session.position,
    );
    unawaited(loading);
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
