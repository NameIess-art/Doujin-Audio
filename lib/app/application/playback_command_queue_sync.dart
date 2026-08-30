part of 'playback_command_coordinator.dart';

extension PlaybackCommandQueueSync on PlaybackCommandCoordinator {
  Future<void> _syncPlaybackQueueSession(
    PlaybackSession session, {
    bool selectFirst = false,
  }) async {
    final queueTracks =
        session.playbackQueue?.expandedTracks ?? const <MusicTrack>[];
    final previousPath = session.currentTrackPath;
    final previousIndex = session.currentQueueIndex;
    final wasPlaying = session.state.playing;
    final previousRuntimeTracks = session.customQueueTracks;
    final queueContainsCurrent = queueTracks.any(
      (track) => PathMatcher.equalsNormalized(track.path, previousPath),
    );
    MusicTrack? retainedCurrentTrack;
    if (!selectFirst && previousPath.isNotEmpty && !queueContainsCurrent) {
      for (final track in previousRuntimeTracks ?? const <MusicTrack>[]) {
        if (PathMatcher.equalsNormalized(track.path, previousPath)) {
          retainedCurrentTrack = track;
          break;
        }
      }
    }
    final tracks = retainedCurrentTrack == null
        ? queueTracks
        : <MusicTrack>[retainedCurrentTrack, ...queueTracks];
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
      final response = await _nativePlaybackRepository.removeSession(
        session.id,
      );
      if (response.isOk) {
        _playbackFacade.forgetNativeSessionRetainedContentUris(session.id);
      }
    } else {
      var nextIndex = retainedCurrentTrack != null
          ? 0
          : selectFirst
          ? 0
          : previousIndex.clamp(0, tracks.length - 1);
      if (!selectFirst && previousPath.isNotEmpty) {
        final matchingIndex = tracks.indexWhere(
          (track) => PathMatcher.equalsNormalized(track.path, previousPath),
        );
        if (matchingIndex >= 0) {
          nextIndex = matchingIndex;
        } else {
          nextIndex = previousIndex.clamp(0, tracks.length - 1);
        }
      }
      if (!selectFirst &&
          previousPath.isNotEmpty &&
          (retainedCurrentTrack != null ||
              (session.loadedPath != null &&
                  PathMatcher.equalsNormalized(
                    session.loadedPath!,
                    _playbackFacade.resolveRetargetedPath(previousPath),
                  ))) &&
          PathMatcher.equalsNormalized(tracks[nextIndex].path, previousPath)) {
        session.currentQueueIndex = nextIndex;
        session.currentTrackPath = tracks[nextIndex].path;
        final nativeQueue = nativePlaybackQueueFor(
          session,
          currentPath: session.currentTrackPath,
        );
        final loopMode = session.loopMode;
        await _nativePlaybackRepository.setRepeatOne(
          session.id,
          loopMode == SessionLoopMode.single,
          queue: nativeQueue,
          queueStartIndex: nativePlaybackQueueStartIndexFor(
            session,
            currentPath: session.currentTrackPath,
          ),
          repeatAll:
              retainedCurrentTrack == null &&
              loopMode != SessionLoopMode.single &&
              !loopMode.isOneShot,
          shuffle: loopMode.isShuffle,
        );
        _syncNotificationState();
        _playbackFacade.scheduleSessionStatePersistence();
        _notifyPlaybackChanged();
      } else {
        await _prepareAndPlay(
          session,
          nextPath: tracks[nextIndex].path,
          autoPlay: wasPlaying,
          targetQueueIndex: nextIndex,
        );
      }
    }
  }
}
