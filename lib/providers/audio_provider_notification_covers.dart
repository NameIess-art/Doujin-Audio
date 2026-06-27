part of 'audio_provider.dart';

extension AudioProviderNotificationCovers on AudioProvider {
  Future<void> _resumeNotificationSession(PlaybackSession session) async {
    if (session.isLoading || session.state.playing) return;
    _notificationFocusSessionId = session.id;
    if (session.state.processingState == ProcessingState.completed) {
      await _prepareAndPlay(
        session,
        nextPath: session.currentTrackPath,
        forceStartAtZero: true,
      );
      return;
    }
    await _startSessionPlayback(session, shouldStartTriggerCountdown: true);
  }

  String _notificationTitleForSession(PlaybackSession session) {
    final trackPath = session.currentTrackPath;
    final track = trackByPath(trackPath);
    final artPath = coverPathForTrack(track, trackPath: trackPath);
    if (artPath == null) {
      unawaited(coverPathFutureForTrack(track, trackPath: trackPath));
    }
    return track?.displayName ??
        path.basenameWithoutExtension(session.currentTrackPath);
  }

  List<String> _notificationOverviewTitles(Iterable<PlaybackSession> sessions) {
    final uniqueTitles = <String>{};
    for (final session in sessions) {
      final title = _notificationTitleForSession(session);
      if (title.isNotEmpty) uniqueTitles.add(title);
    }
    return uniqueTitles.toList(growable: false);
  }

  String _notificationSummaryText(List<PlaybackSession> sessions) {
    final titles = _notificationOverviewTitles(sessions);
    if (titles.isEmpty) return '${sessions.length} active sessions';
    if (titles.length == 1) return titles.first;
    if (titles.length == 2) return '${titles[0]} / ${titles[1]}';
    return '${titles.first} +${titles.length - 1}';
  }

  String? coverPathForTrack(MusicTrack? track, {String? trackPath}) {
    return resolvedCoverPathForTrack(track, trackPath: trackPath);
  }

  String? resolvedCoverPathForTrack(MusicTrack? track, {String? trackPath}) {
    return _coverArtworkCacheService.resolvedForTrack(
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
    return coverPathFutureForTrack(track, trackPath: trackPath);
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

  String? _resolveCoverScopeFolderPath(MusicTrack? track, {String? trackPath}) {
    return _coverArtworkCacheService.coverScopeFolderForTrack(
      track,
      trackPath: trackPath,
    );
  }

  bool _isActiveCoverKey(String coverSearchKey) {
    for (final session in activeSessions) {
      final track = trackByPath(session.currentTrackPath);
      if (_notificationCoverSearchKey(
            track,
            trackPath: session.currentTrackPath,
          ) ==
          coverSearchKey) {
        return true;
      }
    }
    return false;
  }
}
