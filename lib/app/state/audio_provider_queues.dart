part of 'audio_provider.dart';

extension AudioProviderQueues on AudioProvider {
  Future<void> _syncPlaybackQueueSession(
    PlaybackSession session, {
    bool selectFirst = false,
  }) async {
    final tracks =
        session.playbackQueue?.expandedTracks ?? const <MusicTrack>[];
    final previousPath = session.currentTrackPath;
    final previousIndex = session.currentQueueIndex;
    final wasPlaying = session.state.playing;
    session.customQueueTracks = List<MusicTrack>.unmodifiable(tracks);

    if (tracks.isEmpty) {
      session.currentTrackPath = '';
      session.currentQueueIndex = 0;
      session.loadedPath = null;
      session.resetStreamsForNewTrack();
      session.setOptimisticState(
        playing: false,
        processingState: ProcessingState.idle,
      );
      await _nativePlaybackRepository.removeSession(session.id);
    } else {
      var nextIndex = selectFirst
          ? 0
          : previousIndex.clamp(0, tracks.length - 1);
      if (!selectFirst &&
          nextIndex < tracks.length &&
          !PathMatcher.equalsNormalized(tracks[nextIndex].path, previousPath)) {
        final matchingIndex = tracks.indexWhere(
          (track) => PathMatcher.equalsNormalized(track.path, previousPath),
        );
        nextIndex = matchingIndex < 0 ? 0 : matchingIndex;
      }
      await _prepareAndPlay(
        session,
        nextPath: tracks[nextIndex].path,
        autoPlay: wasPlaying,
        targetQueueIndex: nextIndex,
      );
    }
  }
}
