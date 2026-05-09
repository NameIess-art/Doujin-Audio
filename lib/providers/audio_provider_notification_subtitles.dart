part of 'audio_provider.dart';

extension AudioProviderNotificationSubtitles on AudioProvider {
  Future<SubtitleTrack?> subtitleTrackForPath(String trackPath) {
    if (_subtitleTracks.containsKey(trackPath)) {
      return Future<SubtitleTrack?>.value(_subtitleTracks[trackPath]);
    }

    return _subtitleTrackFutures.putIfAbsent(trackPath, () async {
      try {
        final subtitleTrack = await loadSubtitleTrackForAudio(trackPath);
        _subtitleTracks[trackPath] = subtitleTrack;
        
        // Memory optimization: Simple LRU eviction for subtitle tracks
        if (_subtitleTracks.length > 20) {
          final oldestKey = _subtitleTracks.keys.first;
          _subtitleTracks.remove(oldestKey);
        }

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
          _notifyListeners();
        }
        return subtitleTrack;
      } finally {
        _subtitleTrackFutures.remove(trackPath)?.ignore();
      }
    });
  }

  SubtitleTrack? getSubtitleTrackSync(String trackPath) {
    return _subtitleTracks[trackPath];
  }

  String? subtitleTextForTrackAt(
    String trackPath,
    Duration position, {
    SubtitleTrack? subtitleTrack,
  }) {
    final resolvedTrack = subtitleTrack;
    final cue = resolvedTrack?.cueAt(position);
    if (cue == null) return null;
    final text = cue.text.trim();
    return text.isEmpty ? null : text;
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
      ? AudioProvider._multiSessionNotificationRefreshInterval
      : AudioProvider._notificationProgressRefreshInterval;

  void _ensureSubtitleTrackLoaded(String trackPath) {
    if (_subtitleTracks.containsKey(trackPath) ||
        _subtitleTrackFutures.containsKey(trackPath)) {
      return;
    }
    unawaited(subtitleTrackForPath(trackPath));
  }

  bool _refreshNotificationSubtitleForSession(
    PlaybackSession session, {
    Duration? position,
    bool syncNotification = true,
  }) {
    final trackPath = session.currentTrackPath;
    _ensureSubtitleTrackLoaded(trackPath);
    final nextText = subtitleTextForTrackAt(
      trackPath,
      position ?? session.position,
      subtitleTrack: _subtitleTracks[trackPath],
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
