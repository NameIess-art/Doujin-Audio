part of 'playback_command_coordinator.dart';

extension PlaybackCommandRestore on PlaybackCommandCoordinator {
  Future<void> _restorePersistedRuntime(
    List<PlaybackSession> restoredSessions, {
    required String? focusedSessionId,
  }) async {
    try {
      final initialNativeRuntime = await _applyNativeRuntimeSnapshot(
        syncUi: false,
      );
      if (initialNativeRuntime == null) return;
      final nativeSessionIds = initialNativeRuntime.sessions
          .map((snapshot) => snapshot.sessionId)
          .toSet();
      final nativeFocusedSessionId = initialNativeRuntime.focusedSessionId;
      final effectiveFocusedSessionId =
          nativeFocusedSessionId != null &&
              _sessions.containsKey(nativeFocusedSessionId)
          ? nativeFocusedSessionId
          : focusedSessionId;
      final restoredIds = restoredSessions
          .map((session) => session.id)
          .toList(growable: false);

      for (final id in restoredIds) {
        final session = _sessions[id];
        if (session == null || nativeSessionIds.contains(id)) continue;

        final shouldPrepareNow = id == effectiveFocusedSessionId;
        if (!shouldPrepareNow &&
            !_nativePlaybackRepository.supportsDeferredSessionRegistration) {
          continue;
        }

        try {
          final track = _sessionTrackForPath(session, session.currentTrackPath);
          if (track == null) continue;
          final uri =
              track.path.startsWith('content://') ||
                  PathMatcher.isRemoteUri(track.path)
              ? Uri.parse(track.path)
              : Uri.file(track.path);
          final prepareResult = await _nativePlaybackRepository.prepareSession(
            sessionId: session.id,
            uri: uri,
            title: track.displayName,
            path: track.path,
            subtitle: track.groupTitle,
            startPosition: session.lastKnownPosition,
            volume: session.volume,
            speed: session.speed,
            audioEffects: NativeAudioEffects(
              state: session.audioEffects,
              channelSwapEnabled: session.channelSwapEnabled,
            ),
            repeatOne: session.loopMode == SessionLoopMode.single,
            queue: _nativePlaybackQueueFor(
              session,
              currentPath: session.currentTrackPath,
            ),
            queueStartIndex: _nativePlaybackQueueStartIndexFor(
              session,
              currentPath: session.currentTrackPath,
            ),
            repeatAll:
                session.loopMode != SessionLoopMode.single &&
                !session.loopMode.isOneShot,
            shuffle: session.loopMode.isShuffle,
            candidateUris: _candidatePlaybackUrisForTrack(track),
            deferPlayerCreation: !shouldPrepareNow,
          );
          if (!prepareResult.isOk) continue;
          final preparedSnapshot = prepareResult.valueOrNull;
          if (preparedSnapshot != null) {
            _handleNativePlaybackSnapshot(preparedSnapshot);
          }
          session.loadedPath = track.path;
          _ensureSubtitleTrackLoaded(track.path);
          _refreshNotificationSubtitleForSession(
            session,
            position: session.lastKnownPosition,
            syncNotification: false,
          );
        } catch (error, stackTrace) {
          _logRestoreFailure(error, stackTrace);
        }
      }

      await _applyNativeRuntimeSnapshot(syncUi: false);
      _syncNotificationState(immediateUnifiedSync: true);
      if (_sessions.isNotEmpty) _notifyPlaybackChanged();
    } catch (error, stackTrace) {
      _logRestoreFailure(error, stackTrace);
    }
  }

  Future<void> _reconcileNativeRuntime() async {
    await _applyNativeRuntimeSnapshot(syncUi: true);
  }

  Future<NativePlaybackBundleSnapshot?> _applyNativeRuntimeSnapshot({
    required bool syncUi,
  }) async {
    final response = await _nativePlaybackRepository.snapshot();
    final bundle = response.valueOrNull;
    if (bundle == null) {
      AppLogService.warning(
        'native_playback_snapshot_failed '
        'code=${response.errorCodeOrNull} error=${response.errorOrNull}',
      );
      return null;
    }
    for (final snapshot in bundle.sessions) {
      if (!_sessions.containsKey(snapshot.sessionId)) {
        AppLogService.warning(
          'native_playback_unmatched_session_preserved '
          'sessionId=${snapshot.sessionId}',
        );
        continue;
      }
      _handleNativePlaybackSnapshot(snapshot);
    }
    final focusedSessionId = bundle.focusedSessionId;
    if (focusedSessionId != null && _sessions.containsKey(focusedSessionId)) {
      _notificationFacade.setFocusedSession(focusedSessionId);
    }
    if (syncUi) {
      _syncNotificationState(immediateUnifiedSync: true);
      if (_sessions.isNotEmpty) _notifyPlaybackChanged();
    }
    return bundle;
  }

  void _logRestoreFailure(Object error, StackTrace stackTrace) {
    AppLogService.error(
      'playback_runtime_restore_failed',
      error: error,
      stackTrace: stackTrace,
    );
  }
}
