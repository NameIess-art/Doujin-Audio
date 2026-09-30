part of 'playback_facade.dart';

final class PlaybackNativeSnapshotApplication {
  const PlaybackNativeSnapshotApplication({
    required this.snapshot,
    required this.session,
    required this.previousTrackPath,
    required this.trackChanged,
    required this.playbackIntentChanged,
  });

  const PlaybackNativeSnapshotApplication.notApplied(this.snapshot)
    : session = null,
      previousTrackPath = null,
      trackChanged = false,
      playbackIntentChanged = false;

  final NativePlaybackSnapshot snapshot;
  final PlaybackSession? session;
  final String? previousTrackPath;
  final bool trackChanged;
  final bool playbackIntentChanged;

  bool get applied => session != null;
}

extension PlaybackNativeStateCoordinator on PlaybackFacade {
  void _bindSessionListeners(PlaybackSession session) {
    final stateSub = session.stateStream.listen((state) {
      if (!_service.sessions.containsKey(session.id)) return;

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
          !session.loopMode.isOneShot &&
          !session.isLoading &&
          !session.isAdvancingAfterCompletion &&
          session.playbackError == null &&
          _commandPort?.resolveAdvance(session, forward: true) != null &&
          session.lastHandledCompletionGeneration != currentGeneration;
      if (shouldAutoAdvanceAfterCompletion) {
        session.beginCompletionAdvance(
          commandGeneration: currentGeneration,
          markHandled: true,
        );
      }
      session.reconcilePlaybackState();
      _onRuntimeStateChanged?.call();
      _onSessionStateChanged?.call();

      if (previousPlaying != state.playing ||
          previousProcessing != state.processingState) {
        scheduleSessionStatePersistence();
      }

      if (isNewCompletion && shouldAutoAdvanceAfterCompletion) {
        _dispatchSessionCompleted(session.id);
      }
    });
    session.subscriptions.add(stateSub);

    final positionSub = session.positionStream.listen((position) {
      if (!_service.sessions.containsKey(session.id)) return;
      session.lastKnownPosition = position;
      final bucket = position.inSeconds ~/ positionBucketSeconds;
      if (bucket != session.lastPersistedPositionBucket) {
        session.lastPersistedPositionBucket = bucket;
        _scheduleSessionPlaybackStatePersistence(session.id);
      }
      _onSessionPositionChanged?.call(session, position);
    });
    session.subscriptions.add(positionSub);

    final durationSub = session.durationStream.listen((_) {
      if (!_service.sessions.containsKey(session.id)) return;
      _scheduleSessionPlaybackStatePersistence(
        session.id,
        delay: const Duration(milliseconds: 1500),
      );
      _onSessionDurationChanged?.call(session.id);
    });
    session.subscriptions.add(durationSub);
  }

  void _dispatchSessionCompleted(String sessionId) {
    final callback = _onSessionCompleted;
    final session = _service.sessions[sessionId];
    if (callback == null || session == null) return;
    final commandGeneration = session.playbackCommandGeneration;
    final preparationGeneration = session.loadGeneration;
    unawaited(() async {
      try {
        await callback(sessionId);
      } catch (error, stackTrace) {
        if (isRegisteredSession(session) &&
            session.finishCompletionAdvance(
              commandGeneration: commandGeneration,
              preparationGeneration: preparationGeneration,
              error: error.toString(),
            )) {
          _onRuntimeStateChanged?.call();
          _onSessionStateChanged?.call();
        }
        AppLogService.error(
          'PlaybackFacade.sessionCompleted error',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }());
  }

  void updateNativeSessionRetainedContentUris(
    String sessionId,
    Iterable<String> retainedUris,
  ) {
    final next = retainedUris.where(PathMatcher.isContentUri).toSet();
    final previous = _nativeRetainedContentUrisBySession[sessionId];
    if (previous != null &&
        previous.length == next.length &&
        previous.containsAll(next)) {
      return;
    }
    if (next.isEmpty) {
      _nativeRetainedContentUrisBySession.remove(sessionId);
    } else {
      _nativeRetainedContentUrisBySession[sessionId] = Set.unmodifiable(next);
    }
    _nativePersistedUriReferenceRevision += 1;
    _persistedUriReferenceRevisionController.add(persistedUriReferenceRevision);
  }

  void replaceNativeRetainedContentUris(
    Iterable<NativePlaybackSnapshot> snapshots,
  ) {
    final next = <String, Set<String>>{
      for (final snapshot in snapshots)
        if (snapshot.retainedUris.where(PathMatcher.isContentUri).isNotEmpty)
          snapshot.sessionId: snapshot.retainedUris
              .where(PathMatcher.isContentUri)
              .toSet(),
    };
    var changed =
        !_nativeRetainedContentUriInventoryReady ||
        next.length != _nativeRetainedContentUrisBySession.length;
    if (!changed) {
      for (final entry in next.entries) {
        final previous = _nativeRetainedContentUrisBySession[entry.key];
        if (previous == null ||
            previous.length != entry.value.length ||
            !previous.containsAll(entry.value)) {
          changed = true;
          break;
        }
      }
    }
    if (!changed) return;
    _nativeRetainedContentUriInventoryReady = true;
    _nativeRetainedContentUrisBySession
      ..clear()
      ..addAll(
        next.map((key, value) => MapEntry(key, Set.unmodifiable(value))),
      );
    _nativePersistedUriReferenceRevision += 1;
    _persistedUriReferenceRevisionController.add(persistedUriReferenceRevision);
  }

  Future<bool> refreshNativeRetainedContentUriInventory() async {
    final response = await nativeRepository.snapshot();
    final bundle = response.valueOrNull;
    if (bundle == null) return false;
    replaceNativeRetainedContentUris(bundle.sessions);
    return true;
  }

  void _removeNativeRetainedContentUris(Iterable<String> sessionIds) {
    var changed = false;
    for (final sessionId in sessionIds) {
      changed =
          _nativeRetainedContentUrisBySession.remove(sessionId) != null ||
          changed;
    }
    if (!changed) return;
    _nativePersistedUriReferenceRevision += 1;
    _persistedUriReferenceRevisionController.add(persistedUriReferenceRevision);
  }

  void forgetNativeSessionRetainedContentUris(String sessionId) {
    _removeNativeRetainedContentUris(<String>[sessionId]);
  }

  void _clearNativeRetainedContentUris() {
    final changed =
        !_nativeRetainedContentUriInventoryReady ||
        _nativeRetainedContentUrisBySession.isNotEmpty;
    _nativeRetainedContentUriInventoryReady = true;
    _nativeRetainedContentUrisBySession.clear();
    if (!changed) return;
    _nativePersistedUriReferenceRevision += 1;
    _persistedUriReferenceRevisionController.add(persistedUriReferenceRevision);
  }

  Future<void> get pendingSessionPreparation =>
      _service.sessionPreparationQueue;
  bool get hasScheduledSessionStatePersistence =>
      _service.saveSessionStateTimer != null;
  bool get hasScheduledSessionOrderPersistence =>
      _service.saveSessionOrderTimer != null;
  PlaybackSession? sessionById(String sessionId) =>
      _service.sessionById(sessionId);
  List<PlaybackSession> get ordinarySessions => _service.activeSessions
      .where((session) => !session.isPlaybackQueue)
      .toList(growable: false);

  int nextTransportCommandId() => ++_transportCommandSequence;

  bool isRegisteredSession(PlaybackSession session) =>
      !session.isDisposed && identical(_service.sessions[session.id], session);

  void markSessionStateDirty() => _service.markActiveSessionsDirty();

  void syncPresentationState({
    required String? focusedSessionId,
    required int coverGeneration,
    bool? isInitialized,
  }) {
    _service.markSessionStateDirty();
    final current = _service.slice.state;
    _service.syncSlice(
      activeSessions: _service.activeSessions,
      playingSessionCount: _service.playingSessionCount,
      focusedSessionId: focusedSessionId,
      coverGeneration: coverGeneration,
      isInitialized: isInitialized ?? current.isInitialized,
    );
  }

  Future<void> removeSessionsForTrackPaths(Iterable<String> trackPaths) async {
    final removedPaths = trackPaths.toSet();
    final sessionIds = _service.sessions.values
        .where((session) => removedPaths.contains(session.currentTrackPath))
        .map((session) => session.id)
        .toList(growable: false);
    if (sessionIds.isEmpty) return;
    await removeSessions(sessionIds, persist: false, notify: false);
  }

  void applyFadeMultiplierToPlayingSessions(double multiplier) {
    for (final session in _service.sessions.values) {
      if (!session.state.playing) continue;
      unawaited(nativeRepository.setFadeMultiplier(session.id, multiplier));
    }
  }

  void observeTransportCommandId(int? commandId) {
    if (commandId != null && commandId > _transportCommandSequence) {
      _transportCommandSequence = commandId;
    }
  }

  void applyNativeProgress(NativePlaybackProgressUpdate progress) {
    if (_service.sessions[progress.sessionId]?.pendingNativeTrackPath != null) {
      return;
    }
    _service.applyNativeProgress(progress);
  }

  PlaybackNativeSnapshotApplication applyNativeSnapshot(
    NativePlaybackSnapshot snapshot, {
    required bool Function(String path) hasLibraryTrack,
  }) {
    observeTransportCommandId(snapshot.transportCommandId);
    final normalized = _normalizeNativeSnapshot(
      snapshot,
      hasLibraryTrack: hasLibraryTrack,
    );
    final session = _service.sessions[normalized.sessionId];
    if (session == null || session.pendingNativeTrackPath != null) {
      return PlaybackNativeSnapshotApplication.notApplied(normalized);
    }
    final previousTrackPath = session.currentTrackPath;
    final previousState = session.state;
    final previousIsPlaybackStarting = session.isPlaybackStarting;
    final previousPendingPlayingIntent = session.pendingPlayingIntent;
    if (!_service.applyNativeSnapshot(normalized)) {
      return PlaybackNativeSnapshotApplication.notApplied(normalized);
    }
    return PlaybackNativeSnapshotApplication(
      snapshot: normalized,
      session: session,
      previousTrackPath: previousTrackPath,
      trackChanged: session.currentTrackPath != previousTrackPath,
      playbackIntentChanged:
          session.state == previousState &&
          (session.isPlaybackStarting != previousIsPlaybackStarting ||
              session.pendingPlayingIntent != previousPendingPlayingIntent),
    );
  }

  NativePlaybackSnapshot _normalizeNativeSnapshot(
    NativePlaybackSnapshot snapshot, {
    required bool Function(String path) hasLibraryTrack,
  }) {
    final rawPath = snapshot.path ?? _pathFromSnapshotUri(snapshot.uri);
    if (rawPath == null || rawPath.isEmpty) return snapshot;
    final resolvedPath = resolveRetargetedPath(rawPath);
    final currentSession = _service.sessions[snapshot.sessionId];
    final currentSessionPath = currentSession?.currentTrackPath;
    if (currentSession != null &&
        currentSessionPath != null &&
        currentSessionPath.isNotEmpty &&
        PathMatcher.equalsNormalized(resolvedPath, rawPath)) {
      final originalTrack = _sessionTrackForResolvedPath(
        currentSession,
        resolvedPath,
      );
      if (originalTrack != null &&
          PathMatcher.equalsNormalized(
            resolveRetargetedPath(originalTrack.path),
            resolvedPath,
          )) {
        return snapshot.copyWith(
          path: originalTrack.path,
          uri: _snapshotUriForPath(originalTrack.path),
        );
      }
    }
    if (!PathMatcher.equalsNormalized(resolvedPath, rawPath)) {
      return snapshot.copyWith(
        path: resolvedPath,
        uri: _snapshotUriForPath(resolvedPath),
      );
    }
    if (currentSessionPath == null || currentSessionPath.isEmpty) {
      return snapshot;
    }
    final resolvedSessionPath = resolveRetargetedPath(currentSessionPath);
    if (PathMatcher.equalsNormalized(resolvedSessionPath, resolvedPath) ||
        hasLibraryTrack(resolvedPath) ||
        !hasLibraryTrack(resolvedSessionPath)) {
      return snapshot;
    }
    return snapshot.copyWith(
      path: resolvedSessionPath,
      uri: _snapshotUriForPath(resolvedSessionPath),
    );
  }

  MusicTrack? _sessionTrackForResolvedPath(
    PlaybackSession session,
    String resolvedPath,
  ) {
    final track = session.trackForPath(resolvedPath);
    if (track != null) return track;
    final originalPath = originalPathForRetargeted(resolvedPath);
    if (originalPath != null) {
      return session.trackForPath(originalPath);
    }
    return null;
  }

  String _snapshotUriForPath(String value) {
    if (PathMatcher.isContentUri(value) || PathMatcher.isRemoteUri(value)) {
      return value;
    }
    return Uri.file(value).toString();
  }

  String? _pathFromSnapshotUri(String? value) {
    if (value == null || value.isEmpty) return null;
    final uri = Uri.tryParse(value);
    if (uri == null) return value;
    if (uri.scheme == 'file') {
      return uri.toFilePath();
    }
    if (uri.scheme == 'content' ||
        uri.scheme == 'http' ||
        uri.scheme == 'https') {
      return value;
    }
    return null;
  }

  void publishSessionActivated(String sessionId) {
    if (sessionId.isEmpty || _sessionActivations.isClosed) return;
    _sessionActivations.add(sessionId);
  }
}
