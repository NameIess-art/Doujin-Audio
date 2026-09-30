part of 'notification_facade.dart';

extension NotificationFacadeCovers on NotificationFacade {
  Future<void> _resumeNotificationSession(PlaybackSession session) async {
    if (session.isLoading || session.state.playing) return;
    _notificationFocusSessionId = session.id;
    if (session.state.processingState == ProcessingState.completed) {
      await _playbackCommands.prepareAndPlay(
        session,
        nextPath: session.currentTrackPath,
        forceStartAtZero: true,
      );
      return;
    }
    await _playbackCommands.startSession(
      session,
      shouldStartTriggerCountdown: true,
    );
  }

  String _notificationSummaryText(List<String> sessionTitles) {
    final titles = sessionTitles
        .where((title) => title.isNotEmpty)
        .toSet()
        .toList();
    if (titles.isEmpty) return '${sessionTitles.length} active sessions';
    if (titles.length == 1) return titles.first;
    if (titles.length == 2) return '${titles[0]} / ${titles[1]}';
    return '${titles.first} +${titles.length - 1}';
  }

  String? coverPathForTrack(MusicTrack? track, {String? trackPath}) {
    return resolvedPlaybackCoverPathForTrack(track, trackPath: trackPath);
  }

  String? resolvedCoverPathForTrack(MusicTrack? track, {String? trackPath}) {
    return _coverArtworkCacheService.resolvedForTrack(
      track,
      trackPath: trackPath,
    );
  }

  String? resolvedPlaybackCoverPathForTrack(
    MusicTrack? track, {
    String? trackPath,
  }) {
    return _coverArtworkCacheService.resolvedForPlaybackTrack(
      track,
      trackPath: trackPath,
    );
  }

  String? resolvedCoverPathForFolder(String folderPath) {
    return _coverArtworkCacheService.resolvedForFolder(folderPath);
  }

  String? resolvedCoverPathForRemoteCover(String url) {
    return _coverArtworkCacheService.resolvedForRemoteCover(url);
  }

  Future<String?> coverPathFutureForTrack(
    MusicTrack? track, {
    String? trackPath,
  }) {
    return _coverArtworkCacheService.futureForTrack(
      track,
      trackPath: trackPath,
    );
  }

  Future<String?> playbackCoverPathFutureForTrack(
    MusicTrack? track, {
    String? trackPath,
  }) {
    return _coverArtworkCacheService.futureForPlaybackTrack(
      track,
      trackPath: trackPath,
    );
  }

  Future<String?> coverPathFutureForFolder(String folderPath) {
    return _coverArtworkCacheService.futureForFolder(folderPath);
  }

  Future<String?> coverPathFutureForRemoteCover(String url) {
    return _coverArtworkCacheService.futureForRemoteCover(url);
  }

  Future<String?> _resolveNotificationCoverPathForTrack(
    MusicTrack? track, {
    String? trackPath,
  }) {
    return playbackCoverPathFutureForTrack(track, trackPath: trackPath);
  }

  bool isCoverPathLoadingForFolder(String folderPath) {
    return _coverArtworkCacheService.isLoadingForFolder(folderPath);
  }

  String? _notificationCoverSearchKey(MusicTrack? track, {String? trackPath}) {
    return _coverArtworkCacheService.coverSearchKeyForTrack(
      track,
      trackPath: trackPath,
    );
  }

  bool _isActiveCoverKey(String coverSearchKey) {
    var active = false;
    for (final session in activeSessions) {
      final cached = _notificationPresentations[session.id];
      if (cached != null && cached.trackPath == session.currentTrackPath) {
        if (cached.coverSearchKey == coverSearchKey) {
          _notificationPresentations.remove(session.id);
          active = true;
        }
        continue;
      }
      final track = trackByPath(session.currentTrackPath);
      if (_notificationCoverSearchKey(
            track,
            trackPath: session.currentTrackPath,
          ) ==
          coverSearchKey) {
        active = true;
      }
    }
    return active;
  }
}
