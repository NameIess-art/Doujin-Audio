part of 'playback_command_coordinator.dart';

extension PlaybackCommandQueueSync on PlaybackCommandCoordinator {
  Future<void> synchronizeLoopMode(
    PlaybackSession session,
    SessionLoopMode mode,
  ) async {
    if (!_isRegisteredSession(session) || session.loadedPath == null) return;
    final generation = session.loadGeneration;
    final queueRevision = session.queueVersion;
    final previousQueue = session.nativePlaybackQueueCache;
    final nativeQueue = await _nativePlaybackQueueFor(
      session,
      currentPath: session.currentTrackPath,
    );
    if (!_isRegisteredSession(session) ||
        session.loadGeneration != generation ||
        session.queueVersion != queueRevision ||
        session.loopMode != mode) {
      return;
    }
    final scopeChanged =
        previousQueue == null ||
        previousQueue.length != nativeQueue.length ||
        previousQueue.indexed.any(
          (item) => item.$2['path'] != nativeQueue[item.$1]['path'],
        );
    final result = scopeChanged
        ? await _nativePlaybackRepository.updateQueue(
            session.id,
            queue: nativeQueue,
            queueRevision: queueRevision,
            queueStartIndex: _nativePlaybackQueueStartIndexFor(
              session,
              currentPath: session.currentTrackPath,
            ),
            repeatOne: mode == SessionLoopMode.single,
            repeatAll: mode != SessionLoopMode.single && !mode.isOneShot,
            shuffle: mode.isShuffle,
          )
        : await _nativePlaybackRepository.setRepeatOne(
            session.id,
            mode == SessionLoopMode.single,
            repeatAll: mode != SessionLoopMode.single && !mode.isOneShot,
            shuffle: mode.isShuffle,
          );
    if (!result.isOk ||
        !_isRegisteredSession(session) ||
        session.loadGeneration != generation ||
        session.queueVersion != queueRevision ||
        session.loopMode != mode) {
      return;
    }
    _playbackFacade.updateNativeSessionRetainedContentUris(
      session.id,
      <Object?>[
        session.currentTrackPath,
        for (final item in nativeQueue) ...<Object?>[
          item['path'],
          item['uri'],
          item['artUri'],
        ],
      ].whereType<String>(),
    );
  }

  Future<void> _syncPlaybackQueueSession(
    PlaybackSession session, {
    bool selectFirst = false,
  }) async {
    if (!_isRegisteredSession(session)) return;
    final queueTracks =
        session.playbackQueue?.expandedTracks ?? const <MusicTrack>[];
    final previousPath = session.currentTrackPath;
    if (session.hasDetachedQueueTrack && session.currentQueueIndex > 0) {
      session.currentQueueIndex -= 1;
      session.hasDetachedQueueTrack = false;
    }
    final previousIndex = session.currentQueueIndex;
    final wasPlaying = session.playbackRequested;
    session.invalidatePreparation();
    final generation = session.loadGeneration;
    final previousRuntimeTracks = session.customQueueTracks;
    final queueContainsCurrent =
        !session.hasDetachedQueueTrack &&
        previousIndex >= 0 &&
        queueTracks.any(
          (track) => PathMatcher.equalsNormalized(track.path, previousPath),
        );
    MusicTrack? retainedCurrentTrack;
    if (!selectFirst &&
        (session.loadedPath != null || session.hasDetachedQueueTrack) &&
        previousPath.isNotEmpty &&
        !queueContainsCurrent) {
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
    session.hasDetachedQueueTrack = retainedCurrentTrack != null;
    final queueRevision = session.queueVersion;

    if (tracks.isEmpty) {
      final hadNativeSession = session.loadedPath != null;
      session.currentTrackPath = '';
      session.currentQueueIndex = 0;
      session.loadedPath = null;
      session.resetStreamsForNewTrack();
      session.setOptimisticState(
        playing: false,
        processingState: ProcessingState.idle,
      );
      _notifyPlaybackChanged(session.id);
      if (!hadNativeSession) return;
      final response = await _nativePlaybackRepository.removeSession(
        session.id,
      );
      if (!_isRegisteredSession(session) ||
          session.queueVersion != queueRevision ||
          session.loadGeneration != generation) {
        return;
      }
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
        final matchingIndex =
            nextIndex >= 0 &&
                nextIndex < tracks.length &&
                PathMatcher.equalsNormalized(
                  tracks[nextIndex].path,
                  previousPath,
                )
            ? nextIndex
            : tracks.indexWhere(
                (track) =>
                    PathMatcher.equalsNormalized(track.path, previousPath),
              );
        if (matchingIndex >= 0) {
          nextIndex = matchingIndex;
        } else {
          nextIndex = previousIndex.clamp(0, tracks.length - 1);
        }
      }
      if (session.loadedPath == null && !wasPlaying) {
        final trackChanged =
            !PathMatcher.equalsNormalized(
              previousPath,
              tracks[nextIndex].path,
            ) ||
            (previousIndex < 0 && retainedCurrentTrack == null);
        session.currentQueueIndex = nextIndex;
        session.currentTrackPath = tracks[nextIndex].path;
        if (trackChanged || selectFirst) {
          session.resetStreamsForNewTrack();
          session.setOptimisticDuration(tracks[nextIndex].duration);
        }
        _notifyPlaybackChanged(session.id);
        _playbackFacade.scheduleSessionStatePersistence(sessionId: session.id);
        return;
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
        _notifyPlaybackChanged(session.id);
        final nativeQueue = await nativePlaybackQueueFor(
          session,
          currentPath: session.currentTrackPath,
        );
        if (!_isRegisteredSession(session) ||
            session.queueVersion != queueRevision ||
            session.loadGeneration != generation) {
          return;
        }
        final loopMode = session.loopMode;
        final result = await _nativePlaybackRepository.updateQueue(
          session.id,
          repeatOne: loopMode == SessionLoopMode.single,
          queue: nativeQueue,
          queueRevision: queueRevision,
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
        if (!_isRegisteredSession(session) ||
            session.queueVersion != queueRevision ||
            session.loadGeneration != generation) {
          return;
        }
        if (result.isOk && result.valueOrNull != null) {
          _handleNativePlaybackSnapshot(result.valueOrNull!);
        }
        _syncNotificationState();
        _playbackFacade.scheduleSessionStatePersistence(sessionId: session.id);
        _notifyPlaybackChanged(session.id);
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
