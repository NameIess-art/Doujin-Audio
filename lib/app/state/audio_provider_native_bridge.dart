part of 'audio_provider.dart';

extension AudioProviderNativeBridge on AudioProvider {
  void _handleNativePlaybackSnapshot(NativePlaybackSnapshot snapshot) {
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
      _playbackService.markActiveSessionsDirty();
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
        final libraryTrack = _libraryByPath[trackPath];
        if (libraryTrack != null) {
          _libraryByPath[trackPath] = updatedTrack;
          final index = _library.indexOf(libraryTrack);
          if (index != -1) {
            _library[index] = updatedTrack;
          }
          unawaited(_audioDatabaseRepository.upsertTracks([updatedTrack]));
        }
        if (_playbackFacade.replaceSessionTrackSnapshots(updatedTrack)) {
          _playbackService.markActiveSessionsDirty();
          _playbackFacade.scheduleSessionStatePersistence(
            delay: const Duration(milliseconds: 800),
          );
        }
      }
    }
    if (application.playbackIntentChanged) {
      _syncKeepCpuAwake();
      _notifyPlaybackChanged();
    }
  }
}
