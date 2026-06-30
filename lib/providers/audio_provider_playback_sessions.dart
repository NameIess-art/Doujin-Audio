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
    _notifyPlaybackChanged();
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
          session.playbackError == null &&
          _nextPathFor(session, forward: true) != null &&
          session.lastHandledCompletionGeneration != currentGeneration;
      if (shouldAutoAdvanceAfterCompletion) {
        session.isLoading = true;
        session.isAdvancingAfterCompletion = true;
        session.lastHandledCompletionGeneration = currentGeneration;
      }
      if (!state.playing &&
          (state.processingState == ProcessingState.idle ||
              state.processingState == ProcessingState.completed)) {
        session.isPlaybackStarting = false;
      }
      if (state.processingState != ProcessingState.completed) {
        session.isAdvancingAfterCompletion = false;
      }
      _syncKeepCpuAwake();
      _syncNotificationState();
      _notifyPlaybackChanged();

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
      if (changed) {
        _scheduleFocusedNotificationRefresh(session.id, immediate: true);
      }
    });
    session.subscriptions.add(positionSub);

    final durationSub = session.durationStream.listen((_) {
      if (!_sessions.containsKey(session.id)) return;
      _scheduleSaveSessionState(delay: const Duration(milliseconds: 1500));
    });
    session.subscriptions.add(durationSub);
  }

  Future<void> _prepareAndPlay(
    PlaybackSession session, {
    required String nextPath,
    bool autoPlay = true,
    bool forceStartAtZero = false,
    bool showLoading = true,
  }) async {
    if (!_sessions.containsKey(session.id)) return;

    session.loadGeneration++;
    final generation = session.loadGeneration;

    final wasLoading = session.isLoading;
    if (showLoading) {
      session.isLoading = true;
    }
    _syncKeepCpuAwake();
    if (showLoading && !wasLoading) {
      _notifyPlaybackChanged();
    }

    var prepared = false;
    final logicalNextPath = PathMatcher.normalize(nextPath);
    final resolvedNextPath = _resolveRetargetedPath(nextPath);
    try {
      if (!_sessions.containsKey(session.id) ||
          session.loadGeneration != generation) {
        return;
      }

      session.currentTrackPath = logicalNextPath;
      session.lastPersistedPositionBucket = 0;
      if (!PathMatcher.isRemoteUri(logicalNextPath)) {
        _ensureSubtitleTrackLoaded(logicalNextPath);
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

      final track = _sessionTrackForPath(session, logicalNextPath);
      final candidateUris = _candidatePlaybackUrisForTrack(track);
      final coverPath = resolvedCoverPathForTrack(track);
      if (coverPath == null) {
        unawaited(_resolveNotificationCoverPathForTrack(track));
      }

      final isNewTrack = session.loadedPath != resolvedNextPath;
      final isInitialLoad = session.loadedPath == null;

      final Duration startPosition;
      if (forceStartAtZero || (isNewTrack && !isInitialLoad)) {
        startPosition = Duration.zero;
      } else {
        startPosition = session.lastKnownPosition;
      }

      if (isNewTrack) {
        if (!isInitialLoad) {
          session.resetStreamsForNewTrack();
        }
        if (track != null && track.duration > Duration.zero) {
          session.setOptimisticDuration(track.duration);
        }
      } else if (forceStartAtZero) {
        session.setOptimisticPosition(startPosition);
      }
      _markActiveSessionsDirty();
      _notifyPlaybackChanged();

      if (isNewTrack) {
        session.pendingNativeTrackPath = resolvedNextPath;
        final title =
            track?.displayName ??
            path.basenameWithoutExtension(resolvedNextPath);
        final artUri = coverPath != null
            ? Uri.file(coverPath)
            : (track?.remoteCoverUrl == null
                  ? null
                  : Uri.tryParse(track!.remoteCoverUrl!));
        var ok = false;
        final maxAttempts = AppPlatform.usesDesktopPlaybackBridge ? 1 : 2;
        for (var attempt = 0; attempt < maxAttempts; attempt++) {
          if (attempt > 0) {
            AppLogService.warning(
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
            startPosition: startPosition,
            volume: session.volume,
            speed: session.speed,
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
            candidateUris: candidateUris,
          );
          if (!_sessions.containsKey(session.id) ||
              session.loadGeneration != generation) {
            return;
          }
          if (result.isOk) {
            final snapshot = result.valueOrNull;
            if (snapshot != null) {
              _handleNativePlaybackSnapshot(
                snapshot.copyWith(
                  audioEffects: session.audioEffects,
                  eqCapabilities: session.eqCapabilities,
                  channelSwapEnabled: session.channelSwapEnabled,
                ),
              );
            }
            ok = true;
            break;
          }
          AppLogService.warning(
            'AudioProvider._prepareAndPlay: attempt ${attempt + 1} failed: '
            '${result.errorOrNull ?? "unknown error"}.',
          );
        }
        if (!ok) return;
        if (session.channelSwapEnabled ||
            session.audioEffects.hasEnabledEffects) {
          await _nativePlaybackRepository.setAudioEffects(
            session.id,
            NativeAudioEffects(
              state: session.audioEffects,
              channelSwapEnabled: session.channelSwapEnabled,
            ),
          );
        }
        session.loadedPath = resolvedNextPath;
        session.pendingNativeTrackPath = null;
        unawaited(_cacheAsmrPlaybackTrack(track, playedPath: resolvedNextPath));
      } else {
        if (forceStartAtZero) {
          await _nativePlaybackRepository.seek(session.id, Duration.zero);
        }
        if (!_sessions.containsKey(session.id) ||
            session.loadGeneration != generation) {
          return;
        }
      }

      prepared = true;
    } catch (e, stackTrace) {
      AppLogService.error(
        'AudioProvider._prepareAndPlay error',
        error: e,
        stackTrace: stackTrace,
      );
    } finally {
      if (_sessions.containsKey(session.id) &&
          session.loadGeneration == generation) {
        session.pendingNativeTrackPath = null;
        session.isLoading = false;
        session.isAdvancingAfterCompletion = false;
        _syncKeepCpuAwake();
        _syncNotificationState();
        _scheduleSaveSessionState();
        if (showLoading || wasLoading) {
          _notifyPlaybackChanged();
        }
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

  List<Uri>? _candidatePlaybackUrisForTrack(MusicTrack? track) {
    if (track?.remoteMetadataKind != 'asmr.one') return null;
    final raw = track?.remoteMetadata?['playbackUrls'];
    if (raw is! List) return null;
    final candidates = raw
        .whereType<String>()
        .map((value) => Uri.tryParse(value.trim()))
        .whereType<Uri>()
        .where((uri) => uri.scheme == 'http' || uri.scheme == 'https')
        .toSet()
        .toList(growable: false);
    return candidates.isEmpty ? null : candidates;
  }

  Future<void> _cacheAsmrPlaybackTrack(
    MusicTrack? track, {
    required String playedPath,
  }) async {
    if (!_settingsRepository.asmrPlaybackCacheEnabled ||
        track == null ||
        track.remoteMetadataKind != 'asmr.one' ||
        !PathMatcher.isRemoteUri(track.path) ||
        !PathMatcher.isRemoteUri(playedPath)) {
      return;
    }
    final cachedPath = await _asmrPlaybackCacheService.cacheTrack(
      track,
      playedPath: playedPath,
    );
    if (cachedPath == null || cachedPath.isEmpty) return;
    _rememberRetargetedPath(track.path, cachedPath);
  }

  List<Map<String, Object?>> _nativePlaybackQueueFor(
    PlaybackSession session, {
    required String currentPath,
  }) {
    final paths = _nativePlaybackQueuePathsFor(
      session,
      currentPath: currentPath,
    );
    final cacheKey = Object.hash(
      session.loopMode,
      Object.hashAll(
        paths.map((trackPath) {
          final track = _trackForAnyPath(trackPath);
          return Object.hash(trackPath, track?.displayName, track?.groupTitle);
        }),
      ),
    );
    final cached = session.nativePlaybackQueueCache;
    if (session.nativePlaybackQueueCacheKey == cacheKey && cached != null) {
      return cached;
    }
    final queue = List<Map<String, Object?>>.unmodifiable(
      paths.map(_nativePlaybackQueueItemForPath),
    );
    session.nativePlaybackQueueCacheKey = cacheKey;
    session.nativePlaybackQueueCache = queue;
    return queue;
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
    if (session.isPlaybackQueue &&
        session.customQueueTracks?.isNotEmpty == true) {
      return session.currentQueueIndex.clamp(0, paths.length - 1);
    }
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
      Iterable<MusicTrack> candidateTracks = customQueueTracks;
      if (!session.isPlaybackQueue && !_isCrossFolderMode(session.loopMode)) {
        final currentTrack = _sessionTrackForPath(session, resolvedCurrentPath);
        if (currentTrack != null) {
          final folderKey = _folderKeyForTrack(currentTrack);
          candidateTracks = customQueueTracks.where(
            (t) => _folderKeyForTrack(t) == folderKey,
          );
        }
      }
      return candidateTracks
          .map((track) => _resolveRetargetedPath(track.path))
          .toList(growable: false);
    }
    final currentTrack = trackByPath(resolvedCurrentPath);
    switch (session.loopMode) {
      case SessionLoopMode.single:
        return <String>[resolvedCurrentPath];
      case SessionLoopMode.crossSequential:
      case SessionLoopMode.crossRandom:
        final workTrackPaths = _crossFolderTrackPathsFor(currentTrack);
        return workTrackPaths.isEmpty
            ? <String>[resolvedCurrentPath]
            : workTrackPaths;
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
    final coverPath = resolvedCoverPathForTrack(track);
    final artUri = coverPath == null
        ? track?.remoteCoverUrl
        : Uri.file(coverPath).toString();
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
      if (artUri != null && artUri.isNotEmpty) 'artUri': artUri,
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

  MusicTrack? _sessionTrackForResolvedPath(
    PlaybackSession session,
    String resolvedPath,
  ) {
    for (final track in session.customQueueTracks ?? const <MusicTrack>[]) {
      if (PathMatcher.equalsNormalized(
        _resolveRetargetedPath(track.path),
        resolvedPath,
      )) {
        return track;
      }
    }
    return null;
  }

  MusicTrack? _sessionTrackForPath(PlaybackSession session, String trackPath) {
    final normalizedPath = PathMatcher.normalize(trackPath);
    final resolvedPath = _resolveRetargetedPath(trackPath);
    for (final track in session.customQueueTracks ?? const <MusicTrack>[]) {
      if (PathMatcher.equalsNormalized(track.path, normalizedPath) ||
          PathMatcher.equalsNormalized(
            _resolveRetargetedPath(track.path),
            resolvedPath,
          )) {
        return track;
      }
    }
    return trackByPath(resolvedPath);
  }
}
