part of 'audio_provider.dart';

extension AudioProviderPlaybackSessions on AudioProvider {
  Future<void> spawnSession(MusicTrack track, {bool? autoPlay}) async {
    final session = _createSessionForTrack(track);
    _registerSession(session);
    _scheduleSessionPersistence();
    unawaited(
      _enqueueSessionPreparation(
        session,
        nextPath: track.path,
        autoPlay: autoPlay ?? _autoPlayAddedSessions,
      ),
    );
  }

  Future<void> spawnSessionWithQueue(
    List<MusicTrack> tracks, {
    int startIndex = 0,
    bool? autoPlay,
    SessionLoopMode loopMode = SessionLoopMode.folderSequential,
  }) async {
    if (tracks.isEmpty) return;
    final clampedStartIndex = startIndex.clamp(0, tracks.length - 1);
    final startTrack = tracks[clampedStartIndex];
    final session = _createSessionForTrack(
      startTrack,
      loopMode: loopMode,
      customQueueTracks: List<MusicTrack>.unmodifiable(tracks),
    );
    _registerSession(session);
    _scheduleSessionPersistence();
    unawaited(
      _enqueueSessionPreparation(
        session,
        nextPath: startTrack.path,
        autoPlay: autoPlay ?? _autoPlayAddedSessions,
      ),
    );
  }

  PlaybackSession _createSessionForTrack(
    MusicTrack track, {
    SessionLoopMode loopMode = SessionLoopMode.folderSequential,
    double volume = 1.0,
    List<MusicTrack>? customQueueTracks,
  }) {
    return PlaybackSession(
      id: _nextSessionId(),
      currentTrackPath: track.path,
      loopMode: loopMode,
      nonSingleLoopMode: loopMode == SessionLoopMode.single
          ? SessionLoopMode.folderSequential
          : loopMode,
      volume: volume,
      createdAt: DateTime.now(),
      state: PlayerState(false, ProcessingState.idle),
      customQueueTracks: customQueueTracks,
    );
  }

  void _registerSession(PlaybackSession session) {
    _playbackService.registerSession(session);
    _notificationsDismissedWhilePaused = false;
    _notificationFocusSessionId = session.id;
    _bindSessionListeners(session);
    _syncKeepCpuAwake();
    _syncNotificationState();
    _notifyListeners();
  }

  Future<void> _enqueueSessionPreparation(
    PlaybackSession session, {
    required String nextPath,
    required bool autoPlay,
  }) {
    _playbackService.enqueueSessionPreparation(() async {
      if (!_sessions.containsKey(session.id)) return;
      await _prepareAndPlay(session, nextPath: nextPath, autoPlay: autoPlay);
    });
    return _sessionPreparationQueue;
  }

  void _bindSessionListeners(PlaybackSession session) {
    final stateSub = session.stateStream.listen((state) {
      if (!_sessions.containsKey(session.id)) return;

      final previousState =
          session.previousStateBeforeLastStateEvent ?? session.state;
      session.previousStateBeforeLastStateEvent = null;
      final previousPlaying = previousState.playing;
      final previousProcessing = previousState.processingState;
      session.state = state;
      final isNewCompletion =
          previousProcessing != ProcessingState.completed &&
          state.processingState == ProcessingState.completed;
      final currentGeneration = session.playbackCommandGeneration;
      final shouldAutoAdvanceAfterCompletion =
          isNewCompletion &&
          !session.isLoading &&
          !session.isAdvancingAfterCompletion &&
          session.loopMode != SessionLoopMode.single &&
          _nextPathFor(session, forward: true) != null &&
          session.lastHandledCompletionGeneration != currentGeneration;
      if (shouldAutoAdvanceAfterCompletion) {
        session.isLoading = true;
        session.isAdvancingAfterCompletion = true;
        session.lastHandledCompletionGeneration = currentGeneration;
      }
      if (state.processingState == ProcessingState.idle ||
          state.processingState == ProcessingState.completed) {
        session.isPlaybackStarting = false;
      }
      if (state.processingState != ProcessingState.completed) {
        session.isAdvancingAfterCompletion = false;
      }
      _syncKeepCpuAwake();
      _syncNotificationState();
      _notifyListeners();

      if (previousPlaying != state.playing ||
          previousProcessing != state.processingState) {
        _scheduleSaveSessionState();
      }

      if (isNewCompletion && shouldAutoAdvanceAfterCompletion) {
        _handleSessionCompleted(session.id);
      }
    });
    session.subscriptions.add(stateSub);

    final positionSub = session.positionStream.listen((position) {
      if (!_sessions.containsKey(session.id)) return;
      session.lastKnownPosition = position;
      final positionBucket = position.inSeconds ~/ 5;
      if (positionBucket != session.lastPersistedPositionBucket) {
        session.lastPersistedPositionBucket = positionBucket;
        _scheduleSaveSessionState(delay: const Duration(milliseconds: 800));
      }
      if (!_isNotificationFocusedSessionId(session.id)) return;
      final changed = _refreshNotificationSubtitleForSession(
        session,
        position: position,
        syncNotification: false,
      );
      _scheduleFocusedNotificationRefresh(session.id, immediate: changed);
    });
    session.subscriptions.add(positionSub);

    final durationSub = session.durationStream.listen((_) {
      if (!_sessions.containsKey(session.id)) return;
      _scheduleSaveSessionState(delay: const Duration(milliseconds: 1500));
      if (!_isNotificationFocusedSessionId(session.id)) return;
      _scheduleFocusedNotificationRefresh(session.id, immediate: true);
    });
    session.subscriptions.add(durationSub);

    final bufferedPositionSub = session.bufferedPositionStream.listen((_) {
      if (!_sessions.containsKey(session.id)) return;
      if (!session.state.playing &&
          !session.isLoading &&
          !session.isPlaybackStarting) {
        return;
      }
      if (!_isNotificationFocusedSessionId(session.id)) return;
      _scheduleFocusedNotificationRefresh(session.id);
    });
    session.subscriptions.add(bufferedPositionSub);
  }

  Future<void> _prepareAndPlay(
    PlaybackSession session, {
    required String nextPath,
    bool autoPlay = true,
  }) async {
    if (!_sessions.containsKey(session.id)) return;

    session.loadGeneration++;
    final generation = session.loadGeneration;
    session.playbackCommandGeneration = generation;

    final wasLoading = session.isLoading;
    session.isLoading = true;
    _syncKeepCpuAwake();
    _syncNotificationState();
    if (!wasLoading) {
      _notifyListeners();
    }

    var prepared = false;
    final resolvedNextPath = _resolveRetargetedPath(nextPath);
    try {
      if (!_sessions.containsKey(session.id) ||
          session.loadGeneration != generation) {
        return;
      }

      session.currentTrackPath = resolvedNextPath;
      session.lastPersistedPositionBucket = 0;
      if (!PathMatcher.isRemoteUri(resolvedNextPath)) {
        _ensureSubtitleTrackLoaded(resolvedNextPath);
        _refreshNotificationSubtitleForSession(
          session,
          position: Duration.zero,
          syncNotification: false,
        );
      }

      final uri =
          PathMatcher.isContentUri(resolvedNextPath) ||
              PathMatcher.isRemoteUri(resolvedNextPath)
          ? Uri.parse(resolvedNextPath)
          : Uri.file(resolvedNextPath);

      final track = _sessionTrackForPath(session, resolvedNextPath);
      final coverPath = await _resolveNotificationCoverPathForTrack(track);

      final isNewTrack = session.loadedPath != resolvedNextPath;
      if (isNewTrack) {
        session.resetStreamsForNewTrack();
      } else {
        session.setOptimisticPosition(Duration.zero);
      }
      _markActiveSessionsDirty();
      _notifyListeners();

      if (isNewTrack) {
        final title =
            track?.displayName ??
            path.basenameWithoutExtension(resolvedNextPath);
        final artUri = coverPath == null ? null : Uri.file(coverPath);
        var ok = false;
        for (var attempt = 0; attempt < 2; attempt++) {
          if (attempt > 0) {
            debugPrint(
              'AudioProvider._prepareAndPlay: retrying prepareSession '
              'after 300ms delay.',
            );
            await Future<void>.delayed(const Duration(milliseconds: 300));
            if (!_sessions.containsKey(session.id) ||
                session.loadGeneration != generation) {
              return;
            }
          }
          final result = await _nativePlaybackRepository.prepareSession(
            sessionId: session.id,
            uri: uri,
            title: title,
            path: resolvedNextPath,
            subtitle: track?.groupTitle,
            artUri: artUri,
            volume: session.volume,
            repeatOne: session.loopMode == SessionLoopMode.single,
            queue: _nativePlaybackQueueFor(
              session,
              currentPath: resolvedNextPath,
            ),
            queueStartIndex: _nativePlaybackQueueStartIndexFor(
              session,
              currentPath: resolvedNextPath,
            ),
            repeatAll: session.loopMode != SessionLoopMode.single,
            shuffle: _isShuffleMode(session.loopMode),
          );
          if (!_sessions.containsKey(session.id) ||
              session.loadGeneration != generation) {
            return;
          }
          if (result.isOk) {
            ok = true;
            break;
          }
          debugPrint(
            'AudioProvider._prepareAndPlay: attempt ${attempt + 1} failed: '
            '${result.errorOrNull ?? "unknown error"}.',
          );
        }
        if (!ok) return;
        session.loadedPath = resolvedNextPath;
      } else {
        await _nativePlaybackRepository.seek(session.id, Duration.zero);
        if (!_sessions.containsKey(session.id) ||
            session.loadGeneration != generation) {
          return;
        }
      }

      prepared = true;
    } catch (e) {
      debugPrint('AudioProvider._prepareAndPlay error: $e');
    } finally {
      if (_sessions.containsKey(session.id) &&
          session.loadGeneration == generation) {
        session.isLoading = false;
        session.isAdvancingAfterCompletion = false;
        _syncKeepCpuAwake();
        _syncNotificationState();
        _scheduleSaveSessionState();
        _notifyListeners();
      }
    }

    if (!_sessions.containsKey(session.id) ||
        session.loadGeneration != generation) {
      return;
    }

    if (autoPlay && prepared) {
      await _startSessionPlayback(session, shouldStartTriggerCountdown: true);
    } else {
      _syncNotificationState();
      _syncKeepCpuAwake();
    }
  }

  List<Map<String, Object?>> _nativePlaybackQueueFor(
    PlaybackSession session, {
    required String currentPath,
  }) {
    final paths = _nativePlaybackQueuePathsFor(
      session,
      currentPath: currentPath,
    );
    return paths.map(_nativePlaybackQueueItemForPath).toList(growable: false);
  }

  int? _nativePlaybackQueueStartIndexFor(
    PlaybackSession session, {
    required String currentPath,
  }) {
    final resolvedCurrentPath = _resolveRetargetedPath(currentPath);
    final paths = _nativePlaybackQueuePathsFor(
      session,
      currentPath: resolvedCurrentPath,
    );
    final index = paths.indexOf(resolvedCurrentPath);
    return index < 0 ? 0 : index;
  }

  List<String> _nativePlaybackQueuePathsFor(
    PlaybackSession session, {
    required String currentPath,
  }) {
    final resolvedCurrentPath = _resolveRetargetedPath(currentPath);
    final customQueueTracks = session.customQueueTracks;
    if (customQueueTracks != null && customQueueTracks.isNotEmpty) {
      if (session.loopMode == SessionLoopMode.single) {
        return <String>[resolvedCurrentPath];
      }
      return customQueueTracks
          .map((track) => _resolveRetargetedPath(track.path))
          .toList(growable: false);
    }
    final currentTrack = trackByPath(resolvedCurrentPath);
    switch (session.loopMode) {
      case SessionLoopMode.single:
        return <String>[resolvedCurrentPath];
      case SessionLoopMode.crossSequential:
      case SessionLoopMode.crossRandom:
        return _sortedLibraryTrackPaths.isEmpty
            ? <String>[resolvedCurrentPath]
            : _sortedLibraryTrackPaths;
      case SessionLoopMode.folderSequential:
      case SessionLoopMode.folderRandom:
        final groupTracks = currentTrack == null
            ? const <MusicTrack>[]
            : _tracksByGroup[currentTrack.groupKey] ?? const <MusicTrack>[];
        return groupTracks.isEmpty
            ? <String>[resolvedCurrentPath]
            : groupTracks.map((track) => track.path).toList(growable: false);
    }
  }

  Map<String, Object?> _nativePlaybackQueueItemForPath(String trackPath) {
    final resolvedTrackPath = _resolveRetargetedPath(trackPath);
    final track = _trackForAnyPath(resolvedTrackPath);
    final subtitle = track?.groupTitle;
    return <String, Object?>{
      'path': resolvedTrackPath,
      'uri':
          PathMatcher.isContentUri(resolvedTrackPath) ||
              PathMatcher.isRemoteUri(resolvedTrackPath)
          ? resolvedTrackPath
          : Uri.file(resolvedTrackPath).toString(),
      'title':
          track?.displayName ??
          path.basenameWithoutExtension(resolvedTrackPath),
      // ignore: use_null_aware_elements
      if (subtitle != null) 'subtitle': subtitle,
    };
  }

  MusicTrack? _trackForAnyPath(String trackPath) {
    final resolvedPath = _resolveRetargetedPath(trackPath);
    final libraryTrack = trackByPath(resolvedPath);
    if (libraryTrack != null) {
      return libraryTrack;
    }
    for (final session in _sessions.values) {
      final track = _sessionTrackForPath(session, resolvedPath);
      if (track != null) {
        return track;
      }
    }
    return null;
  }

  MusicTrack? _sessionTrackForPath(PlaybackSession session, String trackPath) {
    final resolvedPath = _resolveRetargetedPath(trackPath);
    for (final track in session.customQueueTracks ?? const <MusicTrack>[]) {
      if (PathMatcher.equalsNormalized(track.path, resolvedPath)) {
        return track;
      }
    }
    return trackByPath(resolvedPath);
  }
}
