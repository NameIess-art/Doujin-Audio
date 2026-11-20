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
    final wasPlaying = currentSession?.state.playing == true;
    final wasDetachedCurrent =
        currentSession != null &&
        _hasDetachedPlaybackQueueCurrent(currentSession);
    final discardDetachedQueuePrefix =
        currentSession?.hasDetachedQueueTrack == true &&
        snapshot.discardedQueuePrefix;
    var consumeDetachedTrack = false;
    if (snapshot.queueIndex >= 0 &&
        currentSession != null &&
        (currentSession.customQueueTracks?.isNotEmpty == true ||
            currentSession.isPlaybackQueue)) {
      // Translating the native index only needs the cached paths and indices.
      final scope =
          (discardDetachedQueuePrefix
              ? currentSession.nativePlaybackQueueScopeCache
              : null) ??
          _playbackQueueScopeFor(
            currentSession,
            currentPath: discardDetachedQueuePrefix
                ? currentSession.customQueueTracks?.firstOrNull?.path ??
                      currentSession.currentTrackPath
                : snapshot.path ?? currentSession.currentTrackPath,
            repositionCurrentIndex: false,
          );
      final nativeIndex = discardDetachedQueuePrefix
          ? snapshot.queueIndex + 1
          : snapshot.queueIndex;
      if (nativeIndex < scope.queueIndices.length &&
          (snapshot.path == null ||
              PathMatcher.equalsNormalized(
                scope.paths[nativeIndex],
                _playbackFacade.resolveRetargetedPath(snapshot.path!),
              ))) {
        final queueIndex = scope.queueIndices[nativeIndex];
        consumeDetachedTrack = discardDetachedQueuePrefix && queueIndex > 0;
        snapshot = snapshot.copyWith(
          queueIndex: consumeDetachedTrack ? queueIndex - 1 : queueIndex,
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
    if (_onAudiblePlaybackChanged case final onChanged?) {
      final audiblePath =
          application.snapshot.playing &&
              application.snapshot.processingState == 'ready'
          ? application.session!.currentTrackPath
          : null;
      if (audiblePath != _audibleTrackPaths[snapshot.sessionId]) {
        if (audiblePath == null) {
          _audibleTrackPaths.remove(snapshot.sessionId);
        } else {
          _audibleTrackPaths[snapshot.sessionId] = audiblePath;
        }
        onChanged();
      }
    }
    _timerFacade.reconcileTrackStopTargets();
    if (wasPlaying && !application.snapshot.playWhenReady) {
      _timerFacade.onNativePlaybackPaused();
    }
    _syncActivePlaybackCacheLease(application.session!);
    final normalizedSnapshot = application.snapshot;
    final session = application.session;
    final previousTrackPath = application.previousTrackPath;
    if (consumeDetachedTrack && session != null) {
      session.customQueueTracks = session.playbackQueue?.expandedTracks;
      session.hasDetachedQueueTrack = false;
    }

    // Update track duration in library if it was unknown
    if (session != null &&
        previousTrackPath != null &&
        (application.trackChanged || consumeDetachedTrack)) {
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
        !consumeDetachedTrack &&
        !snapshot.discardedQueuePrefix &&
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
