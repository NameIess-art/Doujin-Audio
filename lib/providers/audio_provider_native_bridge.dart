part of 'audio_provider.dart';

extension AudioProviderNativeBridge on AudioProvider {
  void _handleNativePlaybackSnapshot(NativePlaybackSnapshot snapshot) {
    final previousTrackPath = _sessions[snapshot.sessionId]?.currentTrackPath;
    _playbackService.applyNativeSnapshot(snapshot);

    // Update track duration in library if it was unknown
    final session = _sessions[snapshot.sessionId];
    if (session != null &&
        previousTrackPath != null &&
        session.currentTrackPath != previousTrackPath) {
      _ensureSubtitleTrackLoaded(session.currentTrackPath);
      _refreshNotificationSubtitleForSession(
        session,
        position: session.position,
        syncNotification: false,
      );
      _markActiveSessionsDirty();
      _syncNotificationState();
      _scheduleSaveSessionState(delay: const Duration(milliseconds: 800));
      _notifyListeners();
    }
    final trackPath = session?.currentTrackPath;
    if (trackPath != null && snapshot.duration != null) {
      final track = _libraryByPath[trackPath];
      if (track != null && track.duration == Duration.zero) {
        final updatedTrack = track.copyWith(duration: snapshot.duration!);
        _libraryByPath[trackPath] = updatedTrack;
        final index = _library.indexOf(track);
        if (index != -1) {
          _library[index] = updatedTrack;
          unawaited(_audioDatabaseRepository.upsertTracks([updatedTrack]));
        }
      }
    }
  }
}
