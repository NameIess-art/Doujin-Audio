part of 'audio_provider.dart';

extension AudioProviderNativeBridge on AudioProvider {
  void _handleNativePlaybackSnapshot(NativePlaybackSnapshot snapshot) {
    _playbackService.applyNativeSnapshot(snapshot);
    
    // Update track duration in library if it was unknown
    final session = _sessions[snapshot.sessionId];
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
