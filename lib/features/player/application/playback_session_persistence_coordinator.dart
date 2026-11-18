part of 'playback_facade.dart';

extension PlaybackSessionPersistenceCoordinator on PlaybackFacade {
  Future<void> _setResumeBatch(Map<String, String> targets) {
    _resumeBatch = targets;
    _notifyResumeBatchChanged();
    if (!_persistenceEnabled) return Future<void>.value();
    return _enqueueSessionPersistence(() async {
      if (identical(_resumeBatch, targets)) await _writeResumeBatch(targets);
    });
  }

  Future<void> _writeResumeBatch(Map<String, String> targets) async {
    if (!await AppPreferences.writeJson(
      PlaybackFacade._resumeBatchKey,
      targets,
    )) {
      throw StateError('Could not persist playlist resume batch');
    }
  }

  void _rememberPausedBatch(Map<String, String> candidates, {int? sequence}) {
    final event = sequence ?? ++_pauseSequence;
    if (event <= _recordedPauseSequence || hasActivePlayback) return;
    final targets = Map<String, String>.fromEntries(
      candidates.entries.where(_isResumeTarget),
    );
    if (targets.isEmpty) return;
    _recordedPauseSequence = event;
    // A partially failed resume can be retried after the successful sessions
    // are paused again.
    _resumeRetryTargets.removeWhere((id, _) => targets.containsKey(id));
    _scheduleResumeBatch({...targets, ..._resumeRetryTargets});
  }

  void _scheduleResumeBatch(Map<String, String> targets) {
    unawaited(
      _setResumeBatch(targets).catchError((Object _) {
        // The persistence queue logs write failures.
      }),
    );
  }

  void _pruneResumeBatch() {
    _resumeRetryTargets.removeWhere(
      (id, path) => !_isResumeTarget(MapEntry(id, path)),
    );
    if (_resumeBatch.entries.every(_isResumeTarget)) return;
    _scheduleResumeBatch(
      Map.fromEntries(_resumeBatch.entries.where(_isResumeTarget)),
    );
  }

  Future<void> _saveBackgroundResumeBatch() async {
    if (!_backgroundMode ||
        defaultTargetPlatform != TargetPlatform.android ||
        _pauseAllInFlight != null ||
        _resumeInFlight != null) {
      return;
    }
    final active = Map<String, String>.fromEntries(
      _captureActivePlayback().entries.where((target) {
        final stored = _persistedSessions[target.key];
        return stored != null &&
            PathMatcher.equalsNormalized(stored.trackPath, target.value);
      }),
    );
    if (active.isEmpty) return;
    final targets = {..._resumeRetryTargets, ...active};
    if (mapEquals(targets, _resumeBatch)) return;
    final previous = _resumeBatch;
    _resumeBatch = targets;
    _notifyResumeBatchChanged();
    try {
      await _writeResumeBatch(targets);
    } catch (_) {
      if (identical(_resumeBatch, targets)) {
        _resumeBatch = previous;
        _notifyResumeBatchChanged();
      }
      rethrow;
    }
  }

  int get positionBucketSeconds => _backgroundMode
      ? PlaybackFacade.backgroundPositionBucketSeconds
      : PlaybackFacade.foregroundPositionBucketSeconds;

  void setBackgroundMode(bool value) {
    if (_backgroundMode == value) return;
    if (value) {
      _savePlaybackStateTimer?.cancel();
      _savePlaybackStateTimer = null;
      if (_pendingPlaybackStateSessionIds.isNotEmpty) {
        unawaited(_enqueueSessionPersistence(_savePendingPlaybackStates));
      }
    }
    _backgroundMode = value;
    for (final session in _service.sessions.values) {
      session.lastPersistedPositionBucket =
          session.lastKnownPosition.inSeconds ~/ positionBucketSeconds;
    }
  }

  void _scheduleNewSessionPersistence({
    String? sessionId,
    bool respectConfiguration = true,
  }) {
    if (respectConfiguration && !_persistenceEnabled) return;
    scheduleSessionStatePersistence(sessionId: sessionId);
    scheduleSessionOrderPersistence();
  }

  void attachPersistenceRuntime({
    required MusicTrack? Function(String trackPath) trackByPath,
    required bool Function() recordPlaybackProgress,
    required RestoredPlaybackRuntime restoreRuntime,
    required PlaybackHistoryUpdater updatePlaybackHistory,
    required void Function(String? sessionId) onFocusChanged,
    Future<void> Function(PlaybackSession session)? synchronizePausedRecovery,
  }) {
    _persistedTrackResolver ??= trackByPath;
    _service.libraryTrackByPath ??= trackByPath;
    _recordPlaybackProgress ??= recordPlaybackProgress;
    _restoreRuntime ??= restoreRuntime;
    _updatePlaybackHistory ??= updatePlaybackHistory;
    _onPersistenceFocusChanged ??= onFocusChanged;
    _synchronizePausedRecovery ??= synchronizePausedRecovery;
  }

  void configurePersistence({required bool enabled}) {
    _persistenceEnabled = enabled;
    if (!enabled) cancelScheduledPersistence();
  }

  Future<void> loadPersistedState() async {
    final repository = databaseRepository;
    final persistedSessions = repository is PlaybackQueueStorage
        ? await (repository as PlaybackQueueStorage).loadSessionSummaries()
        : [
            for (final item in await repository.loadAllSessions())
              (
                session: item,
                currentTrack: null as MusicTrack?,
                requiresQueueLoad: false,
              ),
          ];
    if (persistedSessions.isEmpty) return;
    final legacyOrder = await AppPreferences.readJson<List<String>>(
      'session_order_v1',
      (value) => (value as List<dynamic>).cast<String>(),
    );
    final resumeBatch =
        await AppPreferences.readJson<Map<String, String>>(
          PlaybackFacade._resumeBatchKey,
          (value) => Map<String, String>.from(value as Map),
        ) ??
        {};
    final restoredSessions = <PlaybackSession>[];
    final recordProgress = _recordPlaybackProgress?.call() ?? true;

    for (final summary in persistedSessions) {
      final item = summary.session;
      final customQueueTracks = item.customQueueTracks;
      final queueTracks =
          customQueueTracks ?? item.playbackQueue?.expandedTracks;
      MusicTrack? track = summary.currentTrack;
      if (queueTracks != null && queueTracks.isNotEmpty) {
        final index = item.currentQueueIndex;
        track =
            index >= 0 &&
                index < queueTracks.length &&
                PathMatcher.equalsNormalized(
                  queueTracks[index].path,
                  item.trackPath,
                )
            ? queueTracks[index]
            : queueTracks.firstWhere(
                (candidate) => PathMatcher.equalsNormalized(
                  candidate.path,
                  item.trackPath,
                ),
                orElse: () => queueTracks.first,
              );
      }
      track ??= _persistedTrackResolver?.call(item.trackPath);
      if (track == null && item.playbackQueue == null) continue;

      final loopMode =
          SessionLoopMode.values[item.loopModeIndex.clamp(
            0,
            SessionLoopMode.values.length - 1,
          )];
      final restoredPosition = Duration(
        milliseconds: max(0, recordProgress ? item.positionMs : 0),
      );
      final session = PlaybackSession(
        id: item.id,
        currentTrackPath: track?.path ?? '',
        isTemporary: item.isTemporary,
        loopMode: loopMode,
        nonSingleLoopMode: loopMode == SessionLoopMode.single
            ? (item.playbackQueue != null
                  ? SessionLoopMode.crossSequential
                  : SessionLoopMode.folderSequential)
            : loopMode,
        volume: item.volume.clamp(0.0, PlaybackFacade.maxSessionVolume),
        createdAt: item.createdAtMs == null
            ? DateTime.now()
            : DateTime.fromMillisecondsSinceEpoch(item.createdAtMs!),
        lastPlayedAt: item.lastPlayedAtMs == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(item.lastPlayedAtMs!),
        state: const PlayerState(false, ProcessingState.idle),
        customQueueTracks: customQueueTracks,
        playbackQueue: item.playbackQueue,
        queueLoadingRequired: summary.requiresQueueLoad,
        persistedCurrentTrack: summary.currentTrack,
        currentQueueIndex: recordProgress ? item.currentQueueIndex : 0,
      );
      session
        ..lastKnownPosition = restoredPosition
        ..setOptimisticDuration(Duration(milliseconds: item.durationMs))
        ..lastPersistedPositionBucket =
            restoredPosition.inSeconds ~/ positionBucketSeconds
        ..channelSwapEnabled = item.channelSwapEnabled
        ..speed = nearestPlaybackSpeed(item.speed)
        ..audioEffects = item.audioEffects;
      _service.sessions[session.id] = session;
      _persistedSessions[session.id] = item;
      _persistedQueueVersions[session.id] = session.queueVersion;
      observeSession(session);
      restoredSessions.add(session);
    }

    final restoredIds = restoredSessions.map((session) => session.id).toSet();
    final orderedIds = (legacyOrder ?? const <String>[])
        .where(restoredIds.contains)
        .toSet();
    for (final session in restoredSessions) {
      orderedIds.add(session.id);
    }
    _service.sessionOrder
      ..clear()
      ..addAll(orderedIds);
    _service.markActiveSessionsDirty();
    publishSessionState();
    _resumeBatch = Map.fromEntries(resumeBatch.entries.where(_isResumeTarget));
    _notifyResumeBatchChanged();
    final focusedSessionId = orderedIds.firstOrNull;
    _onPersistenceFocusChanged?.call(focusedSessionId);
    await _restoreRuntime?.call(
      restoredSessions,
      focusedSessionId: focusedSessionId,
    );
    await removeMissingTemporarySessions();
  }

  Future<void> removeMissingTemporarySessions() async {
    final candidates = [
      for (final session in _service.sessions.values)
        if (session.isTemporary &&
            !_removingMissingTemporarySessionIds.contains(session.id) &&
            !session.playbackRequested &&
            !session.isPlaybackLoading)
          (session, session.currentTrackPath, session.loadGeneration),
    ];
    final missing = await Future.wait(
      candidates.map((candidate) => _isMissingTemporarySource(candidate.$2)),
    );
    final staleIds = <String>[];
    for (var index = 0; index < candidates.length; index++) {
      final (session, source, generation) = candidates[index];
      if (missing[index] &&
          !_removingMissingTemporarySessionIds.contains(session.id) &&
          isRegisteredSession(session) &&
          session.currentTrackPath == source &&
          session.loadGeneration == generation &&
          !session.playbackRequested &&
          !session.isPlaybackLoading) {
        staleIds.add(session.id);
      }
    }
    if (staleIds.isEmpty) return;
    _removingMissingTemporarySessionIds.addAll(staleIds);
    try {
      await removeSessions(staleIds);
      if (staleIds.any((id) => !_service.sessions.containsKey(id))) {
        await flushSessionStatePersistence();
      }
    } finally {
      _removingMissingTemporarySessionIds.removeAll(staleIds);
    }
  }

  Future<bool> _isMissingTemporarySource(String source) async {
    var filePath = source;
    if (PathMatcher.isContentUri(source)) {
      if (defaultTargetPlatform != TargetPlatform.android ||
          Uri.tryParse(source)?.authority !=
              'com.android.externalstorage.documents') {
        return false;
      }
      final files = FileCachePlatformGateway.instance;
      if (await files.documentPathExistence(source) != false) return false;
      // A failed document lookup can also mean lost access or an offline
      // provider. Require a matching local filesystem path before pruning.
      final resolved = await files.resolveDocumentFileSystemPath(source);
      if (resolved == null) return false;
      filePath = resolved;
    }
    if (!path.isAbsolute(filePath)) return false;
    try {
      final file = await File(filePath).open();
      await file.close();
      return false;
    } on FileSystemException catch (error) {
      final code = error.osError?.errorCode;
      // Opening the file preserves the OS error that File.exists discards.
      if (code != 2 && !(Platform.isWindows && code == 3)) return false;
      if (Platform.isWindows) {
        return Directory(path.rootPrefix(filePath)).exists();
      }
      if (Platform.isAndroid && filePath.startsWith('/storage/')) {
        final components = path.split(filePath);
        if (components.length < 3) return false;
        final rootLength = components[2] == 'emulated' ? 4 : 3;
        if (components.length <= rootLength) return false;
        return Directory(path.joinAll(components.take(rootLength))).exists();
      }
      return true;
    }
  }

  Future<bool> ensureSessionQueueLoaded(String sessionId) {
    final session = _service.sessions[sessionId];
    if (session == null) return Future.value(false);
    if (!session.queueLoadingRequired) return Future.value(true);
    return _deferredQueueLoads.putIfAbsent(session, () async {
      try {
        final storage = databaseRepository as PlaybackQueueStorage;
        final item = await storage.loadSessionQueue(sessionId);
        if (!identical(_service.sessions[sessionId], session)) return false;
        if (item == null) {
          throw StateError(
            'Stored playback queue missing for session $sessionId',
          );
        }
        final before = _persistedSessions[sessionId];
        final previousVersion = session.queueVersion;
        final definition = item.playbackQueue;
        final current = session.playbackQueue;
        session
          ..queueLoadingRequired = false
          ..persistedCurrentTrack = null
          ..playbackQueue = definition != null && current != null
              ? definition.copyWith(
                  name: current.name,
                  colorValue: current.colorValue,
                  clearColor: current.colorValue == null,
                )
              : definition
          ..customQueueTracks =
              item.customQueueTracks ?? definition?.expandedTracks
          ..hasDetachedQueueTrack =
              definition != null &&
              item.customQueueTracks != null &&
              item.customQueueTracks!.length == definition.trackCount + 1;
        if (before != null) {
          final header = before.playbackQueue;
          _persistedSessions[sessionId] = before.withQueue(
            header == null || definition == null
                ? definition
                : definition.copyWith(
                    name: header.name,
                    colorValue: header.colorValue,
                    clearColor: header.colorValue == null,
                  ),
            item.customQueueTracks,
          );
          if (_persistedQueueVersions[sessionId] == previousVersion) {
            _persistedQueueVersions[sessionId] = session.queueVersion;
          }
        }
        publishSessionState(sessionId);
        return true;
      } finally {
        unawaited(_deferredQueueLoads.remove(session));
      }
    });
  }

  Future<PlaybackQueueEntry?> loadQueueEntry(
    String sessionId,
    String entryId,
  ) async {
    final session = _service.sessions[sessionId];
    if (session == null) return null;
    if (session.queueLoadingRequired) {
      final entry = await (databaseRepository as PlaybackQueueStorage)
          .loadQueueEntry(sessionId, entryId);
      if (!identical(_service.sessions[sessionId], session)) return null;
      if (session.queueLoadingRequired) return entry;
    }
    return _queueEntryIn(session, entryId);
  }

  Future<List<MusicTrack>?> resolveQueueEntryTracksForEdit(
    String sessionId,
    PlaybackQueueEntry snapshot,
    List<int> trackIndices,
  ) async {
    final session = _service.sessions[sessionId];
    final indices = trackIndices.toSet();
    if (session == null ||
        indices.isEmpty ||
        indices.any((index) => index < 0 || index >= snapshot.tracks.length)) {
      return null;
    }
    if (session.queueLoadingRequired &&
        !await ensureSessionQueueLoaded(sessionId)) {
      return null;
    }
    if (!identical(_service.sessions[sessionId], session)) return null;
    final entry = _queueEntryIn(session, snapshot.id);
    if (entry == null || entry != snapshot) return null;

    final selected = <MusicTrack>[];
    for (final index in indices) {
      final before = snapshot.tracks[index];
      final track = entry.tracks[index];
      // Queue entry equality omits remote occurrence identifiers.
      if (before.remoteMetadataKind != track.remoteMetadataKind ||
          before.remoteMetadata?['id'] != track.remoteMetadata?['id'] ||
          before.remoteMetadata?['trackStableKey'] !=
              track.remoteMetadata?['trackStableKey'] ||
          before.remoteMetadata?['trackRelativePath'] !=
              track.remoteMetadata?['trackRelativePath']) {
        return null;
      }
      selected.add(track);
    }
    return selected;
  }

  PlaybackQueueEntry? _queueEntryIn(PlaybackSession session, String entryId) =>
      session.playbackQueue?.entries
          .where((entry) => entry.id == entryId)
          .firstOrNull;

  Future<List<PlaybackQueueEntryPreview>> loadQueueEntryPreviews(
    String sessionId, {
    required int start,
    required int limit,
  }) async {
    final session = _service.sessions[sessionId];
    if (session == null || limit <= 0 || start < 0) return const [];
    if (session.queueLoadingRequired) {
      final rows = await (databaseRepository as PlaybackQueueStorage)
          .loadQueueEntryPage(sessionId, start: start, limit: limit);
      if (!identical(_service.sessions[sessionId], session)) return const [];
      if (session.queueLoadingRequired) return rows;
    }
    final entries =
        session.playbackQueue?.entries ?? const <PlaybackQueueEntry>[];
    return [
      for (
        var index = start;
        index < entries.length && index < start + limit;
        index++
      )
        (
          id: entries[index].id,
          title: entries[index].title,
          kind: entries[index].kind,
          trackCount: entries[index].tracks.length,
          firstTrack: entries[index].tracks.firstOrNull,
        ),
    ];
  }

  Future<void> resetPersistedState() async {
    cancelScheduledPersistence();
    final removedSessions = _service.sessions.values.toList(growable: false);
    _service.removeSessions(removedSessions.map((session) => session.id));
    _recordedPauseSequence = ++_pauseSequence;
    _resumeRetryTargets.clear();
    _persistedSessions.clear();
    _persistedQueueVersions.clear();
    // Invalidate old preparations before persistence yields to a replacement.
    await Future.wait<void>([
      for (final session in removedSessions) session.shutdown(),
      _setResumeBatch({}).catchError((Object _) {
        // The persistence queue logs write failures.
      }),
    ]);
    try {
      final response = await nativeRepository.clearAll();
      if (response.isOk) _clearNativeRetainedContentUris();
    } catch (error, stackTrace) {
      AppLogService.error(
        'playback_persisted_state_reset_clear_failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
    clearDeferredVolumeReloads();
    clearRetargetedPaths();
    _onPersistenceFocusChanged?.call(null);
  }

  PersistedPlaybackSession _persistedSessionSnapshot(
    PlaybackSession session, {
    required int sortOrder,
    required DateTime now,
    bool updateHistory = false,
  }) {
    final positionMs = max(
      0,
      max(
        session.position.inMilliseconds,
        session.lastKnownPosition.inMilliseconds,
      ),
    );
    final position = Duration(milliseconds: positionMs);
    final track = _persistedTrackResolver?.call(session.currentTrackPath);
    if (updateHistory &&
        track != null &&
        (track.lastPlayedPosition.inSeconds ~/ positionBucketSeconds !=
                position.inSeconds ~/ positionBucketSeconds ||
            session.state.playing)) {
      final updated = _updatePlaybackHistory?.call(
        trackPath: track.path,
        position: position,
        now: now,
        updatePlayedAt: session.state.playing,
      );
      if (updated != null) {
        _pendingPlaybackHistoryTracks[updated.path] = updated;
      }
    }
    return PersistedPlaybackSession(
      id: session.id,
      trackPath: session.currentTrackPath,
      isTemporary: session.isTemporary,
      loopModeIndex: session.loopMode.index,
      volume: session.volume,
      speed: session.speed,
      positionMs: positionMs,
      durationMs: session.duration?.inMilliseconds ?? 0,
      customQueueTracks: session.customQueueTracks,
      playbackQueue: session.playbackQueue,
      currentQueueIndex: session.currentQueueIndex,
      channelSwapEnabled: session.channelSwapEnabled,
      audioEffects: session.audioEffects,
      createdAtMs: session.createdAt.millisecondsSinceEpoch,
      updatedAtMs: now.millisecondsSinceEpoch,
      lastPlayedAtMs: session.lastPlayedAt?.millisecondsSinceEpoch,
      sortOrder: sortOrder,
    );
  }

  Future<void> _enqueueSessionPersistence(Future<void> Function() persist) {
    final previous = _sessionPersistenceTail;
    final result = previous == null
        ? Future<void>.sync(persist)
        : previous.then((_) => persist());
    _sessionPersistenceTail = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        AppLogService.error(
          'playback_session_persistence_failed',
          error: error,
          stackTrace: stackTrace,
        );
      },
    );
    return result;
  }

  Future<void> savePersistedState() {
    if (!_persistenceEnabled) return Future<void>.value();
    _pendingSessionDefinitionIds.addAll(_service.sessions.keys);
    _service.saveSessionStateTimer?.cancel();
    _service.saveSessionStateTimer = null;
    _savePlaybackStateTimer?.cancel();
    _savePlaybackStateTimer = null;
    _pendingPlaybackStateSessionIds.clear();
    return _enqueueSessionPersistence(_savePendingSessionDefinitions);
  }

  bool _sameSessionDefinition(
    PersistedPlaybackSession a,
    PersistedPlaybackSession b,
  ) =>
      (
        a.trackPath,
        a.isTemporary,
        a.loopModeIndex,
        a.volume,
        a.speed,
        a.positionMs,
        a.durationMs,
        a.currentQueueIndex,
        a.channelSwapEnabled,
        a.createdAtMs,
        a.lastPlayedAtMs,
      ) ==
      (
        b.trackPath,
        b.isTemporary,
        b.loopModeIndex,
        b.volume,
        b.speed,
        b.positionMs,
        b.durationMs,
        b.currentQueueIndex,
        b.channelSwapEnabled,
        b.createdAtMs,
        b.lastPlayedAtMs,
      );

  Future<void> _savePendingSessionDefinitions({
    String? ensurePausedRecoverySessionId,
  }) async {
    if (!_persistenceEnabled) return;
    final deletedIds = Set<String>.of(_pendingDeletedSessionIds);
    _pendingDeletedSessionIds.removeAll(deletedIds);
    final sessionIds = Set<String>.of(_pendingSessionDefinitionIds);
    _pendingSessionDefinitionIds.removeAll(sessionIds);
    final now = DateTime.now();
    try {
      if (deletedIds.isNotEmpty) {
        await databaseRepository.deleteSessions(deletedIds.toList());
        PlaybackQueuePathCoordinator(this)._publishQueueReferencesChanged();
        for (final id in deletedIds) {
          _persistedSessions.remove(id);
          _persistedQueueVersions.remove(id);
        }
      }
      for (final id in sessionIds) {
        final session = _service.sessions[id];
        if (session == null) continue;
        final wasDeferred = session.queueLoadingRequired;
        final queueVersion = session.queueVersion;
        final next = _persistedSessionSnapshot(
          session,
          sortOrder: _service.sessionOrder.indexOf(id),
          now: now,
        );
        final previous = _persistedSessions[id];
        final contentChanged = _persistedQueueVersions[id] != queueVersion;
        final headerChanged =
            previous?.playbackQueue?.name != next.playbackQueue?.name ||
            previous?.playbackQueue?.colorValue !=
                next.playbackQueue?.colorValue;
        final queueChanged = contentChanged || headerChanged;
        final effectsChanged = previous?.audioEffects != next.audioEffects;
        final stateChanged =
            previous == null || !_sameSessionDefinition(previous, next);
        if (!queueChanged && !effectsChanged && !stateChanged) {
          if (id == ensurePausedRecoverySessionId) {
            await _savePausedRecovery(session);
          }
          continue;
        }
        final repository = databaseRepository;
        if (repository is PlaybackQueueStorage && previous != null) {
          await (repository as PlaybackQueueStorage).upsertSessionDelta(
            next,
            previous: previous,
            includeQueue: (contentChanged && !wasDeferred) || headerChanged,
            includeEffects: effectsChanged,
            includeSessionState: contentChanged || stateChanged,
          );
        } else {
          final positions = contentChanged && previous != null
              ? _changedPlaybackQueueEntryPositions(previous, next)
              : null;
          await repository.upsertSession(
            next,
            includeQueue: queueChanged && positions == null,
            includeEffects: effectsChanged,
            queueEntryPositions: positions,
          );
        }
        if (contentChanged && !wasDeferred) {
          PlaybackQueuePathCoordinator(this)._publishQueueReferencesChanged();
        }
        if (contentChanged || effectsChanged || stateChanged) {
          await _savePausedRecovery(session);
        }
        final hydrated = wasDeferred && !session.queueLoadingRequired;
        // Hydration can finish while the summary write is in flight.
        final hydratedBaseline = hydrated ? _persistedSessions[id] : null;
        _persistedSessions[id] = hydratedBaseline == null
            ? next
            : next.withQueue(
                hydratedBaseline.playbackQueue?.copyWith(
                  name: next.playbackQueue?.name,
                  colorValue: next.playbackQueue?.colorValue,
                  clearColor: next.playbackQueue?.colorValue == null,
                ),
                hydratedBaseline.customQueueTracks,
              );
        if (!hydrated) _persistedQueueVersions[id] = queueVersion;
        _persistedSessionSnapshot(
          session,
          sortOrder: next.sortOrder,
          now: now,
          updateHistory: true,
        );
      }
      await _saveBackgroundResumeBatch();
    } catch (_) {
      _pendingDeletedSessionIds.addAll(deletedIds);
      _pendingSessionDefinitionIds.addAll(sessionIds);
      rethrow;
    }
    await _savePendingPlaybackHistory();
  }

  Map<String, int>? _changedPlaybackQueueEntryPositions(
    PersistedPlaybackSession previous,
    PersistedPlaybackSession next,
  ) {
    final previousQueue = previous.playbackQueue;
    final nextQueue = next.playbackQueue;
    if (previousQueue == null ||
        nextQueue == null ||
        previousQueue.name != nextQueue.name ||
        previousQueue.colorValue != nextQueue.colorValue ||
        previousQueue.entries.length != nextQueue.entries.length ||
        identical(previousQueue.entries, nextQueue.entries)) {
      return null;
    }

    final previousEntries = {
      for (final entry in previousQueue.entries) entry.id: entry,
    };
    var trackCount = 0;
    final positions = <String, int>{};
    for (final (index, entry) in nextQueue.entries.indexed) {
      if (!identical(previousEntries.remove(entry.id), entry)) return null;
      trackCount += entry.tracks.length;
      if (!identical(previousQueue.entries[index], entry)) {
        positions[entry.id] = index;
      }
    }
    // A detached current track also stores a copy of the runtime queue order.
    if (positions.isEmpty ||
        (previous.customQueueTracks?.length ?? trackCount) != trackCount ||
        (next.customQueueTracks?.length ?? trackCount) != trackCount) {
      return null;
    }
    return positions;
  }

  Future<void> _savePendingPlaybackStates() async {
    if (!_persistenceEnabled || _pendingPlaybackStateSessionIds.isEmpty) {
      return;
    }
    final sessionIds = Set<String>.of(_pendingPlaybackStateSessionIds);
    _pendingPlaybackStateSessionIds.removeAll(sessionIds);
    final now = DateTime.now();
    final orderedIds = _service.sessionOrder;
    final sortOrders = {
      for (var i = 0; i < orderedIds.length; i++) orderedIds[i]: i,
    };
    final writes = <(PlaybackSession, PersistedPlaybackSession)>[];
    try {
      for (final sessionId in sessionIds) {
        final session = _service.sessions[sessionId];
        if (session == null) continue;
        if (_pendingSessionDefinitionIds.contains(sessionId)) continue;
        final next = _persistedSessionSnapshot(
          session,
          sortOrder: sortOrders[sessionId] ?? orderedIds.length,
          now: now,
          updateHistory: true,
        );
        final previous = _persistedSessions[sessionId];
        if (previous == null ||
            _persistedQueueVersions[sessionId] != session.queueVersion ||
            previous.audioEffects != next.audioEffects ||
            (
                  previous.trackPath,
                  previous.isTemporary,
                  previous.loopModeIndex,
                  previous.createdAtMs,
                  previous.lastPlayedAtMs,
                ) !=
                (
                  next.trackPath,
                  next.isTemporary,
                  next.loopModeIndex,
                  next.createdAtMs,
                  next.lastPlayedAtMs,
                )) {
          _pendingSessionDefinitionIds.add(sessionId);
          continue;
        }
        if (_sameSessionDefinition(previous, next)) continue;
        writes.add((session, next));
      }
      if (writes.isNotEmpty) {
        await databaseRepository.upsertSessionPlaybackStates([
          for (final (_, next) in writes) next,
        ]);
        for (final (session, next) in writes) {
          if (!identical(_service.sessions[next.id], session)) continue;
          await _savePausedRecovery(session);
          final previous = _persistedSessions[next.id];
          _persistedSessions[next.id] = previous == null
              ? next
              : next.withQueue(
                  previous.playbackQueue,
                  previous.customQueueTracks,
                );
        }
      }
      if (_pendingSessionDefinitionIds.isNotEmpty) {
        await _savePendingSessionDefinitions();
      }
      await _savePendingPlaybackHistory();
    } catch (_) {
      _pendingPlaybackStateSessionIds.addAll(sessionIds);
      rethrow;
    }
  }

  Future<void> _savePausedRecovery(PlaybackSession session) async {
    final synchronize = _synchronizePausedRecovery;
    if (synchronize == null) return;
    if (session.loadedPath == null &&
        !session.playbackRequested &&
        !session.effectivePlaying &&
        !session.isLoading) {
      // Keep the comparison cache unchanged until both stores commit, so an
      // existing pending ID also retries a failed native recovery write.
      if (await ensureSessionQueueLoaded(session.id)) {
        await synchronize(session);
      }
    }
  }

  Future<void> _savePendingPlaybackHistory() async {
    if (_pendingPlaybackHistoryTracks.isEmpty) return;
    final pending = Map<String, MusicTrack>.of(_pendingPlaybackHistoryTracks);
    final resolver = _persistedTrackResolver;
    final tracks = <MusicTrack>[
      for (final entry in pending.entries)
        if (resolver == null)
          entry.value
        else if (resolver(entry.key) case final track?)
          track.copyWith(
            lastPlayedPosition: entry.value.lastPlayedPosition,
            lastPlayedAt: entry.value.lastPlayedAt,
          ),
    ];
    if (tracks.isNotEmpty) {
      await databaseRepository.updateTrackPlaybackHistory(tracks);
    }
    for (final entry in pending.entries) {
      if (identical(_pendingPlaybackHistoryTracks[entry.key], entry.value)) {
        _pendingPlaybackHistoryTracks.remove(entry.key);
      }
    }
  }

  Future<void> saveSessionOrder() {
    if (!_persistenceEnabled) return Future<void>.value();
    _pendingSessionOrder = true;
    _service.saveSessionOrderTimer?.cancel();
    _service.saveSessionOrderTimer = null;
    return _enqueueSessionPersistence(_savePendingSessionOrder);
  }

  Future<void> _savePendingSessionOrder() async {
    if (!_persistenceEnabled || !_pendingSessionOrder) return;
    _pendingSessionOrder = false;
    try {
      await databaseRepository.updateSessionOrder(
        List<String>.of(_service.sessionOrder),
      );
      await AppPreferences.remove('session_order_v1');
    } catch (_) {
      _pendingSessionOrder = true;
      rethrow;
    }
  }

  void scheduleSessionStatePersistence({
    String? sessionId,
    Duration delay = const Duration(milliseconds: 220),
  }) {
    if (!_persistenceEnabled) return;
    if (sessionId == null) {
      _pendingSessionDefinitionIds.addAll(_service.sessions.keys);
    } else {
      _pendingSessionDefinitionIds.add(sessionId);
    }
    _service.saveSessionStateTimer?.cancel();
    _service.saveSessionStateTimer = Timer(delay, () {
      _service.saveSessionStateTimer = null;
      unawaited(_enqueueSessionPersistence(_savePendingSessionDefinitions));
    });
  }

  void _scheduleSessionPlaybackStatePersistence(
    String sessionId, {
    Duration delay = const Duration(milliseconds: 800),
  }) {
    if (!_persistenceEnabled ||
        _pendingSessionDefinitionIds.contains(sessionId) ||
        !_service.sessions.containsKey(sessionId)) {
      return;
    }
    _pendingPlaybackStateSessionIds.add(sessionId);
    _savePlaybackStateTimer?.cancel();
    _savePlaybackStateTimer = Timer(delay, () {
      _savePlaybackStateTimer = null;
      unawaited(_enqueueSessionPersistence(_savePendingPlaybackStates));
    });
  }

  void scheduleSessionOrderPersistence({
    Duration delay = const Duration(milliseconds: 180),
  }) {
    if (!_persistenceEnabled) return;
    _pendingSessionOrder = true;
    _service.saveSessionOrderTimer?.cancel();
    _service.saveSessionOrderTimer = Timer(delay, () {
      _service.saveSessionOrderTimer = null;
      unawaited(saveSessionOrder());
    });
  }

  Future<void> flushSessionStatePersistence({String? sessionId}) async {
    if (!_persistenceEnabled) return;
    _service.saveSessionStateTimer?.cancel();
    _service.saveSessionStateTimer = null;
    _service.saveSessionOrderTimer?.cancel();
    _service.saveSessionOrderTimer = null;
    if (sessionId == null) {
      _pendingSessionDefinitionIds.addAll(_service.sessions.keys);
    } else {
      _pendingSessionDefinitionIds.add(sessionId);
    }
    await _enqueueSessionPersistence(() async {
      await _savePendingSessionDefinitions(
        ensurePausedRecoverySessionId: sessionId,
      );
      await _savePendingPlaybackStates();
      await _savePendingSessionOrder();
    });
  }

  void cancelScheduledPersistence() {
    _savePlaybackStateTimer?.cancel();
    _savePlaybackStateTimer = null;
    _pendingPlaybackStateSessionIds.clear();
    _pendingSessionDefinitionIds.clear();
    _pendingDeletedSessionIds.clear();
    _pendingPlaybackHistoryTracks.clear();
    _pendingSessionOrder = false;
    _service.saveSessionStateTimer?.cancel();
    _service.saveSessionStateTimer = null;
    _service.saveSessionOrderTimer?.cancel();
    _service.saveSessionOrderTimer = null;
  }
}
