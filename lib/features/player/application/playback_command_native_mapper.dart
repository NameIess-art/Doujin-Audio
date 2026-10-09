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
    final wasDetachedCurrent =
        currentSession != null &&
        _hasDetachedPlaybackQueueCurrent(currentSession);
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
          currentSession != null &&
          _sessionTrackForPath(currentSession, path) != null,
    );
    if (!application.applied) return;
    _timerFacade.reconcileTrackStopTargets();
    _syncActivePlaybackCacheLease(application.session!);
    final normalizedSnapshot = application.snapshot;
    final session = application.session;
    final previousTrackPath = application.previousTrackPath;

    // Update track duration in library if it was unknown
    if (session != null &&
        previousTrackPath != null &&
        application.trackChanged) {
      _ensureSubtitleTrackLoaded(session.currentTrackPath);
      _refreshNotificationSubtitleForSession(
        session,
        position: session.position,
        syncNotification: false,
      );
      _playbackFacade.markSessionStateDirty(session.id);
      _syncNotificationState();
      _playbackFacade.scheduleSessionStatePersistence(
        sessionId: session.id,
        delay: const Duration(milliseconds: 800),
      );
      _notifyPlaybackChanged(snapshot.sessionId);
    }
    if (wasDetachedCurrent &&
        session != null &&
        session.currentQueueIndex > 0) {
      unawaited(_syncPlaybackQueueSession(session));
    }
    final trackPath = session?.currentTrackPath;
    if (trackPath != null && normalizedSnapshot.duration != null) {
      final track = _sessionTrackForPath(session!, trackPath);
      if (track != null && track.duration == Duration.zero) {
        final updatedTrack = track.copyWith(
          duration: normalizedSnapshot.duration!,
        );
        _libraryFacade.updateTrackDuration(trackPath, updatedTrack.duration);
        _playbackFacade.replaceSessionTrackSnapshots(updatedTrack);
      }
    }
    if (application.playbackIntentChanged) {
      _notifyPlaybackChanged(snapshot.sessionId);
    }
  }
}
