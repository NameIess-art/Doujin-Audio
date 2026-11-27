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
  Map<String, String> httpHeaders,
  bool playOnceBeforeQueue,
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
    final reference = PlaybackMediaReference.parse(
      descriptor.path,
      sourceId: track?.remoteSourceId,
    );
    final headers = descriptor.httpHeaders.isNotEmpty
        ? descriptor.httpHeaders
        : reference.httpHeaders;
    return <String, Object?>{
      'path': descriptor.path,
      'uri':
          PathMatcher.isContentUri(descriptor.path) ||
              PathMatcher.isRemoteUri(descriptor.path)
          ? reference.streamUrl
          : Uri.file(descriptor.path).toString(),
      if (reference.isChapter) 'clipStartMs': reference.startMs,
      if (reference.endMs != null) 'clipEndMs': reference.endMs,
      if (headers.isNotEmpty || track?.remoteSourceId != null)
        'httpHeaders': headers,
      if (descriptor.playOnceBeforeQueue) 'playOnceBeforeQueue': true,
      'title':
          track?.displayName ?? path.basenameWithoutExtension(descriptor.path),
      if (track != null) 'subtitle': track.groupTitle,
      if (track != null) 'usageDescriptor': track.toJson(),
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
      .map(
        (value) =>
            Uri.tryParse(PlaybackMediaReference.parse(value.trim()).streamUrl),
      )
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
    double? initialFadeMultiplier,
  }) async {
    if (!_isRegisteredSession(session)) return false;
    final hadDetachedPlaybackQueueCurrent = _hasDetachedPlaybackQueueCurrent(
      session,
    );
    if (!PathMatcher.equalsNormalized(session.currentTrackPath, nextPath) ||
        (targetQueueIndex != null &&
            targetQueueIndex != session.currentQueueIndex)) {
      final generation = session.playbackCommandGeneration;
      await _timerFacade.clearTimerPauseForManualStop(session.id);
      if (generation != session.playbackCommandGeneration) return false;
      if (!_isRegisteredSession(session)) return false;
    }
    if (!autoPlay) {
      if (session.queueLoadingRequired &&
          !await _playbackFacade.ensureSessionQueueLoaded(session.id)) {
        return false;
      }
      final hadNativeWork =
          session.loadedPath != null ||
          session.pendingNativeTrackPath != null ||
          session.state.playing;
      if (hadNativeWork) {
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
      if (hadNativeWork &&
          trackChanged &&
          !_nativePlaybackRepository.handlesQueueCompletion) {
        final stopGeneration = session.playbackCommandGeneration;
        await _nativePlaybackRepository.stop(session.id);
        if (!_isRegisteredSession(session) ||
            session.playbackCommandGeneration != stopGeneration) {
          return false;
        }
      }
      if (hadNativeWork && (trackChanged || forceStartAtZero)) {
        // Advance past the pause/stop snapshot's command ID so a late event
        // from the previous track or position cannot overwrite the newly
        // selected paused state.
        final nextCommandId = _playbackFacade.nextTransportCommandId();
        session.beginTransportCommand(commandId: nextCommandId, playing: false);
        session.confirmPaused();
      }
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
      if (hadDetachedPlaybackQueueCurrent &&
          !_hasDetachedPlaybackQueueCurrent(session)) {
        await _syncPlaybackQueueSession(session);
      }
      _notifyPlaybackChanged(session.id);
      _playbackFacade.scheduleSessionStatePersistence(sessionId: session.id);
      return true;
    }
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
    final requestedSource = _playbackFacade.resolveRetargetedPath(nextPath);
    final preparationLease = AppCacheService.protectPaths([
      if (!requestedSource.contains('://')) requestedSource,
    ]);
    try {
      if (session.queueLoadingRequired &&
          !await _playbackFacade.ensureSessionQueueLoaded(session.id)) {
        return false;
      }
      if (!_isSessionLoadCurrent(session, generation)) {
        return false;
      }

      await _playbackFacade.validatePlaybackCachePaths([nextPath]);
      if (!_isSessionLoadCurrent(session, generation)) return false;

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
        _syncActivePlaybackCacheLease(session);
        final nativeResult = await _prepareNativeTrackWithRetry(
          session,
          target,
          generation: generation,
          targetQueueIndex: targetQueueIndex,
          autoPlay:
              autoPlay &&
              !_nativePlaybackRepository.handlesQueueCompletion &&
              initialFadeMultiplier == null,
        );
        if (!_isSessionLoadCurrent(session, generation)) return false;
        if (!nativeResult.succeeded) {
          final failureMessage =
              nativeResult.error ?? 'Failed to prepare the selected track.';
          final restored = await _restorePreviousNativeTrack(
            session,
            generation: generation,
            previousLogicalPath: previousLogicalPath,
            previousLoadedPath: previousLoadedPath,
            previousPosition: previousPosition,
            previousWasPlaying: previousWasPlaying,
          );
          if (_isSessionLoadCurrent(session, generation) &&
              !(restored &&
                  (previousWasPlaying || session.playbackRequested))) {
            preparationError = failureMessage;
          }
          return false;
        }
        if (!_isSessionLoadCurrent(session, generation)) return false;
        _applyPlaybackPreparationTarget(
          session,
          target,
          forceStartAtZero: forceStartAtZero,
          targetQueueIndex: targetQueueIndex,
        );
        session.loadedPath = target.resolvedPath;
        session.markNativePreparation(generation, null);
        final snapshot = nativeResult.snapshot;
        if (snapshot != null) {
          _handleNativePlaybackSnapshot(
            snapshot.copyWith(
              volume: session.volume,
              audioEffects: session.audioEffects,
              channelSwapEnabled: session.channelSwapEnabled,
            ),
          );
        }
        prepared = true;
      } else {
        // Direct playback can replace the queue while keeping the loaded media.
        // Reuse the existing scope/repeat synchronization before playing it.
        if (session.nativePlaybackQueueCache == null &&
            !await synchronizeLoopMode(session, session.loopMode)) {
          if (_isSessionLoadCurrent(session, generation)) {
            preparationError = 'Failed to synchronize the playback queue.';
          }
          return false;
        }
        if (!_isSessionLoadCurrent(session, generation)) return false;
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
      var restored = false;
      if (_isSessionLoadCurrent(session, generation)) {
        restored = await _restorePreviousNativeTrack(
          session,
          generation: generation,
          previousLogicalPath: previousLogicalPath,
          previousLoadedPath: previousLoadedPath,
          previousPosition: previousPosition,
          previousWasPlaying: previousWasPlaying,
        );
      }
      if (_isSessionLoadCurrent(session, generation) &&
          !(restored && (previousWasPlaying || session.playbackRequested))) {
        preparationError = e.toString();
      }
    } finally {
      preparationLease.release();
      if (_isRegisteredSession(session) &&
          session.isPreparationCurrent(generation)) {
        session.finishPreparation(
          generation,
          prepared: prepared,
          autoPlay: autoPlay,
          error: preparationError,
        );
        _syncActivePlaybackCacheLease(session);
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

    var shouldStartPlayback = autoPlay && prepared && session.playbackRequested;
    if (prepared &&
        hadDetachedPlaybackQueueCurrent &&
        session.hasDetachedQueueTrack &&
        !_hasDetachedPlaybackQueueCurrent(session)) {
      final synced = await _syncPlaybackQueueSession(
        session,
        preservePlaybackStarting: shouldStartPlayback,
      );
      shouldStartPlayback =
          shouldStartPlayback && synced && session.playbackRequested;
    }

    if (shouldStartPlayback) {
      return _startSessionPlayback(
        session,
        shouldStartTriggerCountdown: shouldStartTriggerCountdown,
        allowPreparationFallback: false,
        initialFadeMultiplier: initialFadeMultiplier,
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
    final track = _sessionTrackForPath(session, logicalPath);
    final uri =
        PathMatcher.isContentUri(resolvedPath) ||
            PathMatcher.isRemoteUri(resolvedPath)
        ? Uri.parse(
            track?.isRemoteSource == true
                ? PlaybackMediaReference.parse(resolvedPath).streamUrl
                : resolvedPath,
          )
        : Uri.file(resolvedPath);
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
        (forceStartAtZero
            ? Duration.zero
            : logicalTrackChanged
            ? _playbackFacade.remoteResumePosition(track)
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

  bool _canReuseExistingNativeQueue(
    PlaybackSession session, {
    required String targetResolvedPath,
  }) {
    if (session.loadedPath == null ||
        session.state.processingState == ProcessingState.idle ||
        session.playbackError != null ||
        session.hasDetachedQueueTrack ||
        session.syncedNativeQueueBaseKey == null) {
      return false;
    }
    final scopeKey = _playbackQueueScopeKey(session, targetResolvedPath);
    final baseKey = Object.hash(
      scopeKey,
      _libraryFacade.contentRevision,
      RemoteSourceHeaderRegistry.instance.revision,
    );
    return session.syncedNativeQueueBaseKey == baseKey;
  }

  Future<_NativePreparationResult> _prepareNativeTrackWithRetry(
    PlaybackSession session,
    _PlaybackPreparationTarget target, {
    required int generation,
    int? targetQueueIndex,
    bool autoPlay = false,
  }) async {
    const maxAttempts = 2;
    String? lastError;
    var tryReuseQueue = _canReuseExistingNativeQueue(
      session,
      targetResolvedPath: target.resolvedPath,
    );
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
      final queueStartIndex = _nativePlaybackQueueStartIndexFor(
        session,
        currentPath: target.resolvedPath,
        targetQueueIndex: targetQueueIndex,
      );
      final repeatAll =
          (_nativePlaybackRepository.handlesQueueCompletion ||
              !_hasDetachedPlaybackQueueCurrent(session)) &&
          session.loopMode != SessionLoopMode.single &&
          !session.loopMode.isOneShot;
      if (tryReuseQueue && queueStartIndex != null) {
        final reuseResult = await _nativePlaybackRepository.prepareSession(
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
          autoPlay: autoPlay,
          queueStartIndex: queueStartIndex,
          repeatAll: repeatAll,
          shuffle: session.loopMode.isShuffle,
          candidateUris: target.candidateUris,
          reuseExistingQueue: true,
        );
        if (!_isSessionLoadCurrent(session, generation)) {
          return const _NativePreparationResult.failure(
            'Playback preparation was superseded.',
          );
        }
        if (reuseResult.isOk) {
          return _NativePreparationResult.success(reuseResult.valueOrNull);
        }
        session.syncedNativeQueueBaseKey = null;
        tryReuseQueue = false;
        if (reuseResult.errorCodeOrNull !=
            nativePlaybackQueueResyncRequiredCode) {
          lastError = reuseResult.errorOrNull;
          AppLogService.warning(
            'PlaybackCommandCoordinator.prepareAndPlay: attempt ${attempt + 1} failed: '
            '${reuseResult.errorOrNull ?? "unknown error"}.',
          );
          continue;
        }
      }
      final builtQueue = await _nativePlaybackQueueWithBaseKey(
        session,
        currentPath: target.resolvedPath,
      );
      final nativeQueue = builtQueue.queue;
      final builtBaseKey = builtQueue.baseKey;
      if (!_isSessionLoadCurrent(session, generation)) {
        return const _NativePreparationResult.failure(
          'Playback preparation was superseded.',
        );
      }
      final fullQueueStartIndex = _nativePlaybackQueueStartIndexFor(
        session,
        currentPath: target.resolvedPath,
        targetQueueIndex: targetQueueIndex,
      );
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
        autoPlay: autoPlay,
        queue: nativeQueue,
        queueStartIndex: fullQueueStartIndex,
        repeatAll: repeatAll,
        shuffle: session.loopMode.isShuffle,
        candidateUris: target.candidateUris,
      );
      if (!_isSessionLoadCurrent(session, generation)) {
        return const _NativePreparationResult.failure(
          'Playback preparation was superseded.',
        );
      }
      if (result.isOk) {
        session.syncedNativeQueueBaseKey = builtBaseKey;
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
      session.syncedNativeQueueBaseKey = null;
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
    final previousSource = _playbackFacade.resolveRetargetedPath(
      previousLogicalPath,
    );
    final restoreLease = AppCacheService.protectPaths([
      if (!previousSource.contains('://')) previousSource,
    ]);
    try {
      await _playbackFacade.validatePlaybackCachePaths([previousLogicalPath]);
      if (!_isSessionLoadCurrent(session, generation)) return false;
      final restoreTarget = _resolvePlaybackPreparationTarget(
        session,
        nextPath: previousLogicalPath,
        forceStartAtZero: false,
        startPositionOverride: previousPosition,
      );
      session.markNativePreparation(generation, restoreTarget.resolvedPath);
      _syncActivePlaybackCacheLease(session);
      final restored = await _prepareNativeTrackWithRetry(
        session,
        restoreTarget,
        generation: generation,
        targetQueueIndex: session.currentQueueIndex,
        autoPlay:
            previousWasPlaying &&
            !_nativePlaybackRepository.handlesQueueCompletion,
      );
      if (!_isSessionLoadCurrent(session, generation)) return false;
      session.markNativePreparation(generation, null);
      if (!restored.succeeded) {
        session.loadedPath = null;
        return false;
      }
      session.loadedPath = restoreTarget.resolvedPath;
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
    } finally {
      restoreLease.release();
    }
  }

  List<Uri>? _candidatePlaybackUrisForTrack(MusicTrack? track) =>
      _candidatePlaybackUris(track);

  void _syncAutomaticPlaybackCache(PlaybackSession session) {
    final playedPath = session.loadedPath;
    if (!_asmrPlaybackCacheEnabled() ||
        session.pendingNativeTrackPath != null ||
        playedPath == null ||
        !PathMatcher.isRemoteUri(playedPath) ||
        !PathMatcher.isRemoteUri(session.currentTrackPath)) {
      _automaticPlaybackCacheTracks.remove(session.id);
      _asmrPlaybackCacheService.releaseOwner(session.id);
      return;
    }
    final request = (
      trackPath: session.currentTrackPath,
      playedPath: playedPath,
    );
    if (_automaticPlaybackCacheTracks[session.id] == request) return;
    final track = _sessionTrackForPath(session, session.currentTrackPath);
    if (track == null || !track.isRemoteAsmr) {
      _automaticPlaybackCacheTracks.remove(session.id);
      _asmrPlaybackCacheService.releaseOwner(session.id);
      return;
    }
    _automaticPlaybackCacheTracks[session.id] = request;
    unawaited(_cacheAsmrPlaybackTrack(session, track, request));
  }

  Future<void> _cacheAsmrPlaybackTrack(
    PlaybackSession session,
    MusicTrack track,
    ({String trackPath, String playedPath}) request,
  ) async {
    final cachedPath = await _asmrPlaybackCacheService.cacheTrack(
      track,
      playedPath: request.playedPath,
      ownerId: session.id,
    );
    if (cachedPath == null ||
        cachedPath.isEmpty ||
        !_isRegisteredSession(session) ||
        !_asmrPlaybackCacheEnabled() ||
        _automaticPlaybackCacheTracks[session.id] != request) {
      return;
    }
    _playbackFacade.rememberRetargetedPath(track.path, cachedPath);
  }

  Future<List<Map<String, Object?>>> _nativePlaybackQueueFor(
    PlaybackSession session, {
    required String currentPath,
  }) async => (await _nativePlaybackQueueWithBaseKey(
    session,
    currentPath: currentPath,
  )).queue;

  Future<({List<Map<String, Object?>> queue, int? baseKey})>
  _nativePlaybackQueueWithBaseKey(
    PlaybackSession session, {
    required String currentPath,
  }) async {
    final logicalCurrentPath =
        _playbackFacade.originalPathForRetargeted(currentPath) ?? currentPath;

    int computeBaseKey() => Object.hash(
      session.nativePlaybackQueueScopeCacheKey,
      _libraryFacade.contentRevision,
      RemoteSourceHeaderRegistry.instance.revision,
    );

    bool cachedQueueCoversMatch(
      PlaybackQueueScope scope,
      List<String> paths,
      List<Map<String, Object?>> cachedQueue,
    ) {
      if (cachedQueue.length != paths.length) return false;
      final customTracks =
          session.isPlaybackQueue && !session.hasDetachedQueueTrack
          ? session.playbackQueue!.expandedTracks
          : session.customQueueTracks;
      String? lastCoverPath;
      String? lastArtUri;
      for (var index = 0; index < paths.length; index++) {
        final track = scope.isCustomQueue && customTracks != null
            ? customTracks[scope.queueIndices[index]]
            : _sessionTrackForPath(session, paths[index]);
        final coverPath = resolvedPlaybackCoverPathForTrack(track);
        final String? artUri;
        if (coverPath == null) {
          artUri = track?.remoteCoverUrl;
        } else if (coverPath == lastCoverPath) {
          artUri = lastArtUri;
        } else {
          lastCoverPath = coverPath;
          lastArtUri = Uri.file(coverPath).toString();
          artUri = lastArtUri;
        }
        final expectedArtUri = artUri != null && artUri.isNotEmpty
            ? artUri
            : null;
        if (cachedQueue[index]['artUri'] != expectedArtUri) {
          return false;
        }
      }
      return true;
    }

    while (true) {
      if (!_isRegisteredSession(session)) {
        return (queue: const <Map<String, Object?>>[], baseKey: null);
      }
      var scope = _playbackQueueScopeFor(
        session,
        currentPath: logicalCurrentPath,
        repositionCurrentIndex: false,
      );
      var paths = scope.paths;
      if (paths.isEmpty) {
        return (queue: const <Map<String, Object?>>[], baseKey: null);
      }
      final hasRetargetedPaths = _playbackFacade.hasRetargetedPaths;

      if (!hasRetargetedPaths) {
        final baseKey = computeBaseKey();
        final cacheKey = Object.hash(baseKey, _libraryFacade.coverGeneration);
        final cached = session.nativePlaybackQueueCache;
        if (session.nativePlaybackQueueCacheKey == cacheKey) {
          if (cached != null) {
            if (_isRegisteredSession(session)) {
              _syncActivePlaybackCacheLease(session);
            }
            return (queue: cached, baseKey: baseKey);
          }
          final pending = session.nativePlaybackQueueFuture;
          if (pending != null) {
            final result = await pending;
            if (result != null) return (queue: result, baseKey: baseKey);
            continue;
          }
        } else if (cached != null &&
            session.nativePlaybackQueueBaseKey == baseKey &&
            cachedQueueCoversMatch(scope, paths, cached)) {
          session.nativePlaybackQueueCacheKey = cacheKey;
          if (_isRegisteredSession(session)) {
            _syncActivePlaybackCacheLease(session);
          }
          return (queue: cached, baseKey: baseKey);
        }
      }

      final lease = AppCacheService.protectPaths(
        paths.where((value) => !value.contains('://')),
      );
      var retryWithLatest = false;
      try {
        if (hasRetargetedPaths) {
          final retargetRevisionBefore = _playbackFacade.retargetRevision;
          await _playbackFacade.validatePlaybackCachePaths(paths);
          if (!_isRegisteredSession(session)) {
            return (queue: const <Map<String, Object?>>[], baseKey: null);
          }
          if (_playbackFacade.retargetRevision != retargetRevisionBefore) {
            scope = _playbackQueueScopeFor(
              session,
              currentPath: logicalCurrentPath,
              repositionCurrentIndex: false,
            );
            paths = scope.paths;
            if (paths.isEmpty) {
              return (queue: const <Map<String, Object?>>[], baseKey: null);
            }
          }
        }
        final baseKey = computeBaseKey();
        final cacheKey = Object.hash(baseKey, _libraryFacade.coverGeneration);
        final cached = session.nativePlaybackQueueCache;
        if (session.nativePlaybackQueueCacheKey == cacheKey) {
          if (cached != null) {
            if (_isRegisteredSession(session)) {
              _syncActivePlaybackCacheLease(session);
            }
            return (queue: cached, baseKey: baseKey);
          }
          final pending = session.nativePlaybackQueueFuture;
          if (pending != null) {
            final result = await pending;
            if (result != null) return (queue: result, baseKey: baseKey);
            retryWithLatest = true;
          }
        } else if (cached != null &&
            session.nativePlaybackQueueBaseKey == baseKey &&
            cachedQueueCoversMatch(scope, paths, cached)) {
          session.nativePlaybackQueueCacheKey = cacheKey;
          if (_isRegisteredSession(session)) {
            _syncActivePlaybackCacheLease(session);
          }
          return (queue: cached, baseKey: baseKey);
        }
        if (retryWithLatest) continue;

        session.nativePlaybackQueueBaseKey = baseKey;
        session.nativePlaybackQueueCacheKey = cacheKey;
        session.nativePlaybackQueueCache = null;
        Future<List<Map<String, Object?>>?> buildQueue() async {
          final descriptors = <_NativeQueueTrack>[];
          final slice = Stopwatch()..start();
          final customTracks =
              session.isPlaybackQueue && !session.hasDetachedQueueTrack
              ? session.playbackQueue!.expandedTracks
              : session.customQueueTracks;
          final playDetachedOnce =
              _nativePlaybackRepository.handlesQueueCompletion &&
              session.hasDetachedQueueTrack &&
              scope.queueIndices.firstOrNull == 0;
          for (final (index, trackPath) in paths.indexed) {
            final track = scope.isCustomQueue && customTracks != null
                ? customTracks[scope.queueIndices[index]]
                : _sessionTrackForPath(session, trackPath);
            descriptors.add((
              path: trackPath,
              track: track,
              coverPath: resolvedPlaybackCoverPathForTrack(track),
              httpHeaders: PlaybackMediaReference.parse(
                trackPath,
                sourceId: track?.remoteSourceId,
              ).httpHeaders,
              playOnceBeforeQueue: playDetachedOnce && index == 0,
            ));
            if (slice.elapsedMicroseconds >= 2000) {
              await Future<void>.delayed(Duration.zero);
              if (!_isRegisteredSession(session)) {
                return const [];
              }
              if (session.nativePlaybackQueueCacheKey != cacheKey) {
                return null;
              }
              slice.reset();
            }
          }
          return compute(_buildNativePlaybackQueue, descriptors);
        }

        final pending = buildQueue();
        session.nativePlaybackQueueFuture = pending;
        try {
          final queue = await pending;
          if (queue == null) {
            retryWithLatest = true;
          } else {
            final registered = _isRegisteredSession(session);
            if (registered &&
                session.nativePlaybackQueueCacheKey == cacheKey &&
                identical(session.nativePlaybackQueueFuture, pending)) {
              session.nativePlaybackQueueCache = queue;
              _syncActivePlaybackCacheLease(session);
            }
            return (queue: queue, baseKey: registered ? baseKey : null);
          }
        } finally {
          if (identical(session.nativePlaybackQueueFuture, pending)) {
            session.nativePlaybackQueueFuture = null;
          }
        }
      } finally {
        lease.release();
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

  PlaybackQueueScope _playbackQueueScopeFor(
    PlaybackSession session, {
    required String currentPath,
    bool repositionCurrentIndex = true,
  }) {
    final resolvedCurrentPath = _playbackFacade.resolveRetargetedPath(
      currentPath,
    );
    final cacheKey = _playbackQueueScopeKey(session, resolvedCurrentPath);
    final cached = session.nativePlaybackQueueScopeCache;
    if (session.nativePlaybackQueueScopeCacheKey == cacheKey &&
        cached != null) {
      if (!repositionCurrentIndex) return cached;
      return _playbackQueueResolver.repositionScope(
        cached,
        currentPath: resolvedCurrentPath,
        currentQueueIndex: session.currentQueueIndex,
      );
    }
    final sessionTrack = _sessionTrackForPath(session, resolvedCurrentPath);
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
      hasDetachedQueuePrefix:
          _nativePlaybackRepository.handlesQueueCompletion &&
          session.hasDetachedQueueTrack,
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
        : crossFolderScope || track == null
        ? null
        : _folderKeyForTrack(track);
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
