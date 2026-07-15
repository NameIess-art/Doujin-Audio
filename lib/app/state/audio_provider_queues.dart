part of 'audio_provider.dart';

extension AudioProviderQueues on AudioProvider {
  Future<void> addWorkToPlaybackQueue(
    String sessionId,
    MusicTrack track,
  ) async {
    if (track.isSingle) {
      await _playbackFacade.addTrackToPlaybackQueue(sessionId, track);
      return;
    }
    final workTracks = tracksInSameWork(track.path);
    final groupTracks = tracksInSameGroup(track.path);
    final tracks = workTracks.isNotEmpty
        ? workTracks
        : groupTracks.isNotEmpty
        ? groupTracks
        : (library
              .where(
                (candidate) => PathMatcher.equalsNormalized(
                  candidate.groupKey,
                  track.groupKey,
                ),
              )
              .toList(growable: false)
            ..sort(getTrackComparator));
    if (tracks.isEmpty) return;
    final resolvedWorkRootPath = workRootForTrack(track.path);
    final workRootPath = resolvedWorkRootPath?.isNotEmpty == true
        ? resolvedWorkRootPath
        : track.groupKey.trim().isEmpty || track.groupKey == '__single_files__'
        ? null
        : PathMatcher.normalize(track.groupKey);
    await _playbackFacade.addWorkToPlaybackQueue(
      sessionId,
      title: track.groupTitle,
      tracks: tracks,
      workRootPath: workRootPath,
    );
  }

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
