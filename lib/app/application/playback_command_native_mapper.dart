part of 'playback_command_coordinator.dart';

extension PlaybackCommandNativeMapper on PlaybackCommandCoordinator {
  void _handleNativePlaybackSnapshot(NativePlaybackSnapshot snapshot) {
    if (snapshot.hasRetainedUrisPayload) {
      _playbackFacade.updateNativeSessionRetainedContentUris(
        snapshot.sessionId,
        snapshot.retainedUris,
      );
    }
    final application = _playbackFacade.applyNativeSnapshot(
      snapshot,
      hasLibraryTrack: (path) => trackByPath(path) != null,
    );
    if (!application.applied) return;
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
      _playbackFacade.markSessionStateDirty();
      _syncNotificationState();
      _playbackFacade.scheduleSessionStatePersistence(
        delay: const Duration(milliseconds: 800),
      );
      _notifyPlaybackChanged();
    }
    final trackPath = session?.currentTrackPath;
    if (trackPath != null && normalizedSnapshot.duration != null) {
      final track = trackByPath(trackPath);
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
