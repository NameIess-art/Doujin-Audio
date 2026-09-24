part of 'playback_command_coordinator.dart';

extension PlaybackCommandNativeMapper on PlaybackCommandCoordinator {
  void _handleNativePlaybackSnapshot(NativePlaybackSnapshot snapshot) {
    if (snapshot.hasRetainedUrisPayload) {
      _playbackFacade.updateNativeSessionRetainedContentUris(
        snapshot.sessionId,
        snapshot.retainedUris,
      );
    }
    final currentSession = _sessions[snapshot.sessionId];
    if (currentSession != null &&
        (currentSession.customQueueTracks?.isNotEmpty == true ||
            currentSession.isPlaybackQueue)) {
      final scope = _playbackQueueScopeFor(
        currentSession,
        currentPath: snapshot.path ?? currentSession.currentTrackPath,
      );
      if (snapshot.queueIndex >= 0 &&
          snapshot.queueIndex < scope.queueIndices.length &&
          (snapshot.path == null ||
              PathMatcher.equalsNormalized(
                scope.paths[snapshot.queueIndex],
                _playbackFacade.resolveRetargetedPath(snapshot.path!),
              ))) {
        snapshot = snapshot.copyWith(
          queueIndex: scope.queueIndices[snapshot.queueIndex],
        );
      }
    }
    final application = _playbackFacade.applyNativeSnapshot(
      snapshot,
      hasLibraryTrack: (path) =>
          _audioPathCoordinator.trackByPath(
            path,
            includeLibraryFallback: false,
          ) !=
          null,
    );
    if (!application.applied) return;
    _syncActivePlaybackCacheLease();
    final normalizedSnapshot = application.snapshot;
    final session = application.session;
    final previousTrackPath = application.previousTrackPath;

    // Update track duration in library if it was unknown
    if (session != null &&
        previousTrackPath != null &&
        application.trackChanged) {
      final leftDetachedPlaybackQueueTrack = _isDetachedPlaybackQueuePath(
        session,
        previousTrackPath,
      );
      _ensureSubtitleTrackLoaded(session.currentTrackPath);
      _refreshNotificationSubtitleForSession(
        session,
        position: session.position,
        syncNotification: false,
      );
      _playbackFacade.markSessionStateDirty();
      _syncNotificationState();
      _playbackFacade.scheduleSessionStatePersistence(
        delay: const Duration(milliseconds: 800),
      );
      _notifyPlaybackChanged();
      if (leftDetachedPlaybackQueueTrack) {
        unawaited(_syncPlaybackQueueSession(session));
      }
    }
    final trackPath = session?.currentTrackPath;
    if (trackPath != null && normalizedSnapshot.duration != null) {
      final track = _audioPathCoordinator.trackByPath(
        trackPath,
        includeLibraryFallback: false,
      );
      if (track != null && track.duration == Duration.zero) {
        final updatedTrack = track.copyWith(
          duration: normalizedSnapshot.duration!,
        );
        _libraryFacade.updateTrackSnapshot(updatedTrack);
        if (_playbackFacade.replaceSessionTrackSnapshots(updatedTrack)) {
          _playbackFacade.markSessionStateDirty();
          _playbackFacade.scheduleSessionStatePersistence(
            delay: const Duration(milliseconds: 800),
          );
        }
      }
    }
    if (application.playbackIntentChanged) {
      _notifyPlaybackChanged();
    }
  }
}
