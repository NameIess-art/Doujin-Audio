part of 'audio_provider.dart';

class _PlaybackPreparationTarget {
  const _PlaybackPreparationTarget({
    required this.logicalPath,
    required this.resolvedPath,
    required this.uri,
    required this.track,
    required this.candidateUris,
    required this.coverPath,
    required this.isNewTrack,
    required this.isInitialLoad,
    required this.startPosition,
  });

  final String logicalPath;
  final String resolvedPath;
  final Uri uri;
  final MusicTrack? track;
  final List<Uri>? candidateUris;
  final String? coverPath;
  final bool isNewTrack;
  final bool isInitialLoad;
  final Duration startPosition;

  String get title =>
      track?.displayName ?? path.basenameWithoutExtension(resolvedPath);

  Uri? get artUri => coverPath != null
      ? Uri.file(coverPath!)
      : (track?.remoteCoverUrl == null
            ? null
            : Uri.tryParse(track!.remoteCoverUrl!));
}

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
    double? volume,
    List<MusicTrack>? customQueueTracks,
  }) {
    final session = PlaybackSession(
      id: _nextSessionId(),
      currentTrackPath: track.path,
      loopMode: loopMode,
      nonSingleLoopMode: loopMode == SessionLoopMode.single
          ? SessionLoopMode.folderSequential
          : loopMode,
      volume: (volume ?? _settingsRepository.defaultSessionVolume)
          .clamp(0.0, _maxSessionVolume)
          .toDouble(),
      createdAt: DateTime.now(),
      state: PlayerState(false, ProcessingState.idle),
      customQueueTracks: customQueueTracks,
    );
    session.speed = _nearestPlaybackSpeed(
      _settingsRepository.defaultSessionSpeed,
    );
    session.channelSwapEnabled =
        _settingsRepository.defaultSessionChannelSwapEnabled;
    session.audioEffects = _settingsRepository.defaultSessionAudioEffects;
    return session;
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
    try {
      if (!_isSessionLoadCurrent(session, generation)) {
        return;
      }

      final target = _resolvePlaybackPreparationTarget(
        session,
        nextPath: nextPath,
        forceStartAtZero: forceStartAtZero,
      );
      _applyPlaybackPreparationTarget(
        session,
        target,
        forceStartAtZero: forceStartAtZero,
      );

      if (target.isNewTrack) {
        prepared = await _prepareNativeTrackWithRetry(
          session,
          target,
          generation: generation,
        );
        if (!prepared) return;
        await _syncPreparedTrackEffects(session);
        if (!_isSessionLoadCurrent(session, generation)) return;
        session.loadedPath = target.resolvedPath;
        session.pendingNativeTrackPath = null;
        unawaited(
          _cacheAsmrPlaybackTrack(
            target.track,
            playedPath: target.resolvedPath,
          ),
        );
      } else {
        if (forceStartAtZero) {
          await _nativePlaybackRepository.seek(session.id, Duration.zero);
        }
        if (!_isSessionLoadCurrent(session, generation)) {
          return;
        }
        prepared = true;
      }
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

  bool _isSessionLoadCurrent(PlaybackSession session, int generation) {
    return _sessions.containsKey(session.id) &&
        session.loadGeneration == generation;
  }

  _PlaybackPreparationTarget _resolvePlaybackPreparationTarget(
    PlaybackSession session, {
    required String nextPath,
    required bool forceStartAtZero,
  }) {
    final logicalPath = PathMatcher.normalize(nextPath);
    final resolvedPath = _resolveRetargetedPath(nextPath);
    final uri =
        PathMatcher.isContentUri(resolvedPath) ||
            PathMatcher.isRemoteUri(resolvedPath)
        ? Uri.parse(resolvedPath)
        : Uri.file(resolvedPath);
    final track = _sessionTrackForPath(session, logicalPath);
    final coverPath = resolvedPlaybackCoverPathForTrack(track);
    if (coverPath == null) {
      unawaited(_resolveNotificationCoverPathForTrack(track));
    }
    final isNewTrack = session.loadedPath != resolvedPath;
    final isInitialLoad = session.loadedPath == null;
    final startPosition = forceStartAtZero || (isNewTrack && !isInitialLoad)
        ? Duration.zero
        : session.lastKnownPosition;
    return _PlaybackPreparationTarget(
      logicalPath: logicalPath,
      resolvedPath: resolvedPath,
      uri: uri,
      track: track,
      candidateUris: _candidatePlaybackUrisForTrack(track),
      coverPath: coverPath,
      isNewTrack: isNewTrack,
      isInitialLoad: isInitialLoad,
      startPosition: startPosition,
    );
  }

  void _applyPlaybackPreparationTarget(
    PlaybackSession session,
    _PlaybackPreparationTarget target, {
    required bool forceStartAtZero,
  }) {
    session.currentTrackPath = target.logicalPath;
    session.lastPersistedPositionBucket = 0;
    if (!PathMatcher.isRemoteUri(target.logicalPath)) {
      _ensureSubtitleTrackLoaded(target.logicalPath);
      _refreshNotificationSubtitleForSession(
        session,
        position: Duration.zero,
        syncNotification: false,
      );
    }
    if (target.isNewTrack) {
      if (!target.isInitialLoad) {
        session.resetStreamsForNewTrack();
      }
      final trackDuration = target.track?.duration ?? Duration.zero;
      if (trackDuration > Duration.zero) {
        session.setOptimisticDuration(trackDuration);
      }
    } else if (forceStartAtZero) {
      session.setOptimisticPosition(target.startPosition);
    }
    _markActiveSessionsDirty();
    _notifyPlaybackChanged();
  }

  Future<bool> _prepareNativeTrackWithRetry(
    PlaybackSession session,
    _PlaybackPreparationTarget target, {
    required int generation,
  }) async {
    session.pendingNativeTrackPath = target.resolvedPath;
    final maxAttempts = AppPlatform.usesDesktopPlaybackBridge ? 1 : 2;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      if (attempt > 0) {
        AppLogService.warning(
          'AudioProvider._prepareAndPlay: retrying prepareSession '
          'after 300ms delay.',
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
        if (!_isSessionLoadCurrent(session, generation)) {
          return false;
        }
      }
      final result = await _nativePlaybackRepository.prepareSession(
        sessionId: session.id,
        uri: target.uri,
        title: target.title,
        path: target.resolvedPath,
        subtitle: target.track?.groupTitle,
        artUri: target.artUri,
        startPosition: target.startPosition,
        volume: session.volume,
        speed: session.speed,
        repeatOne: session.loopMode == SessionLoopMode.single,
        queue: _nativePlaybackQueueFor(
          session,
          currentPath: target.resolvedPath,
        ),
        queueStartIndex: _nativePlaybackQueueStartIndexFor(
          session,
          currentPath: target.resolvedPath,
        ),
        repeatAll: session.loopMode != SessionLoopMode.single,
        shuffle: _isShuffleMode(session.loopMode),
        candidateUris: target.candidateUris,
      );
      if (!_isSessionLoadCurrent(session, generation)) {
        return false;
      }
      if (result.isOk) {
        final snapshot = result.valueOrNull;
        if (snapshot != null) {
          _handleNativePlaybackSnapshot(
            snapshot.copyWith(
              volume: session.volume,
              audioEffects: session.audioEffects,
              eqCapabilities: session.eqCapabilities,
              channelSwapEnabled: session.channelSwapEnabled,
            ),
          );
        }
        return true;
      }
      AppLogService.warning(
        'AudioProvider._prepareAndPlay: attempt ${attempt + 1} failed: '
        '${result.errorOrNull ?? "unknown error"}.',
      );
    }
    return false;
  }

  Future<void> _syncPreparedTrackEffects(PlaybackSession session) async {
    if (!session.channelSwapEnabled &&
        !session.audioEffects.hasEnabledEffects) {
      return;
    }
    await _nativePlaybackRepository.setAudioEffects(
      session.id,
      NativeAudioEffects(
        state: session.audioEffects,
        channelSwapEnabled: session.channelSwapEnabled,
      ),
    );
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
    final scope = _playbackQueueScopeFor(
      session,
      currentPath: resolvedCurrentPath,
    );
    return scope.currentIndex;
  }

  List<String> _nativePlaybackQueuePathsFor(
    PlaybackSession session, {
    required String currentPath,
  }) {
    return _playbackQueueScopeFor(
      session,
      currentPath: _resolveRetargetedPath(currentPath),
    ).paths;
  }

  PlaybackQueueScope _playbackQueueScopeFor(
    PlaybackSession session, {
    required String currentPath,
  }) {
    final resolvedCurrentPath = _resolveRetargetedPath(currentPath);
    final currentTrack = trackByPath(resolvedCurrentPath);
    final sessionTrack = _sessionTrackForPath(session, resolvedCurrentPath);
    final scopeTrack = session.customQueueTracks?.isNotEmpty == true
        ? sessionTrack
        : currentTrack;
    final crossFolderTrackPaths = _isCrossFolderMode(session.loopMode)
        ? _crossFolderTrackPathsFor(currentTrack)
        : _sortedLibraryTrackPaths;
    return _playbackQueueResolver.resolveScope(
      currentPath: resolvedCurrentPath,
      currentTrack: scopeTrack,
      loopMode: session.loopMode,
      sortedLibraryTrackPaths: crossFolderTrackPaths,
      tracksByGroup: _tracksByGroup,
      customQueueTracks: session.customQueueTracks,
      isPlaybackQueue: session.isPlaybackQueue,
      currentQueueIndex: session.currentQueueIndex,
      trackPath: (track) => _resolveRetargetedPath(track.path),
      folderKeyForTrack: _folderKeyForTrack,
    );
  }

  Map<String, Object?> _nativePlaybackQueueItemForPath(String trackPath) {
    final resolvedTrackPath = _resolveRetargetedPath(trackPath);
    final track = _trackForAnyPath(resolvedTrackPath);
    final subtitle = track?.groupTitle;
    final coverPath = resolvedPlaybackCoverPathForTrack(track);
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
