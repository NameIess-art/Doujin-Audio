part of 'playback_command_coordinator.dart';

class _PlaybackPreparationTarget {
  _PlaybackPreparationTarget({
    required this.logicalPath,
    required this.resolvedPath,
    required this.uri,
    required this.track,
    required List<Uri>? candidateUris,
    required this.coverPath,
    required this.isNewTrack,
    required this.isInitialLoad,
    required this.startPosition,
  }) : candidateUris = candidateUris == null
           ? null
           : immutableList(candidateUris);

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

class _NativePreparationResult {
  const _NativePreparationResult.success(this.snapshot)
    : error = null,
      succeeded = true;

  const _NativePreparationResult.failure(this.error)
    : snapshot = null,
      succeeded = false;

  final bool succeeded;
  final NativePlaybackSnapshot? snapshot;
  final String? error;
}

typedef _NativeQueueTrack = ({
  String path,
  MusicTrack? track,
  String? coverPath,
});

List<Map<String, Object?>> _buildNativePlaybackQueue(
  List<_NativeQueueTrack> tracks,
) => List<Map<String, Object?>>.unmodifiable(
  tracks.map((descriptor) {
    final track = descriptor.track;
    final artUri = descriptor.coverPath == null
        ? track?.remoteCoverUrl
        : Uri.file(descriptor.coverPath!).toString();
    final candidates = _candidatePlaybackUris(track);
    return <String, Object?>{
      'path': descriptor.path,
      'uri':
          PathMatcher.isContentUri(descriptor.path) ||
              PathMatcher.isRemoteUri(descriptor.path)
          ? descriptor.path
          : Uri.file(descriptor.path).toString(),
      'title':
          track?.displayName ?? path.basenameWithoutExtension(descriptor.path),
      if (track != null) 'subtitle': track.groupTitle,
      if (artUri != null && artUri.isNotEmpty) 'artUri': artUri,
      if (candidates != null)
        'candidateUris': candidates
            .map((uri) => uri.toString())
            .toList(growable: false),
    };
  }),
);

List<Uri>? _candidatePlaybackUris(MusicTrack? track) {
  if (track?.isRemoteAsmr != true) return null;
  final raw = track?.remoteMetadata?['playbackUrls'];
  if (raw is! List) return null;
  final candidates = raw
      .whereType<String>()
      .map((value) => Uri.tryParse(value.trim()))
      .whereType<Uri>()
      .where((uri) => uri.scheme == 'http' || uri.scheme == 'https')
      .expand<Uri>((uri) {
        final host = uri.host.toLowerCase();
        if (!isAsmrApiHost(host)) return <Uri>[uri];
        return asmrApiDomains.map(
          (domain) => Uri.parse(
            domain,
          ).replace(path: uri.path, query: uri.hasQuery ? uri.query : null),
        );
      })
      .toSet()
      .toList(growable: false);
  return candidates.isEmpty ? null : candidates;
}

extension PlaybackCommandPreparation on PlaybackCommandCoordinator {
  Future<bool> _prepareAndPlay(
    PlaybackSession session, {
    required String nextPath,
    bool autoPlay = true,
    bool forceStartAtZero = false,
    bool showLoading = true,
    int? targetQueueIndex,
    bool shouldStartTriggerCountdown = true,
  }) async {
    if (!_isRegisteredSession(session)) return false;
    if (!PathMatcher.equalsNormalized(session.currentTrackPath, nextPath) ||
        (targetQueueIndex != null &&
            targetQueueIndex != session.currentQueueIndex)) {
      final generation = session.playbackCommandGeneration;
      await _timerFacade.clearTimerPauseForManualStop(session.id);
      if (generation != session.playbackCommandGeneration) return false;
      if (!_isRegisteredSession(session)) return false;
    }
    if (!autoPlay) {
      if (session.loadedPath != null ||
          session.pendingNativeTrackPath != null ||
          session.state.playing) {
        if (!await _pauseSessionPlayback(session)) return false;
      } else {
        session.invalidatePreparation();
      }
      if (!_isRegisteredSession(session)) return false;
      final logicalPath = PathMatcher.normalize(nextPath);
      final trackChanged =
          !PathMatcher.equalsNormalized(
            session.currentTrackPath,
            logicalPath,
          ) ||
          (targetQueueIndex != null &&
              targetQueueIndex != session.currentQueueIndex);
      session.currentTrackPath = logicalPath;
      if (targetQueueIndex != null) {
        session.currentQueueIndex = targetQueueIndex;
      }
      session.loadedPath = null;
      if (trackChanged || forceStartAtZero) {
        session.resetStreamsForNewTrack();
        session.setOptimisticDuration(
          _sessionTrackForPath(session, logicalPath)?.duration,
        );
      }
      session.setOptimisticState(
        playing: false,
        processingState: ProcessingState.idle,
      );
      _notifyPlaybackChanged(session.id);
      _playbackFacade.scheduleSessionStatePersistence(sessionId: session.id);
      return true;
    }
    final hadDetachedPlaybackQueueCurrent = _hasDetachedPlaybackQueueCurrent(
      session,
    );

    final wasLoading = session.isLoading;
    final preparation = session.beginPreparation(
      showLoading: showLoading,
      autoPlay: autoPlay,
    );
    final generation = preparation.generation;
    if (preparation.changed) _notifyPlaybackChanged(session.id);

    var prepared = false;
    String? preparationError;
    final previousLoadedPath = session.loadedPath;
    final previousLogicalPath = session.currentTrackPath;
    final previousPosition = session.position;
    final previousWasPlaying = session.effectivePlaying;
    try {
      if (!_isSessionLoadCurrent(session, generation)) {
        return false;
      }

      final target = _resolvePlaybackPreparationTarget(
        session,
        nextPath: nextPath,
        forceStartAtZero: forceStartAtZero,
        targetQueueIndex: targetQueueIndex,
      );

      final shouldPrepareNativeTrack =
          target.isNewTrack ||
          session.state.processingState == ProcessingState.idle ||
          session.loadedPath == null;

      if (shouldPrepareNativeTrack) {
        session.markNativePreparation(generation, target.resolvedPath);
        final nativeResult = await _prepareNativeTrackWithRetry(
          session,
          target,
          generation: generation,
          targetQueueIndex: targetQueueIndex,
        );
        if (!_isSessionLoadCurrent(session, generation)) return false;
        if (!nativeResult.succeeded) {
          final failureMessage =
              nativeResult.error ?? 'Failed to prepare the selected track.';
          await _restorePreviousNativeTrack(
            session,
            generation: generation,
            previousLogicalPath: previousLogicalPath,
            previousLoadedPath: previousLoadedPath,
            previousPosition: previousPosition,
            previousWasPlaying: previousWasPlaying,
          );
          if (_isSessionLoadCurrent(session, generation)) {
            preparationError = failureMessage;
          }
          return false;
        }
        if (!_isSessionLoadCurrent(session, generation)) return false;
        session.markNativePreparation(generation, null);
        _applyPlaybackPreparationTarget(
          session,
          target,
          forceStartAtZero: forceStartAtZero,
          targetQueueIndex: targetQueueIndex,
        );
        session.loadedPath = target.resolvedPath;
        final snapshot = nativeResult.snapshot;
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
        prepared = true;
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
          return false;
        }
        _applyPlaybackPreparationTarget(
          session,
          target,
          forceStartAtZero: forceStartAtZero,
          targetQueueIndex: targetQueueIndex,
        );
        prepared = true;
      }
    } catch (e, stackTrace) {
      AppLogService.error(
        'PlaybackCommandCoordinator.prepareAndPlay error',
        error: e,
        stackTrace: stackTrace,
      );
      if (_isSessionLoadCurrent(session, generation)) {
        await _restorePreviousNativeTrack(
          session,
          generation: generation,
          previousLogicalPath: previousLogicalPath,
          previousLoadedPath: previousLoadedPath,
          previousPosition: previousPosition,
          previousWasPlaying: previousWasPlaying,
        );
      }
      if (_isSessionLoadCurrent(session, generation)) {
        preparationError = e.toString();
      }
    } finally {
      if (_isRegisteredSession(session) &&
          session.isPreparationCurrent(generation)) {
        session.finishPreparation(
          generation,
          prepared: prepared,
          autoPlay: autoPlay,
          error: preparationError,
        );
        _syncNotificationState();
        if (prepared || preparationError != null) {
          _playbackFacade.scheduleSessionStatePersistence(
            sessionId: session.id,
          );
        }
        if (showLoading || wasLoading) {
          _notifyPlaybackChanged(session.id);
        }
      }
    }

    if (!_isRegisteredSession(session) ||
        session.loadGeneration != generation) {
      return false;
    }

    if (prepared &&
        hadDetachedPlaybackQueueCurrent &&
        !_hasDetachedPlaybackQueueCurrent(session)) {
      await _syncPlaybackQueueSession(session);
    }

    if (autoPlay && prepared && session.playbackRequested) {
      return _startSessionPlayback(
        session,
        shouldStartTriggerCountdown: shouldStartTriggerCountdown,
        allowPreparationFallback: false,
      );
    } else {
      if (autoPlay) {
        session.cancelPlaybackStart(generation);
      }
      _syncNotificationState();
    }
    return prepared;
  }

  bool _isSessionLoadCurrent(PlaybackSession session, int generation) {
    return _isRegisteredSession(session) &&
        session.isPreparationCurrent(generation);
  }

  _PlaybackPreparationTarget _resolvePlaybackPreparationTarget(
    PlaybackSession session, {
    required String nextPath,
    required bool forceStartAtZero,
    int? targetQueueIndex,
    Duration? startPositionOverride,
  }) {
    final logicalPath = PathMatcher.normalize(nextPath);
    final resolvedPath = _playbackFacade.resolveRetargetedPath(nextPath);
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
    final queueIndexChanged =
        targetQueueIndex != null &&
        targetQueueIndex != session.currentQueueIndex;
    final isNewTrack = session.loadedPath != resolvedPath || queueIndexChanged;
    final isInitialLoad = session.loadedPath == null;
    final logicalTrackChanged =
        queueIndexChanged ||
        !PathMatcher.equalsNormalized(
          _playbackFacade.resolveRetargetedPath(session.currentTrackPath),
          resolvedPath,
        );
    final startPosition =
        startPositionOverride ??
        (forceStartAtZero || logicalTrackChanged
            ? Duration.zero
            : session.lastKnownPosition);
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
    int? targetQueueIndex,
  }) {
    session.currentTrackPath = target.logicalPath;
    if (targetQueueIndex != null) {
      session.currentQueueIndex = targetQueueIndex;
    }
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
        session.resetStreamsForNewTrack(position: target.startPosition);
      }
      final trackDuration = target.track?.duration ?? Duration.zero;
      if (trackDuration > Duration.zero) {
        session.setOptimisticDuration(trackDuration);
      }
    } else if (forceStartAtZero) {
      session.setOptimisticPosition(target.startPosition);
    }
    _playbackFacade.markSessionStateDirty(session.id);
    _notifyPlaybackChanged(session.id);
  }

  Future<_NativePreparationResult> _prepareNativeTrackWithRetry(
    PlaybackSession session,
    _PlaybackPreparationTarget target, {
    required int generation,
    int? targetQueueIndex,
  }) async {
    const maxAttempts = 2;
    String? lastError;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      if (attempt > 0) {
        AppLogService.warning(
          'PlaybackCommandCoordinator.prepareAndPlay: retrying prepareSession '
          'after 300ms delay.',
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
        if (!_isSessionLoadCurrent(session, generation)) {
          return const _NativePreparationResult.failure(
            'Playback preparation was superseded.',
          );
        }
      }
      final nativeQueue = await _nativePlaybackQueueFor(
        session,
        currentPath: target.resolvedPath,
      );
      if (!_isSessionLoadCurrent(session, generation)) {
        return const _NativePreparationResult.failure(
          'Playback preparation was superseded.',
        );
      }
      final result = await _nativePlaybackRepository.prepareSession(
        sessionId: session.id,
        isTemporary: session.isTemporary,
        uri: target.uri,
        title: target.title,
        path: target.resolvedPath,
        subtitle: target.track?.groupTitle,
        artUri: target.artUri,
        startPosition: target.startPosition,
        volume: session.volume,
        speed: session.speed,
        audioEffects: NativeAudioEffects(
          state: session.audioEffects,
          channelSwapEnabled: session.channelSwapEnabled,
        ),
        repeatOne: session.loopMode == SessionLoopMode.single,
        queue: nativeQueue,
        queueStartIndex: _nativePlaybackQueueStartIndexFor(
          session,
          currentPath: target.resolvedPath,
          targetQueueIndex: targetQueueIndex,
        ),
        repeatAll:
            !_hasDetachedPlaybackQueueCurrent(session) &&
            session.loopMode != SessionLoopMode.single &&
            !session.loopMode.isOneShot,
        shuffle: session.loopMode.isShuffle,
        candidateUris: target.candidateUris,
      );
      if (!_isSessionLoadCurrent(session, generation)) {
        return const _NativePreparationResult.failure(
          'Playback preparation was superseded.',
        );
      }
      if (result.isOk) {
        _playbackFacade.updateNativeSessionRetainedContentUris(
          session.id,
          <Object?>[
            target.resolvedPath,
            target.artUri?.toString(),
            for (final item in nativeQueue) ...<Object?>[
              item['path'],
              item['uri'],
              item['artUri'],
            ],
          ].whereType<String>(),
        );
        return _NativePreparationResult.success(result.valueOrNull);
      }
      lastError = result.errorOrNull;
      AppLogService.warning(
        'PlaybackCommandCoordinator.prepareAndPlay: attempt ${attempt + 1} failed: '
        '${result.errorOrNull ?? "unknown error"}.',
      );
    }
    return _NativePreparationResult.failure(lastError);
  }

  Future<bool> _restorePreviousNativeTrack(
    PlaybackSession session, {
    required int generation,
    required String previousLogicalPath,
    required String? previousLoadedPath,
    required Duration previousPosition,
    required bool previousWasPlaying,
  }) async {
    if (!_isSessionLoadCurrent(session, generation)) return false;
    if (previousLoadedPath == null || previousLogicalPath.isEmpty) {
      session.loadedPath = null;
      return false;
    }
    try {
      final restoreTarget = _resolvePlaybackPreparationTarget(
        session,
        nextPath: previousLogicalPath,
        forceStartAtZero: false,
        startPositionOverride: previousPosition,
      );
      session.markNativePreparation(generation, previousLoadedPath);
      final restored = await _prepareNativeTrackWithRetry(
        session,
        restoreTarget,
        generation: generation,
        targetQueueIndex: session.currentQueueIndex,
      );
      if (!_isSessionLoadCurrent(session, generation)) return false;
      session.markNativePreparation(generation, null);
      if (!restored.succeeded) {
        session.loadedPath = null;
        return false;
      }
      session.loadedPath = previousLoadedPath;
      final snapshot = restored.snapshot;
      if (snapshot != null) {
        _handleNativePlaybackSnapshot(snapshot);
      }
      if (previousWasPlaying &&
          !await _startSessionPlayback(
            session,
            shouldStartTriggerCountdown: false,
            allowPreparationFallback: false,
          )) {
        session.loadedPath = null;
        return false;
      }
      return true;
    } catch (error, stackTrace) {
      AppLogService.warning(
        'PlaybackCommandCoordinator failed to restore the previous native track.',
        error: error,
        stackTrace: stackTrace,
      );
      if (_isSessionLoadCurrent(session, generation)) {
        session.markNativePreparation(generation, null);
        session.loadedPath = null;
      }
      return false;
    }
  }

  List<Uri>? _candidatePlaybackUrisForTrack(MusicTrack? track) =>
      _candidatePlaybackUris(track);

  Future<void> _cacheAsmrPlaybackTrack(
    MusicTrack? track, {
    required String playedPath,
  }) async {
    if (!_asmrPlaybackCacheEnabled() ||
        track == null ||
        !track.isRemoteAsmr ||
        !PathMatcher.isRemoteUri(track.path) ||
        !PathMatcher.isRemoteUri(playedPath)) {
      return;
    }
    final cachedPath = await _asmrPlaybackCacheService.cacheTrack(
      track,
      playedPath: playedPath,
    );
    if (cachedPath == null || cachedPath.isEmpty) return;
    _playbackFacade.rememberRetargetedPath(track.path, cachedPath);
  }

  Future<List<Map<String, Object?>>> _nativePlaybackQueueFor(
    PlaybackSession session, {
    required String currentPath,
  }) async {
    final cacheKey = Object.hash(
      _playbackQueueScopeKey(session, currentPath),
      _libraryFacade.contentRevision,
      _libraryFacade.coverGeneration,
    );
    final cached = session.nativePlaybackQueueCache;
    if (session.nativePlaybackQueueCacheKey == cacheKey) {
      if (cached != null) return cached;
      final pending = session.nativePlaybackQueueFuture;
      if (pending != null) return pending;
    }
    session.nativePlaybackQueueCacheKey = cacheKey;
    session.nativePlaybackQueueCache = null;
    final paths = _nativePlaybackQueuePathsFor(
      session,
      currentPath: currentPath,
    );
    final descriptors = <_NativeQueueTrack>[];
    for (final trackPath in paths) {
      final track = _sessionTrackForPath(session, trackPath);
      descriptors.add((
        path: trackPath,
        track: track,
        coverPath: resolvedPlaybackCoverPathForTrack(track),
      ));
    }
    final pending = compute(_buildNativePlaybackQueue, descriptors);
    session.nativePlaybackQueueFuture = pending;
    try {
      final queue = await pending;
      if (_isRegisteredSession(session) &&
          session.nativePlaybackQueueCacheKey == cacheKey &&
          identical(session.nativePlaybackQueueFuture, pending)) {
        session.nativePlaybackQueueCache = queue;
      }
      return queue;
    } finally {
      if (identical(session.nativePlaybackQueueFuture, pending)) {
        session.nativePlaybackQueueFuture = null;
      }
    }
  }

  int? _nativePlaybackQueueStartIndexFor(
    PlaybackSession session, {
    required String currentPath,
    int? targetQueueIndex,
  }) {
    final resolvedCurrentPath = _playbackFacade.resolveRetargetedPath(
      currentPath,
    );
    final scope = _playbackQueueScopeFor(
      session,
      currentPath: resolvedCurrentPath,
    );
    if (targetQueueIndex != null && scope.isCustomQueue) {
      final scopedIndex = scope.queueIndices.indexOf(targetQueueIndex);
      if (scopedIndex >= 0) return scopedIndex;
    }
    return scope.currentIndex;
  }

  List<String> _nativePlaybackQueuePathsFor(
    PlaybackSession session, {
    required String currentPath,
  }) {
    return _playbackQueueScopeFor(
      session,
      currentPath: _playbackFacade.resolveRetargetedPath(currentPath),
    ).paths;
  }

  PlaybackQueueScope _playbackQueueScopeFor(
    PlaybackSession session, {
    required String currentPath,
  }) {
    final resolvedCurrentPath = _playbackFacade.resolveRetargetedPath(
      currentPath,
    );
    final sessionTrack = _sessionTrackForPath(session, resolvedCurrentPath);
    final cacheKey = _playbackQueueScopeKey(session, resolvedCurrentPath);
    final cached = session.nativePlaybackQueueScopeCache;
    if (session.nativePlaybackQueueScopeCacheKey == cacheKey &&
        cached != null) {
      return _playbackQueueResolver.repositionScope(
        cached,
        currentPath: resolvedCurrentPath,
        currentQueueIndex: session.currentQueueIndex,
      );
    }
    final queueTracks = session.isPlaybackQueue
        ? (session.hasDetachedQueueTrack
              ? session.customQueueTracks
              : session.playbackQueue!.expandedTracks)
        : session.customQueueTracks;
    final hasCustomQueue = queueTracks?.isNotEmpty == true;
    final crossFolderTrackPaths =
        !hasCustomQueue && session.loopMode.isCrossFolder
        ? _crossFolderTrackPathsFor(sessionTrack)
        : const <String>[];
    final groupKey = sessionTrack?.groupKey;
    final scope = _playbackQueueResolver.resolveScope(
      currentPath: resolvedCurrentPath,
      currentTrack: sessionTrack,
      loopMode: session.loopMode,
      sortedLibraryTrackPaths: crossFolderTrackPaths,
      tracksByGroup:
          !hasCustomQueue && groupKey != null && !session.loopMode.isCrossFolder
          ? {groupKey: _libraryFacade.tracksInGroup(groupKey)}
          : const {},
      customQueueTracks: queueTracks,
      isPlaybackQueue: session.isPlaybackQueue,
      currentQueueIndex: session.currentQueueIndex,
      trackPath: (track) => _playbackFacade.resolveRetargetedPath(track.path),
      folderKeyForTrack: _folderKeyForTrack,
    );
    session.nativePlaybackQueueScopeCacheKey = cacheKey;
    session.nativePlaybackQueueScopeCache = scope;
    return scope;
  }

  int _playbackQueueScopeKey(PlaybackSession session, String currentPath) {
    final track = _sessionTrackForPath(session, currentPath);
    final hasCustomQueue =
        session.isPlaybackQueue ||
        session.customQueueTracks?.isNotEmpty == true;
    final singleTrackScope =
        !hasCustomQueue &&
        (track?.isSingle == true || session.loopMode == SessionLoopMode.single);
    final crossFolderScope =
        !singleTrackScope &&
        (session.loopMode.isCrossFolder || (hasCustomQueue && track == null));
    final scopeIdentity = singleTrackScope
        ? currentPath
        : crossFolderScope
        ? null
        : track?.groupKey;
    return Object.hash(
      session.queueVersion,
      singleTrackScope,
      crossFolderScope,
      scopeIdentity,
      hasCustomQueue ? 0 : _libraryFacade.structureRevision,
      _playbackFacade.retargetRevision,
    );
  }

  bool _hasDetachedPlaybackQueueCurrent(PlaybackSession session) {
    return session.hasDetachedQueueTrack && session.currentQueueIndex == 0;
  }

  MusicTrack? _sessionTrackForPath(PlaybackSession session, String trackPath) {
    final resolvedPath = _playbackFacade.resolveRetargetedPath(trackPath);
    var sessionTrack = session.trackForPath(
      trackPath,
      resolvedPath: resolvedPath,
    );
    if (sessionTrack == null) {
      final originalPath =
          _playbackFacade.originalPathForRetargeted(trackPath) ??
          _playbackFacade.originalPathForRetargeted(resolvedPath);
      if (originalPath != null) {
        sessionTrack = session.trackForPath(originalPath);
      }
    }
    if (sessionTrack != null) return sessionTrack;
    return _libraryFacade.trackByPath(resolvedPath);
  }
}
